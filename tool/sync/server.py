"""Optional same-origin sync service: keeps a person's devices in step.

No accounts, names or emails. The app derives a bearer token from the
person's sync code, and the SHA-256 of that token names their storage here.
Everything stored is encrypted on the device with a key the server never
sees: one document (settings and data) plus content-addressed blobs (fonts).
"""
import hashlib
import ipaddress
import json
import os
import re
import sqlite3
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DB_PATH = os.environ.get('SYNC_DB', '/data/sync.sqlite')
ORIGIN = os.environ.get('SYNC_PUBLIC_ORIGIN', 'https://amud.page')
TRUSTED_PROXIES = tuple(ipaddress.ip_network(value.strip())
                        for value in os.environ.get('SYNC_TRUSTED_PROXIES', '').split(',')
                        if value.strip())
MAX_DOC = 4 * 1024 * 1024
MAX_BLOB = 16 * 1024 * 1024
MAX_ACCOUNT = 64 * 1024 * 1024
MAX_ACCOUNTS = int(os.environ.get('SYNC_MAX_ACCOUNTS', '50000'))
NEW_PER_HOUR = 10
EXPIRE_DAYS = 400
TOKEN = re.compile(r'^[A-Za-z0-9_-]{32,128}$')
BLOB_ID = re.compile(r'^[0-9a-f]{32,64}$')


def client_address(peer, forwarded, trusted_proxies=None):
    """Only the explicitly trusted nginx peer may supply a single client IP."""
    address = ipaddress.ip_address(peer)
    networks = TRUSTED_PROXIES if trusted_proxies is None else trusted_proxies
    if any(address in network for network in networks):
        if not forwarded:
            raise ValueError('Missing proxy client address')
        return str(ipaddress.ip_address(forwarded))
    return str(address)


def connection():
    db = sqlite3.connect(DB_PATH, timeout=15, isolation_level=None)
    db.execute('PRAGMA foreign_keys=ON')
    return db


def initialize():
    db = connection()
    try:
        db.execute('PRAGMA journal_mode=WAL')
        db.executescript('''
          CREATE TABLE IF NOT EXISTS accounts (
            id TEXT PRIMARY KEY, rev INTEGER NOT NULL, data BLOB, seen INTEGER NOT NULL
          );
          CREATE TABLE IF NOT EXISTS blobs (
            owner TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            id TEXT NOT NULL, data BLOB NOT NULL, PRIMARY KEY(owner,id)
          );
        ''')
    finally:
        db.close()


def used_bytes(db, owner):
    doc = db.execute('SELECT COALESCE(LENGTH(data),0) FROM accounts WHERE id=?', (owner,)).fetchone()
    blobs = db.execute('SELECT COALESCE(SUM(LENGTH(data)),0) FROM blobs WHERE owner=?', (owner,)).fetchone()
    return (doc[0] if doc else 0) + blobs[0]


def expire(db, now=None):
    now = int(time.time()) if now is None else now
    db.execute('DELETE FROM accounts WHERE seen < ?', (now - EXPIRE_DAYS * 86400,))


