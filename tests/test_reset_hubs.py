"""sink/reset-hubs.py against a fake Beszel + Pulse on one local port: what it forgets, what it keeps, the
universal-token call (POST, never in a URL), the per-slot Pulse token, strict failures, and that nothing
read from stdin reaches stdout or stderr."""
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
SECRETS = ("beszel-pw", "pulse-pw", "universal-token-value", "pb-_superusers", "pb-users", "csrf-123")


class FakeHub(BaseHTTPRequestHandler):
    log = []
    universal = {}
    fail_delete = False

    def log_message(self, *_):
        pass

    def _send(self, code, body=None, headers=None):
        raw = json.dumps(body if body is not None else {}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(raw)

    def _body(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        return json.loads(self.rfile.read(n) or b"{}") if n else {}

    def do_POST(self):
        p = urlparse(self.path).path
        body = self._body()
        FakeHub.log.append(("POST", self.path, dict(self.headers), body))
        if p.endswith("/auth-with-password"):
            ok = body.get("identity") == "admin@example.test" and body.get("password") == "beszel-pw"
            return self._send(200 if ok else 400, {"token": "pb-" + p.split("/")[3]} if ok else {"message": "bad"})
        if p == "/api/beszel/universal-token":
            if "pb-users" not in self.headers.get("Authorization", ""):
                return self._send(403, {"message": "Superusers cannot use universal tokens"})
            if body.get("enable") == 1:
                FakeHub.universal = {"token": body["token"], "active": True, "permanent": body.get("permanent") == 1}
            return self._send(200, FakeHub.universal)
        if p == "/api/login":
            ok = body.get("username") == "pulse-admin" and body.get("password") == "pulse-pw"
            return self._send(200 if ok else 401, {"success": ok}, {"Set-Cookie": "pulse_csrf=csrf-123; Path=/"} if ok else None)
        if p == "/api/security/tokens":
            if self.headers.get("X-CSRF-Token") != "csrf-123":
                return self._send(403, {"error": "CSRF token validation failed"})
            return self._send(200, {"token": "pulse-raw-token-value", "name": body.get("name"), "scopes": body.get("scopes")})
        self._send(404)

    def do_GET(self):
        u = urlparse(self.path)
        FakeHub.log.append(("GET", self.path, dict(self.headers), parse_qs(u.query)))
        if u.path == "/api/collections/systems/records":
            return self._send(200, {"items": [
                {"id": "sysA", "name": "box-1", "host": "192.0.2.11", "status": "down"},
                {"id": "sysB", "name": "box-4", "host": "192.0.2.14", "status": "up"}]})
        if u.path == "/api/collections/fingerprints/records":
            return self._send(200, {"items": [{"id": "fpA", "system": "sysA"}, {"id": "fpB", "system": "sysB"}]})
        if u.path == "/api/beszel/universal-token":
            return self._send(200, FakeHub.universal)
        if u.path == "/api/state":
            return self._send(200, {"connectedInfrastructure": [
                {"id": "machine:agent-6", "hostname": "box-6", "status": "active", "scopeAgentId": "agent-6", "surfaces": [
                    {"id": "agent:agent-6", "kind": "agent", "idValue": "agent-6"},
                    {"id": "docker:agent-6", "kind": "docker", "idValue": "agent-6"}]},
                {"id": "machine:agent-3", "hostname": "box-3", "status": "offline", "scopeAgentId": "agent-3", "surfaces": [
                    {"id": "agent:agent-3", "kind": "agent", "idValue": "agent-3"},
                    {"id": "docker:dock-3", "kind": "docker", "idValue": "dock-3"}]},
                {"id": "ignored:agent:agent-9", "hostname": "box-9", "status": "ignored", "surfaces": [
                    {"id": "agent:agent-9", "kind": "agent", "idValue": "agent-9"}]}]})
        self._send(404)

    def do_DELETE(self):
        u = urlparse(self.path)
        FakeHub.log.append(("DELETE", self.path, dict(self.headers), parse_qs(u.query)))
        if u.path.startswith("/api/agents/") and self.headers.get("X-CSRF-Token") != "csrf-123":
            return self._send(403, {"error": "CSRF token validation failed"})
        if FakeHub.fail_delete:
            return self._send(500, {"error": "boom"})
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

    def run_script(self, *args, creds=CREDS, port=None, expect=0):
        FakeHub.log.clear()
        FakeHub.universal = {"token": "universal-token-value", "active": False, "permanent": False}
        FakeHub.fail_delete = False
        url = f"http://127.0.0.1:{port or self.port}"
        env = {**os.environ, "BESZEL_URL": url, "PULSE_URL": url}
        r = subprocess.run([sys.executable, "-I", str(SCRIPT), *args], input=creds, capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(r.returncode, expect, r.stdout + r.stderr)
        for s in SECRETS:
            self.assertNotIn(s, r.stdout + r.stderr, f"{s!r} leaked")
        return r

    def deletes(self):
        return [p for m, p, _, _ in FakeHub.log if m == "DELETE"]

    def test_all_forgets_everything_live_and_makes_the_token_permanent_by_post(self):
        out = self.run_script("--all").stdout
        self.assertIn("beszel: forgot box-1 (192.0.2.11, down)", out)
        self.assertIn("beszel: forgot box-4 (192.0.2.14, up)", out)
        self.assertIn("pulse: forgot box-3 (agent-3…, dock-3…)", out)
        self.assertIn("pulse: forgot box-6 (agent-6…, agent-6…)", out)
        self.assertNotIn("box-9", out)                      # already removed ("ignored") entries are skipped
        self.assertIn("beszel: universal token active=True permanent=True", out)
        d = self.deletes()
        self.assertLess(d.index("/api/collections/fingerprints/records/fpA"), d.index("/api/collections/systems/records/sysA"))
        self.assertLess(d.index("/api/agents/docker/runtimes/dock-3?force=true"), d.index("/api/agents/agent/agent-3"))
        self.assertNotIn("/api/agents/agent/dock-3", d)      # ids go to the endpoint of their own kind
        self.assertNotIn("/api/agents/agent/agent-9", d)
        self.assertTrue(FakeHub.universal["permanent"])
        for m, path, _, _ in FakeHub.log:                    # the universal token never travels in a URL
            self.assertNotIn("universal-token-value", path)
        posts = [(path, body) for m, path, _, body in FakeHub.log if m == "POST" and path == "/api/beszel/universal-token"]
        self.assertEqual(posts, [("/api/beszel/universal-token", {"token": "universal-token-value", "enable": 1, "permanent": 1})])

    def test_hostnames_keep_the_others(self):
        out = self.run_script("box-4", "box-6").stdout
        self.assertIn("beszel: forgot box-4", out)
        self.assertNotIn("box-1", out)
        self.assertIn("pulse: forgot box-6", out)
        self.assertNotIn("box-3", out)
        d = self.deletes()
        self.assertNotIn("/api/collections/systems/records/sysA", d)
        self.assertNotIn("/api/agents/agent/agent-3", d)

    def test_unknown_hostnames_report_nothing_to_forget(self):
        out = self.run_script("box-7").stdout
        self.assertIn("beszel: nothing to forget", out)
        self.assertIn("pulse: nothing to forget", out)
        self.assertEqual(self.deletes(), [])

    def test_no_scope_is_refused(self):
        r = self.run_script(expect=1)
        self.assertIn("name the hosts", r.stderr)
        self.assertEqual(FakeHub.log, [])

    def test_dry_run_changes_nothing(self):
        out = self.run_script("--dry-run", "--pulse-token", "bench slot-1 box-3", "--all").stdout
        self.assertIn("beszel: would forget box-1", out)
        self.assertIn("pulse: would forget box-3", out)
        self.assertIn("pulse: would create agent token 'bench slot-1 box-3'", out)
        self.assertEqual(self.deletes(), [])
        self.assertFalse(FakeHub.universal["active"])
        self.assertIn("universal token active=False", out)
        self.assertNotIn("PULSE_TOKEN=", out)
        self.assertEqual([p for m, p, _, _ in FakeHub.log if p == "/api/security/tokens"], [])

    def test_pulse_token_is_created_with_agent_scopes_and_printed_last_only(self):
        r = self.run_script("--pulse-token", "bench slot-1 box-3", "box-3")
        lines = r.stdout.strip().splitlines()
        self.assertEqual(lines[-1], "PULSE_TOKEN=pulse-raw-token-value")
        self.assertEqual(r.stdout.count("pulse-raw-token-value"), 1)
        self.assertIn("pulse: created agent token 'bench slot-1 box-3'", r.stdout)
        create = [(h, b) for m, p, h, b in FakeHub.log if m == "POST" and p == "/api/security/tokens"]
        self.assertEqual(len(create), 1)
        self.assertEqual(create[0][1], {"name": "bench slot-1 box-3", "scopes": ["agent:report", "agent:config:read", "docker:report", "kubernetes:report"]})
        self.assertEqual({k.lower(): v for k, v in create[0][0].items()}.get("x-csrf-token"), "csrf-123")

    def test_blank_credentials_fail_unless_allowed(self):
        blank = "\n\n\n\n\n"
        r = self.run_script("--all", creds=blank, expect=1)
        self.assertIn("blank", r.stderr)
        r = self.run_script("--all", "--allow-skip", creds=blank)
        self.assertIn("beszel: no admin email, skipped", r.stdout)
        self.assertIn("pulse: no admin user, skipped", r.stdout)

    def test_short_stdin_is_blank_credentials(self):
        r = self.run_script("--all", creds="admin@example.test\n", expect=1)
        self.assertIn("auth failed", r.stderr)

    def test_wrong_password_fails(self):
        r = self.run_script("--all", creds=CREDS.replace("beszel-pw", "nope"), expect=1)
        self.assertIn("beszel: superuser auth failed (400)", r.stderr)

    def test_failed_delete_exits_nonzero(self):
        FakeHub.log.clear()
        FakeHub.universal = {"token": "universal-token-value", "active": False, "permanent": False}
        FakeHub.fail_delete = True
        url = f"http://127.0.0.1:{self.port}"
        r = subprocess.run([sys.executable, "-I", str(SCRIPT), "box-4"], input=CREDS, capture_output=True, text=True,
                           env={**os.environ, "BESZEL_URL": url, "PULSE_URL": url}, timeout=60)
        FakeHub.fail_delete = False
        self.assertEqual(r.returncode, 1)
        self.assertIn("beszel: deleting fingerprint of box-4", r.stderr)
        self.assertIn("(500)", r.stderr)

    def test_unreachable_hub_is_a_clean_error(self):
        s = HTTPServer(("127.0.0.1", 0), FakeHub); dead = s.server_address[1]; s.server_close()
        r = self.run_script("--all", port=dead, expect=1)
        self.assertIn("unreachable", r.stderr)
        self.assertNotIn("Traceback", r.stderr)


if __name__ == "__main__":
    unittest.main()
