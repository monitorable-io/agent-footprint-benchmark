#!/usr/bin/env python3
"""Runs on the sink before a slot: forget the hub records of the boxes about to be rebuilt, and keep
Beszel's universal token permanent.

Why: a rebuilt box comes back with a new Beszel fingerprint, and the hub refuses it while the old
system record holds the same token ("fingerprint mismatch"); Pulse binds an API token to one Docker
host, so the next box's Docker module is refused with 400 while the previous host still exists; and
Beszel's universal token is ephemeral (1 h) unless enabled with permanent=1. All three bit slot 1
(2026-10-31, docs/RUN-2026.md).

usage: reset-hubs.py [--dry-run] [HOSTNAME ...]
  no HOSTNAME: forget every system / agent (a full slot start); otherwise only those (a one-box redo).
stdin, five lines: BESZEL_ADMIN_EMAIL, BESZEL_ADMIN_PASSWORD, BESZEL_TOKEN, PULSE_ADMIN_USER,
  PULSE_ADMIN_PASSWORD (an empty email or user skips that hub). Nothing from stdin is printed.
env: BESZEL_URL (default http://127.0.0.1:8090), PULSE_URL (default http://127.0.0.1:7655).
"""
import http.cookiejar
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


def _call(opener, method, url, data=None, headers=None):
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, method=method, headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with opener.open(req, timeout=20) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw.strip() else {})
    except urllib.error.HTTPError as ex:
        raw = ex.read()
        try:
            return ex.code, json.loads(raw)
        except ValueError:
            return ex.code, {"error": raw[:200].decode(errors="replace")}


def beszel(base, email, password, token, only, dry_run, out):
    if not email:
        out("beszel: no admin email, skipped")
        return
    opener = urllib.request.build_opener()
    status, auth = _call(opener, "POST", f"{base}/api/collections/_superusers/auth-with-password", {"identity": email, "password": password})
    if status != 200:
        raise SystemExit(f"beszel: superuser auth failed ({status})")
    su = {"Authorization": auth["token"]}
    status, systems = _call(opener, "GET", f"{base}/api/collections/systems/records?perPage=200", headers=su)
    if status != 200:
        raise SystemExit(f"beszel: listing systems failed ({status})")
    status, prints = _call(opener, "GET", f"{base}/api/collections/fingerprints/records?perPage=200", headers=su)
    if status != 200:
        raise SystemExit(f"beszel: listing fingerprints failed ({status})")
    by_system = {}
    for fp in prints.get("items", []):
        by_system.setdefault(fp.get("system"), []).append(fp["id"])
    for s in systems.get("items", []):
        if only and s.get("name") not in only:
            continue
        label = f"{s.get('name')} ({s.get('host')}, {s.get('status')})"
        if dry_run:
            out(f"beszel: would forget {label}")
            continue
        for fid in by_system.get(s["id"], []):
            _call(opener, "DELETE", f"{base}/api/collections/fingerprints/records/{fid}", headers=su)
        status, _ = _call(opener, "DELETE", f"{base}/api/collections/systems/records/{s['id']}", headers=su)
        out(f"beszel: forgot {label}" if status in (200, 204) else f"beszel: could not forget {label} ({status})")
    # The universal token: the hub's user (not superuser) endpoint; permanent=1 survives the 1-hour TTL.
    if token:
        status, auth = _call(opener, "POST", f"{base}/api/collections/users/auth-with-password", {"identity": email, "password": password})
        if status != 200:
            raise SystemExit(f"beszel: user auth failed ({status})")
        q = urllib.parse.urlencode({"token": token, "enable": "1", "permanent": "1"})
        if dry_run:
            status, state = _call(opener, "GET", f"{base}/api/beszel/universal-token?" + urllib.parse.urlencode({"token": token}), headers={"Authorization": auth["token"]})
        else:
            status, state = _call(opener, "GET", f"{base}/api/beszel/universal-token?{q}", headers={"Authorization": auth["token"]})
        if status != 200:
            raise SystemExit(f"beszel: universal token call failed ({status})")
        out(f"beszel: universal token active={state.get('active')} permanent={state.get('permanent')}")


def pulse(base, user, password, only, dry_run, out):
    if not user:
        out("pulse: no admin user, skipped")
        return
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    status, _ = _call(opener, "POST", f"{base}/api/login", {"username": user, "password": password})
    if status != 200:
        raise SystemExit(f"pulse: login failed ({status})")
    csrf = next((c.value for c in jar if "csrf" in c.name.lower()), "")
    hdr = {"X-CSRF-Token": csrf}
    status, state = _call(opener, "GET", f"{base}/api/state")
    if status != 200:
        raise SystemExit(f"pulse: reading state failed ({status})")
    agents = {}  # agent id -> hostname
    for item in state.get("connectedInfrastructure", []) or []:
        for key in ("scopeAgentId", "uninstallAgentId"):
            if item.get(key):
                agents[item[key]] = item.get("hostname") or item.get("name") or "?"
    for alert in state.get("activeAlerts", []) or []:
        rid = str(alert.get("resourceId", ""))
        if rid.startswith(("agent:", "docker:")):
            agents.setdefault(rid.split(":", 1)[1], alert.get("resourceName") or "?")
        meta = alert.get("metadata") or {}
        for key in ("agentId", "hostId"):
            if meta.get(key):
                agents.setdefault(meta[key], meta.get("hostname") or alert.get("resourceName") or "?")
    for aid, host in sorted(agents.items(), key=lambda kv: kv[1]):
        if only and host not in only:
            continue
        if dry_run:
            out(f"pulse: would forget {host} ({aid[:8]}…)")
            continue
        s1, _ = _call(opener, "DELETE", f"{base}/api/agents/docker/runtimes/{aid}?force=true", headers=hdr)
        s2, _ = _call(opener, "DELETE", f"{base}/api/agents/agent/{aid}", headers=hdr)
        ok = s1 in (200, 404) and s2 in (200, 404)
        out(f"pulse: forgot {host} ({aid[:8]}…)" if ok else f"pulse: could not forget {host} (docker {s1}, agent {s2})")


def main(argv):
    dry_run = "--dry-run" in argv
    only = {a for a in argv if not a.startswith("--")}
    lines = [sys.stdin.readline().rstrip("\n") for _ in range(5)]
    b_email, b_pass, b_token, p_user, p_pass = lines
    out = lambda msg: print(msg, flush=True)  # noqa: E731
    beszel(os.environ.get("BESZEL_URL", "http://127.0.0.1:8090"), b_email, b_pass, b_token, only, dry_run, out)
    pulse(os.environ.get("PULSE_URL", "http://127.0.0.1:7655"), p_user, p_pass, only, dry_run, out)


if __name__ == "__main__":
    main(sys.argv[1:])
