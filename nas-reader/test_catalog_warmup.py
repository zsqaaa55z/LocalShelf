"""Synthetic source only: publication, cache coherency, restart and privacy."""
import gzip
import hashlib
import http.client
import io
import json
import sqlite3
import unittest
from unittest.mock import patch
from PIL import Image
from server import Failure, accepts_gzip
from cover_warmup import CoverWarmup
from thumbnails import ThumbnailCache
import test_server as fixtures
import test_optimizations as http_fixtures


class CatalogResponseTests(unittest.TestCase):
    setUp = fixtures.ReaderTests.setUp
    tearDown = fixtures.ReaderTests.tearDown
    publish = fixtures.ReaderTests.publish
    file = fixtures.ReaderTests.file
    server = http_fixtures.OptimizationTests.server
    request = http_fixtures.OptimizationTests.request

    def test_hot_response_no_query_or_encoding_and_source_unchanged(self):
        before = list(self.db.iterdump())
        first = self.reader.list_response(0, 50)
        with patch.object(self.reader, 'list', side_effect=AssertionError('rebuilt')):
            for _ in range(20): self.assertIs(self.reader.list_response(0, 50), first)
        self.assertEqual(json.loads(first[0]), self.reader.list(0, 50))
        self.assertEqual(before, list(self.db.iterdump()))

    def test_unchanged_revision_does_not_hide_availability_or_cover_change(self):
        old = self.reader.list_response(0, 50)
        self.db.execute("UPDATE ready SET available=1 WHERE gid='3'"); self.db.commit()
        ready = self.reader.list_response(0, 50)
        self.assertNotEqual(ready[1], old[1])
        self.db.execute("UPDATE files SET sha=? WHERE gid='1' AND path='.thumb'", ('d'*64,)); self.db.commit()
        updated = self.reader.list_response(0, 50)
        self.assertNotEqual(updated[1], ready[1])
        self.assertEqual(json.loads(updated[0])['books'][0]['coverIdentity'], 'd'*64)

    def test_concurrent_commit_never_returns_cached_old_response(self):
        old = self.reader.list_response(0, 50)
        real, calls = self.reader.pages_epoch, 0
        def marker():
            nonlocal calls
            calls += 1
            if calls == 2:
                self.db.execute("UPDATE ready SET available=1 WHERE gid='3'"); self.db.commit()
            return real()
        with patch.object(self.reader, 'pages_epoch', side_effect=marker):
            self.assertNotEqual(old[1], self.reader.list_response(0, 50)[1])

    def test_reorder_and_unpublish(self):
        old = self.reader.list_response(0, 50)
        self.books.reverse()
        for rank, book in enumerate(self.books): book.update(rank=rank, time=100-rank)
        self.revision = 'b'*64; self.publish()
        new = self.reader.list_response(0, 50)
        self.assertNotEqual(old[1], new[1])
        self.assertEqual([b['id'] for b in json.loads(new[0])['books']], ['3','2','1'])
        self.db.execute("DELETE FROM state WHERE key='active'"); self.db.commit()
        with self.assertRaises(Failure): self.reader.list_response(0, 50)

    def test_budget_count_and_parameter_isolation(self):
        for n in range(40): self.reader.list_response(n*50, 50)
        self.assertEqual(len(self.reader.catalog_responses), 32)
        self.assertLessEqual(self.reader.catalog_response_bytes, self.reader.catalog_response_budget)
        self.assertEqual(self.reader.catalog_response_bytes, sum(v[1] for v in self.reader.catalog_responses.values()))
        self.reader.catalog_responses.clear(); self.reader.catalog_response_bytes = 0
        self.reader.catalog_response_budget = 10
        self.reader.list_response(0,50)
        self.assertFalse(self.reader.catalog_responses)
        for offset, size in [(-1,50),(0,501),(0,1),(200001,100)]:
            with self.assertRaises(Failure): self.reader.list_response(offset,size)

    def test_gzip_is_deterministic_and_has_own_validator(self):
        for book in self.books: book['title'] *= 100
        self.publish()
        plain = self.reader.list_response(0,50)
        packed = self.reader.list_response(0,50,True)
        self.assertEqual(gzip.decompress(packed[0]), plain[0])
        self.assertLess(len(packed[0]),len(plain[0]))
        self.assertNotEqual(packed[1],plain[1])
        self.assertEqual(packed[1], '"'+hashlib.sha256(packed[0]).hexdigest()+'"')
        self.assertEqual(packed[2], 'gzip')

    def test_http_conditional_auth_and_encoding_negotiation(self):
        for book in self.books: book['title'] *= 100
        self.publish()
        with self.server(keep_alive=True) as server:
            route = '/v1/books?offset=0&limit=50'
            status, headers, data = self.request(server, route)
            self.assertEqual(status,200)
            self.assertEqual(headers['Vary'],'Authorization, Accept-Encoding')
            self.assertEqual(self.request(server,route,headers['ETag'])[0],304)
            self.assertEqual(self.request(server,route,headers['ETag'],False)[0],401)
            conn=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=3)
            try:
                auth={'Authorization':'Bearer '+self.identity.value['token'],'Accept-Encoding':'gzip'}
                conn.request('GET',route,headers=auth); reply=conn.getresponse(); body=reply.read()
                self.assertEqual(reply.status,200); self.assertEqual(gzip.decompress(body),data)
                auth['If-None-Match']=reply.getheader('ETag')
                conn.request('GET',route,headers=auth); reply=conn.getresponse()
                self.assertEqual((reply.status,reply.read()),(304,b''))
                auth['Accept-Encoding']='gzip;q=0'
                conn.request('GET',route,headers=auth); reply=conn.getresponse()
                self.assertEqual((reply.status,reply.read()),(200,data))
            finally:conn.close()

    def test_accept_encoding(self):
        for text in ['gzip','br, gzip;q=0.8','*;q=0.5']: self.assertTrue(accepts_gzip(text))
        for text in [None,'','gzip;q=0','gzip;q=0, *;q=1','gzip;q=garbage','gzip;q=2','gzip;nope','x'*5000]:
            self.assertFalse(accepts_gzip(text))

    def test_concurrent_readers_share_one_encoded_response(self):
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=8) as pool:
            responses=list(pool.map(lambda _:self.reader.list_response(0,50),range(80)))
        self.assertTrue(all(response==responses[0] for response in responses))
        self.assertEqual(self.reader.catalog_response_stats['builds'],1)


