"""LAN-only LocalShelf reader. Never opens the synchronization store for writing."""
import argparse
import contextlib
from collections import OrderedDict
import fcntl
import getpass
import gzip
import hashlib
import hmac
import io
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import socket
import stat
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit
from authors import AuthorIndex
from series import SeriesIndex
from related_cache import RelatedDiskCache, RelatedWarmup
from manual import ManualStore, ManualError, POLICY as MANUAL_POLICY, handle_upload
from readiness import inspect_library, ready as library_ready

BUILD_VERSION = '0.1.18-dev'

PAGE = re.compile(r"([0-9]{8})\.(jpg|jpeg|png|webp|gif|avif)", re.I)
# Match EhViewer_CN_SXJ GalleryProvider2 / SpiderDen's first-existing-file
# policy. AVIF is our existing extra format, after the upstream formats.
PAGE_FORMATS = ("jpg", "jpeg", "png", "gif", "webp", "avif")
ENTITY_TAG = re.compile(r'(?:W/)?"([a-f0-9]{64})"')


def etag_matches(header, current):
    """GET uses weak comparison; only accept our bounded SHA-256 validators."""
    if not header or len(header) > 4096 or any(c in header for c in "\r\n"):
        return False
    if header.strip() == "*":
        return True
    tags = header.split(",")
    match = ENTITY_TAG.fullmatch(current)
    return bool(match and len(tags) <= 64 and any(
        candidate and candidate[1] == match[1]
        for candidate in (ENTITY_TAG.fullmatch(tag.strip()) for tag in tags)))


def page_number(path):
    match = PAGE.fullmatch(path)
    return int(match[1]) if match else 0


def page_variant(path):
    match = PAGE.fullmatch(path)
    if not match:
        return 999
    # Canonical lowercase filenames win a same-format case-only tie. Retain
    # our existing uppercase compatibility as a deterministic fallback.
    return PAGE_FORMATS.index(match[2].lower()) * 2 + int(path != path.lower())


def choose_page(rows):
    if len({row["path"] for row in rows}) != len(rows):
        raise Failure(409, "duplicate_path")
    return min(rows, key=lambda row: (page_variant(row["path"]), row["path"])) if rows else None


def file_signature(info, sha):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns, sha)


class VerificationCache:
    """Bounded metadata-only LRU, coalescing hashes of the same open-file identity."""
    def __init__(self, capacity=4096, max_flights=8, timeout=15):
        self.capacity, self.max_flights, self.timeout = capacity, max_flights, timeout
        self.lock = threading.Lock()
        self.entries, self.flights = OrderedDict(), {}
        self.stats = dict(hits=0, hashes=0, coalesced=0, evictions=0)

    def verify(self, signature, check):
        with self.lock:
            if signature in self.entries:
                self.entries.move_to_end(signature)
                self.stats['hits'] += 1
                return
            flight = self.flights.get(signature)
            leader = flight is None
            if leader:
                if len(self.flights) >= self.max_flights:
                    raise Failure(503, "verification_busy")
                flight = [threading.Event(), (503, "verification_interrupted")]
                self.flights[signature] = flight
                self.stats['hashes'] += 1
            else:
                self.stats['coalesced'] += 1
        if not leader:
            if not flight[0].wait(self.timeout):
                raise Failure(503, "verification_timeout")
            if flight[1]:
                raise Failure(*flight[1])
            return
        try:
            check()
            with self.lock:
                self.entries[signature] = True
                self.entries.move_to_end(signature)
                while len(self.entries) > self.capacity:
                    self.entries.popitem(last=False)
                    self.stats['evictions'] += 1
                flight[1] = None
        except Failure as error:
            flight[1] = (error.status, error.code)
            raise
        finally:
            with self.lock:
                self.flights.pop(signature, None)
                flight[0].set()


