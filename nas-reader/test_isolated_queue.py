import hashlib
import io
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch
import test_optimizations as fixtures
from experiments.queued_thumbnails import QueuedThumbnailCache


class IsolatedQueueTests(unittest.TestCase):
    setUp = fixtures.OptimizationTests.setUp
    tearDown = fixtures.OptimizationTests.tearDown
    publish = fixtures.OptimizationTests.publish
    file = fixtures.OptimizationTests.file
    install_cover = fixtures.OptimizationTests.install_cover

    def cache(self, **options):
        cache = QueuedThumbnailCache(self.root/'experiment', **options)
        self.addCleanup(cache.close)
        return cache

    def test_same_key_shared_once_and_budget_held(self):
        original = self.install_cover(); cache=self.cache()
        barrier=threading.Barrier(8); count=0
        def slow(stream,pixels):
            nonlocal count
            count+=1;time.sleep(.1)
            return b'jpeg-result',hashlib.sha256(b'jpeg-result').hexdigest()
        def call(n):
            barrier.wait()
            return cache.get(io.BytesIO(original), 'a'*64, 480)
        with patch.object(cache,'render',side_effect=slow),ThreadPoolExecutor(max_workers=8) as pool:
            results=list(pool.map(call,range(8)))
        self.assertEqual(count,1);self.assertTrue(all(result==results[0] for result in results))
        self.assertEqual(cache.stats['coalesced'],7)
        self.assertFalse(cache.flights);self.assertFalse(cache.waiting)
        self.assertEqual(cache.waiters,0)

    def test_unique_queue_is_bounded_and_recovers_after_timeout(self):
        cache=self.cache(wait_seconds=.03,queue_limit=2);barrier=threading.Barrier(8)
        def slow(stream,pixels):
            time.sleep(.12);return b'jpeg-result',hashlib.sha256(b'jpeg-result').hexdigest()
        def call(n):
            barrier.wait();return cache.get(io.BytesIO(b'original'),str(n),480)
        with patch.object(cache,'render',side_effect=slow),ThreadPoolExecutor(max_workers=8) as pool:
            results=list(pool.map(call,range(8)))
        self.assertEqual(sum(result is not None for result in results),1)
        self.assertLessEqual(cache.stats['peak_queue'],2)
        self.assertGreater(cache.stats['queue_full'],0);self.assertGreater(cache.stats['queue_timeout'],0)
        self.assertFalse(cache.running);self.assertFalse(cache.flights);self.assertEqual(cache.waiters,0)

    def test_failed_render_releases_every_waiter(self):
        cache=self.cache()
        with patch.object(cache,'render',side_effect=ValueError('bad image')):
            self.assertIsNone(cache.get(io.BytesIO(b'bad'),'a'*64,480))
        self.assertFalse(cache.running);self.assertFalse(cache.flights)

    def test_production_entry_does_not_import_candidates(self):
        import inspect,server
        source=inspect.getsource(server.main)
        self.assertNotIn('QueuedThumbnailCache',source)
        self.assertNotIn('vips_renderer',source)
