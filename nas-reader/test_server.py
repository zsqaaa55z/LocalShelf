import hashlib
import contextlib
from concurrent.futures import ThreadPoolExecutor
import http.client
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
from server import Identity, Reader, Server, Failure, VerificationCache, encoded, etag_matches


class ReaderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'; self.source.mkdir()
        self.identity = Identity(self.root / 'state')
        self.reader = Reader(self.source, self.identity)
        self.db = sqlite3.connect(self.source / 'index.sqlite3')
        self.db.executescript('''PRAGMA journal_mode=WAL;
        CREATE TABLE state(key TEXT PRIMARY KEY,value TEXT);
        CREATE TABLE catalogs(revision TEXT PRIMARY KEY,body TEXT);
        CREATE TABLE ready(revision TEXT,gid TEXT,available INTEGER,PRIMARY KEY(revision,gid));
        CREATE TABLE files(gid TEXT,path TEXT,directory TEXT,size INTEGER,sha TEXT);
        CREATE INDEX files_gid ON files(gid,path);
        ''')
        self.books = [{"id": str(i+1), "rank": i, "title": 'Synthetic '+str(i), "directory": 'book-'+str(i), "time": 100-i} for i in range(3)]
        self.revision = 'a'*64
        self.publish()
        for book in self.books[:2]:
            self.file(book, '00000003.gif', b'GIF89a synthetic three')
            self.file(book, '00000001.jpg', b'jpeg synthetic one')
            self.file(book, '.thumb', b'synthetic thumb')

    def tearDown(self):
        self.reader.close()
        self.db.close(); self.temp.cleanup()

    def publish(self):
        cat = {'schema': 1, 'orderSource': 'ehviewer-downloads-time-desc', 'orderVerified': True, 'books': self.books}
        self.db.execute('INSERT OR REPLACE INTO catalogs VALUES(?,?)', (self.revision, encoded(cat).decode()))
        self.db.execute("INSERT OR REPLACE INTO state VALUES('active',?)", (self.revision,))
        self.db.executemany('INSERT OR REPLACE INTO ready VALUES(?,?,?)', [(self.revision,b['id'],int(i<2)) for i,b in enumerate(self.books)])
        self.db.commit()

    def file(self, book, name, content):
        folder = self.source/'books'/book['directory']; folder.mkdir(parents=True, exist_ok=True)
        (folder/name).write_bytes(content)
        self.db.execute('INSERT INTO files VALUES(?,?,?,?,?)', (book['id'],name,book['directory'],len(content),hashlib.sha256(content).hexdigest()))
        self.db.commit()

    def test_order_and_placeholder(self):
        value = self.reader.list(0,50)
        self.assertEqual([b['id'] for b in value['books']], ['1','2','3'])
        self.assertFalse(value['books'][2]['available'])
        self.assertTrue(value['orderVerified'])

    def test_numeric_pages_and_original_gif(self):
        self.assertEqual(self.reader.pages('1'), {'pages':[{'number':1},{'number':3}]})
        stream, size, _ = self.reader.image('1',3)
        with stream: self.assertEqual(stream.read(),b'GIF89a synthetic three')
        self.assertGreater(size,0)

    def test_thumb_preferred(self):
        stream,_,sha = self.reader.image('1')
        with stream: self.assertEqual(stream.read(),b'synthetic thumb')
        self.assertEqual(self.reader.list(0,50)['books'][0]['coverIdentity'],sha)

    def test_fallback_cover(self):
        self.db.execute("DELETE FROM files WHERE path='.thumb'"); self.db.commit()
        stream,_,_ = self.reader.image('1')
        with stream: self.assertEqual(stream.read(),b'jpeg synthetic one')

    def test_duplicate_page_formats_keep_one_number_and_all_files(self):
        self.file(self.books[0],'00000001.webp',b'webp alternate')
        before=list(self.db.iterdump())
        self.assertEqual(self.reader.pages('1'), {'pages':[{'number':1},{'number':3}]})
        stream,_,_=self.reader.image('1',1)
        with stream:self.assertEqual(stream.read(),b'jpeg synthetic one')
        self.assertEqual(before,list(self.db.iterdump()))
        self.assertEqual((self.source/'books'/'book-0'/'00000001.webp').read_bytes(),b'webp alternate')

    def test_eh_format_order_and_cover_agree(self):
        self.db.execute("DELETE FROM files WHERE gid='1'");self.db.commit()
        formats=['jpg','jpeg','png','gif','webp','avif']
        for ext in reversed(formats):self.file(self.books[0],'00000001.'+ext,ext.encode())
        for ext in formats:
            expected=hashlib.sha256(ext.encode()).hexdigest()
            with self.reader.connection() as db:
                records,_=self.reader.records(db,self.books[0])
                self.assertEqual(records[1]['path'],'00000001.'+ext)
            self.assertEqual(self.reader.list(0,50)['books'][0]['coverIdentity'],expected)
            for number in [None,1]:
                stream,_,sha=self.reader.image('1',number)
                with stream:self.assertEqual(stream.read(),ext.encode())
                self.assertEqual(sha,expected)
            self.db.execute('DELETE FROM files WHERE gid=? AND path=?',('1','00000001.'+ext));self.db.commit()

    def test_format_selection_uses_numeric_page_order_and_thumbnail_first(self):
        self.file(self.books[0],'00000001.avif',b'avif alternate')
        self.file(self.books[0],'00000002.jpg',b'page two')
        self.assertEqual([p['number'] for p in self.reader.pages('1')['pages']],[1,2,3])
        stream,_,_=self.reader.image('1')
        with stream:self.assertEqual(stream.read(),b'synthetic thumb')

    def test_canonical_case_preferred_with_uppercase_fallback(self):
        # Also runs on case-insensitive APFS: verify the chosen path separately,
        # with identical bytes so the fixture cannot overwrite a different JPEG.
        self.file(self.books[0],'00000001.JPG',b'jpeg synthetic one')
        self.db.execute("DELETE FROM files WHERE gid='1' AND path='.thumb'");self.db.commit()
        for selected in ['00000001.jpg','00000001.JPG']:
            with self.reader.connection() as db:
                self.assertEqual(self.reader.page_record(db,self.books[0],1)['path'],selected)
                self.assertEqual(self.reader.cover_record(db,self.books[0])['path'],selected)
            stream,_,sha=self.reader.image('1',1)
            with stream:self.assertEqual(stream.read(),b'jpeg synthetic one')
            self.assertEqual(self.reader.list(0,50)['books'][0]['coverIdentity'],sha)
            self.db.execute("DELETE FROM files WHERE gid='1' AND path='00000001.jpg'");self.db.commit()

    def test_chosen_format_corruption_does_not_silently_fallback(self):
        self.file(self.books[0],'00000001.webp',b'valid alternative')
        path=self.source/'books'/'book-0'/'00000001.jpg'
        path.write_bytes(b'x'*path.stat().st_size)
        with self.assertRaises(Failure) as error:self.reader.image('1',1)
        self.assertEqual(error.exception.code,'image_updating')

    def test_exact_duplicate_path_and_zero_page_still_rejected(self):
        self.file(self.books[0],'00000001.jpg',b'exact duplicate')
        with self.assertRaises(Failure):self.reader.pages('1')
        with self.assertRaises(Failure):self.reader.image('1',1)
        self.db.execute("DELETE FROM files WHERE gid='1' AND path='00000001.jpg'");self.db.commit()
        self.file(self.books[0],'00000000.jpg',b'invalid zero')
        with self.assertRaises(Failure):self.reader.pages('1')

    def test_no_staged_or_archive_books(self):
        self.file({'id':'999','directory':'archive-only'},'00000001.jpg',b'not published')
        with self.assertRaises(Failure): self.reader.pages('999')

    def test_no_active_is_not_ready(self):
        self.db.execute("DELETE FROM state WHERE key='active'"); self.db.commit()
        with self.assertRaises(Failure) as error: self.reader.list(0,50)
        self.assertEqual(error.exception.status,503)

    def test_publish_revision_refreshes_cache(self):
        self.reader.list(0,50)
        self.revision='b'*64; self.books[0]['title']='New title'; self.publish()
        self.assertEqual(self.reader.list(0,50)['books'][0]['title'],'New title')

    def test_locate(self):
        self.assertEqual(self.reader.locate('2')['offset'],1)
        self.assertEqual(self.reader.locate('2')['libraryId'],self.identity.value['libraryId'])

    def test_missing_and_changed_file(self):
        path=self.source/'books'/'book-0'/'00000001.jpg'
        path.write_bytes(b'different size')
        with self.assertRaises(Failure): self.reader.image('1',1)
        path.unlink()
        with self.assertRaises(FileNotFoundError): self.reader.image('1',1)

    def test_symlink_never_followed(self):
        path=self.source/'books'/'book-0'/'.thumb';path.unlink();path.symlink_to('/etc/passwd')
        with self.assertRaises(OSError): self.reader.image('1')

    def test_same_size_replacement_rejected_before_metadata_commit(self):
        path=self.source/'books'/'book-0'/'00000001.jpg'
        path.write_bytes(b'x'*path.stat().st_size)
        with self.assertRaises(Failure):self.reader.image('1',1)

    def test_pin_expiration(self):
        self.identity.new_pin()
        path=self.root/'state'/'pairing-window.json'
        window=json.loads(path.read_bytes());window['expires']=0;path.write_bytes(encoded(window))
        with self.assertRaises(Failure):self.identity.pair(b'001234')

    def test_folder_symlink_never_followed(self):
        folder=self.source/'books'/'book-0'; folder.rename(self.source/'outside');folder.symlink_to(self.source/'outside',target_is_directory=True)
        with self.assertRaises(OSError): self.reader.image('1',1)

    def test_identity_survives_recreation(self):
        self.assertEqual(Identity(self.root/'state').value,self.identity.value)

    def test_pin_single_use(self):
        pin=self.identity.new_pin()
        reply=self.identity.pair(pin.encode())
        self.assertEqual(reply['token'],self.identity.value['token'])
        with self.assertRaises(Failure): self.identity.pair(pin.encode())

    def test_pin_five_attempts(self):
        pin=self.identity.new_pin(); wrong='000000' if pin!='000000' else '111111'
        for _ in range(5):
            with self.assertRaises(Failure): self.identity.pair(wrong.encode())
        with self.assertRaises(Failure): self.identity.pair(pin.encode())

    def test_bad_identity_fails_closed(self):
        (self.root/'state'/'identity.json').write_text('{}')
        with self.assertRaises(KeyError): Identity(self.root/'state')

    def test_invalid_pagination(self):
        for offset,limit in [(-1,50),(0,501),(0,0),(0,51)]:
            with self.assertRaises(Failure): self.reader.list(offset,limit)

    def test_reader_does_not_write_store(self):
        before=list(self.db.iterdump())
        self.reader.list(0,50);self.reader.pages('1');self.reader.locate('1')
        self.assertEqual(before,list(self.db.iterdump()))

    def test_batch_matches_single_queries_and_index_plan(self):
        self.db.execute("DELETE FROM files WHERE path='.thumb' AND gid='2'"); self.db.commit()
        self.file(self.books[1], '00000000.jpg', b'zero excluded')
        self.file(self.books[1], '00000001.AVIF', b'uppercase fallback')
        result = self.reader.list(0,50)
        with self.reader.connection() as db:
            for book, item in zip(self.books, result['books']):
                cover = self.reader.cover_record(db, book)
                expected = cover['sha'] if cover else hashlib.sha256((book['id']+'missing').encode()).hexdigest()
                self.assertEqual(item['coverIdentity'], expected)
        statements=[]
        connection=self.reader.connection
        @contextlib.contextmanager
        def traced():
            with connection() as db:
                db.set_trace_callback(statements.append)
                yield db
        with patch.object(self.reader, 'connection', traced): self.reader.list(0,500)
        selects=[s for s in statements if s.lstrip().startswith(('SELECT','WITH'))]
        # One extra batched range query only when a non-JPG first candidate
        # needs format-priority resolution; never a query for each book.
        count_queries=[s for s in selects if s.startswith('SELECT path FROM files')]
        self.assertEqual(len(count_queries),2)  # only two available legacy books
        self.assertTrue(all('ORDER BY path LIMIT 100001' in s for s in count_queries))
        self.assertEqual(len(selects)-len(count_queries),4)
        cover_queries=[s for s in selects if s.lstrip().startswith('WITH')]
        self.assertEqual(len(cover_queries),2)
        self.db.create_function('ls_page',1,lambda p:0)
        self.db.create_function('ls_variant',1,lambda p:0)
        for cover_sql in cover_queries:
            plan=[r[3] for r in self.db.execute('EXPLAIN QUERY PLAN '+cover_sql)]
            self.assertFalse(any('SCAN files' in r for r in plan),plan)
            self.assertTrue(any('USING INDEX files_gid' in r for r in plan),plan)
        self.assertTrue(any('path>?' in r and 'path<?' in r for r in plan),plan)

    def test_page_cache_reuses_without_mutable_aliases(self):
        with patch.object(self.reader,'records',wraps=self.reader.records) as records:
            first=self.reader.pages('1');first['pages'].clear()
            self.assertEqual(self.reader.pages('1')['pages'],[{'number':1},{'number':3}])
            self.assertEqual(records.call_count,1)
        self.assertFalse(self.reader.observer.in_transaction)

    def test_page_cache_same_revision_changes_invalidate(self):
        self.reader.pages('1')
        self.file(self.books[0],'00000002.png',b'new page')
        self.assertEqual([p['number'] for p in self.reader.pages('1')['pages']],[1,2,3])
        self.db.execute("DELETE FROM files WHERE gid='1' AND path='00000003.gif'");self.db.commit()
        self.assertEqual([p['number'] for p in self.reader.pages('1')['pages']],[1,2])
        self.file(self.books[0],'00000001.png',b'duplicate after cached')
        self.assertEqual([p['number'] for p in self.reader.pages('1')['pages']],[1,2])

    def test_page_cache_commit_during_hit_uses_fresh_snapshot(self):
        self.reader.pages('1')
        original=self.reader.pages_epoch;calls=0
        def racing_epoch():
            nonlocal calls
            calls+=1
            if calls==2:self.file(self.books[0],'00000002.png',b'concurrent')
            return original()
        with patch.object(self.reader,'pages_epoch',racing_epoch):
            self.assertEqual([p['number'] for p in self.reader.pages('1')['pages']],[1,2,3])
        self.assertEqual(calls,2)

    def test_page_cache_commit_during_miss_not_cached(self):
        original=self.reader.pages_epoch;calls=0
        def racing_epoch():
            nonlocal calls
            calls+=1
            if calls==2:self.file(self.books[0],'00000002.png',b'concurrent')
            return original()
        with patch.object(self.reader,'pages_epoch',racing_epoch):self.reader.pages('1')
        self.assertEqual(len(self.reader.page_cache),0)
        self.assertEqual(len(self.reader.pages('1')['pages']),3)

    def test_page_cache_bounds_and_lru(self):
        self.reader.page_cache_capacity=2
        self.reader.pages('1');self.reader.pages('2');self.reader.pages('1');self.reader.pages('3')
        self.assertEqual([k[2] for k in self.reader.page_cache],['1','3'])
        self.reader.page_cache_budget=800
        self.reader.pages('2')
        self.assertLessEqual(self.reader.page_cache_bytes,800)

    def test_hash_transaction_ends_before_verification(self):
        active=0;connection=self.reader.connection;verify=self.reader.verification.verify
        @contextlib.contextmanager
        def observed():
            nonlocal active
            active+=1
            try:
                with connection() as db:yield db
            finally:active-=1
        def observed_verify(signature,check):
            self.assertEqual(active,0)
            return verify(signature,check)
        with patch.object(self.reader,'connection',observed),patch.object(self.reader.verification,'verify',observed_verify):
            stream,_,_=self.reader.image('1',1);stream.close()

    def test_verified_atomic_replacement_requires_new_hash(self):
        stream,_,_=self.reader.image('1',1);stream.close()
        path=self.source/'books'/'book-0'/'00000001.jpg'
        content=b'x'*path.stat().st_size
        temporary=path.with_suffix('.replacement');temporary.write_bytes(content);temporary.replace(path)
        with self.assertRaises(Failure):self.reader.image('1',1)
        self.db.execute("UPDATE files SET sha=? WHERE gid='1' AND path='00000001.jpg'",(hashlib.sha256(content).hexdigest(),));self.db.commit()
        stream,_,sha=self.reader.image('1',1)
        with stream:self.assertEqual(hashlib.sha256(stream.read()).hexdigest(),sha)
        self.assertEqual(self.reader.verification.stats['hashes'],3)

    def test_same_file_concurrent_reads_hash_once(self):
        barrier=threading.Barrier(8)
        def read():
            barrier.wait()
            stream,_,sha=self.reader.image('1',1)
            with stream:self.assertEqual(hashlib.sha256(stream.read()).hexdigest(),sha)
        with ThreadPoolExecutor(max_workers=8) as pool:list(pool.map(lambda _:read(),range(8)))
        self.assertEqual(self.reader.verification.stats['hashes'],1)

    def test_synthetic_upload_and_reads_never_mix_etag_and_bytes(self):
        path=self.source/'books'/'book-0'/'00000001.jpg'
        finished=threading.Event();reads=0
        def writer():
            db=sqlite3.connect(self.source/'index.sqlite3')
            try:
                for n in range(80):
                    content=bytes([n])*4096
                    temporary=path.with_suffix('.replacement');temporary.write_bytes(content);temporary.replace(path)
                    db.execute("UPDATE files SET size=?,sha=? WHERE gid='1' AND path='00000001.jpg'",(len(content),hashlib.sha256(content).hexdigest()));db.commit()
            finally:db.close();finished.set()
        def reader():
            nonlocal reads
            while not finished.is_set():
                try:
                    stream,_,sha=self.reader.image('1',1)
                    with stream:self.assertEqual(hashlib.sha256(stream.read()).hexdigest(),sha)
                    reads+=1
                except Failure as error:self.assertIn(error.status,[409,503])
        with ThreadPoolExecutor(max_workers=3) as pool:
            futures=[pool.submit(reader) for _ in range(2)]
            pool.submit(writer).result()
            for future in futures:future.result()
        stream,_,sha=self.reader.image('1',1)
        with stream:self.assertEqual(hashlib.sha256(stream.read()).hexdigest(),sha)

    def test_removed_scrub_routes_do_not_read_or_decode_images(self):
        from thumbnails import ThumbnailCache
        self.reader.thumbnails = ThumbnailCache(self.identity.root)
        server = Server(('127.0.0.1', 0), self.reader)
        worker = threading.Thread(target=server.serve_forever, daemon=True); worker.start()
        before = list(self.db.iterdump())
        def request(path, authorized=True):
            connection = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=3)
            headers = {'Authorization': 'Bearer '+self.identity.value['token']} if authorized else {}
            try:
                connection.request('GET', path, headers=headers)
                response = connection.getresponse()
                return response.status, response.read()
            finally:
                connection.close()
        try:
            status, body = request('/v2/health', False)
            self.assertEqual(status, 200)
            capabilities = json.loads(body)['capabilities']
            self.assertNotIn('page-preview-v1', capabilities)
            for capability in ['cover-thumbnail-v1', 'page-manifest-v1', 'conditional-manifest-v1', 'author-discovery-v1', 'series-discovery-v1']:
                self.assertIn(capability, capabilities)
            with patch.object(self.reader, 'image', wraps=self.reader.image) as image:
                for route in ['/v1/books/1/preview/1', '/v1/books/1/preview/3', '/v1/books/1/preview/3?width=320']:
                    self.assertEqual(request(route)[0], 404)
                    self.assertEqual(request(route, False)[0], 401)
                image.assert_not_called()
            self.assertEqual(self.reader.thumbnails.stats['generated'], 0)
            self.assertEqual(request('/v1/books/1/pages/3'), (200, b'GIF89a synthetic three'))
            self.assertEqual(request('/v1/books/1/cover'), (200, b'synthetic thumb'))
            self.assertEqual(list(self.db.iterdump()), before)
        finally:
            server.shutdown(); server.server_close(); worker.join()

    def test_cover_cache_key_unchanged_after_scrub_removal(self):
        from thumbnails import ThumbnailCache, pillow_version
        self.reader.thumbnails = ThumbnailCache(self.identity.root)
        source_sha = 'a'*64
        for pixels in (320, 480, 640):
            expected = hashlib.sha256(f'cover-v2-srgb-jpeg85-dark-exif-{pillow_version}:{pixels}:{source_sha}'.encode()).hexdigest()
            self.assertEqual(self.reader.thumbnails.cache_key(source_sha, pixels), expected)

    def test_http_auth_routes_and_etag(self):
        server=Server(('127.0.0.1',0),self.reader)
        worker=threading.Thread(target=server.serve_forever,daemon=True);worker.start()
        def request(path,token=None,headers=None,method='GET',body=None):
            connection=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=3)
            h=headers or {}
            if token:h['Authorization']='Bearer '+token
            connection.request(method,path,body=body,headers=h)
            reply=connection.getresponse();result=(reply.status,dict(reply.getheaders()),reply.read());connection.close();return result
        try:
            self.assertEqual(request('/v2/health')[0],200)
            self.assertEqual(request('/v1/books')[0],401)
            self.assertEqual(request('/v1/books','upload-token')[0],401)
            token=self.identity.value['token']
            self.assertEqual(request('/v1/books',token)[0],200)
            first=request('/v1/books/1/cover',token)
            self.assertEqual(first[0],200)
            self.assertEqual(request('/v1/books/1/cover',token,{'If-None-Match':first[1]['ETag']})[0],304)
            for validator in ['W/'+first[1]['ETag'], '"'+'f'*64+'", W/'+first[1]['ETag'], '*']:
                reply=request('/v1/books/1/cover',token,{'If-None-Match':validator})
                self.assertEqual(reply[0],304);self.assertEqual(reply[2],b'')
                self.assertEqual(reply[1]['Cache-Control'],'private, no-cache')
            self.assertEqual(request('/v1/books/1/cover',headers={'If-None-Match':'*'})[0],401)
            cover_path=self.source/'books'/'book-0'/'.thumb'
            cover_path.write_bytes(b'x'*cover_path.stat().st_size)
            self.assertEqual(request('/v1/books/1/cover',token,{'If-None-Match':first[1]['ETag']})[0],409)
            self.assertEqual(request('/sync/v1/catalog/commit',token,method='POST',body='{}')[0],405)
            self.assertEqual(request('/v1/books/../../etc/passwd',token)[0],404)
            self.assertEqual(request('/v2/identity?nonce='+'a'*64)[0],200)
            self.assertEqual(request('/v2/identity?nonce=bad')[0],400)
        finally:
            server.shutdown();server.server_close();worker.join()


