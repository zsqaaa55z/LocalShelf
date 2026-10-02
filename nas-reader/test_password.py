"""Synthetic-only fixed-password tests; never include an operator password."""
import hashlib
import http.client
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
from server import Identity, Reader, Server, Failure

SECRET = b'Synthetic-pass-42'


class PasswordTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.identity = Identity(self.root/'state')

    def tearDown(self):
        self.temp.cleanup()

    def test_salted_hash_private_storage_and_identity_unchanged(self):
        original = (self.root/'state'/'identity.json').read_bytes()
        self.identity.set_password(SECRET)
        path = self.root/'state'/'reader-password.json'
        first = json.loads(path.read_bytes())
        self.assertNotIn(SECRET, path.read_bytes())
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(first['iterations'], 600000)
        self.assertEqual(first['hash'], hashlib.pbkdf2_hmac('sha256',SECRET,bytes.fromhex(first['salt']),600000).hex())
        self.identity.set_password(SECRET)
        second = json.loads(path.read_bytes())
        self.assertNotEqual(first['salt'],second['salt'])
        self.assertNotEqual(first['hash'],second['hash'])
        self.assertEqual(original,(self.root/'state'/'identity.json').read_bytes())

    def test_reusable_after_restart_and_more_than_five_minutes(self):
        self.identity.set_password(SECRET)
        a=self.identity.pair_password(SECRET)
        reopened=Identity(self.root/'state')
        with patch('server.time.time',return_value=2000000000):
            b=reopened.pair_password(SECRET)
        self.assertEqual(a,b)
        self.assertEqual(a['token'],self.identity.value['token'])

    def test_old_pin_cannot_bypass_configured_password(self):
        pin=self.identity.new_pin()
        self.identity.set_password(SECRET)
        with self.assertRaises(Failure):self.identity.pair(pin.encode())
        with self.assertRaises(Failure):self.identity.new_pin()
        self.assertEqual(self.identity.pair_password(SECRET)['deviceId'],self.identity.value['deviceId'])

    def test_wrong_password_throttle_persists_and_recovers(self):
        self.identity.set_password(SECRET)
        for _ in range(5):
            with patch('server.time.time',return_value=1000):
                with self.assertRaises(Failure) as error:self.identity.pair_password(b'not-the-password')
                self.assertEqual(error.exception.status,403)
        reopened=Identity(self.root/'state')
        with patch('server.time.time',return_value=1100):
            with self.assertRaises(Failure) as error:reopened.pair_password(SECRET)
            self.assertEqual(error.exception.status,429)
        with patch('server.time.time',return_value=1901):
            self.assertEqual(reopened.pair_password(SECRET)['token'],self.identity.value['token'])

    def test_success_resets_partial_failure_count(self):
        self.identity.set_password(SECRET)
        with self.assertRaises(Failure):self.identity.pair_password(b'wrong-secret')
        self.identity.pair_password(SECRET)
        config=json.loads((self.root/'state'/'reader-password.json').read_bytes())
        self.assertEqual(config['attempts'],0)

    def test_invalid_input_does_not_overwrite_configuration(self):
        self.identity.set_password(SECRET)
        before=(self.root/'state'/'reader-password.json').read_bytes()
        for bad in [b'',b'short',b'a'*129,b'password\n',b'password\0',b'\xff'*8]:
            with self.assertRaises(ValueError):self.identity.set_password(bad)
            with self.assertRaises(Failure):self.identity.pair_password(bad)
        self.assertEqual(before,(self.root/'state'/'reader-password.json').read_bytes())
        self.assertTrue(Identity.valid_password('密码测试42'.encode()))

    def test_malformed_configuration_fails_closed(self):
        self.identity.set_password(SECRET)
        path=self.root/'state'/'reader-password.json'
        path.write_text('{}')
        self.assertTrue(self.identity.password_enabled())
        with self.assertRaises(Failure):self.identity.pair(b'001234')
        with self.assertRaises(Failure) as error:self.identity.pair_password(SECRET)
        self.assertEqual(error.exception.status,503)

    def test_symlink_configuration_rejected(self):
        target=self.root/'other';target.write_text('{}')
        (self.root/'state'/'reader-password.json').symlink_to(target)
        with self.assertRaises(Failure):self.identity.password_enabled()
        with self.assertRaises(ValueError):self.identity.set_password(SECRET)
        self.assertEqual(target.read_text(),'{}')

    def test_http_contract_health_auth_body_and_no_password_echo(self):
        self.identity.set_password(SECRET)
        reader=Reader(self.root/'source',self.identity)
        server=Server(('127.0.0.1',0),reader)
        worker=threading.Thread(target=server.serve_forever,daemon=True);worker.start()
        def request(path,body=None,method='GET',headers=None):
            connection=http.client.HTTPConnection('127.0.0.1',server.server_port,timeout=5)
            connection.request(method,path,body=body,headers=headers or {})
            response=connection.getresponse();result=response.status,response.read();connection.close();return result
        try:
            status,body=request('/v2/health')
            self.assertEqual(status,200);self.assertIn('password-pair-v1',json.loads(body)['capabilities'])
            self.assertEqual(request('/v1/books')[0],401)
            self.assertEqual(request('/v2/pair',b'001234','POST')[0],403)
            self.assertEqual(request('/v2/password-pair',b'x','POST')[0],400)
            self.assertEqual(request('/v2/password-pair',b'a'*129,'POST')[0],400)
            self.assertEqual(request('/v2/password-pair',b'not-the-password','POST')[0],403)
            status,body=request('/v2/password-pair',SECRET,'POST')
            self.assertEqual(status,200);self.assertNotIn(SECRET,body)
            self.assertEqual(json.loads(body)['token'],self.identity.value['token'])
            self.assertEqual(request('/v1/books',headers={'Authorization':'Bearer '+self.identity.value['token']})[0],503)
            self.assertEqual(request('/sync/v1/catalog',b'{}','POST')[0],405)
        finally:
            server.shutdown();server.server_close();worker.join();reader.close()


if __name__=='__main__':unittest.main()
