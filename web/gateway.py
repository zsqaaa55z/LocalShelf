"""LocalShelf Web: fixed-upstream, read-only browser gateway. Python 3.12+."""
from __future__ import annotations

import argparse
import contextlib
import http.client
from http.cookies import SimpleCookie, CookieError
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import threading
import time
from urllib.parse import parse_qsl, urlencode, urlsplit

VERSION = '0.1.1-dev'
STATIC = Path(__file__).with_name('static')
ASSETS = {'': ('index.html', 'text/html; charset=utf-8'),
          'app.js': ('app.js', 'text/javascript; charset=utf-8'),
          'core.js': ('core.js', 'text/javascript; charset=utf-8'),
          'style.css': ('style.css', 'text/css; charset=utf-8'),
          'icon.svg': ('icon.svg', 'image/svg+xml')}
ID = r'[1-9][0-9]{0,18}'
SHA = r'[a-f0-9]{64}'


class Rejected(Exception):
    def __init__(self, status, code):
        self.status, self.code = status, code


def read_route(path, query):
    """Map only enumerated reads. Never accept a client-supplied upstream URL."""
    match = re.fullmatch(r'api/(eh|manual)/(v1/books(?:/.*)?)', path)
    if not match:
        raise Rejected(404, 'route_not_found')
    tail = '/' + match[2]
    pairs = parse_qsl(query, keep_blank_values=True, max_num_fields=8)
    params = dict(pairs)
    if len(pairs) != len(params):
        raise Rejected(400, 'duplicate_parameter')
    allowed = set()
    kind = 'json'
    expected = None
    if tail in ('/v1/books', '/v1/books/window'):
        allowed = {'offset', 'limit'}
        if tail.endswith('/window'): allowed.add('anchor')
    elif re.fullmatch(rf'/v1/books/{ID}/(manifest|pages|position)', tail):
        pass
    elif re.fullmatch(rf'/v1/books/{ID}/cover', tail):
        allowed = {'width', 'v'}; kind = 'image'
    elif re.fullmatch(rf'/v1/books/{ID}/pages/[1-9][0-9]{{0,7}}', tail):
        allowed = {'v'}; kind = 'image'
        expected = params.get('v')
    elif re.fullmatch(rf'/v1/books/{ID}/(authors|series)(/{SHA})?', tail):
        allowed = {'offset', 'limit', 'evidence', 'relaxed'}
        if '/authors' in tail: allowed |= {'includePossible', 'credit'}
    else:
        raise Rejected(404, 'read_only_route')
    if set(params) - allowed:
        raise Rejected(400, 'invalid_query')
    for key, value in params.items():
        valid = (key == 'offset' and re.fullmatch(r'[0-9]{1,6}', value) and int(value) <= 200000
                 or key == 'limit' and value in {str(n) for n in range(50, 501, 50)}
                 or key == 'anchor' and re.fullmatch(ID, value)
                 or key == 'width' and value in ('320', '480', '640')
                 or key == 'v' and re.fullmatch(SHA, value)
                 or key == 'evidence' and value == '3'
                 or key in ('credit', 'relaxed') and value == '1'
                 or key == 'includePossible' and value in ('0', '1'))
        if not valid: raise Rejected(400, 'invalid_query')
    params.pop('v', None)
    target = ('/manual' if match[1] == 'manual' else '') + tail
    if params: target += '?' + urlencode(params)
    return target, kind, expected


def image_type(head):
    if head.startswith(b'\xff\xd8\xff'): return 'image/jpeg'
    if head.startswith(b'\x89PNG\r\n\x1a\n'): return 'image/png'
    if head[:6] in (b'GIF87a', b'GIF89a'): return 'image/gif'
    if head[:4] == b'RIFF' and head[8:12] == b'WEBP': return 'image/webp'
    if head[4:8] == b'ftyp' and any(head[i:i+4] in (b'avif', b'avis') for i in range(8, len(head)-3, 4)):
        return 'image/avif'
    raise Rejected(415, 'unsupported_image')


