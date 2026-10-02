"""One idle, bounded worker following *published* catalog revisions.

Only metadata is walked. First enablement establishes a baseline, not a full
library render. All durable state and derivatives live outside the source.
"""
import re
import sqlite3
import threading
import time
from pathlib import Path


class CoverWarmup:
    def __init__(self, reader, state, idle, pixels=480, quiet_seconds=15, clock=time.monotonic):
        if pixels not in (320, 480, 640):
            raise ValueError('invalid warm size')
        self.reader, self.idle, self.pixels = reader, idle, pixels
        self.root = Path(state)
        self.path = self.root / 'cover-warmup.sqlite3'
        self.clock, self.quiet_seconds = clock, quiet_seconds
        self.marker, self.changed_at, self.scan = None, 0, None
        self.db = None
        self.stop_event = threading.Event()
        self.thread = None
        self.stats = dict(baselines=0, publications=0, scanned=0, warmed=0,
                          skipped=0, errors=0, interrupted=0)

    def database(self):
        if self.db is None:
            self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
            if self.root.is_symlink() or self.path.is_symlink():
                raise OSError('unsafe warm state')
            self.db = sqlite3.connect(self.path, timeout=1)
            self.db.execute('PRAGMA cache_size=-1024')
            self.db.executescript('''
                CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY,value TEXT);
                CREATE TABLE IF NOT EXISTS observed(gid TEXT PRIMARY KEY,sha TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS pending(gid TEXT PRIMARY KEY,sha TEXT NOT NULL,rank INTEGER);
                CREATE TEMP TABLE IF NOT EXISTS incoming(gid TEXT PRIMARY KEY,sha TEXT NOT NULL,rank INTEGER);
            ''')
        return self.db

    def source_marker(self):
        # The observer detects ANY writer commit, not just a changed rank list.
        with self.reader.pages_lock:
            epoch = self.reader.pages_epoch()
            with self.reader.connection() as db:
                row = db.execute("SELECT value FROM state WHERE key='active'").fetchone()
        revision = row[0] if row else None
        if revision is not None and not re.fullmatch('[a-f0-9]{64}', revision):
            raise ValueError('invalid published revision')
        return epoch, revision

    def tick(self):
        if self.stop_event.is_set() or not self.idle() or self.reader.thumbnails is None:
            return
        now, marker = self.clock(), self.source_marker()
        if marker != self.marker:
            if self.scan is not None: self.stats['interrupted'] += 1
            self.marker, self.changed_at, self.scan = marker, now, None
            return
        if marker[1] is None or now - self.changed_at < self.quiet_seconds:
            return
        db = self.database()
        row = db.execute("SELECT value FROM state WHERE key='revision'").fetchone()
        if row is None or row[0] != marker[1]:
            self.scan_slice(marker, first=row is None)
            return
        pending = db.execute('SELECT gid,sha FROM pending ORDER BY rank,gid LIMIT 1').fetchone()
        if pending is None or not self.idle():
            return
        gid, expected = pending
        try:
            stream, _, sha = self.reader.image(gid)
            with stream:
                if self.source_marker() != marker:
                    return
                if sha != expected:
                    # Same publication can be updated in-place by the sync
                    # protocol. Do not warm it, and do not block later jobs.
                    self.stats['skipped'] += 1
                    with db: db.execute('DELETE FROM pending WHERE gid=? AND sha=?', (gid, expected))
                    return
                if not self.idle() or self.stop_event.is_set(): return
                cache = self.reader.thumbnails
                before = cache.stats['busy']
                value = cache.get(stream, sha, self.pixels, background=True)
                if cache.stats['busy'] != before:
                    return  # retry later; background never queues behind foreground
                self.stats['warmed' if value else 'skipped'] += 1
        except Exception:
            # A bad/missing cover cannot block the queue or the reading service.
            # Retry is possible on a subsequent publication with a new identity.
            self.stats['errors'] += 1
        with db:
            db.execute('DELETE FROM pending WHERE gid=? AND sha=?', (gid, expected))

    def scan_slice(self, marker, first):
        if self.scan is None: self.scan = []
        # Cover discovery must not populate page counts for the whole library.
        # Reader-facing lists calculate them lazily for the requested page only.
        page = self.reader.list(len(self.scan), 500, include_counts=False)
        if page['catalogRevision'] != marker[1] or self.source_marker() != marker:
            self.scan = None
            self.stats['interrupted'] += 1
            return
        for book in page['books']:
            sha = book['coverIdentity'] if book['available'] else ''
            if sha and not re.fullmatch('[a-f0-9]{64}', sha):
                raise ValueError('invalid cover identity')
            self.scan.append((book['id'], sha, book['rank']))
        self.stats['scanned'] += len(page['books'])
        if len(self.scan) > 20000 or len(self.scan) > page['total']:
            raise ValueError('warm metadata budget')
        if len(self.scan) < page['total']:
            if not page['books']: raise ValueError('short catalog')
            return
        if self.stop_event.is_set() or not self.idle(): return
        db = self.database()
        with db:
            db.execute('DELETE FROM incoming')
            db.executemany('INSERT INTO incoming VALUES(?,?,?)', self.scan)
            # Keep unfinished jobs only if the latest publication still uses
            # exactly those bytes. Pure reordering updates priority, not images.
            db.execute('DELETE FROM pending WHERE NOT EXISTS (SELECT 1 FROM incoming i WHERE i.gid=pending.gid AND i.sha=pending.sha)')
            if not first:
                db.execute('''INSERT OR REPLACE INTO pending
                    SELECT i.* FROM incoming i LEFT JOIN observed o ON o.gid=i.gid
                    WHERE i.sha<>'' AND (o.gid IS NULL OR o.sha<>i.sha)''')
            db.execute('UPDATE pending SET rank=(SELECT rank FROM incoming WHERE incoming.gid=pending.gid)')
            db.execute('DELETE FROM observed')
            db.execute('INSERT INTO observed SELECT gid,sha FROM incoming')
            db.execute("INSERT OR REPLACE INTO state VALUES('revision',?)", (marker[1],))
            db.execute('DELETE FROM incoming')
        self.scan = None
        self.stats['baselines' if first else 'publications'] += 1

    def run(self):
        try:
            while not self.stop_event.wait(1):
                try: self.tick()
                except Exception:
                    # Optional optimization: read paths must work without it.
                    self.stats['errors'] += 1
                    self.scan = None
                    self.stop_event.wait(15)
        finally:
            if self.db is not None: self.db.close(); self.db = None

    def start(self):
        if self.thread is None:
            self.thread = threading.Thread(target=self.run, name='cover-warmup', daemon=True)
            self.thread.start()

    def close(self):
        self.stop_event.set()
        if self.thread is not None:
            self.thread.join()
        elif self.db is not None:
            self.db.close(); self.db = None
