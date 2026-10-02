"""Synthetic fixtures only; no physical NAS, comic files or credentials."""
import hashlib
import http.client
import json
import unittest
from unittest.mock import patch
from server import Failure
import test_server as fixtures
import test_optimizations as http_fixtures


class LocalUpdateTests(unittest.TestCase):
    setUp = fixtures.ReaderTests.setUp
    tearDown = fixtures.ReaderTests.tearDown
    publish = fixtures.ReaderTests.publish
    file = fixtures.ReaderTests.file
    server = http_fixtures.OptimizationTests.server
    request = http_fixtures.OptimizationTests.request

    def large_catalog(self):
        self.books = [dict(id=str(i+1), rank=i, title='Synthetic '+str(i),
                           directory='book-'+str(i), time=20000-i) for i in range(10094)]
        self.revision = 'b'*64
        self.publish()

    def test_anchor_crosses_page_boundaries_without_full_library_response(self):
        self.large_catalog()
        before = list(self.db.iterdump())
        for size in (50, 100, 500):
            value = json.loads(self.reader.list_response(0, size, anchor='7001')[0])
            self.assertEqual(value['offset'], 7000//size*size)
            self.assertEqual(value['anchor'], '7001')
            self.assertEqual(len(value['catalog']['books']), size)
            self.assertEqual(value['catalog']['total'], 10094)
        self.assertEqual(before, list(self.db.iterdump()))

    def test_reorder_and_deleted_anchor(self):
        self.large_catalog()
        old = self.reader.list_response(7000, 50, anchor='7001')
        moved = self.books.pop(7000); self.books.insert(123, moved)
        for rank, book in enumerate(self.books): book.update(rank=rank, time=20000-rank)
        self.revision = 'c'*64; self.publish()
        new = self.reader.list_response(7000, 50, anchor='7001')
        self.assertNotEqual(old[1], new[1])
        self.assertEqual(json.loads(new[0])['offset'], 100)
        self.books.remove(moved)
        for rank, book in enumerate(self.books): book.update(rank=rank, time=20000-rank)
        self.revision = 'd'*64; self.publish()
        value = json.loads(self.reader.list_response(19950, 50, anchor='7001')[0])
        self.assertIsNone(value['anchor'])
        self.assertEqual(value['offset'], 10050)

    def test_window_http_conditional_auth_and_fixed_errors(self):
        with self.server() as server:
            route = '/v1/books/window?anchor=2&offset=0&limit=50'
            status, headers, body = self.request(server, route)
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(body)['anchor'], '2')
            self.assertEqual(self.request(server, route, headers['ETag'])[::2], (304, b''))
            self.assertEqual(self.request(server, route, headers['ETag'], auth=False)[0], 401)
            status, headers, _ = self.request(server, '/v1/books/window?anchor=../&limit=50')
            self.assertEqual((status, headers['X-LocalShelf-Error']), (400, 'invalid_anchor'))
            health = json.loads(self.request(server, '/v2/health')[2])
            self.assertIn('catalog-window-v1', health['capabilities'])
            self.assertIn('page-precondition-v1', health['capabilities'])

    def test_window_same_revision_content_change_and_hot_hit(self):
        first = self.reader.list_response(0, 50, anchor='2')
        with patch.object(self.reader, 'list', side_effect=AssertionError('rebuilt')):
            for _ in range(30): self.assertIs(self.reader.list_response(0, 50, anchor='2'), first)
        self.db.execute("UPDATE files SET sha=? WHERE gid='2' AND path='.thumb'", ('e'*64,)); self.db.commit()
        second = self.reader.list_response(0, 50, anchor='2')
        self.assertNotEqual(first[1], second[1])
        self.assertEqual(json.loads(second[0])['catalog']['books'][1]['coverIdentity'], 'e'*64)

    def test_anchor_keys_share_existing_bounded_cache(self):
        for i in range(70): self.reader.list_response(0, 50, anchor=str(i+1))
        self.assertEqual(len(self.reader.catalog_responses), 32)
        self.assertLessEqual(self.reader.catalog_response_bytes, self.reader.catalog_response_budget)

    def test_precondition_refuses_new_page_before_open_hash_or_transfer(self):
        with patch('server.os.open', side_effect=AssertionError('opened changed image')):
            with self.assertRaises(Failure) as caught: self.reader.image('1', 1, expected_sha='0'*64)
        self.assertEqual((caught.exception.status, caught.exception.code), (412, 'page_content_changed'))
        expected = hashlib.sha256(b'jpeg synthetic one').hexdigest()
        stream, _, sha = self.reader.image('1', 1, expected_sha=expected)
        with stream: self.assertEqual(stream.read(), b'jpeg synthetic one')
        self.assertEqual(sha, expected)

    def test_precondition_http_and_missing_file_are_distinct(self):
        with self.server() as server:
            connection = http.client.HTTPConnection(*server.server_address, timeout=3)
            self.addCleanup(connection.close)
            headers = {'Authorization': 'Bearer '+self.identity.value['token'], 'If-Match': '"'+'0'*64+'"'}
            connection.request('GET', '/v1/books/1/pages/1', headers=headers)
            response = connection.getresponse(); response.read()
            self.assertEqual(response.status, 412)
            self.assertEqual(response.getheader('X-LocalShelf-Error'), 'page_content_changed')
            status, response_headers, _ = self.request(server, '/v1/books/1/pages/2')
            self.assertEqual((status, response_headers['X-LocalShelf-Error']), (404, 'image_missing'))

    def test_unpublished_window_never_returns_cached_catalog(self):
        self.reader.list_response(0, 50, anchor='1')
        self.db.execute("DELETE FROM state WHERE key='active'"); self.db.commit()
        with self.assertRaises(Failure) as caught: self.reader.list_response(0, 50, anchor='1')
        self.assertEqual(caught.exception.code, 'library_not_published')


if __name__ == '__main__': unittest.main()
