import tempfile
import unittest
from unittest.mock import patch
from collections import namedtuple
import test_receiver as fixtures
server=fixtures.server

Usage = namedtuple('Usage', 'total used free')

class SpacePolicyTests(unittest.TestCase):
    setUp=fixtures.ReceiverTests.setUp
    tearDown=fixtures.ReceiverTests.tearDown
    file=fixtures.ReceiverTests.file
    def test_policy_stops_before_reserved_space_and_resumes(self):
        self.store.reserve_bytes=100; self.store.reserve_percent=10
        self.store.warning_bytes=200; self.store.warning_percent=20
        file=self.file(data=b'abcd')
        with patch.object(server.shutil,'disk_usage',return_value=Usage(2000,1798,202)):
            self.assertEqual(self.store.space()['availableForSyncBytes'],2)
            self.assertTrue(self.store.space()['spaceWarning'])
            with self.assertRaisesRegex(ValueError,'nas_space_insufficient'):self.store.begin(file)
        with patch.object(server.shutil,'disk_usage',return_value=Usage(2000,1500,500)):
            u=self.store.begin(file)['upload'];self.store.chunk(u,0,b'ab')
        with patch.object(server.shutil,'disk_usage',return_value=Usage(2000,1801,199)):
            with self.assertRaisesRegex(ValueError,'nas_space_insufficient'):self.store.chunk(u,2,b'cd')
        with patch.object(server.shutil,'disk_usage',return_value=Usage(2000,1500,500)):
            self.assertEqual(self.store.begin(file)['offset'],2)
            self.store.chunk(u,2,b'cd');self.store.finish(u)
        self.assertEqual((self.store.root/'books/7-漫画/00000001.jpg').read_bytes(),b'abcd')

    def test_invalid_policy_fails_without_creating_data(self):
        for policy in ({'reserve_percent':float('nan')},{'reserve_percent':-1},
                       {'reserve_bytes':-1},{'warning_percent':1}, {'warning_bytes':1}):
            with tempfile.TemporaryDirectory() as t:
                from pathlib import Path
                root=Path(t)/'new'
                with self.assertRaisesRegex(ValueError,'invalid_space_policy'):server.Store(root,**policy)
                self.assertFalse(root.exists())