class Sessions:
    def __init__(self, ttl=8*3600, limit=32):
        self.ttl, self.limit = ttl, limit
        self.values = {}
        self.lock = threading.Lock()

    def create(self, token):
        with self.lock:
            now = time.monotonic()
            self.values = {k: v for k, v in self.values.items() if v[1] > now}
            while len(self.values) >= self.limit:
                self.values.pop(next(iter(self.values)))
            sid = secrets.token_urlsafe(32)
            self.values[sid] = (token, now + self.ttl)
            return sid

    def get(self, sid):
        with self.lock:
            value = self.values.get(sid)
            if value and value[1] > time.monotonic(): return value[0]
            self.values.pop(sid, None)
            return None

    def remove(self, sid):
        with self.lock: self.values.pop(sid, None)


class Gateway(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address, upstream, origin, base='/', allowed_hosts=()):
        self.upstream = urlsplit(upstream)
        parsed = urlsplit(origin)
        for value in (self.upstream, parsed):
            if (value.scheme not in ('http', 'https') or not value.hostname or value.username
                or value.password or value.path not in ('', '/') or value.query or value.fragment):
                raise ValueError('Use a fixed HTTP(S) origin without a path, user, or query')
            _ = value.port
        if not re.fullmatch(r'/(?:[A-Za-z0-9_-]+/)*', base):
            raise ValueError('Base path must start/end with / and contain only safe segments')
        self.origin = origin.rstrip('/')
        self.base = base
        self.secure = parsed.scheme == 'https'
        self.allowed_hosts = {parsed.netloc.lower(), *(h.lower() for h in allowed_hosts if h)}
        if any(not re.fullmatch(r'[A-Za-z0-9.\[\]:_-]+', h) for h in self.allowed_hosts):
            raise ValueError('Invalid allowed host')
        self.sessions = Sessions()
        self.cookie_name = '__Secure-lsweb' if self.secure else 'lsweb'
        self.slots = threading.BoundedSemaphore(24)
        self.read_slots = threading.BoundedSemaphore(6)
        self.login_lock = threading.Lock()
        self.next_login = 0.0
        super().__init__(address, Handler)

    def connection(self):
        cls = http.client.HTTPSConnection if self.upstream.scheme == 'https' else http.client.HTTPConnection
        return cls(self.upstream.hostname, self.upstream.port, timeout=20)

    def upstream_ready(self):
        # Fixed upstream only; no credentials and no image/list downloads.
        conn = self.connection()
        conn.timeout = 2
        try:
            conn.request('GET', '/v2/ready', headers={'Connection': 'close'})
            response = conn.getresponse()
            raw = response.read(2049)
            if response.status != 200 or len(raw) > 2048:
                return False
            value = json.loads(raw)
            return isinstance(value, dict) and value.get('app') == 'localshelf-reader' and value.get('schema') == 1 and value.get('ready') is True
        except (OSError, ValueError, http.client.HTTPException):
            return False
        finally:
            conn.close()

    def process_request(self, request, address):
        if not self.slots.acquire(False):
            self.shutdown_request(request); return
        try: super().process_request(request, address)
        except BaseException:
            self.slots.release(); raise

    def process_request_thread(self, request, address):
        try: super().process_request_thread(request, address)
        finally: self.slots.release()