class Handler(BaseHTTPRequestHandler):
    creations = {}
    quota_lock = threading.Lock()

    def log_message(self, *_):
        pass  # Bearer tokens and account ids never enter logs.

    def reply(self, status, value=None, body=None, content_type='application/json'):
        if body is None:
            body = b'' if value is None else json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def owner(self):
        """The account named by the bearer token, or None if it's malformed."""
        token = self.headers.get('Authorization', '').removeprefix('Bearer ')
        return hashlib.sha256(token.encode()).hexdigest() if TOKEN.match(token) else None

    def allowed_origin(self):
        # The installed apps send no Origin; browsers must be the app's own page.
        origin = self.headers.get('Origin')
        return origin is None or origin == ORIGIN

    def body(self, limit):
        length = int(self.headers.get('Content-Length', '0'))
        if length < 0 or length > limit:
            return None
        return self.rfile.read(length) if length else b''

    def ensure_account(self, db, owner):
        """Creates [owner]'s storage on first use, within the creation quotas."""
        if db.execute('SELECT 1 FROM accounts WHERE id=?', (owner,)).fetchone():
            return True
        with self.quota_lock:
            address = client_address(self.client_address[0], self.headers.get('X-Amud-Client-IP'))
            now = time.time()
            recent = [t for t in self.creations.get(address, []) if t > now - 3600]
            if len(recent) >= NEW_PER_HOUR:
                return False
            self.creations[address] = [*recent, now]
        if db.execute('SELECT COUNT(*) FROM accounts').fetchone()[0] >= MAX_ACCOUNTS:
            return False
        db.execute('INSERT INTO accounts VALUES(?,0,NULL,?)', (owner, int(time.time())))
        return True

    def handle_request(self, method):
        if not self.allowed_origin():
            self.reply(403); return
        owner = self.owner()
        if owner is None:
            self.reply(401); return
        path = self.path.split('?', 1)[0]
        db = connection()
        try:
            if path == '/doc':
                self.doc(db, method, owner)
            elif path.startswith('/blobs/') and BLOB_ID.match(path.removeprefix('/blobs/')):
                self.blob(db, method, owner, path.removeprefix('/blobs/'))
            else:
                self.reply(404)
        except (ValueError, TypeError, KeyError):
            if db.in_transaction:
                db.execute('ROLLBACK')
            self.reply(400, {'error': 'Invalid request'})
        finally:
            db.close()

    def doc(self, db, method, owner):
        if method == 'GET':
            row = db.execute('SELECT rev, data FROM accounts WHERE id=?', (owner,)).fetchone()
            if not row:
                self.reply(404, {'rev': 0}); return
            db.execute('UPDATE accounts SET seen=? WHERE id=?', (int(time.time()), owner))
            self.reply(200, {'rev': row[0], 'data': row[1].decode() if row[1] else None})
        elif method == 'PUT':
            raw = self.body(MAX_DOC + 64 * 1024)
            if raw is None:
                self.reply(413); return
            payload = json.loads(raw)
            rev, data, blobs = payload['rev'], payload['data'], payload.get('blobs', [])
            if type(rev) is not int or not isinstance(data, str) or len(data) > MAX_DOC:
                raise ValueError('Invalid document')
            if not isinstance(blobs, list) or len(blobs) > 1000 or not all(isinstance(b, str) and BLOB_ID.match(b) for b in blobs):
                raise ValueError('Invalid blob list')
            db.execute('BEGIN IMMEDIATE')
            if not self.ensure_account(db, owner):
                db.execute('ROLLBACK')
                self.reply(429); return
            current = db.execute('SELECT rev FROM accounts WHERE id=?', (owner,)).fetchone()[0]
            if current != rev:
                db.execute('ROLLBACK')
                self.reply(409, {'rev': current}); return
            db.execute('UPDATE accounts SET rev=?, data=?, seen=? WHERE id=?', (rev + 1, data.encode(), int(time.time()), owner))
            # Blobs the document no longer names are gone for good.
            keep = set(blobs)
            stale = [b for (b,) in db.execute('SELECT id FROM blobs WHERE owner=?', (owner,)) if b not in keep]
            db.executemany('DELETE FROM blobs WHERE owner=? AND id=?', [(owner, b) for b in stale])
            if used_bytes(db, owner) > MAX_ACCOUNT:
                db.execute('ROLLBACK')
                self.reply(413); return
            db.execute('COMMIT')
            self.reply(200, {'rev': rev + 1})
        elif method == 'DELETE':
            db.execute('DELETE FROM accounts WHERE id=?', (owner,))
            self.reply(204)
        else:
            self.reply(405)

    def blob(self, db, method, owner, blob_id):
        if method == 'GET':
            row = db.execute('SELECT data FROM blobs WHERE owner=? AND id=?', (owner, blob_id)).fetchone()
            if not row:
                self.reply(404); return
            self.reply(200, body=row[0], content_type='application/octet-stream')
        elif method == 'PUT':
            data = self.body(MAX_BLOB)
            if data is None:
                self.reply(413); return
            if not data:
                raise ValueError('Empty blob')
            db.execute('BEGIN IMMEDIATE')
            if not self.ensure_account(db, owner):
                db.execute('ROLLBACK')
                self.reply(429); return
            db.execute('INSERT OR REPLACE INTO blobs VALUES(?,?,?)', (owner, blob_id, data))
            if used_bytes(db, owner) > MAX_ACCOUNT:
                db.execute('ROLLBACK')
                self.reply(413); return
            db.execute('COMMIT')
            self.reply(204)
        else:
            self.reply(405)

    def do_GET(self): self.handle_request('GET')
    def do_PUT(self): self.handle_request('PUT')
    def do_DELETE(self): self.handle_request('DELETE')


def housekeeping():
    while True:
        db = connection()
        try:
            expire(db)
        finally:
            db.close()
        time.sleep(86400)


if __name__ == '__main__':
    initialize()
    threading.Thread(target=housekeeping, daemon=True).start()
    ThreadingHTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
