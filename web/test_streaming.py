"""Synthetic wire-level tests: no production services or image library required."""
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import http.client
import threading
import tracemalloc
import unittest

from gateway import Gateway

SIZE = 16 * 1024 * 1024
CHUNK = b'\xff\xd8\xff' + b'x' * (64 * 1024 - 3)


class SyntheticUpstream(BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def do_GET(self):
        if self.path == '/v1/books/2/cover':
            body=b'<html>PRIVATE UPSTREAM DEBUG</html>'
            self.send_response(500);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
            return
        if self.path == '/v1/books/3/cover':
            self.send_response(200);self.send_header('Content-Length',str(513*1024**2));self.end_headers()
            return
        self.send_response(200); self.send_header('Content-Length',str(SIZE)); self.send_header('ETag','"'+'a'*64+'"');self.end_headers()
        try:
            for _ in range(SIZE//len(CHUNK)): self.wfile.write(CHUNK)
        except OSError: pass


class StreamingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.upstream=ThreadingHTTPServer(('127.0.0.1',0),SyntheticUpstream)
        cls.up_thread=threading.Thread(target=cls.upstream.serve_forever,daemon=True);cls.up_thread.start()
        cls.gateway=Gateway(('127.0.0.1',0),f'http://127.0.0.1:{cls.upstream.server_port}','http://localhost')
        cls.gateway.allowed_hosts={f'127.0.0.1:{cls.gateway.server_port}'}
        cls.thread=threading.Thread(target=cls.gateway.serve_forever,daemon=True);cls.thread.start()
        cls.cookie='lsweb='+cls.gateway.sessions.create('t'*32)

    @classmethod
    def tearDownClass(cls):
        cls.gateway.shutdown();cls.gateway.server_close();cls.thread.join()
        cls.upstream.shutdown();cls.upstream.server_close();cls.up_thread.join()

    def get(self,path='/api/eh/v1/books/1/cover'):
        conn=http.client.HTTPConnection('127.0.0.1',self.gateway.server_port,timeout=5)
        conn.request('GET',path,headers={'Cookie':self.cookie})
        return conn,conn.getresponse()

    def test_four_large_streams_use_bounded_python_buffers(self):
        def read(_):
            conn,response=self.get();total=0
            try:
                self.assertEqual(response.status,200)
                self.assertEqual(response.getheader('Content-Type'),'image/jpeg')
                while data:=response.read(64*1024):total+=len(data)
                return total
            finally:conn.close()
        tracemalloc.start()
        try:
            with ThreadPoolExecutor(max_workers=4) as pool: sizes=list(pool.map(read,range(4)))
            _,peak=tracemalloc.get_traced_memory()
        finally:tracemalloc.stop()
        self.assertEqual(sizes,[SIZE]*4)
        self.assertLess(peak,12*1024*1024, f'Unbounded streaming allocation: {peak}')
        print(f'\nStreaming QA: 4 x 16 MiB; traced Python peak {peak/1024**2:.2f} MiB (client + mock + gateway; not RSS).')

    def test_upstream_private_error_not_reflected(self):
        conn,response=self.get('/api/eh/v1/books/2/cover')
        try:
            self.assertEqual(response.status,502)
            self.assertNotIn(b'PRIVATE',response.read())
        finally:conn.close()

    def test_oversized_declared_body_rejected_before_buffering(self):
        conn,response=self.get('/api/eh/v1/books/3/cover')
        try:self.assertEqual(response.status,413)
        finally:conn.close()

    def test_disconnect_does_not_poison_following_requests(self):
        conn,response=self.get();self.assertEqual(response.status,200);response.read(1024);conn.close()
        conn,response=self.get('/api/eh/v1/books/2/cover')
        try:self.assertEqual(response.status,502)
        finally:conn.close()


if __name__=='__main__':unittest.main()
