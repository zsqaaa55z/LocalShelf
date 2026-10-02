import copy
import hashlib
import hmac
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from authors import AuthorIndex
from series import SeriesIndex
from related_cache import RelatedDiskCache, RelatedWarmup, pack_graph, unpack_graph
from test_related import books
import test_server as fixtures


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.data=books('[Team (花子 / Hanako)] 星空 1','[Team (花子)] 星空 2','[Team] Another',
                        '[Hanako] 星空 番外','[花子] 夜空 [Chinese]','[花子] 夜空 [English]',
                        '[アオイ] Other','[あおい] Different')
        self.cache=RelatedDiskCache(self.root,'library-test','not-a-real-credential')
        self.a=AuthorIndex(self.data);self.s=SeriesIndex(self.data,self.a)

    def tearDown(self):self.temp.cleanup()

    def compare(self,a,s,data):
        expected=AuthorIndex(data);expected_series=SeriesIndex(data,expected)
        for b in data:
            for possible,expanded in ((False,False),(True,False),(True,True)):
                options=a.options(b['id'],possible,expanded)
                self.assertEqual(options,expected.options(b['id'],possible,expanded))
                for option in options:
                    self.assertEqual(a.details(b['id'],option['id'],possible,expanded),expected.details(b['id'],option['id'],possible,expanded))
            for expanded in (False,True):
                self.assertEqual(s.options(b['id'],expanded),expected_series.options(b['id'],expanded))
        self.assertEqual(s.group_notes,expected_series.group_notes)

    def test_restore_equal_no_reparse_and_stable_selectors(self):
        self.assertTrue(self.cache.save(self.data,self.a,self.s))
        with patch('authors.parse_credit',side_effect=AssertionError('reparse')),patch('series.parse_series_title',side_effect=AssertionError('reparse')):
            a,s=self.cache.load(self.data)
        self.compare(a,s,self.data);self.assertEqual((a.parsed_count,s.parsed_count),(0,0))
        self.assertEqual(self.cache.path.stat().st_mode&0o777,0o600)

    def test_reordered_restore_uses_current_order_and_can_increment(self):
        self.cache.save(self.data,self.a,self.s);data=list(reversed(self.data))
        a,s=self.cache.load(data);self.compare(a,s,data)
        changed=[dict(b) for b in data];changed[0]['title']='[Other] Changed'
        next_a=AuthorIndex(changed,a);next_s=SeriesIndex(changed,next_a,s)
        self.assertEqual((next_a.parsed_count,next_s.parsed_count),(1,1));self.compare(next_a,next_s,changed)

    def test_metadata_rules_scope_and_identity_invalidate(self):
        self.cache.save(self.data,self.a,self.s)
        for field in ('title','directory','id'):
            data=copy.deepcopy(self.data);data[0][field]+='new';self.assertIsNone(self.cache.load(data))
        self.assertIsNone(RelatedDiskCache(self.root,'different','not-a-real-credential').load(self.data))
        self.assertIsNone(RelatedDiskCache(self.root,'library-test','different').load(self.data))
        self.cache.rules='other-rule-version';self.assertIsNone(self.cache.load(self.data))

    def test_corrupt_truncated_unsigned_and_oversize_fall_back(self):
        self.cache.save(self.data,self.a,self.s);original=self.cache.path.read_bytes()
        for value in (b'',original[:100],original[:-1]+b'X',b'x'*100):
            self.cache.path.write_bytes(value);self.assertIsNone(self.cache.load(self.data))
        self.cache.path.write_bytes(original)
        with patch('related_cache.MAX_BYTES',64):self.assertIsNone(self.cache.load(self.data))
        self.assertIsNotNone(self.cache.load(self.data))

    def test_no_pickle_unknown_nodes_cycles_and_depth(self):
        for graph in ([[['pickle','evil']],0],[[['t',[0]]],0],[[['s','x'],['t',[2]]],1]):
            with self.assertRaises(ValueError):unpack_graph(graph)
        nodes=[['s','x']]+[['t',[i]] for i in range(18)]
        with self.assertRaises(ValueError):unpack_graph([nodes,len(nodes)-1])
        with self.assertRaises(ValueError):pack_graph(object())

    def test_graph_preserves_shared_large_members_not_repeated_expansion(self):
        shared=tuple(str(i) for i in range(10000));graph=pack_graph({str(i):shared for i in range(100)})
        result=unpack_graph(graph)
        self.assertIs(result['0'],result['99']);self.assertLess(len(graph[0]),10300)

    def test_symlink_and_unwritable_snapshot_do_not_block_index(self):
        target=self.root/'outside';target.write_bytes(b'untouched')
        self.cache.path.symlink_to(target);self.assertIsNone(self.cache.load(self.data))
        self.assertEqual(target.read_bytes(),b'untouched')
        with patch('related_cache.os.replace',side_effect=OSError('disk full')):
            self.assertFalse(self.cache.save(self.data,self.a,self.s))
        self.assertEqual(list(self.root.glob('.related-index-????????')),[])

    def test_failed_save_keeps_last_good_snapshot(self):
        self.cache.save(self.data,self.a,self.s);before=self.cache.path.read_bytes()
        self.cache.saved_metadata=None
        with patch('related_cache.os.replace',side_effect=OSError('failed')):
            self.assertFalse(self.cache.save(self.data,self.a,self.s))
        self.assertEqual(self.cache.path.read_bytes(),before)

    def test_no_rewrite_after_restore_or_reorder_and_crash_partial_cleanup(self):
        orphan=self.root/'.related-index-abcdefgh';orphan.write_bytes(b'partial')
        unrelated=self.root/'.related-index-not-ours';unrelated.write_bytes(b'keep')
        self.assertTrue(self.cache.save(self.data,self.a,self.s));self.assertFalse(orphan.exists())
        self.assertEqual(unrelated.read_bytes(),b'keep');stamp=self.cache.path.stat().st_mtime_ns
        other=RelatedDiskCache(self.root,'library-test','not-a-real-credential')
        data=list(reversed(self.data));a,s=other.load(data)
        self.assertTrue(other.save(data,a,s));self.assertEqual(other.saves,0)
        self.assertEqual(self.cache.path.stat().st_mtime_ns,stamp)


