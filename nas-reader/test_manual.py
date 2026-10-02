import hashlib
import http.client
import io
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from manual import ManualStore, ManualError, POLICY, validate_manifest
from server import Reader, Identity, Server, Failure, Handler


class ManualTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.identity = Identity(self.root / 'state')
        self.store = ManualStore(self.root / 'manual', forbidden=(self.root/'sync', self.root/'state'))
        self.reader = Reader(self.store.root, self.identity, library_id=self.store.library_id,
                             order_policy=POLICY, cache_root=self.store.root/'.cache')
        self.data = [b'GIF89a synthetic page 1', b'\xff\xd8\xff synthetic page 2']

    def tearDown(self):
        self.reader.close(); self.temp.cleanup()

    def manifest(self, title='[Synthetic Author] Book 1'):
        return {'title': title, 'files': [{'name': name, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest(), 'modifiedUtcTicks': 639000000000000000}
                                        for name, data in zip(['1.gif', '2.jpg'], self.data)]}

    def complete(self, title='[Synthetic Author] Book 1'):
        value = self.store.start(self.manifest(title)); key=value['uploadId']
        for i, data in enumerate(self.data, 1): self.store.receive(key, i, io.BytesIO(data), len(data))
        return self.store.commit(key)

    def test_empty_manual_not_empty_eh(self):
        self.assertEqual(self.reader.list(0, 50)['total'], 0)
        other=Reader(self.store.root,self.identity)
        try:
            with self.assertRaises(Failure): other.list(0,50)
        finally: other.close()

    def test_separate_root_and_identity(self):
        for path in [self.root/'state', self.root/'state'/'sub', self.root]:
            with self.assertRaises(ValueError):ManualStore(path, forbidden=(self.root/'state',))
        self.assertNotEqual(self.store.library_id, self.identity.value['libraryId'])
        self.assertNotEqual(self.store.upload_token(self.identity), self.identity.value['token'])

    def test_only_complete_book_published(self):
        v=self.store.start(self.manifest()); key=v['uploadId']
        self.store.receive(key,1,io.BytesIO(self.data[0]),len(self.data[0]))
        self.assertEqual(self.reader.list(0,50)['total'],0)
        with self.assertRaises(ManualError):self.store.commit(key)
        self.assertEqual(self.store.start(self.manifest())['missing'],[2])
        self.store.receive(key,2,io.BytesIO(self.data[1]),len(self.data[1]))
        published=self.store.commit(key)
        self.assertTrue(published['published'])
        listing=self.reader.list(0,50)
        self.assertEqual(listing['orderPolicy'],POLICY)
        self.assertEqual(listing['books'][0]['pageCount'],2)
        self.assertEqual(self.reader.manifest_response('1')[0],self.reader.manifest_response('1')[0])
        for i,data in enumerate(self.data,1):
            stream,length,_=self.reader.image('1',i)
            with stream:self.assertEqual(stream.read(),data)
            self.assertEqual(length,len(data))

    def test_resume_after_restart_and_exact_duplicate(self):
        first=self.complete()
        restarted=ManualStore(self.store.root)
        second=restarted.start(self.manifest())
        self.assertEqual(first,second)
        self.assertEqual(restarted.commit(second['uploadId']),first)
        self.assertEqual(self.reader.list(0,50)['total'],1)

    def test_changed_title_new_book_and_stable_old_id(self):
        first=self.complete('Book 1'); second=self.complete('Book 2')
        self.assertEqual([b['id'] for b in self.reader.list(0,50)['books']],['2','1'])
        self.assertNotEqual(first['bookId'],second['bookId'])
        self.assertEqual(self.reader.locate('1')['offset'],1)

    def test_same_title_changed_bytes_never_overwrites(self):
        self.complete()
        old=self.data[0];self.data[0]=b'GIF89a changed bytes'
        self.complete()
        with self.reader.image('1',1)[0] as stream:self.assertEqual(stream.read(),old)
        with self.reader.image('2',1)[0] as stream:self.assertEqual(stream.read(),self.data[0])

    def test_bad_hash_short_body_wrong_signature(self):
        key=self.store.start(self.manifest())['uploadId']
        for data in [b'x'*len(self.data[0]),self.data[0][:2]]:
            with self.assertRaises(ManualError):self.store.receive(key,1,io.BytesIO(data),len(self.data[0]))
        self.assertEqual(self.store.status(key)['missing'],[1,2])
        fake=b'not an image';m=self.manifest('bad');m['files']=[dict(name='1.png',size=len(fake),sha256=hashlib.sha256(fake).hexdigest(),modifiedUtcTicks=639000000000000000)]
        key=self.store.start(m)['uploadId']
        with self.assertRaises(ManualError):self.store.receive(key,1,io.BytesIO(fake),len(fake))
        self.assertEqual(list((self.store.root/'staging'/key).iterdir()),[])

    def test_paths_limits_duplicates(self):
        for name in ['../a.gif','a/b.gif','a\\b.gif','a\x00.gif','a:ads.gif','1.pdf','']:
            m=self.manifest();m['files'][0]['name']=name
            with self.assertRaises(ManualError):validate_manifest(m)
        for size in [0,-1,True,50*1024**2+1]:
            m=self.manifest();m['files'][0]['size']=size
            with self.assertRaises(ManualError):validate_manifest(m)
        m=self.manifest();m['files'][1]['name']='1.GIF'
        with self.assertRaises(ManualError):validate_manifest(m)

    def test_windows_modified_time_is_primary_and_preserved(self):
        m=self.manifest();m['files'][0]['name']='10.gif';m['files'][1]['name']='2.jpg'
        m['files'][0]['modifiedUtcTicks']=638999999999999999
        key=self.store.start(m)['uploadId']
        for i,data in enumerate(self.data,1):self.store.receive(key,i,io.BytesIO(data),len(data))
        self.store.commit(key)
        with self.reader.image('1',1)[0] as stream:self.assertEqual(stream.read(),self.data[0])
        with self.store.db() as db:
            _,saved=self.store.record(db,key)
            self.assertEqual(saved['files'][0]['modifiedUtcTicks'],638999999999999999)
        m['files'].reverse()
        with self.assertRaises(ManualError):self.store.start(m)
        for value in [True, -1, '2026-09-27',3155378976000000000]:
            m=self.manifest();m['files'][0]['modifiedUtcTicks']=value
            with self.assertRaises(ManualError):validate_manifest(m)

    def test_rename_before_database_commit_is_retryable(self):
        key=self.store.start(self.manifest())['uploadId']
        for i,data in enumerate(self.data,1):self.store.receive(key,i,io.BytesIO(data),len(data))
        with patch.object(self.store,'publish',side_effect=OSError('injected crash')):
            with self.assertRaises(OSError):self.store.commit(key)
        self.assertEqual(self.reader.list(0,50)['total'],0)
        self.assertTrue((self.store.root/'books'/key).is_dir())
        self.assertTrue(self.store.commit(key)['published'])

    def test_discard_only_unpublished(self):
        key=self.store.start(self.manifest())['uploadId'];self.store.discard(key)
        self.assertFalse((self.store.root/'staging'/key).exists())
        key=self.complete()['uploadId']
        with self.assertRaises(ManualError):self.store.discard(key)

    def test_symlink_and_full_disk(self):
        key=self.store.start(self.manifest())['uploadId']
        outside=self.root/'outside';outside.write_bytes(b'untouched')
        (self.store.root/'staging'/key/'00000001.gif.partial').symlink_to(outside)
        with self.assertRaises(ManualError):self.store.receive(key,1,io.BytesIO(self.data[0]),len(self.data[0]))
        self.assertEqual(outside.read_bytes(),b'untouched')
        with patch('manual.shutil.disk_usage') as usage:
            usage.return_value.free=0
            with self.assertRaises(ManualError):self.store.start(self.manifest('disk full'))

    def test_related_index_works_in_manual_scope(self):
        self.complete('[Demo (Artist)] Story 1');self.complete('[Demo (Artist)] Story 2')
        result=self.reader.related('1','authors')
        self.assertEqual(result['libraryId'],self.store.library_id)
        self.assertTrue(result['options'])

    def test_new_import_preserves_existing_cached_manifest_and_count(self):
        self.complete('First');self.reader.list(0,50);before=self.reader.manifest_response('1')
        old_count=self.reader.count_stats['builds'];old_manifest=self.reader.manifest_stats['builds']
        self.complete('Second');self.reader.list(0,50)
        self.assertEqual(before,self.reader.manifest_response('1'))
        self.assertEqual(self.reader.count_stats['builds'],old_count+1)
        self.assertEqual(self.reader.manifest_stats['builds'],old_manifest)

    def test_two_store_instances_cannot_write_together(self):
        second=ManualStore(self.store.root)
        with self.store.writer():
            with self.assertRaises(ManualError):second.start(self.manifest())
        self.assertEqual(second.start(self.manifest())['missing'],[1,2])

    def test_pending_metadata_and_safe_discard(self):
        key=self.store.start(self.manifest())['uploadId']
        self.store.receive(key,1,io.BytesIO(self.data[0]),len(self.data[0]))
        self.assertEqual(self.store.pending()['uploads'][0]['received'],1)
        self.store.discard(key);self.assertEqual(self.store.pending(),{'uploads':[]})

    def test_eh_files_database_and_order_unchanged(self):
        sync=self.root/'sync';sync.mkdir();db=sqlite3.connect(sync/'index.sqlite3')
        db.executescript('CREATE TABLE state(key TEXT PRIMARY KEY,value TEXT); CREATE TABLE catalogs(revision TEXT PRIMARY KEY,body TEXT); CREATE TABLE ready(revision TEXT,gid TEXT,available INTEGER); CREATE TABLE files(gid TEXT,path TEXT,directory TEXT,size INTEGER,sha TEXT);')
        catalog={'orderVerified':True,'orderSource':'ehviewer-downloads-time-desc','books':[dict(id='1',title='Eh original',directory='eh-book',rank=0,time=1)]}
        db.execute('INSERT INTO state VALUES(?,?)',('active','a'*64));db.execute('INSERT INTO catalogs VALUES(?,?)',('a'*64,json.dumps(catalog)));db.commit()
        before=list(db.iterdump());db.close()
        eh=Reader(sync,self.identity)
        try:
            self.complete('Manual ID also 1')
            self.assertEqual(eh.list(0,50)['books'][0]['title'],'Eh original')
            self.assertEqual(self.reader.list(0,50)['books'][0]['title'],'Manual ID also 1')
            self.assertNotEqual(eh.list(0,50)['libraryId'],self.reader.list(0,50)['libraryId'])
            db=sqlite3.connect(sync/'index.sqlite3')
            try:self.assertEqual(list(db.iterdump()),before)
            finally:db.close()
        finally:eh.close()


