import concurrent.futures as cf
import errno
import hashlib
import os
import http.client
import socket
import ssl
import tempfile
import json
from pathlib import Path
import threading
import unittest
from unittest.mock import patch
import test_receiver as receiver_tests
server = receiver_tests.server


class ParallelTests(receiver_tests.ReceiverTests):
    # Use setup/helpers without rerunning the inherited suite a second time.
    def tearDown(self):
        self.store.close();self.tmp.cleanup()

    def different(self):
        first = self.store.begin(self.file(path="00000001.jpg", data=b"abcdefgh"))
        for page in range(2, 100):
            second = self.store.begin(self.file(path=f"{page:08}.jpg", data=b"abcdefgh"))
            if server.upload_lock(self.store.root, first["upload"]) is not server.upload_lock(self.store.root, second["upload"]):
                return first, second
        self.fail("no separate lock stripes")

    def test_parallel_fsync_and_pending_reservations(self):
        a, b = self.different()
        barrier = threading.Barrier(2)
        original = os.fsync
        def sync(fd):
            barrier.wait(timeout=3)
            original(fd)
        with patch.object(server.os, "fsync", sync), cf.ThreadPoolExecutor(2) as pool:
            futures = [pool.submit(self.store.chunk, item["upload"], 0, b"abcdefgh") for item in (a,b)]
            self.assertEqual([f.result(timeout=4)["offset"] for f in futures], [8,8])
        self.assertEqual(self.store.pending_space[0], 0)

    def test_same_chunk_is_not_appended_twice(self):
        item = self.store.begin(self.file(data=b"abcdefgh"))
        def send():
            try:return self.store.chunk(item["upload"],0,b"abcdefgh")
            except ValueError as e:return str(e)
        with cf.ThreadPoolExecutor(2) as pool: results=list(pool.map(lambda _:send(),range(2)))
        self.assertIn("offset_conflict",results)
        self.assertEqual((self.store.root/"partial"/item["upload"]).read_bytes(), b"abcdefgh")

    def test_pending_bytes_prevent_concurrent_space_overcommit(self):
        a,b=self.different();entered=threading.Event();release=threading.Event();original=os.fsync
        def sync(fd):
            entered.set();release.wait(3);original(fd)
        with patch.object(self.store,"space",return_value={"freeBytes":10,"reserveBytes":0}), patch.object(server.os,"fsync",sync), cf.ThreadPoolExecutor(2) as pool:
            first=pool.submit(self.store.chunk,a["upload"],0,b"abcdefgh")
            try:
                self.assertTrue(entered.wait(2))
                with self.assertRaisesRegex(ValueError,"nas_space_insufficient"):
                    self.store.chunk(b["upload"],0,b"abcdefgh")
            finally:release.set()
            first.result(timeout=3)
        self.assertEqual(self.store.pending_space[0],0)

    def test_sync_failure_releases_pending_and_does_not_ack(self):
        item=self.store.begin(self.file(data=b"abcdefgh"))
        with patch.object(server.os,"fsync",side_effect=OSError(errno.ENOSPC,"synthetic full")):
            with self.assertRaises(OSError):self.store.chunk(item["upload"],0,b"abcdefgh")
        self.assertEqual(self.store.pending_space[0],0)
        self.assertFalse((self.store.root/"books/7-漫画/00000001.jpg").exists())

    def test_begin_waits_for_same_upload_durability(self):
        spec=self.file(data=b"abcdefgh");item=self.store.begin(spec)
        entered=threading.Event();release=threading.Event();original=os.fsync
        def sync(fd):entered.set();release.wait(3);original(fd)
        with patch.object(server.os,"fsync",sync), cf.ThreadPoolExecutor(2) as pool:
            first=pool.submit(self.store.chunk,item["upload"],0,b"abcdefgh")
            try:
                self.assertTrue(entered.wait(2));begin=pool.submit(self.store.begin,spec)
                with self.assertRaises(cf.TimeoutError):begin.result(timeout=.1)
            finally:release.set()
            first.result(timeout=3);self.assertEqual(begin.result(timeout=3)["offset"],8)

    def test_finish_hash_does_not_block_other_files(self):
        a,b=self.different();self.store.chunk(a["upload"],0,b"abcdefgh")
        entered=threading.Event();release=threading.Event();original=server.digest
        def digest(path):entered.set();release.wait(3);return original(path)
        with patch.object(server,"digest",digest), cf.ThreadPoolExecutor(2) as pool:
            first=pool.submit(self.store.finish,a["upload"])
            try:
                self.assertTrue(entered.wait(2))
                other=pool.submit(self.store.chunk,b["upload"],0,b"abcdefgh")
                self.assertEqual(other.result(timeout=1)["offset"],8)
            finally:release.set()
            self.assertTrue(first.result(timeout=3)["done"])

    def test_parallel_many_files_hashes_and_original_order(self):
        specs=[]
        for gid in ("9","3","7"):
            for page in range(1,13):
                body=f"synthetic-{gid}-{page}".encode();spec=self.file(gid,f"{page:08}.jpg",body);specs.append((spec,body))
        with cf.ThreadPoolExecutor(4) as pool:list(pool.map(lambda pair:self.upload(*pair),specs))
        for gid in ("9","3","7"):
            files=[s for s,_ in specs if s["gid"]==gid];self.commit_book(gid,files)
        result=self.store.publish({"revision":self.rev})
        self.assertEqual(result["orderSha256"],hashlib.sha256(server.encoded(["7","3","9"])).hexdigest())
        for spec,body in specs:
            self.assertEqual((self.store.root/"books"/f'{spec["gid"]}-漫画'/spec["path"]).read_bytes(),body)

    def test_archive_and_main_share_space_reservations(self):
        self.assertIs(self.store.extra().pending_space,self.store.pending_space)

    def test_staged_directory_owner_conflict_cannot_overwrite(self):
        other=receiver_tests.catalog(("11",));other["books"][0]["directory"]="7-漫画"
        revision=self.store.stage(other)["revision"]
        first=self.file(data=b"original");second=self.file(gid="11",data=b"replacement",revision=revision)
        pending=self.store.begin(second);self.store.chunk(pending["upload"],0,b"replacement")
        self.upload(first,b"original")
        with self.assertRaisesRegex(ValueError,"directory_owned_by_another_book"):self.store.finish(pending["upload"])
        self.assertEqual((self.store.root/"books/7-漫画/00000001.jpg").read_bytes(),b"original")


