"""Synthetic metadata only: no live server, original images or uploaded library."""
import json
import sqlite3
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch
import test_response_cache as fixtures


class PageCountTests(unittest.TestCase):
    setUp = fixtures.ResponseCacheTests.setUp
    tearDown = fixtures.ResponseCacheTests.tearDown
    publish = fixtures.ResponseCacheTests.publish
    file = fixtures.ResponseCacheTests.file
    enable_receipts = fixtures.ResponseCacheTests.enable_receipts
    enable_retention = fixtures.ResponseCacheTests.enable_retention

    def counts(self):
        return {b['id']: b['pageCount'] for b in self.reader.list(0, 50)['books']}

    def update_proof(self, proof='d'*64):
        self.db.execute("UPDATE book_versions SET proof=? WHERE gid='1'", (proof,)); self.db.commit()

    def test_actual_unique_pages_not_highest_number_or_frames(self):
        self.file(self.books[0], '00000003.webp', b'alternate')
        self.file(self.books[0], '00001024.JPG', b'number gap')
        self.file(self.books[0], 'notes.txt', b'metadata')
        self.assertEqual(self.counts(), {'1': 3, '2': 2, '3': None})
        self.assertEqual(self.counts()['1'], len(self.reader.pages('1')['pages']))

    def test_all_six_formats_and_case_follow_existing_page_policy(self):
        for ext in ['jpg', 'jpeg', 'png', 'gif', 'webp', 'avif', 'WEBP']:
            self.file(self.books[0], '00000008.'+ext, b'variant')
        self.assertEqual(self.counts()['1'], 3)

    def test_empty_missing_and_legacy(self):
        self.db.execute("DELETE FROM files WHERE gid='1'"); self.db.commit()
        self.assertEqual(self.counts(), {'1': 0, '2': 2, '3': None})
        self.assertFalse(self.reader.count_cache)

    def test_duplicate_or_zero_page_is_unknown_without_breaking_library(self):
        for name in ['00000001.jpg', '00000000.jpg']:
            self.file(self.books[0], name, b'bad')
            self.assertEqual(self.counts(), {'1': None, '2': 2, '3': None})
            self.db.execute('DELETE FROM files WHERE gid=? AND path=?', ('1', name)); self.db.commit()

    def test_page_limit_matches_reader(self):
        self.db.execute("DELETE FROM files WHERE gid='1'")
        self.db.executemany('INSERT INTO files VALUES(?,?,?,?,?)',
            (('1', f'{n:08d}.jpg', 'book-0', 1, 'f'*64) for n in range(1, 20002)))
        self.db.commit()
        self.assertIsNone(self.counts()['1'])

    def test_file_limit_is_bounded(self):
        self.db.execute("DELETE FROM files WHERE gid='1'")
        self.db.executemany('INSERT INTO files VALUES(?,?,?,?,?)',
            (('1', f'metadata-{n}', 'book-0', 1, 'f'*64) for n in range(100002)))
        self.db.commit()
        before=self.reader.count_stats['rows']
        self.assertIsNone(self.counts()['1'])
        self.assertEqual(self.reader.count_stats['rows']-before, 100004)

    def test_receipt_cache_reuses_count_and_never_reads_originals(self):
        self.enable_receipts()
        before=list(self.db.iterdump())
        with patch.object(self.reader, 'image', side_effect=AssertionError('no image IO')), patch.object(self.reader, 'records', side_effect=AssertionError('no full page manifest')):
            self.assertEqual(self.counts()['1'], 2)
            builds=self.reader.count_stats['builds']; self.counts()
        self.assertEqual(self.reader.count_stats['hits'], 1)
        self.assertEqual(self.reader.count_stats['builds'], builds+1)
        self.assertEqual(before, list(self.db.iterdump()))

    def test_order_and_unrelated_commits_keep_count(self):
        self.enable_receipts(); self.counts()
        self.file(self.books[1], '00000008.jpg', b'unrelated')
        self.books.reverse()
        for n,b in enumerate(self.books): b.update(rank=n,time=100-n)
        self.revision='b'*64; self.publish(); self.enable_retention()
        self.db.execute('UPDATE ready SET available=1 WHERE gid=?', ('1',)); self.db.commit()
        with patch.object(self.reader, 'count_pages', wraps=self.reader.count_pages) as counter:
            self.assertEqual(self.counts()['1'], 2)
            self.assertNotIn('1', [call.args[1]['id'] for call in counter.call_args_list])

    def test_added_pages_same_cover_same_order_change_etag(self):
        self.enable_receipts()
        before=self.reader.list_response(0,50)
        cover=json.loads(before[0])['books'][0]['coverIdentity']
        self.file(self.books[0], '00000004.jpg', b'new'); self.update_proof()
        after=self.reader.list_response(0,50)
        self.assertNotEqual(before[1], after[1])
        result=json.loads(after[0])['books'][0]
        self.assertEqual((result['pageCount'], result['coverIdentity']), (3,cover))

    def test_removed_receipt_or_invalid_receipt_is_not_reused(self):
        self.enable_receipts(); self.counts()
        self.update_proof('invalid')
        self.file(self.books[0], '00000004.jpg', b'new')
        self.assertEqual(self.counts()['1'], 3)
        self.db.execute("DELETE FROM book_versions WHERE gid='1'"); self.db.commit()
        self.file(self.books[0], '00000005.jpg', b'more')
        self.assertEqual(self.counts()['1'], 4)

    def test_omitted_page_rows_and_old_directory_not_counted(self):
        self.enable_receipts(); self.counts()
        self.db.execute("DELETE FROM files WHERE gid='1' AND path='00000003.gif'")
        self.db.execute('INSERT INTO files VALUES(?,?,?,?,?)', ('1', '00000009.jpg','retired-folder',1,'e'*64))
        self.update_proof()
        self.assertEqual(self.counts()['1'], 1)

    def test_receipt_directory_and_availability_must_match(self):
        self.enable_receipts(); self.counts()
        self.db.execute("UPDATE book_versions SET directory='old-folder' WHERE gid='1'");self.db.commit()
        self.file(self.books[0], '00000004.jpg', b'new')
        self.assertEqual(self.counts()['1'], 3)
        self.db.execute("UPDATE ready SET available=0 WHERE gid='1'"); self.db.commit()
        self.assertIsNone(self.counts()['1'])

    def test_counts_in_anchor_and_related_responses(self):
        for n,b in enumerate(self.books): b['title']=f'[Demo Artist] Night Sky {n+1}'
        self.publish()
        self.assertEqual(self.reader.list(0,50,'2')['catalog']['books'][0]['pageCount'],2)
        for kind in ['authors','series']:
            options=self.reader.related('1',kind)['options']
            self.assertTrue(options)
            result=self.reader.related('1',kind,options[0]['id'],limit=50)
            self.assertEqual(result['catalog']['books'][0]['pageCount'],2)

    def test_missing_receipt_table_compatibility(self):
        self.enable_retention()
        self.assertEqual(self.counts()['1'],2)

    def test_source_database_replacement_clears_count_cache(self):
        # Atomically replace a checkpointed database, not an unmatched DB/WAL pair.
        self.db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
        self.db.execute('PRAGMA journal_mode=DELETE')
        self.enable_receipts(); self.counts()
        path=self.source/'replacement.sqlite3'
        replacement=sqlite3.connect(path)
        try:
            self.db.backup(replacement)
            replacement.execute("DELETE FROM files WHERE gid='1' AND path='00000003.gif'")
            replacement.commit()
        finally: replacement.close()
        self.db.close()
        path.replace(self.source/'index.sqlite3')
        self.db=sqlite3.connect(self.source/'index.sqlite3')
        self.assertEqual(self.counts()['1'],1)

    def test_count_cache_bounded_and_close_clears(self):
        self.enable_receipts()
        self.db.execute("INSERT INTO book_versions VALUES('2','book-1',?,1)",('e'*64,));self.db.commit()
        self.reader.count_cache_capacity=1
        self.counts(); self.assertEqual(len(self.reader.count_cache),1)
        self.assertEqual(self.reader.count_cache_bytes,sum(v[2] for v in self.reader.count_cache.values()))
        self.reader.count_cache_budget=1
        self.counts(); self.assertFalse(self.reader.count_cache)
        self.reader.close(); self.assertEqual(self.reader.count_cache_bytes,0)

    def test_concurrent_requests_same_counts_no_deadlock(self):
        self.enable_receipts()
        with ThreadPoolExecutor(max_workers=4) as pool:
            values=list(pool.map(lambda _:json.loads(self.reader.list_response(0,50)[0]),range(30)))
        self.assertTrue(all(v['books'][0]['pageCount']==2 for v in values))
        self.assertEqual(self.reader.catalog_response_stats['builds'],1)

    def test_unselected_books_not_counted_and_query_is_indexed(self):
        with patch.object(self.reader,'count_pages',wraps=self.reader.count_pages) as counter:
            self.reader.list(50,50)
            self.assertEqual(counter.call_count,0)
        with self.reader.connection() as db:
            plan=db.execute('EXPLAIN QUERY PLAN SELECT path FROM files WHERE gid=? AND directory=? ORDER BY path LIMIT 100001',('1','book-0')).fetchall()
        self.assertTrue(any('USING INDEX files_gid' in row[3] for row in plan))

    def test_internal_cover_list_skips_counts_without_affecting_public_response(self):
        self.enable_receipts()
        with patch.object(self.reader,'book_page_counts',side_effect=AssertionError('background count')):
            books=self.reader.list(0,500,include_counts=False)['books']
        self.assertTrue(books)
        self.assertTrue(all('pageCount' not in book for book in books))
        self.assertEqual(self.reader.count_stats['rows'],0)
        self.assertFalse(self.reader.count_cache)
        self.assertEqual(json.loads(self.reader.list_response(0,50)[0])['books'][0]['pageCount'],2)


if __name__=='__main__': unittest.main()
