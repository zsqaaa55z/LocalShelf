"""Private manual library. Never opens the EhViewer source or sync database.

Uploads are immutable, verified page by page, and visible only after an atomic
catalog commit. The deterministic manifest key resumes across client restarts;
changed content creates a NEW book rather than overwriting an existing one.
"""
import contextlib
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import threading
import uuid

POLICY = 'manual-import-newest-first-v1'
MAX_FILE = 50 * 1024**2
MAX_MANIFEST = 8 * 1024**2
MAX_BOOK = 20 * 1024**3
EXTENSIONS = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'avif'}


class ManualError(Exception):
    def __init__(self, status, code):
        self.status, self.code = status, code


def packed(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()


def validate_manifest(value):
    if not isinstance(value, dict) or set(value) != {'title', 'files'}:
        raise ManualError(400, 'invalid_upload_manifest')
    title, files = value['title'], value['files']
    if not isinstance(title, str) or not title.strip() or len(title.encode()) > 4096 or any(ord(c) < 32 for c in title):
        raise ManualError(400, 'invalid_upload_title')
    if not isinstance(files, list) or not 1 <= len(files) <= 20000:
        raise ManualError(400, 'invalid_upload_pages')
    clean, names, total, previous_time = [], set(), 0, -1
    for number, item in enumerate(files, 1):
        if not isinstance(item, dict) or set(item) != {'name', 'size', 'sha256', 'modifiedUtcTicks'}:
            raise ManualError(400, 'invalid_upload_file')
        name, size, sha = item['name'], item['size'], item['sha256']
        if not isinstance(name, str) or len(name.encode()) > 1024 or not name or any(c in name for c in '/\\\x00:') or any(ord(c) < 32 for c in name) or name in ('.', '..') or name.casefold() in names:
            raise ManualError(400, 'invalid_upload_name')
        ext = name.rsplit('.', 1)[-1].lower()
        stamp = item['modifiedUtcTicks']
        if type(stamp) is not int or not 0 <= stamp <= 3155378975999999999 or stamp < previous_time:
            raise ManualError(400, 'invalid_modified_time_order')
        previous_time = stamp
        if ext not in EXTENSIONS or type(size) is not int or not 0 < size <= MAX_FILE or not isinstance(sha, str) or not re.fullmatch('[a-f0-9]{64}', sha):
            raise ManualError(400, 'invalid_upload_file')
        total += size
        if total > MAX_BOOK:
            raise ManualError(413, 'upload_book_too_large')
        names.add(name.casefold())
        clean.append({'name': name, 'size': size, 'sha256': sha, 'modifiedUtcTicks': stamp})
    return {'title': title.strip(), 'files': clean}


def image_signature(data, ext):
    if ext in ('jpg', 'jpeg'): return data.startswith(b'\xff\xd8\xff')
    if ext == 'png': return data.startswith(b'\x89PNG\r\n\x1a\n')
    if ext == 'gif': return data.startswith((b'GIF87a', b'GIF89a'))
    if ext == 'webp': return data[:4] == b'RIFF' and data[8:12] == b'WEBP'
    if ext == 'avif': return data[4:8] == b'ftyp' and (b'avif' in data[8:64] or b'avis' in data[8:64])
    return False


class ManualStore:
    def __init__(self, root, forbidden=()):
        raw = Path(root).absolute()
        if raw.is_symlink(): raise ValueError('Manual root must not be a symlink')
        self.root = raw.resolve()
        for value in forbidden:
            other = Path(value).resolve()
            if self.root == other or self.root in other.parents or other in self.root.parents:
                raise ValueError('Manual storage must be separate from sync and reader state')
        self.root.mkdir(parents=True, exist_ok=True)
        for name in ('books', 'staging'):
            path = self.root / name
            if path.is_symlink(): raise ValueError('Unsafe manual directory')
            path.mkdir(exist_ok=True)
        if (self.root / 'index.sqlite3').is_symlink(): raise ValueError('Unsafe manual database')
        self.lock = threading.RLock()
        # One writer request at a time. Reading has a separate semaphore and DB.
        with self.db() as db:
            db.executescript('''PRAGMA journal_mode=WAL;
              CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY,value TEXT NOT NULL);
              CREATE TABLE IF NOT EXISTS catalogs(revision TEXT PRIMARY KEY,body TEXT NOT NULL);
              CREATE TABLE IF NOT EXISTS ready(revision TEXT,gid TEXT,available INTEGER,PRIMARY KEY(revision,gid));
              CREATE TABLE IF NOT EXISTS files(gid TEXT,path TEXT,directory TEXT,size INTEGER,sha TEXT,PRIMARY KEY(gid,path));
              CREATE TABLE IF NOT EXISTS book_versions(gid TEXT PRIMARY KEY,directory TEXT,proof TEXT,available INTEGER);
              CREATE TABLE IF NOT EXISTS imports(id TEXT PRIMARY KEY,body TEXT NOT NULL,book_id INTEGER);
              CREATE TABLE IF NOT EXISTS uploaded(id TEXT,number INTEGER,size INTEGER,sha TEXT,PRIMARY KEY(id,number));
              CREATE TABLE IF NOT EXISTS manual_books(id INTEGER PRIMARY KEY AUTOINCREMENT,title TEXT,directory TEXT UNIQUE);
            ''')
            db.execute("INSERT OR IGNORE INTO state VALUES('libraryId',?)", (uuid.uuid4().hex + uuid.uuid4().hex,))
            self.library_id = db.execute("SELECT value FROM state WHERE key='libraryId'").fetchone()[0]
            if not re.fullmatch('[a-f0-9]{64}', self.library_id): raise ValueError('Invalid manual identity')
            if not db.execute("SELECT 1 FROM state WHERE key='active'").fetchone(): self.publish(db)

    @contextlib.contextmanager
    def db(self):
        db = sqlite3.connect(self.root / 'index.sqlite3', timeout=10)
        db.row_factory = sqlite3.Row
        try:
            with db: yield db
        finally: db.close()

    def upload_token(self, identity):
        return hmac.new(identity.value['token'].encode(), ('manual-upload-v1\n' + self.library_id).encode(), hashlib.sha256).hexdigest()

    @contextlib.contextmanager
    def writer(self):
        if not self.lock.acquire(blocking=False): raise ManualError(503, 'manual_upload_busy')
        fd = None
        try:
            fd = os.open(self.root / '.writer.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
            try: fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError: raise ManualError(503, 'manual_upload_busy') from None
            yield
        finally:
            if fd is not None: os.close(fd)
            self.lock.release()

    def start(self, raw):
        manifest = validate_manifest(raw)
        body = packed(manifest)
        if len(body) > MAX_MANIFEST: raise ManualError(413, 'upload_manifest_too_large')
        key = hashlib.sha256(body).hexdigest()
        with self.writer(), self.db() as db:
            if not db.execute('SELECT 1 FROM imports WHERE id=?', (key,)).fetchone():
                if db.execute('SELECT COUNT(*) FROM imports WHERE book_id IS NULL').fetchone()[0] >= 20:
                    raise ManualError(409, 'too_many_pending_uploads')
                if db.execute('SELECT COUNT(*) FROM manual_books').fetchone()[0] >= 20000:
                    raise ManualError(409, 'manual_library_full')
                if shutil.disk_usage(self.root).free < sum(f['size'] for f in manifest['files']) + 1024**3:
                    raise ManualError(507, 'manual_disk_full')
                folder = self.root / 'staging' / key
                if folder.is_symlink(): raise ManualError(409, 'unsafe_manual_path')
                folder.mkdir(exist_ok=True)
                db.execute('INSERT INTO imports(id,body) VALUES(?,?)', (key, body.decode()))
            return self.status_in(db, key)

    def record(self, db, key):
        if not re.fullmatch('[a-f0-9]{64}', key): raise ManualError(400, 'invalid_upload_id')
        record = db.execute('SELECT * FROM imports WHERE id=?', (key,)).fetchone()
        if record is None: raise ManualError(404, 'upload_not_found')
        return record, json.loads(record['body'])

    def folder(self, key):
        # An interrupted commit can have moved the complete folder already.
        final = self.root / 'books' / key
        return final if final.exists() else self.root / 'staging' / key

    @staticmethod
    def page_name(number, item):
        return f'{number:08d}.' + item['name'].rsplit('.', 1)[-1].lower()

    def status_in(self, db, key):
        record, manifest = self.record(db, key)
        have = {r[0]: r[1] for r in db.execute('SELECT number,size FROM uploaded WHERE id=?', (key,))}
        folder = self.folder(key)
        missing = []
        for i, item in enumerate(manifest['files'], 1):
            path = folder / self.page_name(i, item)
            if i not in have or path.is_symlink() or not path.is_file() or path.stat().st_size != item['size']:
                missing.append(i)
        return dict(uploadId=key, bookId=str(record['book_id']) if record['book_id'] else None,
                    published=record['book_id'] is not None, missing=missing, total=len(manifest['files']), libraryId=self.library_id)

    def status(self, key):
        with self.writer(), self.db() as db: return self.status_in(db, key)

    def pending(self):
        # Metadata only: don't stat hundreds of thousands of pages in this UI.
        with self.db() as db:
            result = []
            for row in db.execute('SELECT id,body FROM imports WHERE book_id IS NULL LIMIT 20'):
                manifest = json.loads(row['body'])
                received = db.execute('SELECT COUNT(*) FROM uploaded WHERE id=?', (row['id'],)).fetchone()[0]
                result.append(dict(uploadId=row['id'], title=manifest['title'], received=received, total=len(manifest['files'])))
            return {'uploads': result}

    def receive(self, key, number, stream, length):
        with self.writer(), self.db() as db:
            record, manifest = self.record(db, key)
            if record['book_id'] is not None: raise ManualError(409, 'upload_already_published')
            if not 1 <= number <= len(manifest['files']): raise ManualError(400, 'invalid_upload_page')
            item = manifest['files'][number-1]
            if length != item['size']: raise ManualError(400, 'upload_size_mismatch')
            if shutil.disk_usage(self.root).free < length + 1024**3: raise ManualError(507, 'manual_disk_full')
            folder = self.folder(key)
            if folder.is_symlink(): raise ManualError(409, 'unsafe_manual_path')
            name = self.page_name(number, item)
            path, tmp = folder / name, folder / (name + '.partial')
            # O_NOFOLLOW and exclusive creation: never follow an externally
            # planted path. Leftover partials belong only to this private store.
            if tmp.is_symlink(): raise ManualError(409, 'unsafe_manual_path')
            tmp.unlink(missing_ok=True)
            digest, prefix, remaining = hashlib.sha256(), b'', length
            try:
                with open(tmp, 'xb') as output:
                    while remaining:
                        chunk = stream.read(min(256 * 1024, remaining))
                        if not chunk: raise ManualError(400, 'upload_incomplete')
                        if len(prefix) < 64: prefix += chunk[:64-len(prefix)]
                        output.write(chunk); digest.update(chunk); remaining -= len(chunk)
                    if digest.hexdigest() != item['sha256']: raise ManualError(409, 'upload_hash_mismatch')
                    if not image_signature(prefix, name.rsplit('.', 1)[-1]): raise ManualError(415, 'upload_not_image')
                    output.flush(); os.fsync(output.fileno())
                os.replace(tmp, path)
                self.sync_dir(folder)
                db.execute('INSERT OR REPLACE INTO uploaded VALUES(?,?,?,?)', (key, number, length, item['sha256']))
            finally:
                tmp.unlink(missing_ok=True)
            return {'received': number}

    @staticmethod
    def sync_dir(path):
        fd = os.open(path, os.O_RDONLY)
        try: os.fsync(fd)
        finally: os.close(fd)

    def commit(self, key):
        with self.writer(), self.db() as db:
            record, manifest = self.record(db, key)
            status = self.status_in(db, key)
            if status['missing']: raise ManualError(409, 'upload_pages_missing')
            if record['book_id'] is not None: return status
            db.execute('BEGIN IMMEDIATE')
            if db.execute('SELECT COUNT(*) FROM manual_books').fetchone()[0] >= 20000:
                raise ManualError(409, 'manual_library_full')
            folder = self.folder(key)
            if folder.is_symlink(): raise ManualError(409, 'unsafe_manual_path')
            final = self.root / 'books' / key
            if folder != final:
                os.rename(folder, final)
                self.sync_dir(self.root / 'books'); self.sync_dir(self.root / 'staging')
            gid = str(db.execute('INSERT INTO manual_books(title,directory) VALUES(?,?)', (manifest['title'], key)).lastrowid)
            db.executemany('INSERT INTO files VALUES(?,?,?,?,?)', [
                (gid, self.page_name(i, f), key, f['size'], f['sha256']) for i, f in enumerate(manifest['files'], 1)])
            db.execute('INSERT INTO book_versions VALUES(?,?,?,1)', (gid, key, key))
            db.execute('UPDATE imports SET book_id=? WHERE id=?', (int(gid), key))
            self.publish(db)
            return self.status_in(db, key)

    def discard(self, key):
        # Only uncommitted uploads; no delete/overwrite API for published books.
        with self.writer(), self.db() as db:
            record, _ = self.record(db, key)
            if record['book_id'] is not None: raise ManualError(409, 'upload_already_published')
            folder = self.folder(key)
            if folder.is_symlink(): raise ManualError(409, 'unsafe_manual_path')
            if folder.exists(): shutil.rmtree(folder)
            db.execute('DELETE FROM uploaded WHERE id=?', (key,)); db.execute('DELETE FROM imports WHERE id=?', (key,))
            return {'discarded': True}

    def publish(self, db):
        books = [dict(id=str(r['id']), title=r['title'], directory=r['directory'], time=r['id'], rank=i)
                 for i, r in enumerate(db.execute('SELECT * FROM manual_books ORDER BY id DESC'))]
        body = packed(dict(schema=1, orderSource=POLICY, orderVerified=True, books=books))
        if len(body) > 16 * 1024**2: raise ManualError(409, 'manual_catalog_full')
        revision = hashlib.sha256(body).hexdigest()
        db.execute('INSERT OR REPLACE INTO catalogs VALUES(?,?)', (revision, body.decode()))
        db.executemany('INSERT OR REPLACE INTO ready VALUES(?,?,1)', ((revision, b['id']) for b in books))
        db.execute("INSERT OR REPLACE INTO state VALUES('active',?)", (revision,))
        # WAL readers retain their prior transaction; no old originals are erased.
        db.execute('DELETE FROM catalogs WHERE revision != ?', (revision,))
        db.execute('DELETE FROM ready WHERE revision != ?', (revision,))


def handle_upload(handler, route, post, identity, store):
    """Returns True only for handled upload endpoints (read routes fall through)."""
    path = route.path
    if path != '/v2/manual-login' and not path.startswith('/manual/v1/uploads'):
        return False
    if store is None: raise ManualError(404, 'manual_library_disabled')
    if route.query: raise ManualError(400, 'invalid_upload_query')
    length = int(handler.headers.get('Content-Length', '-1'))
    if path == '/v2/manual-login':
        if not post or not 8 <= length <= 128: raise ManualError(400, 'invalid_password_length')
        raw = handler.rfile.read(length)
        if len(raw) != length: raise ManualError(400, 'invalid_password_length')
        identity.pair_password(raw)  # reuse persisted password throttling
        handler.reply(200, dict(token=store.upload_token(identity), libraryId=store.library_id, version=1))
        return True
    if not hmac.compare_digest(handler.headers.get('Authorization', ''), 'Bearer ' + store.upload_token(identity)):
        raise ManualError(401, 'manual_auth_required')
    if path == '/manual/v1/uploads' and not post:
        handler.reply(200, store.pending())
        return True
    if path == '/manual/v1/uploads' and post:
        if not 1 <= length <= MAX_MANIFEST: raise ManualError(413, 'upload_manifest_too_large')
        raw = handler.rfile.read(length)
        if len(raw) != length: raise ManualError(400, 'upload_incomplete')
        handler.reply(200, store.start(json.loads(raw)))
        return True
    match = re.fullmatch(r'/manual/v1/uploads/([a-f0-9]{64})(?:/(commit|discard|files/([1-9][0-9]{0,4})))?', path)
    if not match: raise ManualError(404, 'route_not_found')
    key, action, number = match.groups()
    if not post and not action: value = store.status(key)
    elif post and number:
        if not 0 < length <= MAX_FILE: raise ManualError(413, 'upload_file_too_large')
        value = store.receive(key, int(number), handler.rfile, length)
    elif post and action in ('commit', 'discard') and length == 0:
        value = store.commit(key) if action == 'commit' else store.discard(key)
    else: raise ManualError(400, 'invalid_upload_request')
    handler.reply(200, value)
    return True
