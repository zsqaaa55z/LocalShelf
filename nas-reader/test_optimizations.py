import contextlib
import hashlib
import http.client
import io
import json
import os
import socket
import sqlite3
import threading
import time
import unittest
from unittest.mock import patch
from PIL import Image, ImageCms
from server import Server, Failure
import test_server as fixtures
from thumbnails import ThumbnailCache


class OptimizationTests(unittest.TestCase):
    setUp = fixtures.ReaderTests.setUp
    tearDown = fixtures.ReaderTests.tearDown
    publish = fixtures.ReaderTests.publish
    file = fixtures.ReaderTests.file

    def install_cover(self, kind='JPEG', size=(1200, 1800), frames=False):
        output = io.BytesIO()
        with Image.new('RGB', size, 'red') as image:
            if frames:
                with Image.new('RGB', size, 'blue') as second:
                    image.save(output, format='GIF', save_all=True, append_images=[second], duration=100, loop=0)
            else:
                image.save(output, format=kind)
        self.db.execute("DELETE FROM files WHERE gid='1' AND path='.thumb'")
        data = output.getvalue()
        self.file(self.books[0], '.thumb', data)
        self.reader.thumbnails = ThumbnailCache(self.root/'state')
        return data

    @contextlib.contextmanager
    def server(self, **options):
        server = Server(('127.0.0.1', 0), self.reader, **options)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server
        finally:
            server.shutdown(); server.server_close(); thread.join()

    def request(self, server, path, etag=None, auth=True):
        conn = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=3)
        headers = {'Authorization': 'Bearer '+self.identity.value['token']} if auth else {}
        if etag: headers['If-None-Match'] = etag
        try:
            conn.request('GET', path, headers=headers)
            response = conn.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            conn.close()

    def test_thumbnail_size_original_preserved_and_etags(self):
        original = self.install_cover()
        before = list(self.db.iterdump())
        with self.server() as server:
            route = '/v1/books/1/cover'
            status, headers, data = self.request(server, route+'?width=320')
            self.assertEqual(status, 200)
            self.assertEqual(headers['Content-Type'], 'image/jpeg')
            with Image.open(io.BytesIO(data)) as image: self.assertEqual(image.size, (320,480))
            self.assertLess(len(data), len(original))
            self.assertEqual(self.request(server, route)[2], original)
            self.assertEqual(self.request(server, route+'?width=320', headers['ETag'])[0], 304)
            self.assertEqual(self.request(server, route+'?width=640', headers['ETag'])[0], 200)
            self.assertEqual(self.request(server, route+'?width=321')[0], 400)
            self.assertEqual(self.request(server, route+'?width=320&width=640')[0], 400)
            self.assertEqual(self.request(server, route+'?width=320', auth=False)[0], 401)
        self.assertEqual(before, list(self.db.iterdump()))
        self.assertEqual((self.source/'books/book-0/.thumb').read_bytes(), original)

    def test_gif_cover_first_frame_body_untouched(self):
        original = self.install_cover(size=(500,700), frames=True)
        self.db.execute("DELETE FROM files WHERE gid='1' AND path='00000003.gif'")
        self.file(self.books[0], '00000003.gif', original)
        with self.server(keep_alive=True, sendfile=True) as server:
            status, _, data = self.request(server, '/v1/books/1/cover?width=320')
            self.assertEqual(status, 200)
            with Image.open(io.BytesIO(data)) as image:
                self.assertEqual(image.format, 'JPEG')
                self.assertGreater(image.getpixel((10,10))[0], 200)
            self.assertEqual(self.request(server, '/v1/books/1/pages/3')[2], original)

    def test_existing_small_thumb_is_not_reencoded(self):
        original=self.install_cover(size=(200,300))
        with self.server() as server:
            self.assertEqual(self.request(server,'/v1/books/1/cover?width=320')[2],original)
        self.assertEqual(self.reader.thumbnails.stats['generated'],0)

    def test_cache_restart_and_corruption_recovery(self):
        self.install_cover()
        cache = self.reader.thumbnails
        with self.reader.image('1')[0] as stream:
            sha = hashlib.sha256(stream.read()).hexdigest()
            first = cache.get(stream, sha, 320)
        restarted = ThumbnailCache(self.root/'state')
        self.addCleanup(restarted.close)
        with self.reader.image('1')[0] as stream:
            self.assertEqual(restarted.get(stream,sha,320), first)
            self.assertEqual(restarted.stats['generated'], 0)
        with restarted.connection() as db: db.execute("UPDATE covers SET data=x'01'")
        # A validated compressed copy is independent of later disk corruption.
        with self.reader.image('1')[0] as stream:
            self.assertEqual(restarted.get(stream,sha,320), first)
            self.assertEqual(restarted.stats['generated'], 0)
        restarted.clear_memory()
        with self.reader.image('1')[0] as stream:
            self.assertEqual(restarted.get(stream,sha,320), first)
            self.assertEqual(restarted.stats['generated'], 1)

    def test_updated_original_is_verified_before_cached_cover(self):
        original = self.install_cover()
        with self.server() as server:
            self.assertEqual(self.request(server,'/v1/books/1/cover?width=320')[0],200)
            path = self.source/'books/book-0/.thumb'
            replacement = path.with_name('replacement')
            replacement.write_bytes(b'x'*len(original)); os.replace(replacement,path)
            self.assertEqual(self.request(server,'/v1/books/1/cover?width=320')[0],409)

    def test_busy_bad_image_and_unwritable_cache_fall_back(self):
        original = self.install_cover()
        cache = self.reader.thumbnails
        with self.server() as server:
            cache.generation.acquire()
            try: self.assertEqual(self.request(server,'/v1/books/1/cover?width=320')[2],original)
            finally: cache.generation.release()
            with patch.object(cache,'cached',side_effect=sqlite3.OperationalError('locked')):
                self.assertEqual(self.request(server,'/v1/books/1/cover?width=320')[2],original)
            with patch.object(cache,'max_pixels',100):
                self.assertEqual(self.request(server,'/v1/books/1/cover?width=320')[2],original)

    def test_cache_budget_and_metadata_strip(self):
        self.install_cover()
        cache = ThumbnailCache(self.root/'tiny-state', budget=8000, count_limit=2)
        self.addCleanup(cache.close)
        for n in range(4):
            with self.reader.image('1')[0] as stream: cache.get(stream,str(n)*64,320)
        with cache.connection() as db:
            size,count = db.execute('SELECT COALESCE(SUM(size),0),COUNT(*) FROM covers').fetchone()
        self.assertLessEqual(size,8000); self.assertLessEqual(count,2)
        output=io.BytesIO()
        with Image.new('RGB',(600,400),'green') as image:
            exif=Image.Exif();exif[274]=6;exif[315]='synthetic-private-marker'
            image.save(output,format='JPEG',exif=exif)
        data,_=cache.render(io.BytesIO(output.getvalue()),320)
        with Image.open(io.BytesIO(data)) as image:
            self.assertEqual(image.size,(320,480));self.assertFalse(image.getexif())

    def test_color_profile_and_malformed_profile_fallback(self):
        self.install_cover()
        cache=self.reader.thumbnails
        profile=ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()
        for icc,valid in [(profile,True),(b'not-a-profile',False)]:
            output=io.BytesIO()
            with Image.new('RGB',(600,800),(30,160,60)) as image:
                image.save(output,format='JPEG',icc_profile=icc)
            data=output.getvalue()
            result=cache.get(io.BytesIO(data),hashlib.sha256(data).hexdigest(),320)
            self.assertEqual(result is not None,valid)
            if result:
                with Image.open(io.BytesIO(result[0])) as image:
                    self.assertLess(max(abs(a-b) for a,b in zip(image.getpixel((100,100)),(30,160,60))),6)

    def test_idle_connections_do_not_hold_active_slots(self):
        with self.server(keep_alive=True) as server:
            idle=[]
            try:
                for _ in range(10):
                    conn=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=2)
                    conn.request('GET','/v2/health');response=conn.getresponse()
                    self.assertEqual(response.status,200);response.read();idle.append(conn)
                self.assertEqual(self.request(server,'/v1/books/1/pages/1')[0],200)
                # Client can receive the final byte before the server thread
                # executes its finally block (especially on the N100).
                deadline=time.monotonic()+1
                while server.active._value != 8 and time.monotonic()<deadline:
                    threading.Event().wait(.005)
                self.assertEqual(server.active._value,8)
                self.assertLess(server.connections,32)
            finally:
                for conn in idle: conn.close()

    def test_keepalive_reuses_connection_and_rotates(self):
        with self.server(keep_alive=True) as server:
            server.request_limit=4
            conn=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=3)
            try:
                for _ in range(9):
                    conn.request('GET','/v2/health');r=conn.getresponse()
                    self.assertEqual(r.status,200);r.read()
                self.assertEqual(server.connections,3)
            finally: conn.close()

    def test_active_limit_busy_response_and_recovery(self):
        with self.server(keep_alive=True) as server:
            for _ in range(8):server.active.acquire()
            try:self.assertEqual(self.request(server,'/v2/health')[0],503)
            finally:
                for _ in range(8):server.active.release()
            self.assertEqual(self.request(server,'/v2/health')[0],200)

    def test_unread_bodies_close_without_processing_pipeline(self):
        with self.server(keep_alive=True) as server:
            for framing in ['Content-Length: 5','Content-Length: 0\r\nContent-Length: 0','Transfer-Encoding: chunked']:
                with socket.create_connection(('127.0.0.1',server.server_port),timeout=3) as sock:
                    sock.sendall(('GET /v2/health HTTP/1.1\r\nHost: local\r\n'+framing+'\r\n\r\nGET /v2/health HTTP/1.1\r\nHost: local\r\n\r\n').encode())
                    data=b''
                    while block:=sock.recv(4096):data+=block
                    self.assertIn(b'400 Bad Request',data)
                    self.assertEqual(data.count(b'HTTP/1.1'),1)

    def test_idle_socket_timeout(self):
        with self.server(keep_alive=True) as server:
            server.idle_timeout=0.1
            conn=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=2)
            try:
                conn.request('GET','/v2/health');r=conn.getresponse();r.read()
                self.assertEqual(conn.sock.recv(1),b'')
            finally:conn.close()


if __name__ == '__main__':unittest.main()