class CacheTests(unittest.TestCase):
    def test_etag_validation(self):
        tag='"'+'a'*64+'"'
        for header in [tag,'W/'+tag,'*','"'+'b'*64+'", '+tag]:self.assertTrue(etag_matches(header,tag))
        for header in [None,'',tag+'\n','w/'+tag,'"short"','x'*5000,'"'+'b'*64+'"']:
            self.assertFalse(etag_matches(header,tag))

    def test_true_lru(self):
        cache=VerificationCache(capacity=2);runs=[]
        for key in ['a','b','a','c','a']:
            cache.verify(key,lambda:runs.append(key))
        self.assertEqual(runs,['a','b','c']);self.assertEqual(list(cache.entries),['c','a'])

    def test_singleflight_success_failure_and_cleanup(self):
        for fail in [False,True]:
            cache=VerificationCache();started=threading.Event();release=threading.Event();runs=[]
            def check():
                runs.append(1);started.set();release.wait(3)
                if fail:raise Failure(409,'image_updating')
            with ThreadPoolExecutor(max_workers=8) as pool:
                futures=[pool.submit(cache.verify,'same',check) for _ in range(8)]
                self.assertTrue(started.wait(2))
                deadline=time.monotonic()+2
                while cache.stats['coalesced']<7 and time.monotonic()<deadline:threading.Event().wait(.005)
                release.set()
                for future in futures:
                    if fail:
                        with self.assertRaises(Failure):future.result()
                    else:future.result()
            self.assertEqual(len(runs),1);self.assertEqual(len(cache.flights),0)
            self.assertEqual(len(cache.entries),0 if fail else 1)

    def test_flight_timeout_and_bound(self):
        cache=VerificationCache(max_flights=1,timeout=.01)
        started=threading.Event();release=threading.Event()
        def check():started.set();release.wait(2)
        with ThreadPoolExecutor(max_workers=1) as pool:
            future=pool.submit(cache.verify,'one',check);self.assertTrue(started.wait(1))
            try:
                with self.assertRaises(Failure) as error:cache.verify('one',lambda:None)
                self.assertEqual(error.exception.code,'verification_timeout')
                with self.assertRaises(Failure) as error:cache.verify('two',lambda:None)
                self.assertEqual(error.exception.code,'verification_busy')
            finally:release.set();future.result()

    def test_different_files_can_hash_concurrently(self):
        cache=VerificationCache();barrier=threading.Barrier(2)
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures=[pool.submit(cache.verify,key,lambda:barrier.wait(2)) for key in ['a','b']]
            for future in futures:future.result()
        self.assertEqual(cache.stats['hashes'],2)


if __name__=='__main__': unittest.main()
