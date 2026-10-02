"""LocalShelf Sync receiver. Standard library only; TLS required for uploads."""
import argparse
import errno
import hashlib
import hmac
import json
import os
from pathlib import Path, PurePosixPath
import re
import secrets
import socket
import shutil
import sqlite3
import ssl
import subprocess
import threading
import time
from contextlib import contextmanager
from collections import OrderedDict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

CHUNK = 4 * 1024 * 1024
BATCH_FILES = 64
BATCH_BYTES = 16 * 1024 * 1024
BATCH_HEADER = 512 * 1024
MAX_FILE = 8 * 1024**3
LOCK = threading.RLock()
UPLOAD_LOCKS = [threading.RLock() for _ in range(64)]
METRICS_LOCK = threading.Lock()
METRICS = {}
POST_SLOTS = threading.BoundedSemaphore(4)


def measure(name, started):
    with METRICS_LOCK:
        item = METRICS.setdefault(name, {"calls": 0, "seconds": 0.0})
        item["calls"] += 1
        item["seconds"] += time.perf_counter() - started


def metrics_snapshot():
    with METRICS_LOCK:
        return {k: dict(v) for k, v in METRICS.items()}


@contextmanager
def database_lock():
    started = time.perf_counter()
    with LOCK:
        measure("databaseWait", started)
        yield


def upload_lock(root, key):
    # Fixed-size stripes bound memory; collisions only reduce concurrency.
    index = int(hashlib.sha256((str(root) + str(key)).encode()).hexdigest()[:8], 16)
    return UPLOAD_LOCKS[index % len(UPLOAD_LOCKS)]


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


def component(value):
    if not isinstance(value, str) or not value or value in (".", "..") or any(ord(c) < 32 for c in value) or any(c in value for c in "/\\") or len(value.encode()) > 255:
        raise ValueError("invalid_name")
    return value


def relative(value):
    if not isinstance(value, str) or len(value) > 2048:
        raise ValueError("invalid_path")
    for part in value.split("/"):
        component(part)
    return value


def validate_catalog(cat):
    if cat.get("schema") != 1 or cat.get("orderSource") != "ehviewer-downloads-time-desc" or cat.get("orderVerified") is not True:
        raise ValueError("order_not_verified")
    books = cat.get("books")
    if not isinstance(books, list) or not 0 < len(books) <= 20000:
        raise ValueError("invalid_book_count")
    ids, dirs, groups = set(), set(), {}
    previous = None
    for rank, b in enumerate(books):
        gid = b.get("id")
        if not isinstance(gid, str) or not re.fullmatch(r"[1-9][0-9]{0,18}", gid) or gid in ids:
            raise ValueError("duplicate_or_invalid_id")
        directory = component(b.get("directory"))
        if directory in dirs or type(b.get("rank")) is not int or b["rank"] != rank or not isinstance(b.get("title"), str) or not b["title"].strip():
            raise ValueError("invalid_rank_or_directory")
        time = b.get("time")
        if type(time) is not int or (previous is not None and time > previous):
            raise ValueError("not_download_order")
        previous = time
        ids.add(gid)
        dirs.add(directory)
        groups.setdefault(str(time), []).append(gid)
    for time, group in groups.items():
        if len(group) > 1 and cat.get("resolvedTies", {}).get(time) != group:
            raise ValueError("ambiguous_download_order")
    return books


