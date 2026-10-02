import copy,hashlib,json,os,subprocess,sys,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
import test_receiver as fixtures
server=fixtures.server

class ArchiveTests(unittest.TestCase):
    setUp=fixtures.ReceiverTests.setUp
    file=fixtures.ReceiverTests.file
    upload=fixtures.ReceiverTests.upload
    commit_book=fixtures.ReceiverTests.commit_book
    def tearDown(self):self.store.close();self.tmp.cleanup()
    def manifest(self):
        return {'schema':1,'type':'localshelf-extra-v1','sourceRevision':self.rev,'groups':[
            {'id':server.archive_id('directory','75-outside'),'kind':'directory','name':'75-outside'},
            {'id':server.archive_id('root'),'kind':'root','name':''}]}
    def prepare(self):
        m=self.manifest();r=self.store.stage_archive(m)['revision'];return m,r,self.store.extra()
    def extra_file(self,a,r,gid,path,data):
        spec={'revision':r,'gid':gid,'path':path,'size':len(data),'sha256':hashlib.sha256(data).hexdigest()}
        status=a.begin(spec)
        if not status['done']:
            for off in range(status['offset'],len(data),server.CHUNK):a.chunk(status['upload'],off,data[off:off+server.CHUNK])
            a.finish(status['upload'])
        return spec,status
    def complete(self):
        m,r,a=self.prepare()
        for g in m['groups']:
            f,_=self.extra_file(a,r,g['id'],'.nomedia' if g['kind']=='root' else 'sub/0001.webp',b'' if g['kind']=='root' else b'synthetic')
            a.book_commit({'revision':r,'gid':g['id'],'files':[f]})
        a.publish({'revision':r})
        return m,r,a
    def test_root_and_unknown_kept_separate_from_reader_order(self):
        m,r,a=self.complete()
        self.assertIsNone(self.store.active())
        for gid in ['9','7','3']:self.commit_book(gid)
        self.store.publish({'revision':self.rev,'archiveRevision':r})
        self.assertEqual([b['id'] for b in self.store.catalog(self.store.active())['books']],['7','3','9'])
        self.assertTrue((a.root/'books/root-files/.nomedia').exists())
        self.assertEqual((a.root/'books/directories/75-outside/sub/0001.webp').read_bytes(),b'synthetic')
        _,status=self.extra_file(a,r,m['groups'][0]['id'],'sub/0001.webp',b'synthetic')
        self.assertTrue(status['done'])
    def test_missing_archive_group_blocks_publication(self):
        m,r,a=self.prepare()
        for gid in ['7','3','9']:self.commit_book(gid)
        with self.assertRaisesRegex(ValueError,'archive_not_verified'):a.publish({'revision':r})
        with self.assertRaisesRegex(ValueError,'archive_not_verified'):self.store.publish({'revision':self.rev,'archiveRevision':r})
        self.assertIsNone(self.store.active())
    def test_traversal_duplicate_id_and_ordered_folder_rejected(self):
        for name in ['../escape','7-漫画']:
            m=self.manifest();m['groups'][0].update(name=name,id=server.archive_id('directory',name))
            with self.assertRaises(ValueError):self.store.stage_archive(m)
        m=self.manifest();m['groups'].append(m['groups'][0])
        with self.assertRaises(ValueError):self.store.stage_archive(m)
    def test_archive_revision_cannot_be_attached_to_another_main_catalog(self):
        _,r,a=self.complete();new=fixtures.catalog(('11','7','3','9'));rev=self.store.stage(new)['revision']
        with self.assertRaisesRegex(ValueError,'archive_not_verified'):self.store.publish({'revision':rev,'archiveRevision':r})
    def test_lost_ack_disk_pressure_restart_and_hash_failure(self):
        m,r,a=self.prepare();gid=m['groups'][0]['id'];data=b'abcdef'
        f={'revision':r,'gid':gid,'path':'page.bin','size':len(data),'sha256':hashlib.sha256(data).hexdigest()}
        u=a.begin(f)['upload'];a.chunk(u,0,data[:3])
        with self.assertRaisesRegex(ValueError,'offset_conflict'):a.chunk(u,0,data[:3])
        with patch.object(server.shutil,'disk_usage',return_value=type('Usage',(),{'total':1024**3,'free':0})()):
            with self.assertRaisesRegex(ValueError,'nas_space_insufficient'):a.chunk(u,3,data[3:])
        self.store.close();self.store=server.Store(self.tmp.name,reserve_bytes=64*1024**2,reserve_percent=0,warning_bytes=128*1024**2,warning_percent=0)
        a=self.store.extra();self.assertEqual(a.begin(f)['offset'],3)
        a.chunk(u,3,b'XXX')
        with self.assertRaisesRegex(ValueError,'hash_mismatch'):a.finish(u)
        self.assertEqual(a.begin(f)['offset'],0)
        self.extra_file(a,r,gid,'page.bin',data)
        self.assertEqual((a.root/'books/directories/75-outside/page.bin').read_bytes(),data)
    def test_real_sigkill_after_archive_fsync_recovers(self):
        m,r,a=self.prepare();gid=m['groups'][0]['id'];data=b'abcdefgh'
        f={'revision':r,'gid':gid,'path':'page.bin','size':len(data),'sha256':hashlib.sha256(data).hexdigest()}
        self.store.close()
        script="""import sys,json,os,signal
from pathlib import Path
sys.path.insert(0,sys.argv[1]);from server import Store
s=Store(sys.argv[2],reserve_bytes=67108864,reserve_percent=0,warning_bytes=134217728,warning_percent=0);a=s.extra();f=json.loads(sys.argv[3]);u=a.begin(f)['upload'];a.chunk(u,0,b'abcd');os.kill(os.getpid(),signal.SIGKILL)
"""
        result=subprocess.run([sys.executable,'-c',script,str(Path(server.__file__).parent),self.tmp.name,json.dumps(f)],capture_output=True)
        self.assertEqual(result.returncode,-9)
        self.store=server.Store(self.tmp.name,reserve_bytes=64*1024**2,reserve_percent=0,warning_bytes=128*1024**2,warning_percent=0);a=self.store.extra()
        self.assertEqual(a.begin(f)['offset'],4);self.extra_file(a,r,gid,'page.bin',data)
        self.assertEqual(a.db.execute('PRAGMA integrity_check').fetchone()[0],'ok')

    def test_combined_audit_rejects_archive_corruption_missing_root_and_bad_baseline(self):
        from test_audit import audit
        m,r,a=self.complete()
        for gid in ['7','3','9']:self.commit_book(gid)
        self.store.publish({'revision':self.rev,'archiveRevision':r})
        baseline={'books':{gid:{'files':0,'bytes':0} for gid in ['7','3','9']},
            'archives':{g['id']:{'files':1,'bytes':9 if g['kind']=='directory' else 0} for g in m['groups']},
            'totalSourceFiles':2,'totalSourceBytes':9}
        result=audit(self.store.root,self.cat,baseline)
        self.assertTrue(result['fullLibraryAccepted'],result)
        self.assertEqual(result['archiveCheckedFiles'],2)
        self.assertFalse(audit(self.store.root,self.cat,baseline,False)['fullLibraryAccepted'])
        bad=copy.deepcopy(baseline);bad['archives'].pop(m['groups'][0]['id'])
        self.assertFalse(audit(self.store.root,self.cat,bad)['fullLibraryAccepted'])
        page=a.root/'books/directories/75-outside/sub/0001.webp';page.write_bytes(b'X'*9)
        self.assertFalse(audit(self.store.root,self.cat,baseline)['fullLibraryAccepted'])
        page.write_bytes(b'synthetic');(a.root/'books/root-files/.nomedia').unlink()
        self.assertFalse(audit(self.store.root,self.cat,baseline)['fullLibraryAccepted'])

    def test_real_https_lost_reply_resumes_archive_and_keeps_order(self):
        import ssl,threading,urllib.request
        from http.client import RemoteDisconnected
        cert,key,token=server.initialize(self.tmp.name,'127.0.0.1',8443)
        class DropReply(server.Handler):
            def reply(handler,status,data):
                if status==200 and '/archive/file/chunk?' in handler.path and not handler.server.dropped:
                    handler.server.dropped=True;handler.close_connection=True
                    return  # Persisted chunk, deliberately close TLS before the acknowledgment.
                super().reply(status,data)
        tls=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);tls.load_cert_chain(cert,key)
        http=server.TLSServer(('127.0.0.1',0),DropReply,tls);http.store,http.token,http.dropped=self.store,token,False
        worker=threading.Thread(target=http.serve_forever,daemon=True);worker.start()
        def request(path,data):
            raw=data if isinstance(data,bytes) else json.dumps(data).encode()
            req=urllib.request.Request(f'https://127.0.0.1:{http.server_port}/sync/v1/'+path,data=raw,headers={'Authorization':'Bearer '+token})
            with urllib.request.urlopen(req,context=ssl._create_unverified_context(),timeout=5) as response:return json.load(response)
        try:
            m=self.manifest();r=request('archive/catalog/stage',m)['revision'];payload=b'abcdef'
            f={'revision':r,'gid':m['groups'][0]['id'],'path':'page.bin','size':6,'sha256':hashlib.sha256(payload).hexdigest()}
            u=request('archive/file/begin',f)['upload']
            with self.assertRaises((RemoteDisconnected,urllib.error.URLError)):
                request(f'archive/file/chunk?upload={u}&offset=0',payload[:3])
            self.assertEqual(request('archive/file/begin',f)['offset'],3)
            request(f'archive/file/chunk?upload={u}&offset=3',payload[3:]);request('archive/file/finish',{'upload':u})
            request('archive/book/commit',{'revision':r,'gid':f['gid'],'files':[f]})
            request('archive/book/commit',{'revision':r,'gid':m['groups'][1]['id'],'files':[]})
            request('archive/catalog/commit',{'revision':r})
            for gid in ['9','7','3']:request('book/commit',{'revision':self.rev,'gid':gid,'files':[]})
            result=request('catalog/commit',{'revision':self.rev,'archiveRevision':r})
            self.assertEqual(result['orderSha256'],hashlib.sha256(server.encoded(['7','3','9'])).hexdigest())
            self.assertTrue(request('archive/file/begin',f)['done'])
            self.assertEqual((self.store.root/'archive/books/directories/75-outside/page.bin').read_bytes(),payload)
        finally:http.shutdown();http.server_close();worker.join()