class NetworkLockTests(unittest.TestCase):
    def test_slow_request_body_does_not_block_health(self):
        entered=threading.Event()
        class Probe:
            def __init__(self,stream):self.stream=stream
            def read(self,*args):entered.set();return self.stream.read(*args)
            def __getattr__(self,name):return getattr(self.stream,name)
        class Handler(server.Handler):
            def setup(self):super().setup();self.rfile=Probe(self.rfile)
        with tempfile.TemporaryDirectory() as root:
            store=server.Store(root,0,0,0,0);cert,key,token=server.initialize(root,"127.0.0.1",8443)
            context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(cert,key)
            http=server.TLSServer(("127.0.0.1",0),Handler,context);http.store=store;http.token=token
            worker=threading.Thread(target=http.serve_forever,daemon=True);worker.start()
            trust=ssl.create_default_context(cafile=str(cert));trust.check_hostname=False
            slow=trust.wrap_socket(socket.create_connection(("127.0.0.1",http.server_port),timeout=2),server_hostname="LocalShelfSync")
            import http.client as client_module
            client=client_module.HTTPSConnection("127.0.0.1",http.server_port,context=trust,timeout=2)
            try:
                slow.sendall(f"POST /sync/v1/file/begin HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {token}\r\nContent-Length: 1\r\n\r\n".encode())
                self.assertTrue(entered.wait(2))
                client.request("GET","/sync/v1/health",headers={"Authorization":"Bearer "+token})
                response=client.getresponse();body=json.loads(response.read())
                self.assertEqual(response.status,200);self.assertIn("parallel-files-v1",body["capabilities"])
                self.assertIn("transferMetrics",body)
            finally:
                slow.close();client.close();http.shutdown();http.server_close();worker.join();store.close()


# unittest otherwise repeats every inherited test in this helper subclass.
for name in dir(receiver_tests.ReceiverTests):
    if name.startswith("test_") and name not in ParallelTests.__dict__:
        setattr(ParallelTests,name,None)
