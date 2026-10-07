import ipaddress
import json
import tempfile
import threading
import unittest
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

import server

TOKEN = 'a' * 43
OTHER = 'b' * 43


class SyncServerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        server.DB_PATH = str(Path(self.temp.name) / 'sync.sqlite')
        server.initialize()
        server.Handler.creations = {}
        self.httpd = ThreadingHTTPServer(('127.0.0.1', 0), server.Handler)
        worker = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        worker.start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(worker.join)
        self.addCleanup(self.httpd.shutdown)

    def request(self, method, path, body=None, token=TOKEN, headers=None):
        connection = HTTPConnection('127.0.0.1', self.httpd.server_port)
        self.addCleanup(connection.close)
        if isinstance(body, dict):
            body = json.dumps(body).encode()
        connection.request(method, path, body=body, headers={
            **({'Authorization': f'Bearer {token}'} if token else {}),
            **(headers or {}),
        })
        response = connection.getresponse()
        data = response.read()
        if response.headers.get('Content-Type') == 'application/json' and data:
            return response.status, json.loads(data)
        return response.status, data

    def test_document_round_trip_with_revisions(self):
        self.assertEqual(self.request('GET', '/doc'), (404, {'rev': 0}))
        self.assertEqual(self.request('PUT', '/doc', {'rev': 0, 'data': 'one'}), (200, {'rev': 1}))
        self.assertEqual(self.request('GET', '/doc'), (200, {'rev': 1, 'data': 'one'}))
        # A device that missed an update must merge it first.
        self.assertEqual(self.request('PUT', '/doc', {'rev': 0, 'data': 'stale'}), (409, {'rev': 1}))
        self.assertEqual(self.request('PUT', '/doc', {'rev': 1, 'data': 'two'}), (200, {'rev': 2}))
        # Another code sees nothing of it.
        self.assertEqual(self.request('GET', '/doc', token=OTHER), (404, {'rev': 0}))

    def test_tokens_and_origins_are_checked(self):
        self.assertEqual(self.request('GET', '/doc', token=None)[0], 401)
        self.assertEqual(self.request('GET', '/doc', token='short')[0], 401)
        self.assertEqual(self.request('GET', '/doc', headers={'Origin': 'https://evil.example'})[0], 403)
        self.assertEqual(self.request('GET', '/doc', headers={'Origin': server.ORIGIN})[0], 404)
        self.assertEqual(self.request('GET', '/elsewhere')[0], 404)
        self.assertEqual(self.request('GET', '/blobs/not-hex')[0], 404)

    def test_blobs_are_kept_while_the_document_names_them(self):
        blob = 'ab' * 16
        self.assertEqual(self.request('PUT', f'/blobs/{blob}', b'font bytes')[0], 204)
        self.assertEqual(self.request('GET', f'/blobs/{blob}'), (200, b'font bytes'))
        self.assertEqual(self.request('GET', f'/blobs/{blob}', token=OTHER)[0], 404)
        self.assertEqual(self.request('PUT', '/doc', {'rev': 0, 'data': 'x', 'blobs': [blob]})[0], 200)
        self.assertEqual(self.request('GET', f'/blobs/{blob}')[0], 200)
        self.assertEqual(self.request('PUT', '/doc', {'rev': 1, 'data': 'x', 'blobs': []})[0], 200)
        self.assertEqual(self.request('GET', f'/blobs/{blob}')[0], 404)

    def test_invalid_documents_are_rejected(self):
        self.assertEqual(self.request('PUT', '/doc', {'rev': '0', 'data': 'x'})[0], 400)
        self.assertEqual(self.request('PUT', '/doc', {'rev': 0, 'data': 5})[0], 400)
        self.assertEqual(self.request('PUT', '/doc', {'rev': 0, 'data': 'x', 'blobs': ['../x']})[0], 400)
        self.assertEqual(self.request('PUT', '/doc', b'not json')[0], 400)

    def test_quota_per_account(self):
        with patch.object(server, 'MAX_ACCOUNT', 10):
            self.assertEqual(self.request('PUT', f'/blobs/{"cd" * 16}', b'0123456789A')[0], 413)
            self.assertEqual(self.request('PUT', f'/blobs/{"cd" * 16}', b'0123')[0], 204)

    def test_deleting_removes_everything(self):
        self.request('PUT', f'/blobs/{"ef" * 16}', b'data')
        self.request('PUT', '/doc', {'rev': 0, 'data': 'x', 'blobs': ['ef' * 16]})
        self.assertEqual(self.request('DELETE', '/doc')[0], 204)
        self.assertEqual(self.request('GET', '/doc')[0], 404)
        self.assertEqual(self.request('GET', f'/blobs/{"ef" * 16}')[0], 404)

    def test_new_storage_is_rate_limited_per_client(self):
        with patch.object(server, 'NEW_PER_HOUR', 2):
            for i in range(2):
                self.assertEqual(self.request('PUT', '/doc', {'rev': 0, 'data': 'x'}, token=str(i) * 40)[0], 200)
            self.assertEqual(self.request('PUT', '/doc', {'rev': 0, 'data': 'x'}, token='z' * 40)[0], 429)
            # Existing storage keeps working.
            self.assertEqual(self.request('PUT', '/doc', {'rev': 1, 'data': 'y'}, token='0' * 40)[0], 200)

    def test_forwarded_addresses_require_a_trusted_peer(self):
        trusted = [ipaddress.ip_network('172.30.86.2/32')]
        self.assertEqual(server.client_address('172.30.86.2', '203.0.113.1', trusted), '203.0.113.1')
        self.assertEqual(server.client_address('203.0.113.2', '203.0.113.1', trusted), '203.0.113.2')
        with self.assertRaises(ValueError):
            server.client_address('172.30.86.2', None, trusted)

    def test_unused_storage_expires(self):
        self.request('PUT', '/doc', {'rev': 0, 'data': 'x'})
        db = server.connection()
        try:
            server.expire(db, now=10 ** 12)
        finally:
            db.close()
        self.assertEqual(self.request('GET', '/doc')[0], 404)


if __name__ == '__main__':
    unittest.main()
