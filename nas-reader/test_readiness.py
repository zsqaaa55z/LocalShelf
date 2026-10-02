import http.client
import json
import threading
import sqlite3
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import test_server as fixtures
from server import Server
from readiness import inspect_library, ready


class ReadinessTests(unittest.TestCase):
    publish = fixtures.ReaderTests.publish
    file = fixtures.ReaderTests.file
    setUp = fixtures.ReaderTests.setUp
    tearDown = fixtures.ReaderTests.tearDown

    def request(self, server, path, token=None):
        c = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=3)
        try:
            c.request('GET', path, headers={'Authorization': 'Bearer '+token} if token else {})
            r = c.getresponse()
            return r.status, json.loads(r.read())
        finally:
            c.close()

    def test_published_metadata_only_and_read_only(self):
        before = list(self.db.iterdump())
        with patch.object(self.reader, 'snapshot', side_effect=AssertionError('full catalog')):
            checks = inspect_library(self.source)
        self.assertTrue(ready(checks))
        self.assertEqual(before, list(self.db.iterdump()))

    def test_missing_storage(self):
        self.assertEqual(inspect_library(self.root/'missing')['storage'], 'unavailable')

    def test_missing_database_not_created(self):
        root = self.root/'empty'; root.mkdir(); (root/'books').mkdir()
        self.assertEqual(inspect_library(root)['index'], 'unavailable')
        self.assertFalse((root/'index.sqlite3').exists())

    def test_unpublished(self):
        self.db.execute('DELETE FROM state'); self.db.commit()
        self.assertEqual(inspect_library(self.source)['catalog'], 'not_published')

    def test_missing_catalog(self):
        self.db.execute('DELETE FROM catalogs'); self.db.commit()
        self.assertEqual(inspect_library(self.source)['catalog'], 'unavailable')

    def test_symlink_rejected(self):
        root = self.root/'alias'; root.symlink_to(self.source, target_is_directory=True)
        self.assertFalse(ready(inspect_library(root)))

    def test_unreadable_storage_is_not_ready(self):
        with patch('readiness.os.open', side_effect=PermissionError('PRIVATE_PATH')):
            checks = inspect_library(self.source)
        self.assertEqual(checks, dict(storage='unavailable', index='not_checked', catalog='not_checked'))

    def test_database_symlink_rejected(self):
        root = self.root/'dbalias'; root.mkdir(); (root/'books').mkdir()
        (root/'index.sqlite3').symlink_to(self.source/'index.sqlite3')
        self.assertEqual(inspect_library(root)['index'], 'unavailable')

    def test_locked_index_has_bounded_wait(self):
        root = self.root/'locked'; root.mkdir(); (root/'books').mkdir()
        db = sqlite3.connect(root/'index.sqlite3')
        try:
            db.execute('CREATE TABLE state(key TEXT PRIMARY KEY, value TEXT)'); db.commit()
            db.execute('BEGIN EXCLUSIVE')
            start = time.monotonic()
            self.assertEqual(inspect_library(root)['index'], 'unavailable')
            self.assertLess(time.monotonic()-start, 1.0)
        finally: db.close()

    def test_manual_not_ready_keeps_eh_diagnostics(self):
        server = Server(('127.0.0.1', 0), self.reader)
        server.manual_reader = SimpleNamespace(source=self.root/'missing-manual')
        try:
            state = server.readiness()
            self.assertFalse(state['ready'])
            self.assertTrue(ready(state['libraries']['eh']))
            self.assertFalse(ready(state['libraries']['manual']))
        finally: server.server_close()

    def test_http_privacy_auth_and_cache(self):
        server = Server(('127.0.0.1', 0), self.reader)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            status, public = self.request(server, '/v2/ready')
            self.assertEqual(status, 200)
            self.assertEqual(set(public), {'app', 'schema', 'ready'})
            self.assertEqual(self.request(server, '/v2/diagnostics')[0], 401)
            status, private = self.request(server, '/v2/diagnostics', self.identity.value['token'])
            self.assertEqual(status, 200)
            self.assertEqual(private['libraries']['eh']['catalog'], 'ready')
            for secret in [str(self.root), self.identity.value['token'], self.identity.value['deviceId'], 'Synthetic']:
                self.assertNotIn(secret, json.dumps(private))
            with patch('server.inspect_library', side_effect=AssertionError('unexpected repeated probe')):
                self.assertEqual(self.request(server, '/v2/ready')[0], 200)
            self.assertEqual(self.request(server, '/v2/ready?path=/etc')[0], 400)
            self.db.execute('DELETE FROM state'); self.db.commit(); server.readiness_cached = None
            self.assertEqual(self.request(server, '/v2/ready')[0], 503)
        finally:
            server.shutdown(); server.server_close(); thread.join()


if __name__ == '__main__': unittest.main()
