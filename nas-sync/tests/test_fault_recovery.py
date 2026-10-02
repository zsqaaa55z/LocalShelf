"""Isolated fault injection. Never uses a real library or fills a host disk."""
import errno
import hashlib
import json
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from test_receiver import server, catalog

WORKER = r'''
import importlib.util,json,os,sys,time
from pathlib import Path
spec=importlib.util.spec_from_file_location('receiver',sys.argv[1]);s=importlib.util.module_from_spec(spec);spec.loader.exec_module(s)
root,mode=sys.argv[2:4];store=s.Store(root, reserve_bytes=64*1024**2, reserve_percent=0, warning_bytes=128*1024**2, warning_percent=0);data=json.loads(Path(root,'scenario.json').read_text());f=data['file']
def wait():
 print('BOUNDARY',flush=True)
 while True:time.sleep(1)
u=store.begin(f)['upload']
if mode=='chunk':
 store.chunk(u,0,b'a'*s.CHUNK);wait()
elif mode=='replace':
 original=s.os.replace
 def replace(a,b):
  original(a,b);wait()
 s.os.replace=replace
 store.finish(u)
'''

class FaultRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name).resolve();self.store=server.Store(self.root, reserve_bytes=64*1024**2, reserve_percent=0, warning_bytes=128*1024**2, warning_percent=0)
        self.cat=catalog();self.rev=self.store.stage(self.cat)['revision']
        self.data=b'a'*server.CHUNK+b'b'*12345
        self.file={'revision':self.rev,'gid':'7','path':'00000001.jpg','size':len(self.data),'sha256':hashlib.sha256(self.data).hexdigest()}
    def tearDown(self):
        self.store.db.close();self.tmp.cleanup()
    def kill_at(self,mode):
        (self.root/'scenario.json').write_text(json.dumps({'file':self.file}))
        self.store.db.close()
        child=subprocess.Popen([sys.executable,'-c',WORKER,str(Path(server.__file__).resolve()),str(self.root),mode],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            ready,_,_=select.select([child.stdout],[],[],15)
            self.assertTrue(ready,'worker failed to reach fault boundary')
            self.assertEqual(child.stdout.readline().strip(),'BOUNDARY')
            child.kill();child.wait(timeout=10);self.assertLess(child.returncode,0)
        finally:
            if child.poll() is None:child.kill();child.wait()
            child.stdout.close();child.stderr.close()
            self.store=server.Store(self.root, reserve_bytes=64*1024**2, reserve_percent=0, warning_bytes=128*1024**2, warning_percent=0)
    def finish_all(self):
        upload=self.store.begin(self.file)
        if not upload['done']:
            for offset in range(upload['offset'],len(self.data),server.CHUNK):self.store.chunk(upload['upload'],offset,self.data[offset:offset+server.CHUNK])
            self.store.finish(upload['upload'])
        for gid in ('9','7','3'):self.store.book_commit({'revision':self.rev,'gid':gid,'files':[self.file] if gid=='7' else []})
        result=self.store.publish({'revision':self.rev})
        self.assertEqual(result['orderSha256'],hashlib.sha256(server.encoded(['7','3','9'])).hexdigest())
        self.assertEqual((self.root/'books/7-漫画/00000001.jpg').read_bytes(),self.data)
        self.assertEqual(self.store.db.execute('PRAGMA integrity_check').fetchone()[0],'ok')
    def test_sigkill_after_durable_chunk_resumes_exact_offset(self):
        self.kill_at('chunk');self.assertIsNone(self.store.active())
        self.assertEqual(self.store.begin(self.file)['offset'],server.CHUNK);self.finish_all()
    def test_sigkill_after_rename_before_database_update_repairs_file(self):
        u=self.store.begin(self.file)['upload']
        for offset in range(0,len(self.data),server.CHUNK):self.store.chunk(u,offset,self.data[offset:offset+server.CHUNK])
        self.kill_at('replace');self.assertIsNone(self.store.active())
        self.assertEqual((self.root/'books/7-漫画/00000001.jpg').read_bytes(),self.data)
        self.assertFalse(self.store.begin(self.file)['done']);self.finish_all()
    def test_capacity_drop_between_begin_and_chunk_preserves_offset(self):
        u=self.store.begin(self.file)['upload'];self.store.chunk(u,0,self.data[:1024])
        usage=type('Usage',(),{'free':0,'total':1024**4})()
        with patch.object(server.shutil,'disk_usage',return_value=usage):
            with self.assertRaisesRegex(ValueError,'nas_space_insufficient'):self.store.chunk(u,1024,self.data[1024:2048])
        self.assertEqual(self.store.begin(self.file)['offset'],1024);self.finish_all()
    def test_short_write_then_enospc_can_resume_from_actual_bytes(self):
        u=self.store.begin(self.file)['upload'];part=self.root/'partial'/u
        original=Path.open
        class FullWriter:
            def __enter__(self):self.f=original(part,'ab');return self
            def write(self,body):self.f.write(body[:731]);self.f.flush();raise OSError(errno.ENOSPC,'synthetic disk full')
            def __exit__(self,*args):self.f.close()
        def mocked(path,*args,**kwargs):return FullWriter() if path==part and args==('ab',) else original(path,*args,**kwargs)
        with patch.object(Path,'open',mocked):
            with self.assertRaises(OSError):self.store.chunk(u,0,self.data[:1024])
        self.assertIsNone(self.store.active());self.assertEqual(self.store.begin(self.file)['offset'],731);self.finish_all()


class StorageHttpFailures(unittest.TestCase):
    def test_enospc_and_sqlite_full_return_507_and_rollback(self):
        import ssl, threading, urllib.request, urllib.error, sqlite3
        with tempfile.TemporaryDirectory() as tmp:
            store=server.Store(tmp, reserve_bytes=64*1024**2, reserve_percent=0, warning_bytes=128*1024**2, warning_percent=0);cert,key,token=server.initialize(tmp,'127.0.0.1',8443)
            tls=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);tls.load_cert_chain(cert,key)
            http=server.TLSServer(('127.0.0.1',0),server.Handler,tls);http.store,http.token=store,token
            worker=threading.Thread(target=http.serve_forever,daemon=True);worker.start()
            def request():
                req=urllib.request.Request(f'https://127.0.0.1:{http.server_port}/sync/v1/catalog/stage',data=server.encoded(catalog()),headers={'Authorization':'Bearer '+token})
                return urllib.request.urlopen(req,context=ssl._create_unverified_context(),timeout=5)
            try:
                full=sqlite3.OperationalError('synthetic SQLite full');full.sqlite_errorcode=sqlite3.SQLITE_FULL
                for fault in (OSError(errno.ENOSPC,'synthetic full'),full):
                    def fail(data):
                        store.db.execute("INSERT INTO state VALUES('uncommitted','must rollback')")
                        raise fault
                    with patch.object(store,'stage',fail):
                        with self.assertRaises(urllib.error.HTTPError) as error:request()
                        self.assertEqual(error.exception.code,507)
                        self.assertEqual(json.load(error.exception)['error'],'storage_full')
                    self.assertIsNone(store.db.execute("SELECT value FROM state WHERE key='uncommitted'").fetchone())
                with request() as response:self.assertIn('revision',json.load(response))
            finally:
                http.shutdown();http.server_close();worker.join();store.db.close()

if __name__=='__main__':unittest.main()