class WarmupTests(unittest.TestCase):
    setUp=fixtures.ReaderTests.setUp
    tearDown=fixtures.ReaderTests.tearDown
    publish=fixtures.ReaderTests.publish
    file=fixtures.ReaderTests.file

    def test_idle_only_builds_once_no_source_writes(self):
        before=list(self.db.iterdump());idle=False
        worker=RelatedWarmup(self.reader,lambda:idle)
        worker.tick();self.assertIsNone(self.reader.author_index)
        idle=True;worker.tick();first=self.reader.author_index
        self.assertIsNotNone(first);self.assertEqual(self.reader.related_disk.saves,1)
        worker.tick();self.assertIs(self.reader.author_index,first);self.assertEqual(self.reader.related_disk.saves,1)
        self.assertEqual(list(self.db.iterdump()),before)
        worker.close();worker.tick();self.assertEqual(self.reader.related_disk.saves,1)

    def test_publication_change_and_rebuild_outside_read_transaction(self):
        original=self.reader.related_indexes;calls=[]
        def checked(data,need_series):
            # A checkpoint is blocked by a live read transaction after a write.
            self.db.execute("INSERT OR REPLACE INTO state VALUES('check','1')");self.db.commit()
            result=self.db.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchone()
            self.assertEqual(result[0],0);calls.append(1)
            return original(data,need_series)
        worker=RelatedWarmup(self.reader,lambda:True)
        with patch.object(self.reader,'related_indexes',side_effect=checked):worker.tick()
        self.books[0]['title']='[Alice] New 1';self.revision='b'*64;self.publish();worker.tick()
        self.assertEqual(self.reader.author_index.parsed_count,1)
        self.assertEqual(self.reader.related_disk.saves,2);self.assertEqual(len(calls),1)

    def test_foreground_build_outside_txn_and_snapshot_change_rejected(self):
        original=self.reader.related_indexes
        def changed(data,need_series):
            value=original(data,need_series)
            self.revision='d'*64;self.publish()
            return value
        with patch.object(self.reader,'related_indexes',side_effect=changed):
            with self.assertRaises(fixtures.Failure) as error:self.reader.related('1','authors')
        self.assertEqual(error.exception.status,503)
