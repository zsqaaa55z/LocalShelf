"""Only synthetic files and loopback HTTP; no NAS connection."""
import hashlib
import json
import sqlite3
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch
from server import Failure
from thumbnails import ThumbnailCache
import test_manifest as manifest_fixtures
import test_optimizations as optimization_fixtures


class ResponseCacheTests(unittest.TestCase):
    setUp = manifest_fixtures.ManifestTests.setUp
    tearDown = manifest_fixtures.ManifestTests.tearDown
    publish = manifest_fixtures.ManifestTests.publish
    file = manifest_fixtures.ManifestTests.file
    enable_receipts = manifest_fixtures.ManifestTests.enable_receipts
    server = optimization_fixtures.OptimizationTests.server
    request = optimization_fixtures.OptimizationTests.request

    def test_serialized_hit_is_identical_and_does_no_rebuild(self):
        self.enable_receipts()
        before = list(self.db.iterdump())
        first = self.reader.manifest_response('1')
        with patch('server.encoded', side_effect=AssertionError('reencoded')), patch.object(self.reader, 'records', side_effect=AssertionError('requeried')):
            for _ in range(25): self.assertIs(self.reader.manifest_response('1'), first)
        self.assertEqual(first[1], '"'+hashlib.sha256(first[0]).hexdigest()+'"')
        self.assertEqual(self.reader.manifest_stats, dict(hits=25, builds=1))
        self.assertEqual(before, list(self.db.iterdump()))

    def test_http_conditional_auth_variants_and_zero_body(self):
        self.enable_receipts()
        with self.server(keep_alive=True) as server:
            route = '/v1/books/1/manifest'
            status, headers, body = self.request(server, route)
            self.assertEqual(status, 200)
            self.assertEqual(headers['ETag'], '"'+hashlib.sha256(body).hexdigest()+'"')
            self.assertEqual(headers['Vary'], 'Authorization')
            self.assertEqual(headers['Cache-Control'], 'private, no-cache')
            for tag in [headers['ETag'], 'W/'+headers['ETag'], '"other", '+headers['ETag'], '*']:
                status, reply, data = self.request(server, route, tag)
                self.assertEqual((status, data), (304, b''))
                self.assertEqual(reply['ETag'], headers['ETag'])
                self.assertEqual(self.request(server, route, tag, auth=False)[0], 401)
            self.assertEqual(self.request(server, route, '"stale"')[0], 200)
            self.assertEqual(self.request(server, '/v1/books/999/manifest', '*')[0], 404)
            self.assertIn('conditional-manifest-v1', json.loads(self.request(server, '/v2/health')[2])['capabilities'])
            self.db.execute("DELETE FROM state WHERE key='active'"); self.db.commit()
            self.assertEqual(self.request(server, route, headers['ETag'])[0], 503)

    def test_reorder_retains_etag_but_changes_position(self):
        self.enable_receipts(); first = self.reader.manifest_response('1')
        self.books[0], self.books[1] = self.books[1], self.books[0]
        for n, book in enumerate(self.books): book.update(rank=n, time=100-n)
        self.revision = 'b'*64; self.publish(); self.enable_retention()
        self.assertEqual(self.reader.manifest_response('1'), first)
        self.assertEqual(self.reader.locate('1')['offset'], 1)

    def enable_retention(self):
        cat = json.loads(self.db.execute('SELECT body FROM catalogs WHERE revision=?', (self.revision,)).fetchone()[0])
        cat['retentionPolicy'] = 'keep-omitted-files-v1'
        self.db.execute('UPDATE catalogs SET body=? WHERE revision=?', (json.dumps(cat).encode(), self.revision)); self.db.commit()

    def test_receipt_changed_or_removed_never_returns_old_body(self):
        self.enable_receipts(); old = self.reader.manifest_response('1')
        self.file(self.books[0], '00000004.jpg', b'new')
        self.db.execute("UPDATE book_versions SET proof=? WHERE gid='1'", ('d'*64,)); self.db.commit()
        changed = self.reader.manifest_response('1')
        self.assertNotEqual(old[1], changed[1])
        self.assertEqual(len(self.reader.content_cache), 1)
        self.db.execute("DELETE FROM book_versions WHERE gid='1'"); self.db.commit()
        self.file(self.books[0], '00000005.jpg', b'more')
        self.assertNotEqual(changed[1], self.reader.manifest_response('1')[1])

    def test_concurrent_commit_hit_is_requeried(self):
        self.enable_receipts(); old = self.reader.manifest_response('1')
        real = self.reader.pages_epoch; count = 0
        def commit_between_snapshots():
            nonlocal count
            count += 1
            if count == 2:
                self.file(self.books[0], '00000004.jpg', b'concurrent')
                self.db.execute("DELETE FROM book_versions WHERE gid='1'"); self.db.commit()
            return real()
        with patch.object(self.reader, 'pages_epoch', side_effect=commit_between_snapshots):
            self.assertNotEqual(old[1], self.reader.manifest_response('1')[1])

    def test_legacy_validates_each_time_and_budget_is_enforced(self):
        first = self.reader.manifest_response('1')
        self.assertEqual(first, self.reader.manifest_response('1'))
        self.assertEqual(self.reader.manifest_stats['builds'], 2)
        self.assertFalse(self.reader.content_cache)
        self.enable_receipts(); self.reader.content_contract = None
        self.reader.page_cache_budget = 10
        self.reader.manifest_response('1')
        self.assertFalse(self.reader.content_cache)
        self.db.execute("UPDATE files SET sha='invalid' WHERE gid='1'"); self.db.commit()
        with self.assertRaises(Failure): self.reader.manifest_response('1')

    def test_response_lru_count_and_byte_accounting(self):
        def snapshot(db, gid):return dict(id=gid,directory='synthetic-'+gid),'a'*64
        with patch.object(self.reader, 'content_snapshot', side_effect=snapshot), patch.object(self.reader, 'records', return_value=({1:dict(sha='b'*64,size=1)},None)):
            for n in range(130): self.reader.manifest_response(str(n+1))
        self.assertEqual(len(self.reader.content_cache), 128)
        self.assertNotIn('1', [key[0] for key in self.reader.content_cache])
        self.assertEqual(self.reader.content_cache_bytes, sum(value[1] for value in self.reader.content_cache.values()))
        self.assertLessEqual(self.reader.content_cache_bytes, self.reader.page_cache_budget)


