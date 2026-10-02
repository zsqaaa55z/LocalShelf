import hashlib
import http.client
import importlib.util
import json
from pathlib import Path
import threading
import unittest
from unittest.mock import patch
from server import Server, encoded
import test_server as fixtures


class ManifestTests(unittest.TestCase):
    setUp=fixtures.ReaderTests.setUp
    tearDown=fixtures.ReaderTests.tearDown
    publish=fixtures.ReaderTests.publish
    file=fixtures.ReaderTests.file

    def enable_receipts(self):
        cat=json.loads(self.db.execute('SELECT body FROM catalogs WHERE revision=?',(self.revision,)).fetchone()[0])
        cat['retentionPolicy']='keep-omitted-files-v1'
        self.db.execute('UPDATE catalogs SET body=? WHERE revision=?',(encoded(cat),self.revision))
        self.db.execute('CREATE TABLE book_versions(gid TEXT PRIMARY KEY,directory TEXT,proof TEXT,available INTEGER)')
        self.db.execute("INSERT INTO book_versions VALUES('1','book-0',?,1)",('c'*64,));self.db.commit()

    def test_manifest_numbers_formats_hashes_original_untouched(self):
        self.file(self.books[0],'00000001.webp',b'webp')
        before=list(self.db.iterdump());result=self.reader.manifest('1')
        self.assertEqual([p['number'] for p in result['pages']],[1,3])
        self.assertEqual(result['pages'][0]['sha256'],hashlib.sha256(b'jpeg synthetic one').hexdigest())
        self.assertEqual(result['libraryId'],self.identity.value['libraryId'])
        self.assertEqual(before,list(self.db.iterdump()))

    def test_reorder_does_not_change_content_revision(self):
        self.enable_receipts();first=self.reader.manifest('1')
        self.books=[self.books[1],self.books[0],self.books[2]]
        for n,b in enumerate(self.books):b.update(rank=n,time=100-n)
        self.revision='b'*64;self.publish()
        self.assertEqual(self.reader.manifest('1')['contentRevision'],first['contentRevision'])
        self.assertEqual(self.reader.locate('1')['offset'],1)

    def test_unrelated_upload_retains_receipt_cache(self):
        self.enable_receipts();self.reader.manifest('1')
        self.file(self.books[1],'00000004.jpg',b'other')
        with patch.object(self.reader,'records',wraps=self.reader.records) as records:
            self.reader.manifest('1');self.assertEqual(records.call_count,0)

    def test_incomplete_receipt_rebuilds_and_changes_version(self):
        self.enable_receipts();old=self.reader.manifest('1')
        self.db.execute("DELETE FROM book_versions WHERE gid='1'");self.db.commit()
        self.file(self.books[0],'00000004.jpg',b'new')
        new=self.reader.manifest('1');self.assertNotEqual(old['contentRevision'],new['contentRevision'])
        self.assertEqual([p['number'] for p in new['pages']],[1,3,4])

    def test_same_size_replacement_changes_page_hash(self):
        before=self.reader.manifest('1')
        self.db.execute("DELETE FROM files WHERE gid='1' AND path='00000001.jpg'");self.db.commit()
        self.file(self.books[0],'00000001.jpg',b'jpeg synthetic two')
        after=self.reader.manifest('1');self.assertEqual(before['pages'][0]['size'],after['pages'][0]['size'])
        self.assertNotEqual(before['contentRevision'],after['contentRevision'])

    def test_mutating_result_does_not_mutate_cache(self):
        self.enable_receipts();a=self.reader.manifest('1');a['pages'][0]['sha256']='x'
        self.assertNotEqual(self.reader.manifest('1')['pages'][0]['sha256'],'x')

    def test_manifest_auth_and_capability(self):
        server=Server(('127.0.0.1',0),self.reader);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            for auth,status in [(False,401),(True,200)]:
                conn=http.client.HTTPConnection('127.0.0.1',server.server_port)
                conn.request('GET','/v1/books/1/manifest',headers={'Authorization':'Bearer '+self.identity.value['token']} if auth else {})
                response=conn.getresponse();self.assertEqual(response.status,status);response.read();conn.close()
        finally:server.shutdown();server.server_close();thread.join()

    def test_legacy_and_invalid_sha_fail_closed(self):
        first=self.reader.manifest('1');self.assertEqual(len(first['pages']),2)
        self.db.execute("UPDATE files SET sha='bad' WHERE gid='1' AND path='00000001.jpg'");self.db.commit()
        with self.assertRaises(Exception):self.reader.manifest('1')

if __name__=='__main__':unittest.main()
