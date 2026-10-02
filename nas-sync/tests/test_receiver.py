import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import ssl
import socket
import tempfile
import threading
import unittest
import urllib.request
import urllib.error

spec = importlib.util.spec_from_file_location("receiver", Path(__file__).parents[1] / "server.py")
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


def catalog(ids=("7", "3", "9")):
    return {"schema": 1, "orderSource": "ehviewer-downloads-time-desc", "orderVerified": True,
            "resolvedTies": {}, "books": [{"id": gid, "directory": f"{gid}-漫画", "title": f"测试漫画 {gid}", "time": 1000-i, "rank": i} for i, gid in enumerate(ids)]}


class ReceiverTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = server.Store(self.tmp.name, reserve_bytes=64*1024**2, reserve_percent=0, warning_bytes=128*1024**2, warning_percent=0)
        self.cat = catalog()
        self.rev = self.store.stage(self.cat)["revision"]

    def tearDown(self):
        self.store.db.close()
        self.tmp.cleanup()

    def file(self, gid="7", path="00000001.jpg", data=b"synthetic-image", revision=None):
        return {"revision": revision or self.rev, "gid": gid, "path": path, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}

    def upload(self, file, data):
        begin = self.store.begin(file)
        if not begin["done"]:
            if begin["offset"] < len(data):
                self.store.chunk(begin["upload"], begin["offset"], data[begin["offset"]:])
            self.store.finish(begin["upload"])
        return begin

    def commit_book(self, gid, files=(), revision=None):
        return self.store.book_commit({"revision": revision or self.rev, "gid": gid, "files": list(files)})

    def publish_empty(self):
        for b in self.cat["books"]:
            self.commit_book(b["id"])
        self.store.publish({"revision": self.rev})

    def test_transfer_order_cannot_change_download_order(self):
        for gid in ("9", "7", "3"):
            data = ("synthetic-" + gid).encode()
            file = self.file(gid=gid, data=data)
            self.upload(file, data)
            self.commit_book(gid, [file])
        self.store.publish({"revision": self.rev})
        self.assertEqual([b["id"] for b in self.store.catalog(self.store.active())["books"]], ["7", "3", "9"])

    def test_resume_survives_receiver_restart(self):
        data = b"abcdefghij"
        file = self.file(data=data)
        begin = self.store.begin(file)
        self.store.chunk(begin["upload"], 0, data[:4])
        self.store.db.close()
        self.store = server.Store(self.tmp.name, reserve_bytes=64*1024**2, reserve_percent=0, warning_bytes=128*1024**2, warning_percent=0)
        self.assertEqual(self.store.begin(file)["offset"], 4)
        self.upload(file, data)
        self.assertTrue(self.store.begin(file)["done"])
        self.assertEqual((Path(self.tmp.name) / "books/7-漫画/00000001.jpg").read_bytes(), data)

    def test_lost_ack_retry_does_not_duplicate_chunk(self):
        file = self.file(data=b"abcd")
        begin = self.store.begin(file)
        self.store.chunk(begin["upload"], 0, b"ab")
        with self.assertRaisesRegex(ValueError, "offset_conflict"):
            self.store.chunk(begin["upload"], 0, b"ab")
        self.assertEqual(self.store.begin(file)["offset"], 2)

    def test_bad_checksum_not_published_and_retry_starts_clean(self):
        file = self.file(data=b"good")
        begin = self.store.begin(file)
        self.store.chunk(begin["upload"], 0, b"evil")
        with self.assertRaisesRegex(ValueError, "hash_mismatch"):
            self.store.finish(begin["upload"])
        self.assertFalse((Path(self.tmp.name) / "books/7-漫画/00000001.jpg").exists())
        self.assertEqual(self.store.begin(file)["offset"], 0)

    def test_finish_is_idempotent(self):
        file = self.file()
        begin = self.upload(file, b"synthetic-image")
        self.assertTrue(self.store.finish(begin["upload"])["done"])
        self.assertTrue(self.store.begin(file)["done"])

    def test_incomplete_catalog_cannot_replace_previous(self):
        self.publish_empty()
        new = catalog(("11", "7", "3", "9"))
        revision = self.store.stage(new)["revision"]
        self.commit_book("11", revision=revision)
        with self.assertRaisesRegex(ValueError, "books_not_verified"):
            self.store.publish({"revision": revision})
        self.assertEqual(self.store.active(), self.rev)

    def test_tied_times_require_explicit_observed_order(self):
        cat = copy.deepcopy(self.cat)
        cat["books"][1]["time"] = 1000
        with self.assertRaisesRegex(ValueError, "ambiguous_download_order"):
            self.store.stage(cat)
        cat["resolvedTies"] = {"1000": ["7", "3"]}
        self.store.stage(cat)
        cat["resolvedTies"] = {"1000": ["3", "7"]}
        with self.assertRaisesRegex(ValueError, "ambiguous_download_order"):
            self.store.stage(cat)

    def test_reject_rank_duplicates_and_wrong_time_direction(self):
        for change in (lambda c: c["books"][1].update(rank=0), lambda c: c["books"][1].update(time=2000), lambda c: c.update(orderVerified=False)):
            cat = copy.deepcopy(self.cat)
            change(cat)
            with self.assertRaises(ValueError):
                self.store.stage(cat)

    def test_no_silent_deletion_when_phone_backup_omits_books(self):
        self.publish_empty()
        with self.assertRaisesRegex(ValueError, "backup_omits"):
            self.store.stage(catalog(("7",)))

    def test_no_directory_remapping_for_existing_books(self):
        self.publish_empty()
        cat = copy.deepcopy(self.cat)
        cat["books"][0]["directory"] = "different"
        with self.assertRaisesRegex(ValueError, "existing_directory_changed"):
            self.store.stage(cat)

    def test_nested_hidden_files_and_zero_byte_preserved(self):
        for name, data in ((".thumb", b"thumb"), (".ehviewer", b"metadata"), ("sub/empty", b"")):
            self.upload(self.file(path=name, data=data), data)
            self.assertEqual((Path(self.tmp.name) / "books/7-漫画" / name).read_bytes(), data)

    def test_path_traversal_and_symlinks_rejected(self):
        for path in ("../outside", "/root", "a//b", "a/../b", "a\\b", "a/\x00"):
            with self.assertRaises(ValueError):
                self.store.begin(self.file(path=path))
        (Path(self.tmp.name) / "books/7-漫画").symlink_to(Path(self.tmp.name) / "config", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.store.begin(self.file())

    def test_missing_or_modified_destination_is_repaired(self):
        file = self.file()
        self.upload(file, b"synthetic-image")
        target = Path(self.tmp.name) / "books/7-漫画/00000001.jpg"
        target.write_bytes(b"synthetic-xxxxx")
        self.assertFalse(self.store.begin(file)["done"])
        self.upload(file, b"synthetic-image")
        target.unlink()
        self.assertFalse(self.store.begin(file)["done"])

    def test_book_inventory_must_be_fully_verified(self):
        with self.assertRaisesRegex(ValueError, "inventory_not_complete"):
            self.commit_book("7", [self.file()])

    def test_batch_status_only_requests_new_or_changed_files(self):
        old = self.file()
        self.upload(old, b"synthetic-image")
        new = self.file(path="00000002.jpg")
        self.assertEqual(self.store.file_status({"revision": self.rev, "gid": "7", "files": [old, new]})["missing"], ["00000002.jpg"])

    def test_missing_phone_directory_keeps_nas_pages_available(self):
        file = self.file()
        self.upload(file, b"synthetic-image")
        self.commit_book("7", [])
        self.assertEqual(self.store.db.execute("SELECT available FROM ready WHERE revision=? AND gid='7'", (self.rev,)).fetchone()[0], 1)

    def test_upload_folder_cannot_be_reassigned_before_publish(self):
        self.upload(self.file(), b"synthetic-image")
        cat = catalog(("11",))
        cat["books"][0]["directory"] = "7-漫画"
        with self.assertRaisesRegex(ValueError, "directory_owned"):
            self.store.stage(cat)

    def test_same_page_encodings_preserved_verified_and_published_in_original_order(self):
        contents = {"00000005.jpg": b"jpeg-five", "00000005.webp": b"webp-five",
                    "00000009.jpg": b"jpeg-nine", "00000009.webp": b"webp-nine"}
        files = [self.file(path=name, data=data) for name, data in contents.items()]
        for file in files:
            self.upload(file, contents[file["path"]])
        receipt = self.commit_book("7", files)
        self.assertEqual(receipt["verifiedFiles"], 4)
        self.assertEqual(receipt, self.commit_book("7", list(reversed(files))))
        for gid in ("3", "9"):
            self.commit_book(gid)
        result = self.store.publish({"revision": self.rev})
        self.assertEqual(result["orderSha256"], hashlib.sha256(server.encoded(["7", "3", "9"])).hexdigest())
        self.assertEqual(self.store.db.execute("SELECT COUNT(*),SUM(size) FROM files WHERE gid='7'").fetchone()[:],
                         (4, sum(map(len, contents.values()))))
        self.store.close()
        self.store = server.Store(self.tmp.name, 0, 0, 0, 0)
        self.assertEqual(self.commit_book("7", files), receipt)
        for file in files:
            self.assertTrue(self.store.begin(file)["done"])
            self.assertEqual((self.store.root / "books/7-漫画" / file["path"]).read_bytes(), contents[file["path"]])

    def test_same_page_encodings_still_require_every_file_verified(self):
        one = self.file(path="00000005.jpg", data=b"jpeg")
        two = self.file(path="00000005.webp", data=b"webp")
        self.upload(one, b"jpeg")
        with self.assertRaisesRegex(ValueError, "inventory_not_complete"):
            self.commit_book("7", [one, two])
        self.assertIsNone(self.store.db.execute("SELECT gid FROM ready WHERE gid='7'").fetchone())
        self.upload(two, b"webp")
        wrong = dict(two, sha256="0" * 64)
        with self.assertRaisesRegex(ValueError, "inventory_not_complete"):
            self.commit_book("7", [one, wrong])
        self.assertEqual(self.commit_book("7", [one, two])["verifiedFiles"], 2)

    def test_identical_inventory_paths_still_rejected(self):
        one = self.file()
        self.upload(one, b"synthetic-image")
        with self.assertRaisesRegex(ValueError, "inventory_not_complete"):
            self.commit_book("7", [one, dict(one)])
        self.assertIsNone(self.store.db.execute("SELECT gid FROM ready WHERE gid='7'").fetchone())

    def test_variant_receipt_covers_every_encoding(self):
        one = self.file(path="00000005.jpg", data=b"jpeg")
        two = self.file(path="00000005.webp", data=b"webp")
        for f, body in ((one, b"jpeg"), (two, b"webp")):
            self.upload(f, body)
        first = self.commit_book("7", [one, two])["proof"]
        changed = self.file(path="00000005.webp", data=b"changed-webp")
        self.upload(changed, b"changed-webp")
        self.assertEqual(self.store.reuse({"revision": self.rev, "books": [{"gid": "7", "proof": first}]})["reused"], [])
        self.assertNotEqual(self.commit_book("7", [one, changed])["proof"], first)

    def test_reuse_requires_matching_successful_receipt(self):
        data=b"verified-image"; f=self.file(data=data);self.upload(f,data)
        self.assertEqual(self.store.reuse({"revision":self.rev,"books":[{"gid":"7","proof":"0"*64}]})["reused"],[])
        proof=self.store.book_commit({"revision":self.rev,"gid":"7","files":[f]})["proof"]
        result=self.store.reuse({"revision":self.rev,"books":[{"gid":"7","proof":proof}]})
        self.assertEqual(result["reused"],["7"])
        with self.assertRaisesRegex(ValueError,"books_not_verified"):self.store.publish({"revision":self.rev})

    def test_reuse_receipt_survives_restart_but_update_invalidates_it(self):
        f=self.file();self.upload(f,b"synthetic-image")
        proof=self.store.book_commit({"revision":self.rev,"gid":"7","files":[f]})["proof"]
        self.store.db.close();self.store=server.Store(self.tmp.name, reserve_bytes=64*1024**2, reserve_percent=0, warning_bytes=128*1024**2, warning_percent=0)
        request={"revision":self.rev,"books":[{"gid":"7","proof":proof}]}
        self.assertEqual(self.store.reuse(request)["reused"],["7"])
        changed=self.file(data=b"changed");self.upload(changed,b"changed")
        self.assertEqual(self.store.reuse(request)["reused"],[])

    def test_empty_inventory_cannot_supply_reuse_receipt(self):
        self.assertIsNone(self.store.book_commit({"revision":self.rev,"gid":"7","files":[]})["proof"])

    def test_reuse_rejects_duplicate_or_unknown_ids_without_partial_write(self):
        f=self.file();self.upload(f,b"synthetic-image");proof=self.store.book_commit({"revision":self.rev,"gid":"7","files":[f]})["proof"]
        with self.store.db:self.store.db.execute('DELETE FROM ready')
        with self.assertRaisesRegex(ValueError,'invalid_reuse_receipt'):
            self.store.reuse({"revision":self.rev,"books":[{"gid":"7","proof":proof}]*2})
        self.assertEqual(self.store.db.execute('SELECT COUNT(*) FROM ready').fetchone()[0],0)
        with self.assertRaises(ValueError):self.store.reuse({"revision":self.rev,"books":[{"gid":"999","proof":proof}]})

    def test_owner_index_migration_preserves_unpublished_directory_ownership(self):
        self.upload(self.file(),b"synthetic-image")
        with self.store.db:
            self.store.db.execute('DROP TABLE directory_owners')
            self.store.db.execute("DELETE FROM state WHERE key='owners_v1'")
        self.store.db.close();self.store=server.Store(self.tmp.name, reserve_bytes=64*1024**2, reserve_percent=0, warning_bytes=128*1024**2, warning_percent=0)
        cat=catalog(("11",));cat['books'][0]['directory']='7-漫画'
        with self.assertRaisesRegex(ValueError,'directory_owned'):self.store.stage(cat)

    def test_reused_old_books_preserve_order_when_new_download_added(self):
        receipts=[]
        for gid in ['9','3','7']:
            f=self.file(gid=gid);self.upload(f,b"synthetic-image")
            proof=self.store.book_commit({'revision':self.rev,'gid':gid,'files':[f]})['proof'];receipts.append({'gid':gid,'proof':proof})
        self.store.publish({'revision':self.rev})
        cat=catalog(('11','7','3','9'));rev=self.store.stage(cat)['revision']
        self.assertEqual(self.store.reuse({'revision':rev,'books':receipts})['reused'],['9','3','7'])
        with self.assertRaisesRegex(ValueError,'books_not_verified'):self.store.publish({'revision':rev})
        self.store.book_commit({'revision':rev,'gid':'11','files':[]})
        result=self.store.publish({'revision':rev})
        self.assertEqual(result['orderSha256'],hashlib.sha256(server.encoded(['11','7','3','9'])).hexdigest())


class HttpsIntegration(unittest.TestCase):
    def test_real_tls_upload_roundtrip_auth_and_resume(self):
        with tempfile.TemporaryDirectory() as tmp:
            cert, key, token = server.initialize(tmp, "127.0.0.1", 8443)
            store = server.Store(tmp, reserve_bytes=64*1024**2, reserve_percent=0, warning_bytes=128*1024**2, warning_percent=0)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(cert, key)
            http = server.TLSServer(("127.0.0.1", 0), server.Handler, context)
            http.store, http.token = store, token
            worker = threading.Thread(target=http.serve_forever, daemon=True)
            worker.start()
            client = ssl._create_unverified_context()  # Test only; production Android requires the exported pin.
            base = f"https://127.0.0.1:{http.server_port}"
            def request(path, data=None, auth=token):
                raw = data if isinstance(data, bytes) else None if data is None else json.dumps(data).encode()
                req = urllib.request.Request(base + path, data=raw, headers={"Authorization": "Bearer " + auth})
                with urllib.request.urlopen(req, context=client, timeout=5) as response:
                    return json.load(response)
            try:
                # An idle TCP peer must not block acceptance of another TLS connection.
                idle = socket.create_connection(("127.0.0.1", http.server_port), timeout=2)
                self.assertEqual(request("/sync/v1/health")["protocol"], 1)
                idle.close()
                with self.assertRaises(urllib.error.HTTPError) as error:
                    request("/sync/v1/health", auth="wrong")
                self.assertEqual(error.exception.code, 401)
                cat = catalog(("8",))
                rev = request("/sync/v1/catalog/stage", cat)["revision"]
                data = b"synthetic-network-image" * 1024
                file = {"revision": rev, "gid": "8", "path": "00000001.jpg", "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                upload = request("/sync/v1/file/begin", file)["upload"]
                request(f"/sync/v1/file/chunk?upload={upload}&offset=0", data[:4000])
                self.assertEqual(request("/sync/v1/file/begin", file)["offset"], 4000)
                request(f"/sync/v1/file/chunk?upload={upload}&offset=4000", data[4000:])
                request("/sync/v1/file/finish", {"upload": upload})
                request("/sync/v1/book/commit", {"revision": rev, "gid": "8", "files": [file]})
                self.assertTrue(request("/sync/v1/catalog/commit", {"revision": rev})["published"])
                self.assertEqual((Path(tmp) / "books/8-漫画/00000001.jpg").read_bytes(), data)
            finally:
                http.shutdown()
                http.server_close()
                worker.join()
                store.db.close()


if __name__ == "__main__":
    unittest.main()
