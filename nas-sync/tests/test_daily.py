"""Synthetic data only; daily ordering/version paths never target a real NAS."""
import copy
import hashlib
import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch
import test_receiver as fixtures

server = fixtures.server

class DailyTests(fixtures.ReceiverTests):
    # Reuse the existing safe temporary receiver fixtures and regression checks.
    def seed(self):
        self.proofs = {}
        for gid in ('7','3','9'):
            data = ('old-' + gid).encode()
            f = self.file(gid=gid,data=data)
            self.upload(f,data)
            self.proofs[gid] = self.commit_book(gid,[f])['proof']
        self.store.publish({'revision':self.rev})

    def reuse_and_publish(self, staged, ids):
        request = {'revision':staged['revision'],'books':[{'gid':gid,'proof':self.proofs[gid]} for gid in ids]}
        self.assertEqual(self.store.reuse(request)['reused'],list(ids))
        return self.store.publish({'revision':staged['revision']})

    def test_daily_reorder_reuses_without_reading_page_content(self):
        self.seed()
        with patch.object(server,'digest',side_effect=AssertionError('must not hash media on reorder')):
            staged=self.store.daily_stage(fixtures.catalog(('9','7','3')))
            result=self.reuse_and_publish(staged,('9','7','3'))
        self.assertEqual(result['orderSha256'],hashlib.sha256(server.encoded(['9','7','3'])).hexdigest())
        self.assertEqual([b['id'] for b in self.store.catalog(self.store.active())['books']],['9','7','3'])

    def test_daily_unchanged_revision_stable(self):
        self.seed();first=self.store.daily_stage(self.cat);self.reuse_and_publish(first,('7','3','9'))
        second=self.store.daily_stage(self.cat)
        self.assertEqual(second['revision'],first['revision'])
        self.assertEqual(second['retainedBooks'],0)

    def test_content_change_can_refresh_revision_without_changing_order(self):
        self.seed();first=copy.deepcopy(self.cat);first['contentSnapshot']='a'*64
        stage=self.store.daily_stage(first);self.reuse_and_publish(stage,('7','3','9'))
        second=copy.deepcopy(first);second['contentSnapshot']='b'*64
        refreshed=self.store.daily_stage(second)
        self.assertNotEqual(refreshed['revision'],stage['revision'])
        self.assertEqual([b['id'] for b in refreshed['catalog']['books']],['7','3','9'])

    def test_missing_sources_bulk_ready_preserves_nas_pages(self):
        self.seed();cat=copy.deepcopy(self.cat);cat['missingSourceIds']=['7','3','9']
        with patch.object(self.store,'book_commit',side_effect=AssertionError('must not issue per-book commits')):
            staged=self.store.daily_stage(cat)
            self.store.publish({'revision':staged['revision']})
        self.assertEqual(set(staged['readyIds']),{'7','3','9'})
        self.assertEqual(staged['missingSourceIds'],['7','3','9'])
        self.assertNotIn('missingSourceIds',staged['catalog'])
        self.assertEqual((self.store.root/'books/7-漫画/00000001.jpg').read_bytes(),b'old-7')

    def test_missing_sources_reject_unknown_and_duplicates(self):
        self.seed()
        for ids in [['7','7'],['999'],[None],['3',{}]]:
            cat=copy.deepcopy(self.cat);cat['missingSourceIds']=ids
            with self.assertRaises(ValueError):self.store.daily_stage(cat)

    def test_new_version_reusing_phone_folder_keeps_old_bytes(self):
        self.seed();new=fixtures.catalog(('11','3','9'));new['books'][0]['directory']='7-漫画'
        staged=self.store.daily_stage(new);book=staged['catalog']['books'][0]
        self.assertEqual(book['sourceDirectory'],'7-漫画');self.assertNotEqual(book['directory'],'7-漫画')
        self.assertEqual(staged['retainedBooks'],1)
        data=b'new-version';f=self.file(gid='11',data=data,revision=staged['revision']);self.upload(f,data);self.commit_book('11',[f],staged['revision'])
        self.reuse_and_publish(staged,('3','9'))
        self.assertEqual((self.store.root/'books/7-漫画/00000001.jpg').read_bytes(),b'old-7')
        self.assertEqual((self.store.root/'books'/book['directory']/'00000001.jpg').read_bytes(),data)
        self.assertEqual(self.store.daily_stage(new)['catalog']['books'][0]['directory'],book['directory'])
        # Rolling the source back to old ID reuses its original retained storage.
        self.assertEqual(self.store.daily_stage(self.cat)['catalog']['books'][0]['directory'],'7-漫画')

    def test_omitted_book_retained_not_in_current_catalog(self):
        self.seed();staged=self.store.daily_stage(fixtures.catalog(('7','9')));self.reuse_and_publish(staged,('7','9'))
        self.assertTrue((self.store.root/'books/3-漫画/00000001.jpg').is_file())
        self.assertIsNotNone(self.store.db.execute("SELECT * FROM files WHERE gid='3'").fetchone())
        self.assertEqual([b['id'] for b in self.store.catalog(self.store.active())['books']],['7','9'])

    def test_source_folder_rename_keeps_nas_location(self):
        self.seed();cat=copy.deepcopy(self.cat);cat['books'][0]['directory']='renamed-folder'
        staged=self.store.daily_stage(cat)
        self.assertEqual(staged['catalog']['books'][0]['directory'],'7-漫画')
        self.assertEqual(staged['catalog']['books'][0]['sourceDirectory'],'renamed-folder')

    def test_updated_page_inventory_hides_obsolete_format_but_retains_file(self):
        self.seed();staged=self.store.daily_stage(self.cat);data=b'new-webp'
        f=self.file(gid='7',path='00000001.webp',data=data,revision=staged['revision']);self.upload(f,data);self.commit_book('7',[f],staged['revision'])
        self.assertEqual([r[0] for r in self.store.db.execute("SELECT path FROM files WHERE gid='7'")],['00000001.webp'])
        self.assertEqual(self.store.db.execute("SELECT path FROM retained_files WHERE gid='7'").fetchone()[0],'00000001.jpg')
        self.assertEqual((self.store.root/'books/7-漫画/00000001.jpg').read_bytes(),b'old-7')

    def test_daily_invalid_and_duplicate_order_still_rejected(self):
        self.seed()
        for change in (lambda c:c['books'][1].update(rank=0),lambda c:c['books'][1].update(directory='7-漫画'),lambda c:c.update(books=[])):
            cat=copy.deepcopy(self.cat);change(cat)
            with self.assertRaises(ValueError):self.store.daily_stage(cat)
        self.assertEqual(self.store.active(),self.rev)

    def test_reader_observes_order_version_and_new_format_without_restart(self):
        path=os.environ.get('LOCALSHELF_READER_SOURCE')
        if not path:self.skipTest('set LOCALSHELF_READER_SOURCE for reader integration')
        spec=importlib.util.spec_from_file_location('daily_reader',path);reader_module=importlib.util.module_from_spec(spec);spec.loader.exec_module(reader_module)
        self.seed();reader=reader_module.Reader(self.store.root,reader_module.Identity(self.store.root/'reader-state'))
        try:
            self.assertEqual([b['id'] for b in reader.list(0,50)['books']],['7','3','9'])
            self.assertEqual(reader.pages('7')['pages'],[{'number':1}])
            new=fixtures.catalog(('11','9','7','3'));new['books'][0]['directory']='new-version-folder'
            staged=self.store.daily_stage(new)
            for gid,path,data in [('11','00000001.gif',b'GIF89a synthetic'),('7','00000002.webp',b'updated synthetic')]:
                f=self.file(gid=gid,path=path,data=data,revision=staged['revision']);self.upload(f,data);self.commit_book(gid,[f],staged['revision'])
            self.reuse_and_publish(staged,('9','3'))
            self.assertEqual([b['id'] for b in reader.list(0,50)['books']],['11','9','7','3'])
            self.assertEqual(reader.locate('7')['offset'],2)
            self.assertEqual(reader.pages('7')['pages'],[{'number':2}])
            stream,_,_=reader.image('7',2)
            with stream:self.assertEqual(stream.read(),b'updated synthetic')
        finally:reader.close()

if __name__=='__main__':unittest.main()
