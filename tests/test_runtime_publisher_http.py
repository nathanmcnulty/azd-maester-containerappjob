"""Offline transport proof. Only a synthetic token and loopback HTTP fixture are used."""
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
PWSH = os.environ.get('PWSH_PATH') or shutil.which('pwsh')

@unittest.skipUnless(PWSH, 'pwsh is required')
class PublisherTransportTests(unittest.TestCase):
    def run_request(self, method, payload=b'verified bundle', response=b'verified bundle', status=200, extra=None):
        calls = []
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def handle_request(self):
                calls.append((self.command, self.path, dict(self.headers), self.rfile.read(int(self.headers.get('Content-Length', 0)))))
                self.send_response(status)
                self.send_header('Content-Length', str(len(response)))
                if extra:
                    for key, value in extra.items():
                        self.send_header(key, value)
                self.end_headers()
                self.wfile.write(response)
            do_GET = handle_request
            do_PUT = handle_request
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp)/'bundle.zip'
                path.write_bytes(payload)
                fixture = Path(tmp)/'test.ps1'
                fixture.write_text("""$ErrorActionPreference='Stop'
Import-Module '%s' -Force
& (Get-Module Maester-RuntimeFiles) {
  $bundle=@{Path='%s';Size=%s;Sha256='%s'}
  Invoke-MaesterBlobRequest -Method '%s' -Uri 'http://127.0.0.1:%s/test' -Token 'synthetic-never-real' -Bundle $bundle
}
""" % (ROOT/'scripts/Maester-RuntimeFiles.psm1', path, len(payload), hashlib.sha256(payload).hexdigest(), method, server.server_port))
                proc = subprocess.run([PWSH, '-NoLogo', '-NoProfile', '-File', str(fixture)], capture_output=True, text=True, timeout=30)
            return proc, calls
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_create_only_authenticated_put(self):
        proc, calls = self.run_request('PUT', status=201)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(calls), 1)
        headers = {k.lower():v for k,v in calls[0][2].items()}
        self.assertEqual(headers['authorization'], 'Bearer synthetic-never-real')
        self.assertEqual(headers['if-none-match'], '*')
        self.assertEqual(headers['x-ms-blob-type'], 'BlockBlob')
        self.assertEqual(calls[0][3], b'verified bundle')

    def test_readback_hashes_actual_bytes(self):
        proc, _ = self.run_request('GET')
        self.assertEqual(proc.returncode, 0, proc.stderr)
        bad, _ = self.run_request('GET', response=b'untrusted bytes')
        self.assertNotEqual(bad.returncode, 0)
        self.assertNotIn('synthetic-never-real', bad.stdout + bad.stderr)

    def test_redirect_does_not_forward_bearer(self):
        proc, calls = self.run_request('GET', status=302, extra={'Location':'http://127.0.0.1:1/should-not-follow'})
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), '302')
        self.assertEqual(len(calls), 1)

    def test_size_mismatch_fails_before_acceptance(self):
        proc, _ = self.run_request('GET', response=b'too short')
        self.assertNotEqual(proc.returncode, 0)
        self.assertNotIn('synthetic-never-real', proc.stdout + proc.stderr)

if __name__ == '__main__':
    unittest.main()
