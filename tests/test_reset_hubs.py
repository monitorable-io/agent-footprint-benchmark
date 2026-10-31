"""sink/reset-hubs.py against a fake Beszel + Pulse on one local port: what it forgets, what it keeps,
the universal-token call, and that credentials never reach stdout."""
import json
import os
import subprocess
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "sink" / "reset-hubs.py"
CREDS = "admin@example.test\nbeszel-pw\nuniversal-token-value\npulse-admin\npulse-pw\n"


class FakeHub(BaseHTTPRequestHandler):
    log = []
    universal = {"token": "universal-token-value", "active": False, "permanent": False}

    def log_message(self, *_):  # silence
        pass

    def _send(self, code, body=None, headers=None):
        raw = json.dumps(body if body is not None else {}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        p = urlparse(self.path).path
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0)) or 0) or b"{}")
        FakeHub.log.append(("POST", p, dict(self.headers), body))
        if p.endswith("/auth-with-password"):
            ok = body.get("identity") == "admin@example.test" and body.get("password") == "beszel-pw"
            return self._send(200 if ok else 400, {"token": "pb-" + p.split("/")[3]} if ok else {"message": "bad"})
        if p == "/api/login":
            ok = body.get("username") == "pulse-admin" and body.get("password") == "pulse-pw"
            return self._send(200 if ok else 401, {"success": ok}, {"Set-Cookie": "pulse_csrf=csrf-123; Path=/"} if ok else None)
        self._send(404)

    def do_GET(self):
        u = urlparse(self.path)
        FakeHub.log.append(("GET", u.path, dict(self.headers), parse_qs(u.query)))
        if u.path == "/api/collections/systems/records":
            return self._send(200, {"items": [
                {"id": "sysA", "name": "box-1", "host": "192.0.2.11", "status": "down"},
                {"id": "sysB", "name": "box-4", "host": "192.0.2.14", "status": "up"}]})
        if u.path == "/api/collections/fingerprints/records":
            return self._send(200, {"items": [{"id": "fpA", "system": "sysA"}, {"id": "fpB", "system": "sysB"}]})
        if u.path == "/api/beszel/universal-token":
            q = parse_qs(u.query)
            if q.get("enable") == ["1"]:
                FakeHub.universal = {"token": q["token"][0], "active": True, "permanent": q.get("permanent") == ["1"]}
            return self._send(200, FakeHub.universal)
        if u.path == "/api/state":
            return self._send(200, {
                "connectedInfrastructure": [{"hostname": "box-6", "scopeAgentId": "agent-6", "uninstallAgentId": "agent-6"}],
                "activeAlerts": [{"resourceId": "docker:agent-3", "resourceName": "box-3", "metadata": {"agentId": "agent-3", "hostname": "box-3"}}]})
        self._send(404)

    def do_DELETE(self):
        u = urlparse(self.path)
        FakeHub.log.append(("DELETE", u.path, dict(self.headers), parse_qs(u.query)))
        if u.path.startswith("/api/agents/") and self.headers.get("X-CSRF-Token") != "csrf-123":
            return self._send(403, {"error": "CSRF token validation failed"})
        self._send(204 if u.path.startswith("/api/collections/") else 200, {"success": True})


class ResetHubsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(("127.0.0.1", 0), FakeHub)
        cls.port = cls.server.server_address[1]
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def run_script(self, *args):
        FakeHub.log.clear()
        FakeHub.universal = {"token": "universal-token-value", "active": False, "permanent": False}
        env = {**os.environ, "BESZEL_URL": f"http://127.0.0.1:{self.port}", "PULSE_URL": f"http://127.0.0.1:{self.port}"}
        r = subprocess.run([sys.executable, "-I", str(SCRIPT), *args], input=CREDS, capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def deletes(self):
        return [(p, q) for m, p, _, q in FakeHub.log if m == "DELETE"]

    def test_full_reset_forgets_everything_and_makes_the_token_permanent(self):
        out = self.run_script()
        self.assertIn("beszel: forgot box-1 (192.0.2.11, down)", out)
        self.assertIn("beszel: forgot box-4 (192.0.2.14, up)", out)
        self.assertIn("pulse: forgot box-3 (agent-3…)", out)
        self.assertIn("pulse: forgot box-6 (agent-6…)", out)
        self.assertIn("beszel: universal token active=True permanent=True", out)
        paths = [p for p, _ in self.deletes()]
        self.assertIn("/api/collections/fingerprints/records/fpA", paths)
        self.assertIn("/api/collections/systems/records/sysA", paths)
        self.assertIn("/api/agents/docker/runtimes/agent-3", paths)
        self.assertIn("/api/agents/agent/agent-3", paths)
        self.assertEqual([q for p, q in self.deletes() if "runtimes" in p][0], {"force": ["true"]})
        self.assertTrue(FakeHub.universal["permanent"])

    def test_hostname_filter_keeps_the_others(self):
        out = self.run_script("box-4", "box-6")
        self.assertIn("beszel: forgot box-4", out)
        self.assertNotIn("box-1", out)
        self.assertIn("pulse: forgot box-6", out)
        self.assertNotIn("box-3", out)
        paths = [p for p, _ in self.deletes()]
        self.assertNotIn("/api/collections/systems/records/sysA", paths)
        self.assertNotIn("/api/agents/agent/agent-3", paths)

    def test_dry_run_deletes_nothing_and_does_not_enable(self):
        out = self.run_script("--dry-run")
        self.assertIn("beszel: would forget box-1", out)
        self.assertIn("pulse: would forget box-3", out)
        self.assertEqual(self.deletes(), [])
        self.assertFalse(FakeHub.universal["active"])
        self.assertIn("universal token active=False", out)

    def test_credentials_never_reach_stdout(self):
        out = self.run_script()
        for secret in ("beszel-pw", "pulse-pw", "universal-token-value", "pb-_superusers", "csrf-123"):
            self.assertNotIn(secret, out)


if __name__ == "__main__":
    unittest.main()
