import importlib.util,json,sys,unittest
from pathlib import Path
import test_receiver as fixtures
sys.path.insert(0,str(Path(__file__).parents[1]))
from audit import audit

class AuditTests(unittest.TestCase):
    setUp=fixtures.ReceiverTests.setUp
    tearDown=fixtures.ReceiverTests.tearDown
    file=fixtures.ReceiverTests.file
    upload=fixtures.ReceiverTests.upload
    commit_book=fixtures.ReceiverTests.commit_book

    def prepared(self):
        data=b'synthetic-image';f=self.file();self.upload(f,data)
        for gid in ['7','3','9']:self.commit_book(gid,[f] if gid=='7' else [])
        self.store.publish({'revision':self.rev})
        return {'books':{gid:{'files':1 if gid=='7' else 0,'bytes':len(data) if gid=='7' else 0} for gid in ['7','3','9']},'unmappedDirectoryCount':0}

    def test_full_rehash_and_source_baseline_required(self):
        b=self.prepared()
        self.assertTrue(audit(self.store.root,self.cat,b)['fullLibraryAccepted'])
        self.assertFalse(audit(self.store.root,self.cat,b,False)['fullLibraryAccepted'])
        self.assertFalse(audit(self.store.root,self.cat)['fullLibraryAccepted'])
        b['unmappedDirectoryCount']=1
        self.assertFalse(audit(self.store.root,self.cat,b)['fullLibraryAccepted'])
        b['unmappedDirectoryCount']=0;b['missingOrEmptyDirectoryCount']=1
        self.assertFalse(audit(self.store.root,self.cat,b)['fullLibraryAccepted'])

    def test_corruption_and_missing_file_reported(self):
        b=self.prepared();p=self.store.root/'books/7-漫画/00000001.jpg'
        p.write_bytes(b'X'*p.stat().st_size)
        r=audit(self.store.root,self.cat,b)
        self.assertFalse(r['fullLibraryAccepted']);self.assertEqual(r['issues'][0]['code'],'hash_mismatch')
        p.unlink();self.assertFalse(audit(self.store.root,self.cat,b)['fullLibraryAccepted'])

    def test_order_and_source_totals_mismatch(self):
        b=self.prepared();different=fixtures.catalog(('3','7','9'))
        self.assertFalse(audit(self.store.root,different,b)['orderMatches'])
        b['books']['7']['files']+=1
        self.assertFalse(audit(self.store.root,self.cat,b)['fullLibraryAccepted'])

    def test_pending_catalog_and_symlink_never_pass(self):
        b=self.prepared();new=fixtures.catalog(('11','7','3','9'));rev=self.store.stage(new)['revision']
        self.assertFalse(audit(self.store.root,new,b,revision=rev)['fullLibraryAccepted'])
        p=self.store.root/'books/7-漫画/00000001.jpg';q=self.store.root/'outside'
        q.write_bytes(p.read_bytes());p.unlink();p.symlink_to(q)
        self.assertFalse(audit(self.store.root,self.cat,b)['fullLibraryAccepted'])