class WarmupTests(unittest.TestCase):
    setUp = fixtures.ReaderTests.setUp
    publish = fixtures.ReaderTests.publish
    file = fixtures.ReaderTests.file

    def tearDown(self):
        if hasattr(self,'warm'): self.warm.close()
        fixtures.ReaderTests.tearDown(self)

    def worker(self):
        self.now=0; self.idle=True
        self.reader.thumbnails=ThumbnailCache(self.root/'derived')
        self.warm=CoverWarmup(self.reader,self.root/'warm',lambda:self.idle,clock=lambda:self.now)
        return self.warm

    def settle(self):
        self.warm.tick(); self.now+=16; self.warm.tick()

    def update(self, gid='1', color='red'):
        output=io.BytesIO()
        with Image.new('RGB',(900,1200),color) as image:image.save(output,format='JPEG')
        book=next(b for b in self.books if b['id']==gid)
        self.db.execute("DELETE FROM files WHERE gid=? AND path='.thumb'",(gid,))
        self.file(book,'.thumb',output.getvalue())
        return output.getvalue()

    def pending(self):
        return self.warm.database().execute('SELECT gid,sha FROM pending ORDER BY rank').fetchall()

    def test_first_start_only_establishes_metadata_baseline(self):
        self.worker(); before=list(self.db.iterdump())
        with patch.object(self.reader,'image',side_effect=AssertionError('read original')):
            self.settle(); self.warm.tick()
        self.assertEqual(self.warm.stats['baselines'],1)
        self.assertFalse(self.pending())
        self.assertEqual(before,list(self.db.iterdump()))

    def test_cover_scans_never_build_page_counts(self):
        self.worker()
        with patch.object(self.reader,'count_pages',side_effect=AssertionError('counted background pages')):
            self.settle()
            self.update(); self.revision='b'*64; self.publish(); self.settle()
        self.assertEqual(self.warm.stats['baselines'],1)
        self.assertEqual(self.warm.stats['publications'],1)
        self.assertEqual(len(self.pending()),1)
        self.assertEqual(self.reader.count_stats['builds'],0)
        self.assertFalse(self.reader.count_cache)

    def test_only_changed_cover_warms_after_publish_original_preserved(self):
        self.worker(); self.settle(); original=self.update()
        self.revision='b'*64; self.publish(); before=list(self.db.iterdump())
        self.settle(); self.assertEqual(len(self.pending()),1)
        self.warm.tick()
        self.assertFalse(self.pending()); self.assertEqual(self.warm.stats['warmed'],1)
        self.assertEqual(before,list(self.db.iterdump()))
        self.assertEqual((self.source/'books/book-0/.thumb').read_bytes(),original)

    def test_unpublished_cover_change_does_not_start_generation(self):
        self.worker(); self.settle(); self.update()
        self.settle(); self.warm.tick()
        self.assertFalse(self.pending()); self.assertEqual(self.warm.stats['warmed'],0)

    def test_pure_reorder_does_not_warm(self):
        self.worker(); self.settle()
        self.books[0],self.books[1]=self.books[1],self.books[0]
        for rank,book in enumerate(self.books):book.update(rank=rank,time=100-rank)
        self.revision='b'*64;self.publish();self.settle()
        self.assertFalse(self.pending());self.assertEqual(self.warm.stats['publications'],1)

    def test_new_missing_and_removed_books(self):
        self.worker();self.settle()
        self.books.append(dict(id='4',rank=3,title='New',directory='new-book',time=90))
        self.update('4');self.revision='b'*64;self.publish()
        self.db.execute("UPDATE ready SET available=1 WHERE gid='4'");self.db.commit()
        self.settle();self.assertEqual(self.pending()[0][0],'4')
        self.books=self.books[:3];self.revision='c'*64;self.publish();self.settle()
        self.assertFalse(self.pending())

    def test_restart_keeps_pending_not_full_warm(self):
        self.worker();self.settle();self.update();self.revision='b'*64;self.publish();self.settle()
        self.warm.close()
        self.warm=CoverWarmup(self.reader,self.root/'warm',lambda:self.idle,clock=lambda:self.now)
        self.settle();self.assertEqual(self.warm.stats['warmed'],1)
        self.assertEqual(self.warm.stats['baselines'],0)

    def test_foreground_and_writer_quiet_period_pause(self):
        self.worker();self.idle=False;self.now=100;self.warm.tick()
        self.assertIsNone(self.warm.db)
        self.idle=True;self.settle();self.update();self.revision='b'*64;self.publish()
        self.warm.tick();self.now+=1;self.warm.tick();self.assertFalse(self.pending())
        self.now+=15;self.warm.tick();self.assertEqual(len(self.pending()),1)
        self.idle=False;self.warm.tick();self.assertEqual(len(self.pending()),1)
        self.idle=True;self.warm.tick();self.assertFalse(self.pending())

    def test_busy_decoder_defers_and_failed_cover_does_not_block(self):
        self.worker();self.settle();self.update();self.revision='b'*64;self.publish();self.settle()
        self.reader.thumbnails.generation.acquire()
        try:self.warm.tick();self.assertEqual(len(self.pending()),1)
        finally:self.reader.thumbnails.generation.release()
        (self.source/'books/book-0/.thumb').unlink()
        self.warm.tick();self.assertFalse(self.pending());self.assertEqual(self.warm.stats['errors'],1)

    def test_scan_interrupted_by_source_commit_does_not_publish_partial(self):
        self.worker();real=self.reader.list
        def racing(offset,limit,**kwargs):
            result=real(offset,limit,**kwargs)
            self.db.execute("UPDATE ready SET available=1 WHERE gid='3'");self.db.commit()
            return result
        self.warm.tick();self.now+=16
        with patch.object(self.reader,'list',side_effect=racing):self.warm.tick()
        self.assertEqual(self.warm.stats['baselines'],0)
        self.assertIsNone(self.warm.scan)

    def test_same_revision_changed_pending_bytes_are_not_warmed(self):
        self.worker();self.settle();self.update();self.revision='b'*64;self.publish();self.settle()
        self.update(color='blue');self.settle()
        self.assertFalse(self.pending());self.assertEqual(self.warm.stats['warmed'],0)

    def test_state_symlink_rejected_and_stop_does_no_work(self):
        self.worker();self.warm.root.mkdir()
        self.warm.path.symlink_to(self.source/'index.sqlite3')
        with self.assertRaises(OSError):self.warm.database()
        self.warm.close();self.warm.tick();self.assertIsNone(self.warm.db)

    def test_large_baseline_is_sliced_and_contains_no_titles_or_paths(self):
        self.books=[dict(id=str(n+1),rank=n,title='Synthetic',directory='book-'+str(n),time=2000-n) for n in range(1001)]
        self.publish();self.worker();self.warm.tick();self.now=16
        self.warm.tick();self.assertEqual(len(self.warm.scan),500)
        self.warm.tick();self.assertEqual(len(self.warm.scan),1000)
        self.warm.tick();self.assertIsNone(self.warm.scan)
        db=self.warm.database()
        self.assertEqual(db.execute('SELECT COUNT(*) FROM observed').fetchone()[0],1001)
        self.assertFalse(self.pending())
        self.assertEqual([row[1] for row in db.execute('PRAGMA table_info(observed)')],['gid','sha'])

    def test_restart_of_background_thread_shuts_down_cleanly(self):
        # Production opens the private SQLite connection on the worker itself.
        self.worker();self.warm.start();self.warm.close()
        self.assertFalse(self.warm.thread.is_alive())