class ThumbnailHotPathTests(unittest.TestCase):
    setUp = manifest_fixtures.ManifestTests.setUp
    tearDown = manifest_fixtures.ManifestTests.tearDown
    publish = manifest_fixtures.ManifestTests.publish
    file = manifest_fixtures.ManifestTests.file

    def cache(self, **options):
        cache = ThumbnailCache(self.root/'derived', **options)
        self.addCleanup(cache.close); return cache

    def put(self, cache, key, size=100):
        data = (key.encode()*size)[:size]
        cache.store(key, data, hashlib.sha256(data).hexdigest())
        return data

    def assert_totals(self, cache):
        with cache.connection() as db:
            self.assertEqual(db.execute('SELECT bytes,items FROM cover_totals').fetchone(),
                             db.execute('SELECT COALESCE(SUM(size),0),COUNT(*) FROM covers').fetchone())

    def test_hot_hit_no_disk_and_fixed_memory_limit(self):
        cache = self.cache(memory_budget=1500)
        first = self.put(cache, 'a')
        for _ in range(50): self.assertEqual(cache.cached('a')[0], first)
        self.assertEqual(cache.stats['disk_reads'], 0)
        self.assertEqual(cache.stats['memory_hits'], 50)
        for n in range(20):
            self.put(cache, str(n)); self.assertLessEqual(cache.memory_bytes, 1500)
        self.assertLessEqual(len(cache.memory), 2)
        self.assertEqual(cache.stats['db_connections'], 1)
        self.assertEqual(cache.stats['aggregate_scans'], 1)

    def test_counter_replace_rollback_eviction_and_restart(self):
        cache = self.cache(budget=500, count_limit=3)
        self.put(cache, 'a'); self.put(cache, 'a', 150); self.assert_totals(cache)
        try:
            with cache.connection() as db:
                db.execute("DELETE FROM covers WHERE key='a'")
                raise ValueError('rollback')
        except ValueError: pass
        self.assert_totals(cache)
        for n in range(10): self.put(cache, str(n), 180); self.assert_totals(cache)
        with cache.connection() as db:
            total, count = db.execute('SELECT bytes,items FROM cover_totals').fetchone()
        self.assertLessEqual(total, 500); self.assertLessEqual(count, 3)
        cache.close(); reopened = self.cache(budget=500, count_limit=3)
        self.assert_totals(reopened)

    def test_touches_and_vacuum_not_on_read_or_store_path(self):
        cache = self.cache(count_limit=2); self.put(cache, 'a')
        with cache.connection() as db: db.execute('UPDATE covers SET used=0')
        cache.clear_memory()
        statements = []; cache.db.set_trace_callback(statements.append)
        cache.cached('a'); cache.cached('a')
        self.assertTrue(cache.touches)
        self.assertFalse(any('UPDATE covers' in sql for sql in statements))
        self.put(cache, 'b'); self.put(cache, 'c')
        self.assertFalse(any('SUM(' in sql.upper() or 'VACUUM' in sql.upper() for sql in statements))
        self.assertTrue(cache.needs_vacuum)
        cache.maintain(); self.assertEqual(cache.stats['maintenance'], 0)
        cache.maintain(force=True)
        self.assertFalse(cache.touches); self.assertFalse(cache.needs_vacuum)
        self.assertTrue(any('incremental_vacuum' in sql for sql in statements))
        self.assert_totals(cache)

    def test_parallel_hits_stores_and_maintenance(self):
        cache = self.cache(budget=5000)
        def work(n):
            key = str(n); data = self.put(cache, key)
            self.assertEqual(cache.cached(key)[0], data)
            cache.maintain(force=True)
        with ThreadPoolExecutor(max_workers=4) as pool: list(pool.map(work, range(40)))
        self.assert_totals(cache)
        self.assertEqual(cache.stats['db_connections'], 1)
        self.assertLessEqual(cache.memory_bytes, cache.memory_budget)

    def test_cold_disk_corruption_removed_and_closed_cache_safe(self):
        cache = self.cache(memory_budget=0); self.put(cache, 'a')
        with cache.connection() as db: db.execute("UPDATE covers SET data=x'00'")
        self.assertIsNone(cache.cached('a')); self.assert_totals(cache)
        cache.close(); cache.close(); cache.maintain(force=True)
        with self.assertRaises(OSError): cache.cached('a')

    def test_oversized_replacement_does_not_leave_old_memory_copy(self):
        cache = self.cache(memory_budget=700)
        self.put(cache, 'a', 100)
        changed = self.put(cache, 'a', 1000)
        self.assertNotIn('a', cache.memory)
        self.assertEqual(cache.cached('a')[0], changed)
        self.assertEqual(cache.memory_bytes, 0)

    def test_concurrent_same_key_commits_match_memory(self):
        cache = self.cache()
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(lambda n:self.put(cache,'shared',100+n),range(100)))
        with cache.connection() as db: expected=db.execute("SELECT data,sha FROM covers WHERE key='shared'").fetchone()
        self.assertEqual(cache.cached('shared'), expected)
        self.assert_totals(cache)

    def test_memory_entry_count_is_bounded(self):
        cache = self.cache()
        for n in range(300): self.put(cache, str(n))
        self.assertEqual(len(cache.memory), 256)
        self.assertLessEqual(cache.memory_bytes, cache.memory_budget)


if __name__ == '__main__': unittest.main()