class Store:
    def __init__(self, root, reserve_bytes=10 * 1024**3, reserve_percent=2,
                 warning_bytes=50 * 1024**3, warning_percent=10):
        import math
        if (type(reserve_bytes) is not int or type(warning_bytes) is not int or
            not 0 <= reserve_bytes <= warning_bytes or
            not all(math.isfinite(v) for v in (reserve_percent, warning_percent)) or
            not 0 <= reserve_percent <= warning_percent < 100):
            raise ValueError("invalid_space_policy")
        self.reserve_bytes, self.reserve_percent = reserve_bytes, reserve_percent
        self.warning_bytes, self.warning_percent = warning_bytes, warning_percent
        self.root = Path(root).resolve()
        self.pending_space = [0]
        for folder in ("books", "partial", "config"):
            (self.root / folder).mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(self.root / "index.sqlite3", check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.cache = OrderedDict()
        self.db.executescript("""
          PRAGMA journal_mode=WAL;
          PRAGMA synchronous=FULL;
          CREATE TABLE IF NOT EXISTS catalogs(revision TEXT PRIMARY KEY, body TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY,value TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS uploads(id TEXT PRIMARY KEY,revision TEXT,gid TEXT,path TEXT,size INTEGER,sha TEXT);
          CREATE TABLE IF NOT EXISTS files(gid TEXT,path TEXT,directory TEXT,size INTEGER,sha TEXT,mtime INTEGER,PRIMARY KEY(gid,path));
          CREATE TABLE IF NOT EXISTS ready(revision TEXT,gid TEXT,available INTEGER,PRIMARY KEY(revision,gid));
          CREATE TABLE IF NOT EXISTS directory_owners(directory TEXT PRIMARY KEY,gid TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS book_versions(gid TEXT PRIMARY KEY,directory TEXT,proof TEXT,available INTEGER);
          CREATE TABLE IF NOT EXISTS book_locations(gid TEXT PRIMARY KEY,directory TEXT UNIQUE NOT NULL);
          CREATE TABLE IF NOT EXISTS retained_files(gid TEXT,path TEXT,directory TEXT,size INTEGER,sha TEXT,mtime INTEGER,PRIMARY KEY(gid,path,sha));
        """)
        # Backfill once, atomically with the marker, including pre-upgrade unfinished uploads.
        if not self.db.execute("SELECT 1 FROM state WHERE key='owners_v1'").fetchone():
            with self.db:
                self.db.execute("INSERT OR IGNORE INTO directory_owners SELECT DISTINCT directory,gid FROM files")
                self.db.execute("INSERT INTO state VALUES('owners_v1','1')")

    def space(self):
        usage = shutil.disk_usage(self.root)
        reserve = max(self.reserve_bytes, int(usage.total * self.reserve_percent / 100))
        warning = max(self.warning_bytes, int(usage.total * self.warning_percent / 100))
        return {"totalBytes": usage.total, "freeBytes": usage.free,
                "reserveBytes": reserve, "warningBytes": warning,
                "availableForSyncBytes": max(0, usage.free - reserve),
                "spaceWarning": usage.free < warning}

    def require_space(self, incoming):
        space = self.space()
        if space["freeBytes"] < space["reserveBytes"] + incoming + self.pending_space[0]:
            raise ValueError("nas_space_insufficient")

    def extra(self):
        if not hasattr(self, "_extra"):
            if (self.root / "archive").is_symlink():
                raise ValueError("symlink_not_allowed")
            self._extra = ArchiveStore(self.root / "archive", self.reserve_bytes, self.reserve_percent,
                                       self.warning_bytes, self.warning_percent)
            self._extra.pending_space = self.pending_space
        return self._extra

    def close(self):
        if hasattr(self, "_extra"):
            self._extra.close()
        self.db.close()

    def stage_archive(self, manifest):
        known = {b.get("sourceDirectory", b["directory"]) for b in self.catalog(manifest["sourceRevision"])["books"]}
        if any(g.get("kind") == "directory" and g.get("name") in known for g in manifest["groups"]):
            raise ValueError("archive_contains_ordered_directory")
        return self.extra().stage(manifest)

    def catalog(self, revision):
        if revision in self.cache:
            self.cache.move_to_end(revision)
            return self.cache[revision][0]
        row = self.db.execute("SELECT body FROM catalogs WHERE revision=?", (revision,)).fetchone()
        if not row:
            raise ValueError("catalog_not_found")
        cat = json.loads(row[0])
        self.cache[revision] = (cat, {b["id"]: b for b in cat["books"]})
        while len(self.cache) > 4:
            self.cache.popitem(last=False)
        return cat

    def book(self, revision, gid):
        self.catalog(revision)
        book = self.cache[revision][1].get(gid)
        if book is None:
            raise ValueError("book_not_in_catalog")
        return book

    def destination(self, directory, path):
        component(directory)
        relative(path)
        base = self.root / "books"
        result = base / directory / path
        # NAS managed tree must contain no symlinks, including leaf and ancestors.
        current = base
        for piece in (directory, *path.split("/")):
            current = current / piece
            if current.is_symlink():
                raise ValueError("symlink_not_allowed")
        if not result.resolve().is_relative_to(base.resolve()):
            raise ValueError("invalid_path")
        return result

    def active(self):
        row = self.db.execute("SELECT value FROM state WHERE key='active' ").fetchone()
        return row[0] if row else None

    def valid_file(self, gid, path, size, sha, directory):
        row = self.db.execute("SELECT * FROM files WHERE gid=? AND path=?", (gid, path)).fetchone()
        target = self.destination(directory, path)
        if not row or row["directory"] != directory or row["size"] != size or row["sha"] != sha or not target.is_file():
            return False
        st = target.stat()
        if st.st_size != size:
            return False
        if st.st_mtime_ns != row["mtime"]:
            return digest(target) == sha
        return True

    def daily_stage(self, source):
        """Publish latest order without deleting omitted books or reassigning old data.

        Phone directory and NAS storage directory are separate identities. In
        particular a new gallery ID may reuse an old EhViewer download folder.
        This operation reads/writes catalog metadata only, never media files.
        """
        missing_source = source.get("missingSourceIds", [])
        source = {k: v for k, v in source.items() if k != "missingSourceIds"}
        books = validate_catalog(source)
        if not isinstance(missing_source, list) or not all(isinstance(gid, str) for gid in missing_source) or len(set(missing_source)) != len(missing_source) or not set(missing_source) <= {b['id'] for b in books}:
            raise ValueError("invalid_missing_source_ids")
        owners = dict(self.db.execute("SELECT directory,gid FROM directory_owners"))
        locations = dict(self.db.execute("SELECT gid,directory FROM book_locations"))
        # Includes historical and uploaded-but-not-published books, not just active ones.
        for directory, gid in owners.items():
            if gid in locations and locations[gid] != directory:
                raise ValueError("existing_directory_changed")
            locations[gid] = directory
        previous = self.catalog(self.active())["books"] if self.active() else []
        for book in previous:
            locations.setdefault(book["id"], book["directory"])
        occupied = {directory: gid for gid, directory in locations.items()}
        planned = []
        for book in books:
            gid, phone = book["id"], book["directory"]
            directory = locations.get(gid)
            if directory is None:
                directory = phone
                if directory in occupied or (self.root / "books" / directory).exists():
                    directory = "LocalShelf-version-" + gid + "-" + hashlib.sha256(phone.encode()).hexdigest()[:16]
                if directory in occupied or (self.root / "books" / directory).exists():
                    raise ValueError("version_directory_conflict")
                locations[gid] = directory
                occupied[directory] = gid
            planned.append({**book, "directory": directory, "sourceDirectory": phone})
        cat = {**source, "books": planned, "retentionPolicy": "keep-omitted-files-v1"}
        # stage still validates order, directory ownership and stable existing IDs.
        staged = self.stage(cat)
        with self.db:
            self.db.executemany("INSERT OR IGNORE INTO book_locations VALUES(?,?)", locations.items())
            if missing_source:
                old_ready = dict(self.db.execute("SELECT gid,available FROM book_versions"))
                old_ready.update(dict(self.db.execute("SELECT gid,available FROM ready WHERE revision=?", (self.active(),))))
                self.db.executemany("INSERT OR REPLACE INTO ready VALUES(?,?,?)",
                                    [(staged['revision'],gid,int(bool(old_ready.get(gid, 0)))) for gid in missing_source])
        staged['readyIds'] = [r[0] for r in self.db.execute("SELECT gid FROM ready WHERE revision=?", (staged['revision'],))]
        missing = {b['id'] for b in previous} - {b['id'] for b in books}
        return {**staged, "catalog": cat, "retainedBooks": len(missing), "missingSourceIds": missing_source}

    def stage(self, cat):
        books = validate_catalog(cat)
        # Also protect uploaded but not yet published folders from reassignment.
        owners = dict(self.db.execute("SELECT directory,gid FROM directory_owners"))
        for book in books:
            if book["directory"] in owners and owners[book["directory"]] != book["id"]:
                raise ValueError("directory_owned_by_another_book")
        old = self.active()
        if old:
            old_books = self.catalog(old)["books"]
            new_by_id = {b["id"]: b for b in books}
            retain = cat.get("retentionPolicy") == "keep-omitted-files-v1"
            if any(b["id"] not in new_by_id for b in old_books) and not retain:
                raise ValueError("backup_omits_existing_books_use_complete_backup")
            if any(b["id"] in new_by_id and b["directory"] != new_by_id[b["id"]]["directory"] for b in old_books):
                raise ValueError("existing_directory_changed")
        body = encoded(cat)
        revision = hashlib.sha256(body).hexdigest()
        self.db.execute("INSERT OR IGNORE INTO catalogs VALUES(?,?)", (revision, body.decode()))
        self.db.commit()
        return {"revision": revision, "readyIds": [r[0] for r in self.db.execute("SELECT gid FROM ready WHERE revision=?", (revision,))]}

    def begin(self, data):
        key = hashlib.sha256(encoded([data["revision"], data["gid"], data["path"], data["size"], data["sha256"]])).hexdigest()
        with upload_lock(self.root, key), database_lock(), self.db:
            return self._begin(data)

    def _begin(self, data):
        revision, gid, path = data["revision"], data["gid"], relative(data["path"])
        book = self.book(revision, gid)
        size, sha = data["size"], data["sha256"]
        if type(size) is not int or not 0 <= size <= MAX_FILE or not isinstance(sha, str) or not re.fullmatch("[a-f0-9]{64}", sha):
            raise ValueError("invalid_file")
        if self.valid_file(gid, path, size, sha, book["directory"]):
            return {"done": True, "offset": size}
        key = hashlib.sha256(encoded([revision, gid, path, size, sha])).hexdigest()
        part = self.root / "partial" / key
        if part.exists() and part.stat().st_size > size:
            part.unlink()
        offset = part.stat().st_size if part.exists() else 0
        self.require_space(size - offset)
        self.db.execute("INSERT OR IGNORE INTO uploads VALUES(?,?,?,?,?,?)", (key, revision, gid, path, size, sha))
        self.db.commit()
        return {"done": False, "upload": key, "offset": offset, "chunkSize": CHUNK}

    def file_status(self, data):
        book = self.book(data["revision"], data["gid"])
        files = data["files"]
        if not isinstance(files, list) or len(files) > 100000:
            raise ValueError("invalid_inventory")
        missing = []
        seen = set()
        for file in files:
            path = relative(file["path"])
            if path in seen:
                raise ValueError("duplicate_file")
            seen.add(path)
            if not self.valid_file(book["id"], path, file["size"], file["sha256"], book["directory"]):
                missing.append(path)
        return {"missing": missing}

    def batch(self, raw):
        """Bounded, uncompressed frames; keep existing per-file durable receipts.

        Wire: uint32 big-endian JSON length, UTF-8 metadata, concatenated bytes.
        Validate the entire frame before writing; a disk/network failure can still
        finish a prefix of files. Retries are idempotent and never publish a book.
        """
        if not 4 < len(raw) <= 4 + BATCH_HEADER + BATCH_BYTES:
            raise ValueError("invalid_batch")
        header_size = int.from_bytes(raw[:4], "big")
        if not 0 < header_size <= BATCH_HEADER or 4 + header_size > len(raw):
            raise ValueError("invalid_batch")
        data = json.loads(raw[4:4 + header_size])
        if not isinstance(data, dict) or not isinstance(data.get("files"), list) or not 1 <= len(data["files"]) <= BATCH_FILES:
            raise ValueError("invalid_batch")
        payload = memoryview(raw)[4 + header_size:]
        if len(payload) > BATCH_BYTES:
            raise ValueError("invalid_batch")
        with database_lock():
            book = self.book(data["revision"], data["gid"])
            for item in data["files"]:
                if not isinstance(item, dict):
                    raise ValueError("invalid_batch")
                self.destination(book["directory"], relative(item["path"]))
        started = time.perf_counter()
        specs = []
        offset = 0
        seen = set()
        for item in data["files"]:
            path, size, sha = relative(item["path"]), item["size"], item["sha256"]
            if path in seen or type(size) is not int or not 0 <= size <= CHUNK or not isinstance(sha, str) or not re.fullmatch("[a-f0-9]{64}", sha):
                raise ValueError("invalid_batch_file")
            seen.add(path)
            end = offset + size
            if end > len(payload) or hashlib.sha256(payload[offset:end]).hexdigest() != sha:
                raise ValueError("hash_mismatch_source_may_be_changing")
            specs.append(({"revision": data["revision"], "gid": data["gid"], "path": path, "size": size, "sha256": sha}, offset))
            offset = end
        if offset != len(payload):
            raise ValueError("invalid_batch_length")
        measure("batchValidation", started)
        for spec, offset in specs:
            # Same locks, SHA-256 re-read, fsync, atomic rename and SQLite FULL
            # as the resumable protocol. Do not acknowledge merely buffered data.
            begin = self.begin(spec)
            if not begin["done"]:
                remaining = spec["size"] - begin["offset"]
                if remaining:
                    self.chunk(begin["upload"], begin["offset"], payload[offset + begin["offset"]:offset + spec["size"]])
                self.finish(begin["upload"])
        return {"confirmedFiles": len(specs), "confirmedBytes": len(payload)}

    def chunk(self, key, offset, body):
        with upload_lock(self.root, key):
            with database_lock():
                row = self.db.execute("SELECT * FROM uploads WHERE id=?", (key,)).fetchone()
                if not row:
                    raise ValueError("upload_not_found")
                part = self.root / "partial" / row["id"]
                current = part.stat().st_size if part.exists() else 0
                if offset != current or not body or len(body) > CHUNK or current + len(body) > row["size"]:
                    raise ValueError("offset_conflict")
                self.require_space(len(body))
                self.pending_space[0] += len(body)
            started = time.perf_counter()
            try:
                with part.open("ab") as f:
                    f.write(body)
                    f.flush()
                    os.fsync(f.fileno())
            finally:
                measure("writeAndSync", started)
                with database_lock():
                    self.pending_space[0] -= len(body)
            return {"offset": current + len(body)}

    def finish(self, key):
        with upload_lock(self.root, key):
            with database_lock():
                row = self.db.execute("SELECT * FROM uploads WHERE id=?", (key,)).fetchone()
                if not row:
                    raise ValueError("upload_not_found")
                book = self.book(row["revision"], row["gid"])
                if self.valid_file(row["gid"], row["path"], row["size"], row["sha"], book["directory"]):
                    return {"done": True}
            part = self.root / "partial" / row["id"]
            if row["size"] == 0:
                with part.open("ab") as f:
                    os.fsync(f.fileno())
            if not part.exists() or part.stat().st_size != row["size"]:
                raise ValueError("file_incomplete")
            started = time.perf_counter()
            try:
                if digest(part) != row["sha"]:
                    part.unlink()
                    raise ValueError("hash_mismatch_source_may_be_changing")
            finally:
                measure("fileHash", started)
            with part.open("rb") as f:
                os.fsync(f.fileno())
            # Target replacement and SQLite/cache access remain serialized.
            with database_lock(), self.db:
                return self._finish_verified(row, book, part)

    def _finish_verified(self, row, book, part):
        owner = self.db.execute("SELECT gid FROM directory_owners WHERE directory=?", (book["directory"],)).fetchone()
        if owner and owner["gid"] != row["gid"]:
            raise ValueError("directory_owned_by_another_book")
        # An interrupted update must never leave an old successful-book receipt reusable.
        with self.db:
            self.db.execute("DELETE FROM book_versions WHERE gid=?", (row["gid"],))
        target = self.destination(book["directory"], row["path"])
        target.parent.mkdir(parents=True, exist_ok=True)
        os.replace(part, target)
        fd = os.open(target.parent, os.O_RDONLY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        self.db.execute("INSERT OR REPLACE INTO files VALUES(?,?,?,?,?,?)", (row["gid"], row["path"], book["directory"], row["size"], row["sha"], target.stat().st_mtime_ns))
        self.db.execute("INSERT OR IGNORE INTO directory_owners VALUES(?,?)", (book["directory"], row["gid"]))
        self.db.commit()
        return {"done": True}

    def book_commit(self, data):
        book = self.book(data["revision"], data["gid"])
        files = data["files"]
        if not isinstance(files, list) or len(files) > 100000:
            raise ValueError("invalid_inventory")
        seen = set()
        for file in files:
            path = relative(file["path"])
            if path in seen or not self.valid_file(book["id"], path, file["size"], file["sha256"], book["directory"]):
                raise ValueError("inventory_not_complete")
            seen.add(path)
        pages = [p for p in seen if re.fullmatch(r"[0-9]{8}\.(jpg|jpeg|png|webp|gif|avif)", p, re.I)]
        # Backup identity is the complete relative path, not the numeric page.
        # EhViewer directories can contain multiple encodings of the same page.
        # Preserve and verify all of them; selecting a reading variant belongs
        # to the reader and must never block a lossless backup or drop a file.
        # Missing phone folders keep their position and any previously received NAS pages.
        available = bool(pages)
        if not files:
            for row in self.db.execute("SELECT * FROM files WHERE gid=?", (book["id"],)).fetchall():
                if re.fullmatch(r"[0-9]{8}\.(jpg|jpeg|png|webp|gif|avif)", row["path"], re.I) and self.valid_file(book["id"], row["path"], row["size"], row["sha"], book["directory"]):
                    available = True
                    break
        self.db.execute("INSERT OR REPLACE INTO ready VALUES(?,?,?)", (data["revision"], book["id"], int(available)))
        proof = None
        if files and available:
            inventory = sorted([[f["path"], f["size"], f["sha256"]] for f in files])
            proof = hashlib.sha256(encoded([book["id"], book["directory"], inventory])).hexdigest()
            self.db.execute("INSERT OR REPLACE INTO book_versions VALUES(?,?,?,?)", (book["id"], book["directory"], proof, int(available)))
            if self.catalog(data["revision"]).get("retentionPolicy") == "keep-omitted-files-v1":
                # Exclude obsolete pages/encodings from the current reader index.
                # Keep both their physical files and their metadata for recovery.
                retired = [r for r in self.db.execute("SELECT * FROM files WHERE gid=?", (book["id"],)) if r['path'] not in seen]
                self.db.executemany("INSERT OR REPLACE INTO retained_files VALUES(?,?,?,?,?,?)",
                                    [(r['gid'],r['path'],r['directory'],r['size'],r['sha'],r['mtime']) for r in retired])
                self.db.executemany("DELETE FROM files WHERE gid=? AND path=?", [(r['gid'],r['path']) for r in retired])
        else:
            self.db.execute("DELETE FROM book_versions WHERE gid=?", (book["id"],))
        self.db.commit()
        return {"verifiedFiles": len(files), "proof": proof}

    def reuse(self, data):
        """Explicit new-only mode: reuse previous receipts, without auditing old files."""
        self.catalog(data["revision"])
        requested = data["books"]
        if not isinstance(requested, list) or len(requested) > 20000:
            raise ValueError("invalid_reuse_list")
        versions = {r["gid"]: r for r in self.db.execute("SELECT * FROM book_versions")}
        reused, seen, rows = [], set(), []
        for item in requested:
            gid, proof = item["gid"], item["proof"]
            book = self.book(data["revision"], gid)
            if gid in seen or not isinstance(proof, str) or not re.fullmatch(r"[a-f0-9]{64}", proof):
                raise ValueError("invalid_reuse_receipt")
            seen.add(gid)
            old = versions.get(gid)
            if old and old["directory"] == book["directory"] and old["available"] and hmac.compare_digest(old["proof"], proof):
                reused.append(gid)
                rows.append((data["revision"], gid, old["available"]))
        with self.db:
            self.db.executemany("INSERT OR REPLACE INTO ready VALUES(?,?,?)", rows)
        return {"reused": reused}

    def publish(self, data):
        cat = self.catalog(data["revision"])
        validate_catalog(cat)
        archive_revision = data.get("archiveRevision")
        if archive_revision is not None:
            extra = self.extra()
            if extra.catalog(archive_revision)["sourceRevision"] != data["revision"] or extra.active() != archive_revision:
                raise ValueError("archive_not_verified")
        # Revalidate against current active catalog in case another client published.
        self.stage(cat)
        ready = {r[0] for r in self.db.execute("SELECT gid FROM ready WHERE revision=?", (data["revision"],))}
        if any(book["id"] not in ready for book in cat["books"]):
            raise ValueError("books_not_verified")
        self.db.execute("INSERT OR REPLACE INTO state VALUES('active',?)", (data["revision"],))
        if archive_revision is None:
            self.db.execute("DELETE FROM state WHERE key='active_archive'")
        else:
            self.db.execute("INSERT OR REPLACE INTO state VALUES('active_archive',?)", (archive_revision,))
        self.db.commit()
        order_sha = hashlib.sha256(encoded([b["id"] for b in cat["books"]])).hexdigest()
        return {"published": True, "books": len(cat["books"]), "revision": data["revision"], "orderSha256": order_sha}


def archive_id(kind, name=""):
    return hashlib.sha256((kind + "\n" + name).encode()).hexdigest()


class ArchiveStore(Store):
    """Independent, unordered extras. Never supplies books to the reader catalog."""
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.db.execute("CREATE TABLE IF NOT EXISTS inventories(revision TEXT,gid TEXT,body TEXT,PRIMARY KEY(revision,gid))")
        self.db.commit()

    def catalog(self, revision):
        if revision in self.cache:
            self.cache.move_to_end(revision)
            return self.cache[revision][0]
        row = self.db.execute("SELECT body FROM catalogs WHERE revision=?", (revision,)).fetchone()
        if not row:
            raise ValueError("archive_not_found")
        cat = json.loads(row[0])
        books = {g["id"]: {"id": g["id"], "directory": "directories/" + g["name"] if g["kind"] == "directory" else "root-files"} for g in cat["groups"]}
        self.cache[revision] = (cat, books)
        while len(self.cache) > 4:
            self.cache.popitem(last=False)
        return cat

    def destination(self, directory, path):
        relative(directory); relative(path)
        base = self.root / "books"
        if base.is_symlink():
            raise ValueError("symlink_not_allowed")
        current = base
        for piece in (*directory.split("/"), *path.split("/")):
            current = current / piece
            if current.is_symlink():
                raise ValueError("symlink_not_allowed")
        if not current.resolve().is_relative_to(base.resolve()):
            raise ValueError("invalid_path")
        return current

    def stage(self, cat):
        if cat.get("schema") != 1 or cat.get("type") != "localshelf-extra-v1" or not re.fullmatch("[a-f0-9]{64}", cat.get("sourceRevision", "")):
            raise ValueError("invalid_archive_manifest")
        groups = cat.get("groups")
        if not isinstance(groups, list) or not 1 <= len(groups) <= 20001:
            raise ValueError("invalid_archive_groups")
        seen = set(); roots = 0
        for group in groups:
            kind, name = group.get("kind"), group.get("name")
            if kind == "directory":
                component(name)
            elif kind == "root" and name == "":
                roots += 1
            else:
                raise ValueError("invalid_archive_group")
            gid = archive_id(kind, name)
            if group.get("id") != gid or gid in seen:
                raise ValueError("invalid_archive_id")
            seen.add(gid)
        if roots != 1:
            raise ValueError("archive_root_group_required")
        body = encoded(cat); revision = hashlib.sha256(body).hexdigest()
        self.db.execute("INSERT OR IGNORE INTO catalogs VALUES(?,?)", (revision, body.decode()))
        self.db.commit()
        return {"revision": revision, "readyIds": [r[0] for r in self.db.execute("SELECT gid FROM ready WHERE revision=?", (revision,))]}

    def book_commit(self, data):
        book = self.book(data["revision"], data["gid"])
        files = data["files"]
        if not isinstance(files, list) or len(files) > 100000:
            raise ValueError("invalid_inventory")
        seen = set()
        for file in files:
            path = relative(file["path"])
            if path in seen or not self.valid_file(book["id"], path, file["size"], file["sha256"], book["directory"]):
                raise ValueError("inventory_not_complete")
            seen.add(path)
        # Also retain an empty top-level source directory; no fake image pages.
        self.destination(book["directory"], ".check").parent.mkdir(parents=True, exist_ok=True)
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO inventories VALUES(?,?,?)", (data["revision"], book["id"], encoded(files).decode()))
            self.db.execute("INSERT OR REPLACE INTO ready VALUES(?,?,1)", (data["revision"], book["id"]))
        return {"verifiedFiles": len(files), "verifiedBytes": sum(f["size"] for f in files)}

    def publish(self, data):
        cat = self.catalog(data["revision"])
        ready = {r[0] for r in self.db.execute("SELECT gid FROM ready WHERE revision=?", (data["revision"],))}
        if ready != {g["id"] for g in cat["groups"]}:
            raise ValueError("archive_not_verified")
        count = size = 0
        for row in self.db.execute("SELECT body FROM inventories WHERE revision=?", (data["revision"],)):
            files = json.loads(row[0]); count += len(files); size += sum(f["size"] for f in files)
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO state VALUES('active',?)", (data["revision"],))
        return {"published": True, "revision": data["revision"], "groups": len(ready), "files": count, "bytes": size}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        self.request.settimeout(15)
        super().setup()

    def handle(self):
        try:
            super().handle()
        except (ConnectionResetError, BrokenPipeError, TimeoutError, ssl.SSLError):
            pass

    def finish(self):
        try:
            super().finish()
        except (ConnectionResetError, BrokenPipeError, TimeoutError, ssl.SSLError):
            pass

    def log_message(self, *args):
        pass  # No tokens, gallery names or request bodies in logs.

    def reply(self, status, data):
        body = encoded(data)
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if status != 200:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.handle_request()

    def do_POST(self):
        # Bound aggregate request-body memory independently of idle TLS sockets.
        with POST_SLOTS:
            self.handle_request()

    def handle_request(self):
        request_started = time.perf_counter()
        try:
            self.connection.settimeout(45)
            if not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + self.server.token):
                self.reply(401, {"error": "unauthorized"})
                return
            url = urlsplit(self.path)
            if self.command == "GET" and url.path == "/sync/v1/health":
                with database_lock():
                    result = {"protocol": 1, "capabilities": ["book-reuse-v1", "daily-catalog-v1", "space-policy-v1", "extra-archive-v1", "parallel-files-v1", "batch-files-v1"], **self.server.store.space(), "activeRevision": self.server.store.active(), "transferMetrics": metrics_snapshot()}
            elif self.command == "POST":
                is_extra = url.path.startswith("/sync/v1/archive/")
                route = url.path.replace("/sync/v1/archive/", "/sync/v1/", 1) if is_extra else url.path
                is_chunk = route == "/sync/v1/file/chunk"
                is_batch = route == "/sync/v1/files/batch"
                size = int(self.headers.get("Content-Length", "-1"))
                body_limit = CHUNK if is_chunk else (4 + BATCH_HEADER + BATCH_BYTES if is_batch else 32 * 1024**2)
                if size < 0 or size > body_limit or self.headers.get("Transfer-Encoding"):
                    raise ValueError("request_too_large")
                started = time.perf_counter()
                try:
                    raw = self.rfile.read(size)
                finally:
                    measure("receiveBody", started)
                if len(raw) != size:
                    raise ValueError("request_incomplete")
                with database_lock():
                    store = self.server.store.extra() if is_extra else self.server.store
                # Never acquire an upload lock while holding LOCK: chunk/finish
                # take the upload lock first, then briefly acquire LOCK.
                if is_batch:
                    result = store.batch(raw)
                elif is_chunk:
                    query = parse_qs(url.query)
                    result = store.chunk(query["upload"][0], int(query["offset"][0]), raw)
                else:
                    data = json.loads(raw)
                    if route == "/sync/v1/file/begin":
                        result = store.begin(data)
                    elif route == "/sync/v1/file/finish":
                        result = store.finish(data["upload"])
                    else:
                        routes = {"/sync/v1/catalog/stage": store.stage, "/sync/v1/file/begin": store.begin,
                                  "/sync/v1/files/status": store.file_status,
                                  "/sync/v1/file/finish": lambda d: store.finish(d["upload"]),
                                  "/sync/v1/book/commit": store.book_commit, "/sync/v1/catalog/commit": store.publish}
                        if is_extra:
                            routes["/sync/v1/catalog/stage"] = self.server.store.stage_archive
                        else:
                            routes["/sync/v1/catalog/reuse"] = store.reuse
                            routes["/sync/v1/catalog/daily-stage"] = store.daily_stage
                        if route not in routes:
                            self.reply(404, {"error": "not_found"})
                            return
                        with database_lock(), store.db:
                            result = routes[route](data)
            else:
                self.reply(404, {"error": "not_found"})
                return
            self.reply(200, result)
        except (ValueError, KeyError, TypeError) as e:
            self.reply(400, {"error": str(e) if isinstance(e, ValueError) else "invalid_request"})
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass
        except OSError as e:
            self.reply(507 if e.errno in (errno.ENOSPC, errno.EDQUOT) else 500, {"error": "storage_full" if e.errno in (errno.ENOSPC, errno.EDQUOT) else "storage_or_server_error"})
        except sqlite3.Error as e:
            full = getattr(e, "sqlite_errorcode", None) == sqlite3.SQLITE_FULL
            self.reply(507 if full else 500, {"error": "storage_full" if full else "storage_or_server_error"})
        except Exception:
            self.reply(500, {"error": "storage_or_server_error"})
        finally:
            measure("request", request_started)


class TLSServer(ThreadingHTTPServer):
    """TLS handshakes run in bounded workers, never in the accepting thread."""
    def __init__(self, address, handler, context):
        self.context = context
        self.slots = threading.BoundedSemaphore(32)
        super().__init__(address, handler)

    def get_request(self):
        sock, address = super().get_request()
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.settimeout(15)
        return self.context.wrap_socket(sock, server_side=True, do_handshake_on_connect=False), address

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()


def initialize(root, host, port):
    config = Path(root) / "config"
    config.mkdir(parents=True, exist_ok=True)
    cert, key = config / "server.crt", config / "server.key"
    if not cert.exists() or not key.exists():
        if cert.exists() or key.exists():
            raise RuntimeError("TLS 配置不完整；恢复原证书和私钥后重试")
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "3650", "-keyout", str(key), "-out", str(cert), "-subj", "/CN=LocalShelfSync"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        key.chmod(0o600)
    token_file = config / "upload-token"
    if not token_file.exists():
        token_file.write_text(secrets.token_hex(32))
        token_file.chmod(0o600)
    token = token_file.read_text().strip()
    pin = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).hexdigest()
    pairing = {"app": "localshelf-sync", "version": 1, "url": f"https://{host}:{port}", "token": token, "certificateSha256": pin}
    (config / "pairing.json").write_bytes(encoded(pairing))
    (config / "pairing.json").chmod(0o600)
    return cert, key, token


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", default="/data")
    parser.add_argument("--host-ip", default=os.environ.get("NAS_IP"))
    parser.add_argument("--port", type=int, default=8443)
    parser.add_argument("--reserve-gib", type=int, default=int(os.environ.get("SYNC_RESERVE_GIB", "10")))
    parser.add_argument("--reserve-percent", type=float, default=float(os.environ.get("SYNC_RESERVE_PERCENT", "2")))
    parser.add_argument("--warning-gib", type=int, default=int(os.environ.get("SYNC_WARNING_GIB", "50")))
    parser.add_argument("--warning-percent", type=float, default=float(os.environ.get("SYNC_WARNING_PERCENT", "10")))
    args = parser.parse_args()
    if not args.host_ip:
        parser.error("请通过 NAS_IP 或 --host-ip 指定 NAS 局域网地址")
    store = Store(args.data, args.reserve_gib * 1024**3, args.reserve_percent,
                  args.warning_gib * 1024**3, args.warning_percent)
    cert, key, token = initialize(args.data, args.host_ip, args.port)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(cert, key)
    server = TLSServer(("0.0.0.0", args.port), Handler, context)
    server.store, server.token = store, token
    print("LocalShelf Sync 已启动。请将数据目录 config/pairing.json 导入安卓 App。", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