class ManualHTTPTests(ManualTests):
    # Real HTTP handler/parser over bounded in-memory streams, no TCP sockets.
    def setUp(self):
        super().setUp()
        self.identity.set_password(b'fixture-pass-123')
        self.server=SimpleNamespace(reader=self.reader,manual_store=self.store,manual_reader=self.reader,
                                    active=threading.BoundedSemaphore(8),upload_slots=threading.BoundedSemaphore(1),
                                    activity_lock=threading.Lock(),active_requests=0,last_request=0,
                                    keep_alive=False,sendfile=False)

    def call(self, method, path, body=None, token=None, headers=None):
        h=dict(headers or {})
        if token:h['Authorization']='Bearer '+token
        if body is not None:h.setdefault('Content-Length',str(len(body)))
        request=(f'{method} {path} HTTP/1.0\r\nHost: 127.0.0.1\r\n'+''.join(f'{k}: {v}\r\n' for k,v in h.items())+'\r\n').encode()+(body or b'')
        class MemorySocket:
            def __init__(self,raw):self.input=io.BytesIO(raw);self.output=io.BytesIO()
            def settimeout(self,_):pass
            def makefile(self,*_):return self.input
            def sendall(self,data):self.output.write(data)
        sock=MemorySocket(request)
        Handler(sock,('127.0.0.1',0),self.server)
        response=http.client.HTTPResponse(MemorySocket(sock.output.getvalue()));response.begin()
        return response.status,response.read()

    def test_http_upload_and_auth_scopes(self):
        status,raw=self.call('POST','/v2/manual-login',b'fixture-pass-123')
        self.assertEqual(status,200);token=json.loads(raw)['token']
        read=self.identity.value['token']
        self.assertEqual(self.call('GET','/manual/v1/books',token=token)[0],401)
        self.assertEqual(self.call('POST','/manual/v1/uploads',b'{}',read)[0],401)
        self.assertEqual(self.call('GET','/manual/v1/books',token=read)[0],200)
        status,raw=self.call('POST','/manual/v1/uploads',json.dumps(self.manifest()).encode(),token)
        self.assertEqual(status,200);key=json.loads(raw)['uploadId']
        for i,data in enumerate(self.data,1):self.assertEqual(self.call('POST',f'/manual/v1/uploads/{key}/files/{i}',data,token)[0],200)
        self.assertEqual(self.call('POST',f'/manual/v1/uploads/{key}/commit',b'',token)[0],200)
        status,data=self.call('GET','/manual/v1/books/1/pages/1',token=read)
        self.assertEqual(status,200);self.assertEqual(data,self.data[0])
        self.assertEqual(self.call('GET','/manual/v1/books/1/manifest',token=read)[0],200)
        self.assertEqual(self.call('GET','/manual/v1/books/1/position',token=read)[0],200)
        status,raw=self.call('GET','/manual/v1/uploads',token=token)
        self.assertEqual(status,200);self.assertEqual(json.loads(raw),{'uploads':[]})

    def test_http_limits_and_bad_login(self):
        token=self.store.upload_token(self.identity)
        self.assertEqual(self.call('POST','/v2/manual-login',b'incorrect123')[0],403)
        self.assertEqual(self.call('POST','/v2/password-pair',b'fixture-pass-123')[0],200)
        self.assertEqual(self.call('POST','/manual/v1/uploads',b'{}',token,{'Transfer-Encoding':'chunked'})[0],400)
        self.assertEqual(self.call('POST','/v2/pair',b'x'*1000)[0],400)
        health=json.loads(self.call('GET','/v2/health')[1]);self.assertIn('manual-library-v1',health['capabilities'])


if __name__=='__main__':unittest.main()