def encoded(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


def accepts_gzip(header):
    """Only negotiate a supported coding; explicit gzip;q=0 beats a wildcard."""
    if not header or len(header) > 4096:
        return False
    weights = {}
    for item in header.lower().split(','):
        parts = [part.strip() for part in item.split(';')]
        quality = 1.0
        for part in parts[1:]:
            if not re.fullmatch(r'q=(?:0(?:\.[0-9]{0,3})?|1(?:\.0{0,3})?)', part):
                quality = 0.0; break
            quality = float(part[2:])
        weights[parts[0]] = quality
    return weights.get('gzip', weights.get('*', 0)) > 0


class Failure(Exception):
    def __init__(self, status, code):
        self.status, self.code = status, code


def atomic(path, value):
    temporary = path.with_suffix(".tmp-" + secrets.token_hex(8))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(encoded(value)); out.flush(); os.fsync(out.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


class Identity:
    def __init__(self, root):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.lock = threading.Lock()
        path = self.root / "identity.json"
        if not path.exists():
            atomic(path, {"deviceId": secrets.token_hex(16), "libraryId": secrets.token_hex(32), "token": secrets.token_urlsafe(24)})
        self.value = json.loads(path.read_bytes())
        if not re.fullmatch(r"[a-f0-9]{32}", self.value["deviceId"]) or not re.fullmatch(r"[a-f0-9]{64}", self.value["libraryId"]) or not re.fullmatch(r"[A-Za-z0-9_-]{32}", self.value["token"]):
            raise ValueError("invalid persisted identity; do not regenerate automatically")

    def new_pin(self):
        with self.window_lock():
            if self.password_enabled():
                raise Failure(403, "password_pair_required")
            pin = f"{secrets.randbelow(1000000):06d}"
            atomic(self.root / "pairing-window.json", {"hash": hashlib.sha256(pin.encode()).hexdigest(), "expires": time.time() + 300, "attempts": 0})
            return pin

    @contextlib.contextmanager
    def window_lock(self):
        with self.lock, open(self.root / "pairing.lock", "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try: yield
            finally: fcntl.flock(lock, fcntl.LOCK_UN)

    def pair(self, raw):
        with self.window_lock():
            if self.password_enabled():
                raise Failure(403, "password_pair_required")
            path = self.root / "pairing-window.json"
            try:
                window = json.loads(path.read_bytes())
            except FileNotFoundError:
                raise Failure(403, "pairing_closed")
            if window["expires"] < time.time() or window["attempts"] >= 5:
                raise Failure(403, "pairing_closed")
            window["attempts"] += 1
            valid = bool(re.fullmatch(rb"[0-9]{6}", raw)) and hmac.compare_digest(window["hash"], hashlib.sha256(raw).hexdigest())
            if valid:
                window["expires"] = 0
            atomic(path, window)
            if not valid:
                raise Failure(403, "incorrect_pin")
            return {"app": "localshelf", "version": 2, "deviceId": self.value["deviceId"], "token": self.value["token"]}

    def password_enabled(self):
        path = self.root / "reader-password.json"
        if path.is_symlink():
            raise Failure(503, "invalid_password_configuration")
        return path.exists()

    @staticmethod
    def valid_password(raw):
        try:
            text = raw.decode('utf-8')
            return 8 <= len(raw) <= 128 and not any(ord(c) < 32 or ord(c) == 127 for c in text)
        except (UnicodeDecodeError, AttributeError):
            return False

    def set_password(self, raw):
        if not self.valid_password(raw):
            raise ValueError('Password must be 8-128 UTF-8 bytes, without control characters')
        salt = secrets.token_bytes(32)
        value = {'schema': 1, 'algorithm': 'pbkdf2-sha256', 'iterations': 600000,
                 'salt': salt.hex(), 'hash': hashlib.pbkdf2_hmac('sha256', raw, salt, 600000).hex(),
                 'attempts': 0, 'lastFailure': 0, 'blockedUntil': 0}
        with self.window_lock():
            if (self.root / 'reader-password.json').is_symlink():
                raise ValueError('Invalid password configuration path')
            atomic(self.root / 'reader-password.json', value)

    def pair_password(self, raw):
        if not self.valid_password(raw):
            raise Failure(400, 'invalid_password_length')
        with self.window_lock():
            if not self.password_enabled():
                raise Failure(403, 'password_pair_not_enabled')
            try:
                path = self.root / 'reader-password.json'
                with path.open('rb') as source:
                    data = source.read(4097)
                if len(data) > 4096:
                    raise ValueError()
                value = json.loads(data)
                if value['schema'] != 1 or value['algorithm'] != 'pbkdf2-sha256' or value['iterations'] != 600000:
                    raise ValueError()
                if not re.fullmatch(r'[a-f0-9]{64}', value['salt']) or not re.fullmatch(r'[a-f0-9]{64}', value['hash']):
                    raise ValueError()
                if type(value['attempts']) is not int or not 0 <= value['attempts'] <= 5:
                    raise ValueError()
                if any(type(value[k]) not in (int, float) or not 0 <= value[k] < 1e12 for k in ('lastFailure', 'blockedUntil')):
                    raise ValueError()
            except (ValueError, KeyError, TypeError):
                raise Failure(503, 'invalid_password_configuration')
            now = time.time()
            if value['blockedUntil'] > now:
                raise Failure(429, 'password_pair_rate_limited')
            if now - value['lastFailure'] >= 900:
                value['attempts'] = 0
            digest = hashlib.pbkdf2_hmac('sha256', raw, bytes.fromhex(value['salt']), 600000).hex()
            valid = hmac.compare_digest(value['hash'], digest)
            if valid:
                if value['attempts'] or value['blockedUntil']:
                    value.update(attempts=0, lastFailure=0, blockedUntil=0)
                    atomic(path, value)
            else:
                value['attempts'] += 1
                value['lastFailure'] = now
                value['blockedUntil'] = now + 900 if value['attempts'] >= 5 else 0
                atomic(path, value)
                raise Failure(403, 'incorrect_password')
            # Only the random device credential is returned/stored on iOS.
            # Existing paired devices retain their credential and reading scope.
            return {'app': 'localshelf', 'version': 2, 'deviceId': self.value['deviceId'], 'token': self.value['token']}

    def proof(self, nonce):
        if not re.fullmatch(r"[a-f0-9]{64}", nonce):
            raise Failure(400, "invalid_nonce")
        identity = self.value["deviceId"]
        proof = hmac.new(self.value["token"].encode(), f"localshelf-server-v2\n{identity}\n{nonce}".encode(), hashlib.sha256).hexdigest()
        return {"deviceId": identity, "proof": proof}


class Reader:
    def __init__(self, source, identity, thumbnails=None, *, library_id=None, order_policy='ehviewer-downloads-time-desc', cache_root=None):
        self.source = Path(source).resolve()
        self.identity = identity
        self.library_id = library_id or identity.value['libraryId']
        self.order_policy = order_policy
        self.thumbnails = thumbnails
        self.cache_lock = threading.Lock()
        self.cache = None
        self.verification = VerificationCache()
        self.pages_lock = threading.RLock()
        self.page_cache = OrderedDict()
        self.page_cache_bytes = 0
        self.page_cache_capacity = 128
        self.page_cache_budget = 4 * 1024**2
        self.observer = None
        self.observer_identity = None
        self.observer_version = None
        self.page_epoch = 0
        self.content_cache = OrderedDict()
        self.content_cache_bytes = 0
        self.content_identity = None
        self.content_contract = None
        self.manifest_stats = dict(hits=0, builds=0)
        # Counts contain metadata only, never decoded images or per-page arrays.
        # A committed content receipt survives order-only and unrelated updates.
        self.count_cache = OrderedDict()
        self.count_cache_bytes = 0
        self.count_cache_budget = 8 * 1024**2
        self.count_cache_capacity = 20000
        self.count_stats = dict(hits=0, builds=0, rows=0)
        self.catalog_responses = OrderedDict()
        self.catalog_response_bytes = 0
        self.catalog_response_budget = 8 * 1024**2
        self.catalog_response_epoch = None
        self.catalog_response_stats = dict(hits=0, builds=0)
        self.related_lock = threading.Lock()
        self.author_index = self.series_index = self.related_snapshot = self.series_snapshot = None
        self.related_disk=RelatedDiskCache(cache_root or identity.root,self.library_id,identity.value['token'])

    def related_indexes(self,books,need_series):
        with self.related_lock:
            if self.author_index is None:
                saved=self.related_disk.load(books)
                if saved is not None:
                    self.author_index,self.series_index=saved
                    self.related_snapshot=self.series_snapshot=books
            try:
                if self.related_snapshot is not books:
                    self.author_index=AuthorIndex(books,self.author_index)
                    self.related_snapshot=books
                if need_series and self.series_snapshot is not books:
                    self.series_index=SeriesIndex(books,self.author_index,self.series_index)
                    self.series_snapshot=books
            except ValueError:raise Failure(503,'related_index_unavailable') from None
            return self.author_index,self.series_index

    def close(self):
        with self.related_lock:
            self.author_index = self.series_index = self.related_snapshot = self.series_snapshot = None
        with self.pages_lock:
            if self.observer:
                self.observer.close()
                self.observer = None
            self.page_cache.clear()
            self.page_cache_bytes = 0
            self.content_cache.clear()
            self.content_cache_bytes = 0
            self.count_cache.clear()
            self.count_cache_bytes = 0
            self.catalog_responses.clear()
            self.catalog_response_bytes = 0
        if self.thumbnails is not None:
            self.thumbnails.close()

    def pages_epoch(self):
        # Called under pages_lock. This connection never holds a read transaction.
        # data_version must be compared on the SAME connection, not request DBs.
        path = self.source / "index.sqlite3"
        if not path.is_file() or path.is_symlink():
            raise Failure(503, "library_not_published")
        info = path.stat()
        identity = (info.st_dev, info.st_ino)
        if self.observer is None or identity != self.observer_identity:
            if self.observer:
                self.observer.close()
            self.observer = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True,
                                           timeout=2, check_same_thread=False)
            self.observer.execute("PRAGMA query_only=ON")
            self.observer_identity, self.observer_version = identity, None
            self.count_cache.clear()
            self.count_cache_bytes = 0
            self.content_contract = None
            with self.cache_lock: self.cache = None
        version = self.observer.execute("PRAGMA data_version").fetchone()[0]
        if version != self.observer_version:
            self.observer_version = version
            self.page_epoch += 1
            self.page_cache.clear()
            self.page_cache_bytes = 0
        return self.page_epoch

    @contextlib.contextmanager
    def connection(self):
        path = self.source / "index.sqlite3"
        if not path.is_file() or path.is_symlink():
            raise Failure(503, "library_not_published")
        db = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=2)
        db.row_factory = sqlite3.Row
        db.create_function("ls_page", 1, page_number, deterministic=True)
        db.create_function("ls_variant", 1, page_variant, deterministic=True)
        try:
            db.execute("PRAGMA query_only=ON")
            db.execute("BEGIN")
            yield db
        finally:
            db.close()

    def snapshot(self, db):
        active = db.execute("SELECT value FROM state WHERE key='active'").fetchone()
        if not active:
            raise Failure(503, "library_not_published")
        revision = active[0]
        with self.cache_lock:
            if self.cache and self.cache[0] == revision:
                return self.cache
            row = db.execute("SELECT body FROM catalogs WHERE revision=?", (revision,)).fetchone()
            if not row or len(row[0]) > 16 * 1024 * 1024:
                raise Failure(409, "invalid_catalog")
            catalog = json.loads(row[0])
            books = catalog.get("books", [])
            minimum = 0 if self.order_policy == MANUAL_POLICY else 1
            if catalog.get("orderVerified") is not True or catalog.get("orderSource") != self.order_policy or not minimum <= len(books) <= 20000:
                raise Failure(409, "unverified_catalog")
            seen, directories = set(), set()
            previous = None
            ties = {}
            for rank, book in enumerate(books):
                gid, directory = book["id"], book["directory"]
                if not re.fullmatch(r"[1-9][0-9]{0,18}", gid) or gid in seen or book["rank"] != rank or not isinstance(book["title"], str) or not book["title"].strip() or len(book["title"].encode()) > 16384:
                    raise Failure(409, "invalid_catalog")
                if not directory or directory in (".", "..") or any(c in directory for c in "/\\") or directory in directories:
                    raise Failure(409, "invalid_directory")
                stamp = book["time"]
                if type(stamp) is not int or (previous is not None and stamp > previous):
                    raise Failure(409, "invalid_order")
                previous = stamp; ties.setdefault(str(stamp), []).append(gid)
                seen.add(gid); directories.add(directory)
            for stamp, ids in ties.items():
                if len(ids) > 1 and catalog.get("resolvedTies", {}).get(stamp) != ids:
                    raise Failure(409, "unverified_ties")
            if not re.fullmatch(r"[a-f0-9]{64}", revision):
                raise Failure(409, "invalid_revision")
            self.cache = (revision, books, {b["id"]: b for b in books})
            return self.cache

    @contextlib.contextmanager
    def counting_connection(self):
        # Serializes receipt/count cache access and observes database replacement
        # before opening the request's consistent read snapshot. Reentrant for
        # list_response, which already owns pages_lock.
        with self.pages_lock:
            self.pages_epoch()
            with self.connection() as db:
                yield db

    def list(self, offset, limit, anchor=None, *, include_counts=True):
        if offset < 0 or offset > 200000 or limit not in range(50, 501, 50):
            raise Failure(400, "invalid_pagination")
        if anchor is not None and anchor != '' and not re.fullmatch(r'[1-9][0-9]{0,18}', anchor):
            raise Failure(400, 'invalid_anchor')
        with self.counting_connection() as db:
            revision, books, by_id = self.snapshot(db)
            found = by_id.get(anchor) if anchor else None
            if anchor is not None:
                # Resolve the visible book and its page in the SAME read snapshot.
                # Reordering is not navigation; missing anchors use the last valid page.
                offset = (found['rank'] if found else min(offset, max(0, len(books)-1))) // limit * limit
            selected = books[offset:offset + limit]
            result = self.book_items(db, revision, selected, include_counts=include_counts)
            catalog = {"orderVerified": True, "orderPolicy": self.order_policy, "total": len(books), "books": result, "catalogRevision": revision, "libraryId": self.library_id}
            return catalog if anchor is None else {'offset': offset, 'anchor': found['id'] if found else None, 'catalog': catalog}

    def book_items(self, db, revision, selected, *, include_counts=True):
        result = []
        availability, covers, counts = {}, {}, {}
        for start in range(0, len(selected), 200):
            chunk = selected[start:start + 200]
            marks = ",".join("?" for _ in chunk)
            availability.update((r[0], bool(r[1])) for r in db.execute(
                f"SELECT gid,available FROM ready WHERE revision=? AND gid IN ({marks})",
                (revision, *(b['id'] for b in chunk))))
            # Each correlated lookup uses files(gid,path). Only return one
            # hash per book; never materialize all of a 500-book page's files.
            values = ",".join("(?,?)" for _ in chunk)
            first_covers = db.execute(f"""
                WITH wanted(gid,directory) AS (VALUES {values})
                SELECT w.gid, COALESCE(
                  (SELECT sha FROM files WHERE gid=w.gid AND directory=w.directory AND path='.thumb'),
                  (SELECT sha || ':' || path FROM (
                    SELECT path,sha FROM files WHERE gid=w.gid AND directory=w.directory
                    ORDER BY path LIMIT 100001
                  ) WHERE ls_page(path)>0 LIMIT 1))
                FROM wanted w""", tuple(v for b in chunk for v in (b['id'], b['directory']))).fetchall()
            directories = {b['id']: b['directory'] for b in chunk}
            variants = []
            for gid, candidate in first_covers:
                if candidate is None or len(candidate) == 64:
                    covers[gid] = candidate
                    continue
                sha, path = candidate[:64], candidate[65:]
                if candidate[64:65] != ':' or not PAGE.fullmatch(path):
                    raise Failure(409, "invalid_cover_identity")
                covers[gid] = sha
                if page_variant(path) != 0:
                    variants.append((gid, directories[gid], path[:8]))
            if variants:
                # Resolve only alternate formats, once per batch. Explicit
                # prefix bounds retain the (gid,path) range index instead
                # of reevaluating a correlated first-page query per file.
                variant_values = ','.join('(?,?,?)' for _ in variants)
                covers.update((r[0], r[1]) for r in db.execute(f"""
                    WITH wanted(gid,directory,page) AS (VALUES {variant_values})
                    SELECT w.gid, (SELECT sha FROM files
                      WHERE gid=w.gid AND directory=w.directory
                        AND path >= w.page || '.' AND path < w.page || '/'
                        AND ls_page(path)>0
                      ORDER BY ls_variant(path),path LIMIT 1)
                    FROM wanted w""", tuple(v for row in variants for v in row)))
            if include_counts:
                counts.update(self.book_page_counts(db, revision, chunk, availability))
        for book in selected:
            # File identity comes from committed per-file hashes, not a folder timestamp.
            cover = covers.get(book['id'])
            item = {"id": book["id"], "title": book["title"], "rank": book["rank"], "available": availability.get(book['id'], False), "coverIdentity": cover if cover else hashlib.sha256((book["id"] + "missing").encode()).hexdigest()}
            if include_counts:
                item['pageCount'] = counts.get(book['id'])
            result.append(item)
        return result

    def receipts_supported(self, db, revision):
        if self.content_contract is None or self.content_contract[0] != revision:
            body = db.execute('SELECT body FROM catalogs WHERE revision=?', (revision,)).fetchone()[0]
            self.content_contract = (revision, self.order_policy == MANUAL_POLICY or json.loads(body).get('retentionPolicy') == 'keep-omitted-files-v1')
        return self.content_contract[1]

    def count_pages(self, db, book):
        # Same filename/page limits as records(), without loading hashes, sizes,
        # opening directories, hashing originals, or decoding animation frames.
        # Invalid books have no badge; they must not prevent other covers loading.
        numbers, previous = set(), None
        self.count_stats['builds'] += 1
        rows = db.execute('SELECT path FROM files WHERE gid=? AND directory=? ORDER BY path LIMIT 100001',
                          (book['id'], book['directory']))
        try:
            for index, (path,) in enumerate(rows):
                self.count_stats['rows'] += 1
                if index >= 100000: return None
                match = PAGE.fullmatch(path)
                if match:
                    number = int(match[1])
                    if number < 1 or previous == path: return None
                    numbers.add(number)
                    if len(numbers) > 20000: return None
                previous = path
        finally:
            rows.close()
        return len(numbers)

    def book_page_counts(self, db, revision, books, availability):
        while self.count_cache and (len(self.count_cache) > self.count_cache_capacity or self.count_cache_bytes > self.count_cache_budget):
            _, (_, _, removed) = self.count_cache.popitem(last=False)
            self.count_cache_bytes -= removed
        receipts = {}
        if self.receipts_supported(db, revision):
            marks = ','.join('?' for _ in books)
            try:
                receipts = {row['gid']: row for row in db.execute(
                    f'SELECT gid,directory,proof,available FROM book_versions WHERE gid IN ({marks})',
                    tuple(book['id'] for book in books))}
            except sqlite3.OperationalError as error:
                if 'no such table' not in str(error): raise
        result = {}
        for book in books:
            gid = book['id']
            if not availability.get(gid, False):
                result[gid] = None
                continue
            row = receipts.get(gid)
            proof = row['proof'] if row else None
            trusted = bool(row and row['directory'] == book['directory'] and row['available'] == 1
                           and isinstance(proof, str) and re.fullmatch('[a-f0-9]{64}', proof))
            key = (book['directory'], proof) if trusted else None
            saved = self.count_cache.get(gid) if trusted else None
            if saved is not None and saved[0] == key:
                self.count_cache.move_to_end(gid)
                self.count_stats['hits'] += 1
                result[gid] = saved[1]
                continue
            count = self.count_pages(db, book)
            result[gid] = count
            old = self.count_cache.pop(gid, None)
            if old: self.count_cache_bytes -= old[2]
            cost = 512 + 4 * (len(gid) + len(book['directory']) + 64)
            if trusted and cost <= self.count_cache_budget:
                self.count_cache[gid] = (key, count, cost)
                self.count_cache_bytes += cost
                while len(self.count_cache) > self.count_cache_capacity or self.count_cache_bytes > self.count_cache_budget:
                    _, (_, _, removed) = self.count_cache.popitem(last=False)
                    self.count_cache_bytes -= removed
        return result

    def related(self, gid, kind, selection=None, offset=0, limit=100, include_possible=False, expanded=False, known=False, relaxed=False):
        if kind not in ('authors','series') or offset<0 or offset>20000 or limit not in range(50,501,50) or offset%limit:
            raise Failure(400, 'invalid_related_query')
        if known and (kind!='authors' or not expanded):raise Failure(400,'invalid_related_query')
        if relaxed and not expanded:raise Failure(400,'invalid_related_query')
        # Do not hold a source read transaction while rebuilding the naming
        # index. Re-check the exact published snapshot before forming a reply.
        with self.counting_connection() as db:
            _,books,by_id=self.snapshot(db)
            if gid not in by_id:raise Failure(404,'book_not_in_published_catalog')
        author,series=self.related_indexes(books,kind=='series' or relaxed)
        work_peers=series.relaxed['work_peers'] if relaxed else None
        expected=books
        with self.counting_connection() as db:
            revision, books, by_id = self.snapshot(db)
            if books is not expected:raise Failure(503,'related_index_changed')
            if gid not in by_id: raise Failure(404, 'book_not_in_published_catalog')
            # The captured indexes are immutable even if a worker publishes a
            # newer pair meanwhile. No global relation lock spans SQL or IO.
            index = author if kind=='authors' else series
            if selection is None:
                options=index.options(gid,include_possible,expanded,known,work_peers) if kind=='authors' else index.relaxed_options(gid) if relaxed else index.options(gid,expanded)
                return dict(bookID=gid,kind=kind,libraryId=self.library_id,catalogRevision=revision,options=options)
            possible=frozenset()
            relaxed_notes={}
            try:
                if kind=='authors':option,ids,possible=index.details(gid,selection,include_possible,expanded,known,work_peers)
                elif relaxed:option,ids,possible,relaxed_notes=index.relaxed_details(gid,selection)
                elif expanded:option,ids,possible=index.details(gid,selection)
                else:option,ids=index.selection(gid,selection)
            except KeyError: raise Failure(404, 'related_selection_changed') from None
            # Result order is published rank, not inferred volume or date.
            offset = min(offset, max(0,len(ids)-1)//limit*limit)
            selected = [by_id[i] for i in ids[offset:offset+limit]]
            parts={b['id']:index.part_labels[b['id']] for b in selected if b['id'] in index.part_labels} if kind=='series' else None
            if kind=='series' and relaxed:
                for b in selected:
                    row=index.relaxed['rows'].get(b['id'])
                    if row and row[0].part:parts[b['id']]=row[0].part[:96]
            notes={}
            if expanded:
                if kind=='authors':
                    group=index.selector_group(selection)
                    notes=index.notes(group,possible,work_peers)
                elif relaxed:notes=relaxed_notes
                else:notes=index.group_notes[index.expanded_group_for[selection]]
                notes={b['id']:notes[b['id']] for b in selected if b['id'] in notes}
            catalog=dict(orderVerified=True,orderPolicy=self.order_policy,
                total=len(ids),books=self.book_items(db,revision,selected),
                catalogRevision=revision,libraryId=self.library_id)
            result=dict(bookID=gid,kind=kind,option=option,offset=offset,catalog=catalog)
            if expanded or (kind=='authors' and include_possible):
                result['possibleBookIDs']=[b['id'] for b in selected if b['id'] in possible]
            if expanded:result['matchNotes']=notes
            if parts is not None:result['partLabels']=parts
            return result

    def list_response(self, offset, limit, compressed=False, anchor=None):
        # A catalog revision is NOT sufficient: available/cover hashes can
        # change while the writer keeps the same published order. Check the
        # same observer connection around each snapshot, exactly as for pages.
        if offset < 0 or offset > 200000 or limit not in range(50, 501, 50):
            raise Failure(400, 'invalid_pagination')
        with self.pages_lock:
            epoch = self.pages_epoch()
            if epoch != self.catalog_response_epoch:
                self.catalog_responses.clear(); self.catalog_response_bytes = 0
                self.catalog_response_epoch = epoch
            key = (offset, limit, bool(compressed), anchor)
            saved = self.catalog_responses.get(key)
            if saved is not None and epoch == self.pages_epoch():
                self.catalog_responses.move_to_end(key)
                self.catalog_response_stats['hits'] += 1
                return saved[0]
            body = encoded(self.list(offset, limit, anchor))
            coding = 'gzip' if compressed and len(body) >= 1024 else None
            if coding: body = gzip.compress(body, compresslevel=1, mtime=0)
            response = (body, '"' + hashlib.sha256(body).hexdigest() + '"', coding)
            self.catalog_response_stats['builds'] += 1
            if epoch == self.pages_epoch():
                cost = len(body) + 512
                if cost <= self.catalog_response_budget:
                    previous = self.catalog_responses.pop(key, None)
                    if previous: self.catalog_response_bytes -= previous[1]
                    self.catalog_responses[key] = (response, cost)
                    self.catalog_response_bytes += cost
                    while len(self.catalog_responses) > 32 or self.catalog_response_bytes > self.catalog_response_budget:
                        _, (_, removed) = self.catalog_responses.popitem(last=False)
                        self.catalog_response_bytes -= removed
            return response

    def records(self, db, book):
        rows = db.execute("SELECT path,size,sha FROM files WHERE gid=? AND directory=?", (book["id"], book["directory"])).fetchmany(100001)
        if len(rows) > 100000:
            raise Failure(409, "too_many_files")
        pages = {}
        paths = set()
        thumb = None
        for row in rows:
            if row["path"] == ".thumb":
                thumb = row
            match = PAGE.fullmatch(row["path"])
            if match:
                number = int(match[1])
                if number < 1 or row["path"] in paths:
                    raise Failure(409, "duplicate_or_invalid_page")
                paths.add(row["path"])
                previous = pages.get(number)
                pages[number] = choose_page([previous, row]) if previous else row
        if len(pages) > 20000:
            raise Failure(409, "too_many_pages")
        return pages, thumb

    def cover_record(self, db, book):
        # Bounded indexed query: no directory scan or full page enumeration per cover.
        thumb = db.execute("SELECT path,size,sha FROM files WHERE gid=? AND directory=? AND path='.thumb'", (book["id"], book["directory"])).fetchone()
        if thumb:
            return thumb
        for row in db.execute("SELECT path,size,sha FROM files WHERE gid=? AND directory=? ORDER BY path LIMIT 100001", (book["id"], book["directory"])):
            match = PAGE.fullmatch(row["path"])
            if match and int(match[1]) > 0:
                return self.page_record(db, book, int(match[1]))
        return None

    def page_record(self, db, book, number):
        rows = db.execute(
            "SELECT path,size,sha FROM files WHERE gid=? AND directory=? AND path GLOB ?",
            (book["id"], book["directory"], f"{number:08d}.*"))
        candidates = []
        for row in rows:
            if PAGE.fullmatch(row["path"]):
                candidates.append(row)
                if len(candidates) > 128:
                    raise Failure(409, "too_many_page_variants")
        return choose_page(candidates)

    def book(self, db, gid):
        revision, _, by_id = self.snapshot(db)
        if gid not in by_id:
            raise Failure(404, "book_not_in_published_catalog")
        return revision, by_id[gid]

    def locate(self, gid):
        with self.connection() as db:
            revision, book = self.book(db, gid)
            return {"id": gid, "offset": book["rank"], "catalogRevision": revision, "libraryId": self.library_id}

    def pages(self, gid):
        # A revision alone is insufficient: uploads can add pages without
        # republishing the catalog. Check external commits around each snapshot.
        with self.pages_lock:
            epoch = self.pages_epoch()
            with self.connection() as db:
                revision, book = self.book(db, gid)
                key = (epoch, revision, gid, book['directory'])
                cached = self.page_cache.get(key)
                if cached is None:
                    pages, _ = self.records(db, book)
                    numbers = tuple(sorted(pages))
                else:
                    numbers = cached[0]
            unchanged = epoch == self.pages_epoch()
            if cached is not None and not unchanged:
                # Do not return a stale cache hit during a concurrent commit.
                # One fresh snapshot is enough; avoid retry loops during uploads.
                return self.uncached_pages(gid)
            if unchanged:
                if cached is not None:
                    self.page_cache.move_to_end(key)
                else:
                    cost = 512 + len(book['directory'].encode()) + len(numbers) * 40
                    if cost <= self.page_cache_budget:
                        self.page_cache[key] = (numbers, cost)
                        self.page_cache_bytes += cost
                        while len(self.page_cache) > self.page_cache_capacity or self.page_cache_bytes > self.page_cache_budget:
                            _, (_, removed) = self.page_cache.popitem(last=False)
                            self.page_cache_bytes -= removed
            return {"pages": [{"number": n} for n in numbers]}

    def uncached_pages(self, gid):
        with self.connection() as db:
            _, book = self.book(db, gid)
            pages, _ = self.records(db, book)
            return {"pages": [{"number": n} for n in sorted(pages)]}

    def content_snapshot(self, db, gid):
        revision, book = self.book(db, gid)
        row = None
        if self.receipts_supported(db, revision):
            try:
                row = db.execute('SELECT directory,proof,available FROM book_versions WHERE gid=?', (gid,)).fetchone()
            except sqlite3.OperationalError as error:
                if 'no such table' not in str(error): raise
        proof = row['proof'] if row else None
        trusted = bool(row and row['directory'] == book['directory'] and row['available'] == 1
                       and isinstance(proof, str) and re.fullmatch('[a-f0-9]{64}', proof))
        return book, proof if trusted else None

    def manifest(self, gid):
        # Compatibility API returns a private mutable value, never the cache.
        return json.loads(self.manifest_response(gid)[0])

    def manifest_response(self, gid):
        # Same source transaction for receipt + selected file metadata. No image
        # bytes read; legacy/in-progress books are queried afresh, never guessed.
        with self.pages_lock:
            epoch = self.pages_epoch()
            if self.content_identity != self.observer_identity:
                self.content_identity = self.observer_identity
                self.content_cache.clear(); self.content_cache_bytes = 0
                self.content_contract = None
                with self.cache_lock: self.cache = None
            with self.connection() as db:
                book, proof = self.content_snapshot(db, gid)
                key = (gid, book['directory'], proof)
                saved = self.content_cache.get(key) if proof else None
                if saved is None:
                    records, _ = self.records(db, book)
                    rows = tuple((n, row['sha'], row['size']) for n,row in sorted(records.items()))
                else: rows = None
            stable = epoch == self.pages_epoch()
            if saved is not None and not stable:
                # One uncached snapshot under a concurrent writer; no retry loop.
                with self.connection() as db:
                    _, book = self.book(db,gid); records,_ = self.records(db,book)
                    rows = tuple((n,row['sha'],row['size']) for n,row in sorted(records.items()))
                proof = None
            if proof and stable:
                if saved:
                    self.content_cache.move_to_end(key)
                    self.manifest_stats['hits'] += 1
                    return saved[0]
            # The content hash does not include rank/catalog revision; reorder is
            # still represented by the separate global catalogRevision.
            if any(not isinstance(sha,str) or not re.fullmatch('[a-f0-9]{64}',sha)
                   or type(size) is not int or size<0 for _,sha,size in rows):
                raise Failure(409, 'invalid_page_identity')
            version = hashlib.sha256(encoded([gid,book['directory'],rows])).hexdigest()
            body = encoded({'id':gid,'libraryId':self.library_id,'contentRevision':version,
                            'pages':[{'number':n,'sha256':sha,'size':size} for n,sha,size in rows]})
            response = (body, '"' + hashlib.sha256(body).hexdigest() + '"')
            self.manifest_stats['builds'] += 1
            if proof and stable:
                for old in [k for k in self.content_cache if k[0] == gid]:
                    self.content_cache_bytes -= self.content_cache.pop(old)[1]
                cost = 1024 + len(book['directory'].encode()) + len(body)
                if cost <= self.page_cache_budget:
                    self.content_cache[key] = (response,cost); self.content_cache_bytes += cost
                    while len(self.content_cache)>128 or self.content_cache_bytes>self.page_cache_budget:
                        _,(_,removed) = self.content_cache.popitem(last=False);self.content_cache_bytes -= removed
            return response

    def image(self, gid, number=None, expected_sha=None):
        with self.connection() as db:
            _, book = self.book(db, gid)
            if number is None:
                row = self.cover_record(db, book)
            else:
                row = self.page_record(db, book, number)
            if not row:
                raise Failure(404, "image_missing")
            if expected_sha is not None and row['sha'] != expected_sha:
                raise Failure(412, 'page_content_changed')
            # Walk using directory descriptors and O_NOFOLLOW; no user-controlled
            # request is ever interpreted as a filesystem path.
            fd = os.open(self.source, os.O_RDONLY | os.O_DIRECTORY)
            try:
                for part in ("books", book["directory"]):
                    next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                    os.close(fd); fd = next_fd
                image_fd = os.open(row["path"], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
            finally:
                os.close(fd)
            stream = os.fdopen(image_fd, "rb")
        # End the SQLite read transaction BEFORE hashing or waiting for another
        # request; large images must not pin the uploader's WAL checkpoint.
        try:
            info = os.fstat(image_fd)
            limit = 8 * 1024**2 if number is None and self.order_policy != MANUAL_POLICY else 50 * 1024**2
            if not stat.S_ISREG(info.st_mode) or info.st_size != row["size"] or info.st_size > limit:
                stream.close(); raise Failure(409, "image_updating_or_too_large")
            signature = file_signature(info, row['sha'])
            def check():
                # Sync replaces a file before committing its metadata: a same-size
                # replacement must not be served under the old file's ETag.
                digest = hashlib.sha256()
                for chunk in iter(lambda: stream.read(256 * 1024), b""):
                    digest.update(chunk)
                if digest.hexdigest() != row["sha"]:
                    raise Failure(409, "image_updating")
                if file_signature(os.fstat(image_fd), row['sha']) != signature:
                    raise Failure(409, "image_updating")
                stream.seek(0)
            self.verification.verify(signature, check)
            if file_signature(os.fstat(image_fd), row['sha']) != signature:
                raise Failure(409, "image_updating")
            # In-place external writes are unsupported; sync uses atomic rename.
            return stream, info.st_size, row["sha"]
        except BaseException:
            stream.close()
            raise


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    def __init__(self, address, reader, keep_alive=False, sendfile=False, cover_warm=False, warm_pixels=480, related_warm=False, manual_store=None, manual_reader=None):
        self.reader = reader
        self.manual_store, self.manual_reader = manual_store, manual_reader
        self.upload_slots = threading.BoundedSemaphore(1)
        self.keep_alive, self.sendfile = keep_alive, sendfile
        self.idle_timeout = 3
        self.request_limit = 64
        self.connections = 0
        self.slots = threading.BoundedSemaphore(32 if keep_alive else 8)
        self.active = threading.BoundedSemaphore(8)
        self.activity_lock = threading.Lock()
        self.active_requests = 0
        self.last_request = time.monotonic()
        self.warmup = None
        self.related_warmup = None
        self.readiness_lock = threading.Lock()
        self.readiness_cached = None
        super().__init__(address, PersistentHandler if keep_alive else Handler)
        if cover_warm and reader.thumbnails is not None:
            from cover_warmup import CoverWarmup
            self.warmup = CoverWarmup(reader, reader.identity.root, self.warm_idle, pixels=warm_pixels)
            self.warmup.start()
        if related_warm:
            self.related_warmup=RelatedWarmup(reader,self.warm_idle);self.related_warmup.start()

    def warm_idle(self):
        with self.activity_lock:
            return self.active_requests == 0 and time.monotonic() - self.last_request >= 5

    def readiness(self):
        # One metadata check at a time, shared by all health/diagnostic callers.
        with self.readiness_lock:
            now = time.monotonic()
            if self.readiness_cached and now - self.readiness_cached[0] < 3:
                return self.readiness_cached[1]
            libraries = {"eh": inspect_library(self.reader.source)}
            if self.manual_reader is not None:
                libraries["manual"] = inspect_library(self.manual_reader.source)
            value = {"app": "localshelf-reader", "schema": 1, "buildVersion": BUILD_VERSION,
                     "ready": all(library_ready(checks) for checks in libraries.values()),
                     "libraries": libraries}
            self.readiness_cached = (time.monotonic(), value)
            return value

    def server_close(self):
        if self.related_warmup is not None:self.related_warmup.close()
        if self.warmup is not None: self.warmup.close()
        super().server_close()

    def get_request(self):
        sock, address = super().get_request()
        self.connections += 1
        if self.keep_alive:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        return sock, address

    def service_actions(self):
        # Periodic server housekeeping, no extra thread and no work on /source.
        if self.reader.thumbnails is not None:
            self.reader.thumbnails.maintain()
        if self.manual_reader is not None and self.manual_reader.thumbnails is not None:
            self.manual_reader.thumbnails.maintain()

    def process_request(self, request, address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request); return
        try:
            super().process_request(request, address)
        except BaseException:
            self.slots.release(); raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()


class Handler(BaseHTTPRequestHandler):
    # Production default stays HTTP/1.0; PersistentHandler is opt-in for A/B.
    def setup(self):
        self.request.settimeout(15)
        super().setup()

    def log_message(self, *args):
        pass

    def reply(self, status, body, etag=None):
        data = encoded(body)
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        code = body.get('error') if isinstance(body, dict) else None
        if status >= 400 and isinstance(code, str) and re.fullmatch(r'[a-z_]{1,64}', code):
            self.send_header('X-LocalShelf-Error', code)
        self.end_headers(); self.wfile.write(data)

    def do_GET(self):
        self.dispatch(False)

    def do_POST(self):
        self.dispatch(True)

    def dispatch(self, post):
        # Never reuse sockets with unread/ambiguous bodies. Rejected POSTs also
        # close below; otherwise a body can be interpreted as the next request.
        lengths = self.headers.get_all('Content-Length', [])
        upload = self.path.startswith('/manual/v1/uploads')
        length_pattern = r'[0-9]{1,8}' if upload else r'[0-9]{1,3}'
        if self.headers.get('Transfer-Encoding') or len(lengths) > 1 or (lengths and not re.fullmatch(length_pattern, lengths[0])) or (not post and lengths and lengths[0] != '0'):
            self.close_connection = True
            return self.reply(400, {'error': 'invalid_framing'})
        if post:
            self.close_connection = True
        if upload and not self.server.upload_slots.acquire(blocking=False):
            self.close_connection = True
            return self.reply(503, {'error': 'manual_upload_busy'})
        if not self.server.active.acquire(blocking=False):
            if upload: self.server.upload_slots.release()
            self.close_connection = True
            return self.reply(503, {'error': 'reader_busy'})
        self.request.settimeout(30 if upload else 15)
        self.response_started = False
        with self.server.activity_lock:
            self.server.active_requests += 1
        try:
            self.handle_api(post)
        finally:
            if upload: self.server.upload_slots.release()
            self.server.active.release()
            with self.server.activity_lock:
                self.server.active_requests -= 1
                self.server.last_request = time.monotonic()
            if self.server.keep_alive:
                self.request.settimeout(self.server.idle_timeout)

    def end_headers(self):
        if self.close_connection:
            self.send_header('Connection', 'close')
        super().end_headers()
        self.response_started = True

    def handle_api(self, post):
        try:
            if len(self.path) > 2048:
                raise Failure(400, "invalid_route")
            route = urlsplit(self.path)
            query = parse_qs(route.query, max_num_fields=8)
            if any(len(v) != 1 for v in query.values()):
                raise Failure(400, "duplicate_parameter")
            reader, identity = self.server.reader, self.server.reader.identity
            if handle_upload(self, route, post, identity, self.server.manual_store):
                return
            if post:
                if route.path == '/v2/password-pair':
                    lengths = self.headers.get_all('Content-Length', [])
                    if self.headers.get('Transfer-Encoding') or len(lengths) != 1 or not re.fullmatch(r'[0-9]{1,3}', lengths[0]):
                        raise Failure(400, 'invalid_password_length')
                    length = int(lengths[0])
                    if not 8 <= length <= 128:
                        raise Failure(400, 'invalid_password_length')
                    raw = self.rfile.read(length)
                    if len(raw) != length:
                        raise Failure(400, 'invalid_password_length')
                    return self.reply(200, identity.pair_password(raw))
                if route.path != "/v2/pair":
                    raise Failure(405, "read_only")
                if self.headers.get("Transfer-Encoding") or self.headers.get("Content-Length") != "6":
                    raise Failure(400, "invalid_pin_length")
                return self.reply(200, identity.pair(self.rfile.read(6)))
            if route.path == "/v2/identity":
                return self.reply(200, identity.proof(query.get("nonce", [""])[0]))
            if route.path == "/v2/health":
                capabilities = ['reader-v1', 'pair-v2', 'locate-v1', 'page-manifest-v1', 'conditional-manifest-v1', 'conditional-catalog-v1', 'catalog-window-v1', 'page-precondition-v1', 'author-discovery-v1', 'series-discovery-v1', 'author-evidence-v2', 'related-evidence-v3', 'author-credit-fallback-v1', 'related-relaxed-v1']
                if reader.thumbnails is not None:
                    capabilities.append('cover-thumbnail-v1')
                if identity.password_enabled():
                    capabilities.append('password-pair-v1')
                if self.server.manual_reader is not None:
                    capabilities.append('manual-library-v1')
                capabilities.append('connection-diagnostics-v1')
                return self.reply(200, {"app": "localshelf-reader", "version": 1, "serverKind": "nas", "buildVersion": BUILD_VERSION, "capabilities": capabilities})
            if route.path == "/v2/ready":
                if query: raise Failure(400, "invalid_query")
                status = self.server.readiness()
                # Public readiness deliberately omits paths, library details and credentials.
                return self.reply(200 if status['ready'] else 503,
                                  {"app": "localshelf-reader", "schema": 1, "ready": status['ready']})
            if not hmac.compare_digest(self.headers.get("Authorization", ""), "Bearer " + identity.value["token"]):
                raise Failure(401, "reader_auth_required")
            if route.path == "/v2/diagnostics":
                if query: raise Failure(400, "invalid_query")
                return self.reply(200, self.server.readiness())
            if route.path.startswith('/manual/v1/'):
                if self.server.manual_reader is None: raise Failure(404, 'manual_library_disabled')
                reader = self.server.manual_reader
                route = route._replace(path=route.path[len('/manual'):])
            related = re.fullmatch(r'/v1/books/([1-9][0-9]{0,18})/(authors|series)(?:/([a-f0-9]{64}))?',route.path)
            if related:
                query=parse_qs(route.query,max_num_fields=8,keep_blank_values=True)
                if any(len(v)!=1 for v in query.values()):raise Failure(400,'duplicate_parameter')
                if set(query)-{'offset','limit','includePossible','evidence','credit','relaxed'} or query.get('includePossible',['0'])[0] not in ('0','1') or query.get('evidence',['3'])[0]!='3':
                    raise Failure(400,'invalid_related_query')
                if 'includePossible' in query and related[2]!='authors':raise Failure(400,'invalid_related_query')
                if 'credit' in query and (query['credit']!=['1'] or 'evidence' not in query or related[2]!='authors'):raise Failure(400,'invalid_related_query')
                if 'relaxed' in query and (query['relaxed']!=['1'] or 'evidence' not in query):raise Failure(400,'invalid_related_query')
                value=reader.related(related[1],related[2],related[3],int(query.get('offset',['0'])[0]),int(query.get('limit',['100'])[0]),query.get('includePossible',['0'])[0]=='1','evidence' in query,'credit' in query,'relaxed' in query)
                body=encoded(value)
                coding='gzip' if len(body)>=1024 and accepts_gzip(self.headers.get('Accept-Encoding')) else None
                if coding: body=gzip.compress(body,compresslevel=1,mtime=0)
                etag='"'+hashlib.sha256(body).hexdigest()+'"'
                unchanged=etag_matches(self.headers.get('If-None-Match'),etag)
                self.send_response(304 if unchanged else 200)
                self.send_header('ETag',etag);self.send_header('Cache-Control','private, no-cache')
                self.send_header('Vary','Authorization, Accept-Encoding')
                if coding:self.send_header('Content-Encoding',coding)
                if not unchanged:
                    self.send_header('Content-Type','application/json; charset=utf-8')
                    self.send_header('Content-Length',str(len(body)))
                self.end_headers()
                if not unchanged:self.wfile.write(body)
                return
            if route.path in ("/v1/books", "/v1/books/window"):
                body, etag, coding = reader.list_response(int(query.get('offset', ['0'])[0]),
                    int(query.get('limit', ['100'])[0]), accepts_gzip(self.headers.get('Accept-Encoding')),
                    query.get('anchor', [''])[0] if route.path.endswith('/window') else None)
                unchanged = etag_matches(self.headers.get('If-None-Match'), etag)
                self.send_response(304 if unchanged else 200)
                self.send_header('ETag', etag)
                self.send_header('Cache-Control', 'private, no-cache')
                self.send_header('Vary', 'Authorization, Accept-Encoding')
                if coding: self.send_header('Content-Encoding', coding)
                if not unchanged:
                    self.send_header('Content-Type', 'application/json; charset=utf-8')
                    self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                if not unchanged: self.wfile.write(body)
                return
            match = re.fullmatch(r"/v1/books/([1-9][0-9]{0,18})/(pages|cover|position|manifest)(?:/([1-9][0-9]{0,7}))?", route.path)
            if not match or (match[3] and match[2] != "pages"):
                raise Failure(404, "route_not_found")
            gid, kind, number = match.groups()
            if kind == 'manifest':
                body, etag = reader.manifest_response(gid)
                unchanged = etag_matches(self.headers.get('If-None-Match'), etag)
                self.send_response(304 if unchanged else 200)
                self.send_header('ETag', etag)
                self.send_header('Cache-Control', 'private, no-cache')
                self.send_header('Vary', 'Authorization')
                if not unchanged:
                    self.send_header('Content-Type', 'application/json; charset=utf-8')
                    self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                if not unchanged: self.wfile.write(body)
                return
            if kind == "position":
                return self.reply(200, reader.locate(gid))
            if kind == "pages" and number is None:
                return self.reply(200, reader.pages(gid))
            with contextlib.ExitStack() as stack:
                pixels = None
                if kind == 'cover' and 'width' in query:
                    if query['width'][0] not in ('320', '480', '640'):
                        raise Failure(400, 'invalid_cover_width')
                    pixels = int(query['width'][0])
                expected = self.headers.get('If-Match') if number else None
                if expected is not None and not re.fullmatch(r'"[a-f0-9]{64}"', expected):
                    raise Failure(400, 'invalid_page_precondition')
                stream, length, sha = reader.image(gid, int(number) if number else None,
                                                  expected[1:-1] if expected else None)
                stack.enter_context(stream)
                content_type = 'application/octet-stream'
                if pixels and reader.thumbnails is not None:
                    derivative = reader.thumbnails.get(stream, sha, pixels)
                    if derivative:
                        data, sha = derivative
                        stream = stack.enter_context(io.BytesIO(data))
                        length, content_type = len(data), 'image/jpeg'
                etag = '"' + sha + '"'
                if etag_matches(self.headers.get("If-None-Match"), etag):
                    self.send_response(304); self.send_header("ETag", etag)
                    self.send_header("Cache-Control", "private, no-cache")
                    self.end_headers(); return
                self.send_response(200)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(length)); self.send_header("ETag", etag)
                self.send_header("Cache-Control", "private, no-cache")
                self.end_headers()
                if self.server.sendfile and not isinstance(stream, io.BytesIO):
                    self.wfile.flush()
                    offset = 0
                    while offset < length:
                        sent = self.connection.sendfile(stream, offset=offset, count=min(1024**2, length-offset))
                        if not sent:
                            raise OSError('short file transfer')
                        offset += sent
                else:
                    while chunk := stream.read(256 * 1024):
                        self.wfile.write(chunk)
        except (Failure, ManualError) as error:
            self.reply(error.status, {"error": error.code})
        except (FileNotFoundError, NotADirectoryError):
            self.reply(404, {"error": "image_missing"})
        except (sqlite3.Error, OSError):
            # Includes WAL visibility and concurrent atomic file replacement.
            self.close_connection = True
            if getattr(self, 'response_started', False):
                return  # never append JSON/a second response inside an image
            try: self.reply(503, {"error": "storage_temporarily_unavailable"})
            except OSError: pass
        except (ValueError, KeyError, TypeError):
            self.reply(409, {"error": "invalid_data"})


class PersistentHandler(Handler):
    protocol_version = 'HTTP/1.1'

    def setup(self):
        super().setup()
        self.request.settimeout(self.server.idle_timeout)
        self.requests_seen = 0

    def parse_request(self):
        valid = super().parse_request()
        self.requests_seen += 1
        if self.requests_seen >= self.server.request_limit:
            self.close_connection = True
        return valid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", default="/source")
    parser.add_argument("--state", default="/state")
    parser.add_argument('--manual-root', help='Optional separate writable manual library; never the sync store or reader state')
    parser.add_argument("--new-pin", action="store_true")
    parser.add_argument('--set-password', action='store_true', help='Set NAS pairing password interactively; never pass it as a command argument')
    parser.add_argument("--listen", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8089)
    parser.add_argument('--no-thumbnails', action='store_true')
    parser.add_argument('--no-cover-warm', action='store_true', help='Disable publication-only idle cover preparation')
    parser.add_argument('--no-related-warm', action='store_true', help='Disable idle author/series snapshot preparation')
    parser.add_argument('--warm-pixels', type=int, choices=(320, 480, 640), default=480)
    parser.add_argument('--keep-alive', action='store_true', help='Isolated A/B candidate; disabled by default')
    parser.add_argument('--sendfile', action='store_true', help='Separate file-send experiment; disabled by default')
    args = parser.parse_args()
    identity = Identity(args.state)
    if args.set_password:
        first = getpass.getpass('New reader password: ')
        second = getpass.getpass('Confirm reader password: ')
        if first != second:
            raise SystemExit('Passwords do not match; unchanged')
        identity.set_password(first.encode('utf-8'))
        del first, second
        print('Fixed reader password configured; existing paired credentials preserved.', flush=True)
        return
    if args.new_pin:
        print(identity.new_pin(), flush=True); return
    print("LocalShelf NAS Reader ready. Pairing can use a fixed password (--set-password); otherwise --new-pin. Private LAN HTTP only.", flush=True)
    thumbnails = None
    if not args.no_thumbnails:
        try:
            from thumbnails import ThumbnailCache
            thumbnails = ThumbnailCache(args.state)
        except (ImportError, OSError, sqlite3.Error):
            print('Cover derivatives unavailable; original covers remain available.', flush=True)
    reader = Reader(args.source, identity, thumbnails)
    manual_store = manual_reader = None
    if args.manual_root:
        manual_store = ManualStore(args.manual_root, forbidden=(args.source, args.state))
        manual_thumbnails = None
        if not args.no_thumbnails:
            try:
                from thumbnails import ThumbnailCache
                manual_thumbnails = ThumbnailCache(manual_store.root / '.cache')
            except (ImportError, OSError, sqlite3.Error): pass
        manual_reader = Reader(manual_store.root, identity, manual_thumbnails,
                               library_id=manual_store.library_id, order_policy=MANUAL_POLICY,
                               cache_root=manual_store.root / '.cache')
    try:
        with Server((args.listen, args.port), reader, keep_alive=args.keep_alive, sendfile=args.sendfile,
                    cover_warm=not args.no_cover_warm, warm_pixels=args.warm_pixels,
                    related_warm=not args.no_related_warm, manual_store=manual_store, manual_reader=manual_reader) as server:
            server.serve_forever()
    finally:
        if manual_reader is not None: manual_reader.close()
        reader.close()


if __name__ == "__main__":
    main()
