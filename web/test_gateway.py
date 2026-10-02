"""Isolated protocol/security regression against the actual NAS Reader implementation."""
import contextlib
from concurrent.futures import ThreadPoolExecutor
import hashlib
import http.client
import io
import json
from pathlib import Path
import socket
import sys
import threading
import time
import unittest
from unittest.mock import patch

from gateway import Gateway, Sessions, Rejected, image_type, read_route

READER = Path(__file__).resolve().parent.parent / 'nas-reader'
sys.path.insert(0, str(READER))
import test_server as fixtures
from server import Reader, Server
from manual import ManualStore, POLICY


class RouteTests(unittest.TestCase):
    def test_whitelisted_reads(self):
        routes = ['v1/books', 'v1/books/window', 'v1/books/1/pages', 'v1/books/1/manifest',
                  'v1/books/1/position', 'v1/books/1/cover', 'v1/books/1/pages/3',
                  'v1/books/1/authors', 'v1/books/1/series/'+'a'*64]
        for library in ('eh', 'manual'):
            for route in routes:
                with self.subTest(library=library, route=route):
                    self.assertEqual(read_route(f'api/{library}/{route}', '')[0], ('/manual' if library=='manual' else '') + '/' + route)

    def test_mutations_traversal_and_proxy_routes_rejected(self):
        for route in ['api/eh/manual/v1/uploads', 'api/manual/v1/uploads', 'api/eh/v2/manual-login',
                      'api/eh/v1/books/1/delete', 'api/eh/v1/books/../manifest',
                      'api/eh/v1/books/1/pages/0', 'api/eh/v1/books/1/pages/1/../2',
                      'api/eh/v1/books/1/cover/1', 'api/http://127.0.0.1:22', 'api/eh/v1/books/01/cover']:
            with self.subTest(route=route), self.assertRaises(Rejected): read_route(route, '')

    def test_query_validation(self):
        for query in ['limit=1', 'limit=1000', 'offset=-1', 'offset=999999', 'limit=50&limit=50',
                      'url=http://other', 'token=secret', 'path=../', 'limit=', 'anchor=1']:
            with self.subTest(query=query), self.assertRaises(Rejected): read_route('api/eh/v1/books', query)
        self.assertEqual(read_route('api/eh/v1/books', 'limit=500&offset=10000')[0], '/v1/books?limit=500&offset=10000')

    def test_image_identity_is_precondition_not_forwarded_query(self):
        sha = 'a'*64
        self.assertEqual(read_route('api/eh/v1/books/1/pages/3', 'v='+sha), ('/v1/books/1/pages/3', 'image', sha))
        self.assertEqual(read_route('api/manual/v1/books/1/cover', 'width=480&v='+sha), ('/manual/v1/books/1/cover?width=480', 'image', None))

    def test_related_parity(self):
        target, _, _ = read_route('api/eh/v1/books/1/authors', 'evidence=3&relaxed=1&credit=1&includePossible=1')
        self.assertIn('credit=1', target)
        with self.assertRaises(Rejected): read_route('api/eh/v1/books/1/series', 'credit=1')

    def test_safe_image_mime_and_html_svg_blocking(self):
        for header, kind in [(b'\xff\xd8\xffx', 'image/jpeg'), (b'GIF89a', 'image/gif'),
                             (b'\x89PNG\r\n\x1a\n', 'image/png'), (b'RIFF0000WEBP', 'image/webp'),
                             (b'0000ftypavif', 'image/avif')]: self.assertEqual(image_type(header), kind)
        for data in [b'<svg>', b'<html>', b'unknown', b'0000ftypheic']:
            with self.assertRaises(Rejected): image_type(data)

    def test_sessions_expiry_revoke_and_capacity(self):
        sessions = Sessions(ttl=1, limit=2)
        first = sessions.create('one'); second = sessions.create('two'); third = sessions.create('three')
        self.assertIsNone(sessions.get(first)); self.assertEqual(sessions.get(second), 'two')
        sessions.remove(second); self.assertIsNone(sessions.get(second))
        with patch('gateway.time.monotonic', return_value=time.monotonic()+2): self.assertIsNone(sessions.get(third))

    def test_invalid_configuration(self):
        for upstream in ['file:///etc/passwd', 'http://name:password@host', 'http://host/path', 'http://host/?q=1']:
            with self.assertRaises(ValueError): Gateway(('127.0.0.1',0), upstream, 'http://localhost')
        for base in ['x/', '//', '/../', '/bad path/']:
            with self.assertRaises(ValueError): Gateway(('127.0.0.1',0), 'http://localhost', 'http://localhost', base)


