"""Local-only integration fixture. Never forwards or logs submitted body text."""
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
import hashlib, json, sys
out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
requests = []
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        requests.append({'unexpectedGET': self.path}); self.save()
        self.send_response(500); self.end_headers()
    def save(self):
        (out/'requests.json').write_text(json.dumps(requests, indent=2))
    def do_POST(self):
        length = int(self.headers.get('Content-Length','0'))
        if not 0 < length <= 2*1024*1024: self.send_error(413); return
        body = self.rfile.read(length)
        value = json.loads(body); mode = value.get('fixture','success')
        requests.append({'fixture':mode,'path':self.path,
            'contentDigestMatches':self.headers.get('Idempotency-Key','').startswith('goalong-history-') and self.headers.get('Idempotency-Key','').endswith('-'+hashlib.sha256(body).hexdigest()),
            'syntheticAuthorization':self.headers.get('Authorization') == 'Bearer synthetic-local-transport-test-token',
            'bytes':len(body)})
        self.save()
        receipt = {'verification':'unverified','imported':1,'updated':0,'skipped':0}
        status=200
        if mode=='refused': status=401
        if mode=='server-error': status=500
        if mode=='redirect':
            self.send_response(302)
            self.send_header('Location', f'http://127.0.0.1:{self.server.server_port}/must-not-be-followed')
            self.send_header('Content-Length','0'); self.end_headers(); return
        if mode=='invalid-receipt': receipt['verification']='verified'
        encoded=json.dumps(receipt).encode()
        if mode=='oversized': encoded=b'x'*65537
        self.send_response(status); self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(encoded))); self.end_headers()
        try: self.wfile.write(encoded)
        except (BrokenPipeError, ConnectionResetError): pass
server = HTTPServer(('127.0.0.1',0),Handler)
(out/'port.txt').write_text(str(server.server_port))
print('Loopback fixture ready on port',server.server_port,flush=True)
server.serve_forever()
