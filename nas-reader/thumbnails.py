"""Optional cover derivatives. Source bytes/metadata are never written here."""
import hashlib
import io
from pathlib import Path
import sqlite3
import threading
import time
from collections import OrderedDict

from PIL import Image, ImageCms, ImageOps, __version__ as pillow_version


class ThumbnailCache:
    sizes = (320, 480, 640)
    max_pixels = 16_000_000
    max_output = 1024 * 1024

    def __init__(self, state, budget=256 * 1024**2, count_limit=20000, memory_budget=8 * 1024**2):
        self.root = Path(state) / 'cover-cache-v1'
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        if self.root.is_symlink():
            raise OSError('unsafe cache directory')
        self.path = self.root / 'covers.sqlite3'
        if self.path.is_symlink():
            raise OSError('unsafe cache database')
        self.budget, self.count_limit = budget, count_limit
        self.lock = threading.Lock()
        self.memory_lock = threading.Lock()
        self.memory = OrderedDict()
        self.memory_bytes = 0
        self.memory_budget = max(0, memory_budget)
        self.touches = OrderedDict()
        self.last_access = time.monotonic()
        self.last_maintenance = 0
        self.needs_vacuum = False
        self.closed = False
        self.db = None
        self.generation = threading.BoundedSemaphore(1)
        self.stats = dict(hits=0, generated=0, busy=0, fallback=0, already_small=0,
                          memory_hits=0, disk_reads=0, db_connections=0, aggregate_scans=0, maintenance=0)
        with self.connection() as db:
            db.execute('PRAGMA auto_vacuum=INCREMENTAL')
            db.execute('CREATE TABLE IF NOT EXISTS covers(key TEXT PRIMARY KEY, data BLOB NOT NULL, sha TEXT NOT NULL, size INTEGER NOT NULL, used REAL NOT NULL)')
            db.execute('CREATE INDEX IF NOT EXISTS cover_lru ON covers(used)')
            db.execute('CREATE TABLE IF NOT EXISTS cover_totals(id INTEGER PRIMARY KEY CHECK(id=1),bytes INTEGER NOT NULL,items INTEGER NOT NULL)')
            # One startup reconciliation; per-insert accounting is O(1) and
            # transactional, including replacement, eviction and rollback.
            db.execute('INSERT OR REPLACE INTO cover_totals SELECT 1,COALESCE(SUM(size),0),COUNT(*) FROM covers')
            self.stats['aggregate_scans'] += 1
            db.executescript('''
                CREATE TRIGGER IF NOT EXISTS covers_added AFTER INSERT ON covers BEGIN
                  UPDATE cover_totals SET bytes=bytes+NEW.size,items=items+1 WHERE id=1;
                END;
                CREATE TRIGGER IF NOT EXISTS covers_removed AFTER DELETE ON covers BEGIN
                  UPDATE cover_totals SET bytes=bytes-OLD.size,items=items-1 WHERE id=1;
                END;
                CREATE TRIGGER IF NOT EXISTS covers_resized AFTER UPDATE OF size ON covers BEGIN
                  UPDATE cover_totals SET bytes=bytes+NEW.size-OLD.size WHERE id=1;
                END;
            ''')

    def connection(self):
        # Independent maintenance/test connection; production uses one connection
        # serialized by self.lock. Source DB settings are never changed.
        return ClosingConnection(self.path)

    def database(self):
        if self.closed:
            raise OSError('cache closed')
        if self.db is None:
            if self.path.is_symlink():
                raise OSError('unsafe cache database')
            self.db = sqlite3.connect(self.path, timeout=1, check_same_thread=False)
            self.db.execute('PRAGMA cache_size=-2048')
            self.stats['db_connections'] += 1
        return self.db

    def clear_memory(self):
        with self.memory_lock:
            self.memory.clear(); self.memory_bytes = 0

    def remember(self, key, data, sha, used):
        cost = len(data) + 512
        with self.memory_lock:
            if self.closed:
                return
            old = self.memory.pop(key, None)
            if old: self.memory_bytes -= len(old[0]) + 512
            if cost > self.memory_budget:
                return
            while self.memory and (self.memory_bytes + cost > self.memory_budget or len(self.memory) >= 256):
                _, old = self.memory.popitem(last=False)
                self.memory_bytes -= len(old[0]) + 512
            self.memory[key] = (data, sha, used)
            self.memory_bytes += cost

    def touch(self, key, used, now):
        # Called under memory_lock. Approximate LRU timestamps may be delayed;
        # this affects eviction order, never content validity.
        if now - used > 60:
            self.touches[key] = now
            self.touches.move_to_end(key)
            while len(self.touches) > 1024: self.touches.popitem(last=False)
            return now
        return used

    def flush_touches(self, db):
        with self.memory_lock:
            touches = list(self.touches.items()); self.touches.clear()
        db.executemany('UPDATE covers SET used=MAX(used,?) WHERE key=?', [(used,key) for key,used in touches])

    def maintain(self, force=False):
        now = time.monotonic()
        if self.closed or (not force and (now-self.last_access < 15 or now-self.last_maintenance < 30)):
            return
        if not self.lock.acquire(blocking=False): return
        try:
            if self.closed: return
            with self.database() as db:
                self.flush_touches(db)
            if self.needs_vacuum:
                self.database().execute('PRAGMA incremental_vacuum(64)')
                self.needs_vacuum = False
            self.last_maintenance = now
            self.stats['maintenance'] += 1
        except (OSError, sqlite3.Error):
            self.last_maintenance = now
        finally:
            self.lock.release()

    def close(self):
        with self.lock:
            if self.closed: return
            self.closed = True
            if self.db is not None:
                self.db.close(); self.db = None
            with self.memory_lock:
                self.memory.clear(); self.memory_bytes = 0; self.touches.clear()

    def cached(self, key):
        now = time.time()
        with self.memory_lock:
            self.last_access = time.monotonic()
            hit = self.memory.get(key)
            if hit:
                self.memory.move_to_end(key)
                self.memory[key] = (hit[0], hit[1], self.touch(key, hit[2], now))
                self.stats['hits'] += 1; self.stats['memory_hits'] += 1
                return hit[:2]
        with self.lock, self.database() as db:
            self.stats['disk_reads'] += 1
            row = db.execute('SELECT data,sha,size,used FROM covers WHERE key=?', (key,)).fetchone()
            if row is None:
                return None
            data, sha, size, used = row
            if size != len(data) or size > self.max_output or hashlib.sha256(data).hexdigest() != sha:
                db.execute('DELETE FROM covers WHERE key=?', (key,))
                return None
            with self.memory_lock:
                used = self.touch(key, used, now)
            self.stats['hits'] += 1
            self.remember(key, data, sha, used)
            return data, sha

    def store(self, key, data, sha):
        if len(data) > min(self.max_output, self.budget):
            return
        with self.lock:
            with self.database() as db:
                # UPSERT fires the size delta trigger, unlike REPLACE's implicit
                # delete whose trigger depends on recursive_triggers configuration.
                db.execute('INSERT INTO covers VALUES(?,?,?,?,?) ON CONFLICT(key) DO UPDATE SET data=excluded.data,sha=excluded.sha,size=excluded.size,used=excluded.used', (key, data, sha, len(data), time.time()))
                total, count = db.execute('SELECT bytes,items FROM cover_totals WHERE id=1').fetchone()
                if total > self.budget or count > self.count_limit: self.flush_touches(db)
                while total > self.budget or count > self.count_limit:
                    old, size = db.execute('SELECT key,size FROM covers ORDER BY used,key LIMIT 1').fetchone()
                    db.execute('DELETE FROM covers WHERE key=?', (old,))
                    total -= size
                    count -= 1
                    self.needs_vacuum = True
            # Publish memory in DB commit order, even if callers share a key.
            self.remember(key, data, sha, time.time())

    def render(self, stream, pixels):
        # Decode only frame zero. Animated BODY requests never enter this module.
        stream.seek(0)
        with Image.open(stream) as source:
            width, height = source.size
            if width <= 0 or height <= 0 or width * height > self.max_pixels:
                raise ValueError('cover pixel limit')
            if width <= pixels and height <= pixels * 2 and not getattr(source, 'is_animated', False):
                return None  # existing suitable .thumb needs no lossy re-encode
            source.seek(0)
            source.draft('RGB', (pixels, pixels * 2))
            oriented = ImageOps.exif_transpose(source)
            try:
                oriented.thumbnail((pixels, pixels * 2), Image.Resampling.LANCZOS, reducing_gap=2.0)
                profile = source.info.get('icc_profile')
                if profile:
                    if len(profile) > 1024 * 1024:
                        raise ValueError('cover profile limit')
                    converted = ImageCms.profileToProfile(oriented, ImageCms.ImageCmsProfile(io.BytesIO(profile)), ImageCms.createProfile('sRGB'), outputMode='RGBA' if oriented.mode == 'RGBA' else 'RGB')
                    oriented.close()
                    oriented = converted
                # Composite transparency onto the app's dark background; strip
                # EXIF/location data from disposable derivatives, not originals.
                with oriented.convert('RGBA') as rgba, Image.new('RGB', rgba.size, (18, 18, 18)) as rgb:
                    rgb.paste(rgba, mask=rgba.getchannel('A'))
                    output = io.BytesIO()
                    rgb.save(output, format='JPEG', quality=85, optimize=False)
                    data = output.getvalue()
            finally:
                oriented.close()
        if len(data) > self.max_output:
            raise ValueError('cover byte limit')
        return data, hashlib.sha256(data).hexdigest()

    def cache_key(self, source_sha, pixels):
        return hashlib.sha256(f'cover-v2-srgb-jpeg85-dark-exif-{pillow_version}:{pixels}:{source_sha}'.encode()).hexdigest()

    def get(self, stream, source_sha, pixels, background=False):
        if pixels not in self.sizes:
            raise ValueError('unsupported thumbnail size')
        key = self.cache_key(source_sha, pixels)
        try:
            hit = self.cached(key)
            if hit:
                return hit
            # At most one decoder on N100. Do not queue all visible covers behind
            # it: busy requests return original bytes and remain compatible.
            if not self.generation.acquire(timeout=0 if background else 0.15):
                self.stats['busy'] += 1
                return None
            try:
                hit = self.cached(key)
                if hit:
                    return hit
                rendered = self.render(stream, pixels)
                if rendered is None:
                    self.stats['already_small'] += 1
                    return None
                data, sha = rendered
                self.stats['generated'] += 1
                try:
                    self.store(key, data, sha)
                except (OSError, sqlite3.Error):
                    pass  # disk full/readonly cache must not break reading
                return data, sha
            finally:
                self.generation.release()
        except (OSError, sqlite3.Error, ValueError, Image.DecompressionBombError, ImageCms.PyCMSError):
            self.stats['fallback'] += 1
            return None
        finally:
            if not stream.closed:
                stream.seek(0)


class ClosingConnection:
    def __init__(self, path):
        self.db = sqlite3.connect(path, timeout=1)
        self.db.execute('PRAGMA journal_mode=TRUNCATE')

    def __enter__(self):
        return self.db

    def __exit__(self, kind, value, traceback):
        try:
            self.db.rollback() if kind else self.db.commit()
        finally:
            self.db.close()