class Handler(BaseHTTPRequestHandler):
    server_version = 'LocalShelfWeb'
    sys_version = ''

    def setup(self):
        self.request.settimeout(15)
        super().setup()

    def log_message(self, *args):
        pass  # no URLs, cookies, passwords, titles, or bearer credentials in logs

    def headers_for(self, status, kind, length, cache='no-store', extra=()):
        self.send_response(status)
        self.send_header('Content-Type', kind)
        if status != 304: self.send_header('Content-Length', str(length))
        self.send_header('Cache-Control', cache)
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Cross-Origin-Resource-Policy', 'same-origin')
        self.send_header('Content-Security-Policy', "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob:; connect-src 'self'; font-src 'self'; base-uri 'none'; object-src 'none'; form-action 'self'; frame-ancestors 'self'")
        self.send_header('Permissions-Policy', 'camera=(), microphone=(), geolocation=()')
        for key, value in extra: self.send_header(key, value)
        self.send_header('Connection', 'close')
        self.end_headers()
        self.started = True

    def reply(self, status, value, extra=()):
        body = json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()
        self.headers_for(status, 'application/json; charset=utf-8', len(body), extra=extra)
        self.wfile.write(body)

    def sid(self):
        try:
            cookie = SimpleCookie(self.headers.get('Cookie', ''))
            item = cookie.get(self.server.cookie_name)
            return item.value if item and re.fullmatch(r'[A-Za-z0-9_-]{43}', item.value) else ''
        except CookieError: return ''

    def cookie(self, value, expire=False):
        return ('Set-Cookie', f'{self.server.cookie_name}={value}; Path={self.server.base}; HttpOnly; SameSite=Strict; Max-Age={0 if expire else self.server.sessions.ttl}' + ('; Secure' if self.server.secure else ''))

    def validate(self, post):
        lengths = self.headers.get_all('Content-Length', [])
        hosts = self.headers.get_all('Host', [])
        if len(hosts) != 1 or hosts[0].lower() not in self.server.allowed_hosts:
            raise Rejected(421, 'unexpected_host')
        if (self.headers.get('Transfer-Encoding') or len(lengths) > 1 or
            lengths and (not re.fullmatch(r'[0-9]{1,4}', lengths[0]) or int(lengths[0]) > 512)
            or not post and lengths and int(lengths[0]) != 0):
            raise Rejected(400, 'invalid_framing')
        if len(self.path) > 2048 or not self.path.startswith(self.server.base):
            raise Rejected(404, 'route_not_found')
        route = urlsplit(self.path)
        public = route.path[len(self.server.base):] in ASSETS and not post
        if not public and self.headers.get('Sec-Fetch-Site') == 'cross-site':
            raise Rejected(403, 'same_origin_required')
        origin = self.headers.get('Origin')
        if origin and origin != self.server.origin: raise Rejected(403, 'same_origin_required')
        if post and (origin != self.server.origin or self.headers.get('X-LocalShelf-Request') != '1'):
            raise Rejected(403, 'same_origin_required')
        if route.scheme or route.netloc or route.fragment or '%' in route.path or '\\' in route.path:
            raise Rejected(400, 'invalid_route')
        return route.path[len(self.server.base):], route.query, int(lengths[0]) if lengths else 0

    def do_GET(self): self.dispatch(False)
    def do_POST(self): self.dispatch(True)

    def dispatch(self, post):
        self.started = False
        self.close_connection = True
        try:
            path, query, length = self.validate(post)
            if post:
                if query: raise Rejected(400, 'invalid_query')
                if path == 'auth/logout':
                    self.server.sessions.remove(self.sid())
                    return self.reply(200, {'ok': True}, [self.cookie('', True)])
                if path != 'auth/login': raise Rejected(405, 'read_only')
                return self.login(length)
            if path in ASSETS:
                if query: raise Rejected(400, 'invalid_query')
                name, kind = ASSETS[path]
                body = (STATIC / name).read_bytes()
                self.headers_for(200, kind, len(body), 'no-cache')
                self.wfile.write(body); return
            if path == 'healthz' and not query:
                return self.reply(200, {'app': 'localshelf-web', 'version': VERSION})
            if path == 'readyz' and not query:
                is_ready = self.server.upstream_ready()
                return self.reply(200 if is_ready else 503, {'app': 'localshelf-web', 'ready': is_ready})
            token = self.server.sessions.get(self.sid())
            if path == 'auth/session' and not query:
                return self.reply(200, {'authenticated': bool(token), 'version': VERSION})
            if not token: raise Rejected(401, 'login_required')
            if path == 'api/health' and not query:
                return self.proxy('/v2/health', 'json', None, token)
            target, kind, expected = read_route(path, query)
            self.proxy(target, kind, expected, token)
        except Rejected as error:
            if not self.started: self.reply(error.status, {'error': error.code})
        except (ValueError, UnicodeError):
            if not self.started: self.reply(400, {'error': 'invalid_request'})
        except (OSError, http.client.HTTPException):
            if not self.started:
                with contextlib.suppress(OSError): self.reply(502, {'error': 'reader_unavailable'})

    def login(self, length):
        if self.headers.get('Content-Type') != 'application/json' or not 1 <= length <= 512:
            raise Rejected(400, 'invalid_login')
        raw = self.rfile.read(length)
        if len(raw) != length: raise Rejected(400, 'invalid_login')
        body = json.loads(raw)
        password = body.get('password') if isinstance(body, dict) else None
        if not isinstance(password, str) or not 8 <= len(password.encode()) <= 128 or any(ord(c) < 32 or ord(c) == 127 for c in password):
            raise Rejected(400, 'invalid_login')
        if not self.server.login_lock.acquire(False): raise Rejected(429, 'login_rate_limited')
        try:
            if time.monotonic() < self.server.next_login: raise Rejected(429, 'login_rate_limited')
            self.server.next_login = time.monotonic() + 3
            conn = self.server.connection()
            try:
                conn.request('POST', '/v2/password-pair', password.encode(), {'Content-Type': 'text/plain', 'Connection': 'close'})
                response = conn.getresponse()
                data = response.read(8193)
                if response.status != 200:
                    # Never relay upstream bodies or headers that might disclose private state.
                    raise Rejected(429 if response.status == 429 else 403 if response.status == 403 else 502,
                                   'login_rate_limited' if response.status == 429 else 'login_failed')
                if len(data) > 8192: raise Rejected(502, 'invalid_reader_response')
                result = json.loads(data)
                token = result.get('token') if isinstance(result, dict) else None
                if not isinstance(token, str) or not re.fullmatch(r'[A-Za-z0-9_-]{32}', token):
                    raise Rejected(502, 'invalid_reader_response')
            finally: conn.close()
            self.server.sessions.remove(self.sid())
            sid = self.server.sessions.create(token)
            self.reply(200, {'authenticated': True}, [self.cookie(sid)])
        finally: self.server.login_lock.release()

    def proxy(self, target, kind, expected, token):
        if not self.server.read_slots.acquire(timeout=2): raise Rejected(503, 'reader_busy')
        conn = self.server.connection()
        try:
            headers = {'Authorization': 'Bearer ' + token, 'Connection': 'close', 'Accept-Encoding': 'identity'}
            etag = self.headers.get('If-None-Match', '')
            if re.fullmatch(r'(?:W/)?"[a-f0-9]{64}"', etag): headers['If-None-Match'] = etag
            if expected: headers['If-Match'] = '"' + expected + '"'
            conn.request('GET', target, headers=headers)
            response = conn.getresponse()
            if response.status == 401:
                self.server.sessions.remove(self.sid())
                raise Rejected(401, 'login_required')
            if response.status not in (200, 304):
                status = response.status if response.status in (400, 403, 404, 409, 412, 415, 429, 503) else 502
                codes = {404: 'not_found', 409: 'catalog_changed', 412: 'page_changed', 503: 'reader_busy'}
                raise Rejected(status, codes.get(status, 'reader_request_failed'))
            extra = [('Vary', 'Cookie')]
            remote_etag = response.getheader('ETag', '')
            if re.fullmatch(r'"[a-f0-9]{64}"', remote_etag): extra.append(('ETag', remote_etag))
            if response.status == 304:
                self.headers_for(304, 'application/octet-stream', 0, 'private, no-cache', extra)
                return
            raw_length = response.getheader('Content-Length', '')
            if not re.fullmatch(r'[0-9]{1,10}', raw_length) or response.getheader('Content-Encoding'):
                raise Rejected(502, 'invalid_reader_response')
            length = int(raw_length)
            if kind == 'json' and length > 8*1024**2 or kind == 'image' and length > 512*1024**2:
                raise Rejected(413, 'response_too_large')
            head = response.read(min(length, 64))
            content_type = image_type(head) if kind == 'image' else 'application/json; charset=utf-8'
            self.headers_for(200, content_type, length, 'private, no-cache', extra)
            self.wfile.write(head)
            remaining = length - len(head)
            while remaining:
                chunk = response.read(min(256*1024, remaining))
                if not chunk: raise OSError('short upstream response')
                self.wfile.write(chunk)
                remaining -= len(chunk)
        finally:
            conn.close()
            self.server.read_slots.release()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--listen', default=os.environ.get('WEB_LISTEN', '127.0.0.1'))
    parser.add_argument('--port', type=int, default=int(os.environ.get('WEB_PORT', '8090')))
    parser.add_argument('--upstream', default=os.environ.get('READER_UPSTREAM', 'http://127.0.0.1:8089'))
    parser.add_argument('--origin', default=os.environ.get('WEB_ORIGIN', 'http://127.0.0.1:8090'))
    parser.add_argument('--base', default=os.environ.get('WEB_BASE_PATH', '/'))
    args = parser.parse_args()
    with Gateway((args.listen, args.port), args.upstream, args.origin, args.base,
                 os.environ.get('WEB_ALLOWED_HOSTS', '').split(',')) as server:
        print(f'LocalShelf Web {VERSION}: read-only gateway ready; sessions are memory-only.', flush=True)
        try: server.serve_forever()
        except KeyboardInterrupt: pass


if __name__ == '__main__': main()
