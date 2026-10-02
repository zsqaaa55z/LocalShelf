"""Synthetic fixtures only. Batch protocol durability and legacy resume."""
import concurrent.futures
import hashlib
import json
import http.client
import os
import ssl
import tempfile
import threading
from pathlib import Path
import unittest
from unittest.mock import patch
import test_receiver as fixtures

server = fixtures.server


def frame(revision, gid, items, specs=None):
    specs = specs if specs is not None else [{"path": p, "size": len(b), "sha256": hashlib.sha256(b).hexdigest()} for p, b in items]
    header = server.encoded({"revision": revision, "gid": gid, "files": specs})
    return len(header).to_bytes(4, "big") + header + b"".join(b for _, b in items)


class BatchTests(unittest.TestCase):
    setUp = fixtures.ReceiverTests.setUp
    file = fixtures.ReceiverTests.file
    upload = fixtures.ReceiverTests.upload

    def tearDown(self):
        self.store.close()
        self.tmp.cleanup()

    def send(self, items, gid="7"):
        return self.store.batch(frame(self.rev, gid, items))

    def assert_empty(self):
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM files").fetchone()[0], 0)
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM uploads").fetchone()[0], 0)
        self.assertIsNone(self.store.active())

    def test_hidden_nested_zero_files_and_bytes(self):
        items=[("00000001.gif",b"GIF89a"),(".thumb",b"thumb"),("sub/empty",b"")]
        self.assertEqual(self.send(items), {"confirmedFiles":3,"confirmedBytes":11})
        for path, body in items:
            self.assertEqual((self.store.root/"books/7-漫画"/path).read_bytes(),body)
        self.assertIsNone(self.store.active())

    def test_lost_ack_repeat_no_rewrite(self):
        items=[("00000001.jpg",b"one"),("00000002.jpg",b"two")]
        first=self.send(items)
        with patch.object(server.os,"fsync",side_effect=AssertionError("durable files must be reused")):
            self.assertEqual(self.send(items),first)
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM files").fetchone()[0],2)

    def test_duplicate_page_variants_batch_retry_and_commit_keep_all_bytes(self):
        items=[("00000005.jpg",b"jpeg-five"),("00000005.webp",b"webp-five"),
               ("00000009.jpg",b"jpeg-nine"),("00000009.webp",b"webp-nine")]
        result=self.send(items)
        specs=[self.file(path=p,data=b) for p,b in items]
        request={"revision":self.rev,"gid":"7","files":specs}
        receipt=self.store.book_commit(request)
        self.assertEqual(receipt["verifiedFiles"],4)
        with patch.object(server.os,"fsync",side_effect=AssertionError("verified variants must not be uploaded again")):
            self.assertEqual(self.send(items),result)
            self.assertEqual(self.store.book_commit(request),receipt)
        for path,body in items:
            self.assertEqual((self.store.root/"books/7-漫画"/path).read_bytes(),body)

    def test_resumes_part_from_old_protocol(self):
        spec=self.file(data=b"abcdefgh")
        start=self.store.begin(spec)
        self.store.chunk(start["upload"],0,b"abc")
        self.send([(spec["path"],b"abcdefgh")])
        self.assertTrue(self.store.begin(spec)["done"])

    def test_old_protocol_recognizes_batch_result(self):
        spec=self.file(data=b"good")
        self.send([(spec["path"],b"good")])
        self.assertTrue(self.store.begin(spec)["done"])

    def test_bad_later_hash_writes_nothing(self):
        items=[("00000001.jpg",b"good"),("00000002.jpg",b"bad")]
        specs=[self.file(path=p,data=b) for p,b in items]
        specs[1]["sha256"]="0"*64
        with self.assertRaisesRegex(ValueError,"hash_mismatch"):
            self.store.batch(frame(self.rev,"7",items,specs))
        self.assert_empty()

    def test_truncated_and_extra_payload_writes_nothing(self):
        raw=frame(self.rev,"7",[("00000001.jpg",b"good")])
        for broken in (raw[:-1],raw+b"x",b"",b"\0\0\0\0",b"\xff\xff\xff\xff"):
            with self.assertRaises(ValueError):self.store.batch(broken)
        self.assert_empty()

    def test_limits_and_duplicate_paths(self):
        for items in ([],[("a",b"")]*2,[(str(i),b"") for i in range(65)],[("a",b"x"*(server.CHUNK+1))]):
            with self.assertRaises(ValueError):self.send(items)
        self.assert_empty()

    def test_byte_limit_and_maximum_accepted(self):
        block=b"x"*server.CHUNK
        items=[(str(i),block) for i in range(4)]
        self.assertEqual(self.send(items)["confirmedBytes"],server.BATCH_BYTES)
        with self.assertRaises(ValueError):self.send(items+[("4",b"x")])

    def test_invalid_type_size_hash(self):
        for change in ({"size":True},{"size":-1},{"size":1.0},{"sha256":"x"},{"sha256":None}):
            spec={"path":"a","size":1,"sha256":hashlib.sha256(b"x").hexdigest()};spec.update(change)
            with self.assertRaises(ValueError):self.store.batch(frame(self.rev,"7",[("a",b"x")],[spec]))
        self.assert_empty()

    def test_path_and_symlink_rejected(self):
        for name in ("../outside","/tmp/out","a//b","a\\b"):
            with self.assertRaises(ValueError):self.send([(name,b"x")])
        (self.store.root/"books/7-漫画").symlink_to(self.store.root/"config",target_is_directory=True)
        with self.assertRaisesRegex(ValueError,"symlink"):self.send([("x",b"x")])
        self.assert_empty()

    def test_fsync_failure_never_confirms_and_retry_recovers(self):
        items=[("00000001.jpg",b"abcd")]
        with patch.object(server.os,"fsync",side_effect=OSError("synthetic I/O failure")):
            with self.assertRaises(OSError):self.send(items)
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM files").fetchone()[0],0)
        self.assertEqual(self.send(items)["confirmedFiles"],1)

    def test_failed_suffix_keeps_prefix_and_retries_after_restart(self):
        items=[("00000001.jpg",b"first"),("00000002.jpg",b"second")]
        original=self.store.finish;calls=0
        def fail_second(key):
            nonlocal calls
            calls+=1
            if calls==2:raise OSError("synthetic interruption")
            return original(key)
        with patch.object(self.store,"finish",fail_second):
            with self.assertRaises(OSError):self.send(items)
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM files").fetchone()[0],1)
        self.store.close();self.store=server.Store(self.tmp.name,0,0,0,0)
        self.assertEqual(self.send(items)["confirmedFiles"],2)

    def test_insufficient_space_no_publish(self):
        with patch.object(self.store,"space",return_value={"freeBytes":0,"reserveBytes":0}):
            with self.assertRaisesRegex(ValueError,"nas_space_insufficient"):self.send([("a",b"x")])
        self.assertIsNone(self.store.active())
        self.assertEqual(self.store.pending_space[0],0)

    def test_batch_cannot_reassign_owned_directory(self):
        other=fixtures.catalog(("11",));other["books"][0]["directory"]="7-漫画"
        revision=self.store.stage(other)["revision"]
        self.send([("a",b"original")])
        with self.assertRaisesRegex(ValueError,"directory_owned"):
            self.store.batch(frame(revision,"11",[("a",b"changed")]))
        self.assertEqual((self.store.root/"books/7-漫画/a").read_bytes(),b"original")

    def test_parallel_disjoint_batches_and_order(self):
        with concurrent.futures.ThreadPoolExecutor(3) as pool:
            list(pool.map(lambda gid:self.send([("00000001.jpg",gid.encode())],gid),["9","3","7"]))
        for gid in ["9","3","7"]:
            self.store.book_commit({"revision":self.rev,"gid":gid,"files":[self.file(gid=gid,data=gid.encode())]})
        self.store.publish({"revision":self.rev})
        self.assertEqual([b["id"] for b in self.store.catalog(self.store.active())["books"]],["7","3","9"])

    def test_archive_uses_identical_batch_protocol(self):
        from test_archive import ArchiveTests
        cat=ArchiveTests.manifest(self)
        revision=self.store.stage_archive(cat)["revision"]
        extra=self.store.extra();group=cat["groups"][0]
        self.assertEqual(extra.batch(frame(revision,group["id"],[("a",b"archive")]))["confirmedFiles"],1)


class BatchHTTPTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.store=server.Store(self.tmp.name,0,0,0,0)
        cert,key,self.token=server.initialize(self.tmp.name,"127.0.0.1",8443)
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(cert,key)
        self.http=server.TLSServer(("127.0.0.1",0),server.Handler,context);self.http.store=self.store;self.http.token=self.token
        self.thread=threading.Thread(target=self.http.serve_forever,daemon=True);self.thread.start()
        trust=ssl.create_default_context(cafile=str(cert));trust.check_hostname=False
        self.client=http.client.HTTPSConnection("127.0.0.1",self.http.server_port,context=trust,timeout=5)
        self.rev=self.store.stage(fixtures.catalog())["revision"]

    def tearDown(self):
        self.client.close();self.http.shutdown();self.http.server_close();self.thread.join();self.store.close();self.tmp.cleanup()

    def post(self,body,token=None,route="/sync/v1/files/batch"):
        self.client.request("POST",route,body,{"Authorization":"Bearer "+(token if token is not None else self.token),"Content-Type":"application/octet-stream"})
        response=self.client.getresponse();return response.status,json.loads(response.read())

    def test_framing_authenticated_keepalive_and_replay(self):
        raw=frame(self.rev,"7",[("a",b"x")])
        for _ in range(2):self.assertEqual(self.post(raw),(200,{"confirmedFiles":1,"confirmedBytes":1}))

    def test_auth_required_before_batch_parsing(self):
        self.assertEqual(self.post(b"malformed",token="incorrect")[0],401)
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM files").fetchone()[0],0)

    def test_malformed_frame_bad_request(self):
        self.assertEqual(self.post(b"\0\0\0\0")[0],400)
        self.assertEqual(self.store.db.execute("SELECT COUNT(*) FROM files").fetchone()[0],0)

    def test_archive_http_route(self):
        from test_archive import ArchiveTests
        catalog=ArchiveTests.manifest(self);revision=self.store.stage_archive(catalog)["revision"]
        raw=frame(revision,catalog["groups"][0]["id"],[("a",b"archive")])
        self.assertEqual(self.post(raw,route="/sync/v1/archive/files/batch"),(200,{"confirmedFiles":1,"confirmedBytes":7}))


if __name__=="__main__":unittest.main()