class HTTPTests(unittest.TestCase):
    publish = fixtures.ReaderTests.publish
    file = fixtures.ReaderTests.file

    def setUp(self):
        fixtures.ReaderTests.setUp(self)
        self.identity.set_password(b'isolated-test-password')
        self.manual = ManualStore(self.root/'manual', forbidden=(self.source,self.root/'state'))
        self.manual_reader = Reader(self.manual.root,self.identity,library_id=self.manual.library_id,order_policy=POLICY,cache_root=self.manual.root/'.cache')
        self.upstream = Server(('127.0.0.1',0),self.reader,cover_warm=False,related_warm=False,manual_store=self.manual,manual_reader=self.manual_reader)
        self.up_thread = threading.Thread(target=self.upstream.serve_forever, daemon=True); self.up_thread.start()
        self.gateway = Gateway(('127.0.0.1',0), f'http://127.0.0.1:{self.upstream.server_port}', 'http://localhost')
        self.gateway.origin = f'http://127.0.0.1:{self.gateway.server_port}'
        self.gateway.allowed_hosts = {f'127.0.0.1:{self.gateway.server_port}'}
        self.thread = threading.Thread(target=self.gateway.serve_forever,daemon=True); self.thread.start()
        self.cookie = ''
        self.baseline = list(self.db.iterdump())

    def tearDown(self):
        self.gateway.shutdown(); self.gateway.server_close(); self.thread.join()
        self.upstream.shutdown(); self.upstream.server_close(); self.up_thread.join()
        self.manual_reader.close(); fixtures.ReaderTests.tearDown(self)

    def request(self, path, method='GET', body=None, headers=None):
        conn = http.client.HTTPConnection('127.0.0.1',self.gateway.server_port, timeout=4)
        all_headers = {'Cookie': self.cookie}
        if method=='POST': all_headers.update({'Origin': self.gateway.origin, 'X-LocalShelf-Request':'1', 'Content-Type':'application/json'})
        all_headers.update(headers or {})
        try:
            conn.request(method,path,body,all_headers); response=conn.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally: conn.close()

    def login(self):
        self.gateway.next_login=0
        status, headers, data = self.request('/auth/login','POST',json.dumps({'password':'isolated-test-password'}))
        self.assertEqual(status,200,data); self.cookie=headers['Set-Cookie'].split(';',1)[0]
        return headers, data

    def test_login_is_private_httponly_session(self):
        headers, data = self.login()
        self.assertIn('HttpOnly',headers['Set-Cookie']); self.assertIn('SameSite=Strict',headers['Set-Cookie'])
        self.assertNotIn(self.identity.value['token'], data.decode()); self.assertNotIn(self.identity.value['token'], self.cookie)
        self.assertEqual(json.loads(self.request('/auth/session')[2])['authenticated'],True)
        self.assertEqual(self.request('/auth/logout','POST','{}')[0],200)
        self.assertEqual(self.request('/api/eh/v1/books')[0],401)

    def test_unauthenticated_read_blocked_and_public_landing(self):
        self.assertEqual(self.request('/api/eh/v1/books')[0],401)
        status,headers,body = self.request('/',headers={'Sec-Fetch-Site':'cross-site'})
        self.assertEqual(status,200); self.assertIn(b'LocalShelf',body)
        self.assertIn("object-src 'none'",headers['Content-Security-Policy'])
        self.assertEqual(headers['X-Content-Type-Options'],'nosniff')

    def test_readiness_checks_upstream_not_just_web_process(self):
        self.assertEqual(self.request('/readyz')[0], 200)
        self.db.execute('DELETE FROM state'); self.db.commit()
        self.upstream.readiness_cached = None
        self.assertEqual(self.request('/healthz')[0], 200)
        status, _, raw = self.request('/readyz')
        self.assertEqual(status, 503)
        self.assertEqual(json.loads(raw), {'app': 'localshelf-web', 'ready': False})
        self.assertNotIn(self.identity.value['token'], raw.decode())

    def test_real_catalog_page_order_and_manual_isolation(self):
        self.login()
        status,_,body=self.request('/api/eh/v1/books?offset=0&limit=50')
        self.assertEqual(status,200); self.assertEqual([b['id'] for b in json.loads(body)['books']],['1','2','3'])
        self.assertEqual(json.loads(self.request('/api/manual/v1/books?limit=50')[2])['total'],0)
        pages=json.loads(self.request('/api/eh/v1/books/1/manifest')[2])['pages']
        self.assertEqual([p['number'] for p in pages],[1,3])
        sha=pages[1]['sha256']; status,headers,body=self.request('/api/eh/v1/books/1/pages/3?v='+sha)
        self.assertEqual(status,200); self.assertEqual(headers['Content-Type'],'image/gif')
        self.assertEqual(body,b'GIF89a synthetic three')
        self.assertEqual(self.baseline,list(self.db.iterdump()))

    def test_mutations_and_raw_proxy_not_exposed(self):
        self.login()
        for route in ['/manual/v1/uploads','/v2/manual-login','/api/manual/v1/uploads','/api/eh/v1/books/1/delete', '/v2/password-pair', '/api/eh/../v2/health']:
            with self.subTest(route=route): self.assertIn(self.request(route)[0],(400,404))
        for route in ['/api/eh/v1/books','/api/manual/v1/uploads']:
            self.assertEqual(self.request(route,'POST','{}')[0],405)
        self.assertEqual(self.baseline,list(self.db.iterdump()))

    def test_csrf_and_host_rebinding_blocked(self):
        self.login()
        for headers in [{'Origin':'https://evil.invalid'}, {'Sec-Fetch-Site':'cross-site'}, {'Host':'evil.invalid'}]:
            self.assertIn(self.request('/api/eh/v1/books',headers=headers)[0],(403,421))
        for headers in [{'Origin':''},{'X-LocalShelf-Request':''},{'Origin':'null'}]:
            self.assertEqual(self.request('/auth/logout','POST','{}',headers)[0],403)
        self.assertEqual(self.request('/auth/session')[0],200)

    def test_conditional_response_and_updated_file_precondition(self):
        self.login()
        status,headers,body=self.request('/api/eh/v1/books?limit=50')
        second=self.request('/api/eh/v1/books?limit=50',headers={'If-None-Match':headers['ETag']})
        self.assertEqual(second[0],304); self.assertEqual(second[2],b''); self.assertNotIn('Content-Length',second[1])
        self.assertEqual(self.request('/api/eh/v1/books/1/pages/3?v='+'0'*64)[0],412)
        self.cookie=''; self.assertEqual(self.request('/api/eh/v1/books?limit=50',headers={'If-None-Match':headers['ETag']})[0],401)

    def test_invalid_requests_and_framing(self):
        self.login()
        for route in ['/api/eh/v1/books?limit=5000','/api/eh/v1/books?limit=50&limit=100','/api/eh/v1/books%2f1/cover', '/../../gateway.py', '/static/../gateway.py']:
            self.assertIn(self.request(route)[0],(400,404))
        self.assertEqual(self.request('/auth/login','POST','{}',{'Transfer-Encoding':'chunked'})[0],400)
        self.assertEqual(self.request('/api/eh/v1/books',headers={'Content-Length':'1'})[0],400)

    def test_wrong_password_and_throttle(self):
        body=json.dumps({'password':'incorrect-test-only'})
        self.assertEqual(self.request('/auth/login','POST',body)[0],403)
        self.assertEqual(self.request('/auth/login','POST',body)[0],429)
        self.assertEqual(json.loads(self.request('/auth/session')[2])['authenticated'],False)

    def test_prefix_and_secure_cookie(self):
        self.gateway.base='/reader/'; self.gateway.secure=True; self.gateway.cookie_name='__Secure-lsweb'
        self.gateway.next_login=0
        status,headers,body=self.request('/reader/auth/login','POST',json.dumps({'password':'isolated-test-password'}))
        self.assertEqual(status,200,body); self.assertIn('; Secure',headers['Set-Cookie']); self.assertIn('Path=/reader/',headers['Set-Cookie'])
        self.cookie=headers['Set-Cookie'].split(';',1)[0]
        self.assertEqual(self.request('/reader/api/eh/v1/books')[0],200)
        self.assertEqual(self.request('/api/eh/v1/books')[0],404)
        self.assertEqual(self.request('/reader/app.js')[0],200)

    def test_related_routes_real_index(self):
        self.books[0]['title']='[Studio (Alice)] Journey Vol. 1'
        self.books[1]['title']='[Alice] Journey Vol. 2'
        self.publish(); self.login()
        for kind in ['authors','series']:
            query='evidence=3&relaxed=1'+('&credit=1&includePossible=1' if kind=='authors' else '')
            status,_,body=self.request(f'/api/eh/v1/books/1/{kind}?{query}')
            self.assertEqual(status,200,body); options=json.loads(body)['options']; self.assertTrue(options)
            status,_,body=self.request(f'/api/eh/v1/books/1/{kind}/{options[0]["id"]}?{query}')
            self.assertEqual(status,200,body); self.assertEqual([b['id'] for b in json.loads(body)['catalog']['books']],['1','2'])

    def test_bounded_parallel_reads(self):
        self.login()
        with ThreadPoolExecutor(max_workers=6) as pool:
            results=list(pool.map(lambda _:self.request('/api/eh/v1/books/1/pages/3'),range(24)))
        self.assertTrue(all(r[0]==200 for r in results)); self.assertTrue(all(r[2]==b'GIF89a synthetic three' for r in results))

    def test_invalid_image_body_not_rendered(self):
        self.login()
        self.assertEqual(self.request('/api/eh/v1/books/1/cover')[0],415)

    def test_expired_and_revoked_upstream_session(self):
        self.login(); sid=self.cookie.split('=',1)[1]
        self.gateway.sessions.values[sid]=('x'*32,time.monotonic()+30)
        self.assertEqual(self.request('/api/eh/v1/books')[0],401)
        self.assertIsNone(self.gateway.sessions.get(sid))


if __name__=='__main__': unittest.main()
