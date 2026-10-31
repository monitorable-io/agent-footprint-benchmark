#!/usr/bin/env python3
"""Runs on the sink before a slot: make the hubs forget the boxes about to be rebuilt, keep Beszel's
universal token permanent, and mint the slot's Pulse agent token.

Why: a rebuilt box comes back with a new Beszel fingerprint; Beszel's universal token is ephemeral (1 h)
unless enabled with permanent=1, and while a system record still holds the token a new fingerprint is
refused ("fingerprint mismatch"). Pulse binds an API token to one Docker host, so the next box's Docker
module is refused with 400 while the previous host exists — and removing the last host that uses a token
REVOKES that token (Pulse 6.6.0 monitor_agents.go), so every slot's Pulse box gets a token of its own.
All of it bit slot 1 (2026-10-31, docs/RUN-2026.md).

usage: reset-hubs.py [--dry-run] [--allow-skip] [--pulse-token NAME] (--all | HOSTNAME ...)
  HOSTNAME ...     forget only these hosts (a slot's boxes, or a one-box redo)
  --all            forget every system / agent (never while a slot is running)
  --pulse-token N  after forgetting, create a scoped Pulse agent token named N and print it as the LAST
                   stdout line, `PULSE_TOKEN=<value>` (the caller keeps that line out of its logs)
  --allow-skip     a hub with blank credentials is skipped instead of failing
stdin, five lines: BESZEL_ADMIN_EMAIL, BESZEL_ADMIN_PASSWORD, BESZEL_TOKEN, PULSE_ADMIN_USER,
  PULSE_ADMIN_PASSWORD. Nothing read from stdin is printed. Exit 1 on any failure.
env: BESZEL_URL (default http://127.0.0.1:8090), PULSE_URL (default http://127.0.0.1:7655).
"""
import http.cookiejar
import json
import os
import sys
import urllib.error
import urllib.request

PULSE_AGENT_SCOPES = ["agent:report", "agent:config:read", "docker:report", "kubernetes:report"]


class HubError(SystemExit):
    def __init__(self, msg):
        super().__init__(f"reset-hubs: {msg}")


def _call(opener, method, url, data=None, headers=None):
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body, method=method, headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with opener.open(req, timeout=20) as resp:
            raw = resp.read()
            try:
                return resp.status, (json.loads(raw) if raw.strip() else {})
            except ValueError:
                return resp.status, {"raw": raw[:200].decode(errors="replace")}
    except urllib.error.HTTPError as ex:
        raw = ex.read()
        try:
            return ex.code, json.loads(raw)
        except ValueError:
            return ex.code, {"error": raw[:200].decode(errors="replace")}
    except urllib.error.URLError as ex:
        raise HubError(f"{url.split('/api/')[0]} unreachable ({ex.reason})")


def beszel(base, email, password, token, only, dry_run, allow_skip, out):
    if not email:
        if allow_skip:
            out("beszel: no admin email, skipped")
            return
        raise HubError("beszel: BESZEL_ADMIN_EMAIL / BESZEL_ADMIN_PASSWORD are blank")
    opener = urllib.request.build_opener()
    status, auth = _call(opener, "POST", f"{base}/api/collections/_superusers/auth-with-password", {"identity": email, "password": password})
    if status != 200:
        raise HubError(f"beszel: superuser auth failed ({status})")
    su = {"Authorization": auth["token"]}
    status, systems = _call(opener, "GET", f"{base}/api/collections/systems/records?perPage=200", headers=su)
    if status != 200:
        raise HubError(f"beszel: listing systems failed ({status})")
    status, prints = _call(opener, "GET", f"{base}/api/collections/fingerprints/records?perPage=200", headers=su)
    if status != 200:
        raise HubError(f"beszel: listing fingerprints failed ({status})")
    by_system = {}
    for fp in prints.get("items", []):
        by_system.setdefault(fp.get("system"), []).append(fp["id"])
    chosen = [s for s in systems.get("items", []) if only is None or s.get("name") in only]
    if not chosen:
        out("beszel: nothing to forget")
    for s in chosen:
        label = f"{s.get('name')} ({s.get('host')}, {s.get('status')})"
        if dry_run:
            out(f"beszel: would forget {label}")
            continue
        for fid in by_system.get(s["id"], []):   # fingerprints first: they reference the system
            status, _ = _call(opener, "DELETE", f"{base}/api/collections/fingerprints/records/{fid}", headers=su)
            if status not in (200, 204, 404):
                raise HubError(f"beszel: deleting fingerprint of {label} failed ({status})")
        status, _ = _call(opener, "DELETE", f"{base}/api/collections/systems/records/{s['id']}", headers=su)
        if status not in (200, 204, 404):
            raise HubError(f"beszel: forgetting {label} failed ({status})")
        out(f"beszel: forgot {label}")
    if token:
        # The hub's user endpoint (superusers get 403); POST keeps the token out of the URL and the
        # request log; permanent=1 survives the 1-hour TTL of the UI toggle.
        status, auth = _call(opener, "POST", f"{base}/api/collections/users/auth-with-password", {"identity": email, "password": password})
        if status != 200:
            raise HubError(f"beszel: user auth failed ({status})")
        body = {"token": token} if dry_run else {"token": token, "enable": 1, "permanent": 1}
        status, state = _call(opener, "POST", f"{base}/api/beszel/universal-token", body, headers={"Authorization": auth["token"]})
        if status != 200:
            raise HubError(f"beszel: universal token call failed ({status})")
        out(f"beszel: universal token active={state.get('active')} permanent={state.get('permanent')}")
        if not dry_run and not (state.get("active") and state.get("permanent")):
            raise HubError("beszel: universal token is not active+permanent after enabling it")


def pulse_agents(state):
    """(hostname, agent ids, docker runtime ids) per machine still in Pulse's state; removed ('ignored')
    entries are skipped. Ids come from each surface's own idValue, by kind."""
    machines = []
    for item in state.get("connectedInfrastructure", []) or []:
        if str(item.get("status", "")).lower() == "ignored" or str(item.get("id", "")).startswith("ignored:"):
            continue
        host = item.get("hostname") or item.get("name") or "?"
        agents, dockers = [], []
        for surf in item.get("surfaces", []) or []:
            sid = surf.get("idValue") or surf.get("controlId")
            if not sid:
                continue
            (agents if surf.get("kind") == "agent" else dockers if surf.get("kind") == "docker" else []).append(sid)
        if not agents and item.get("scopeAgentId"):
            agents.append(item["scopeAgentId"])
        if agents or dockers:
            machines.append((host, agents, dockers))
    return machines


def pulse(base, user, password, only, dry_run, allow_skip, token_name, out):
    if not user:
        if allow_skip:
            out("pulse: no admin user, skipped")
            return None
        raise HubError("pulse: PULSE_ADMIN_USER / PULSE_ADMIN_PASSWORD are blank")
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    status, _ = _call(opener, "POST", f"{base}/api/login", {"username": user, "password": password})
    if status != 200:
        raise HubError(f"pulse: login failed ({status})")
    csrf = next((c.value for c in jar if "csrf" in c.name.lower()), "")
    hdr = {"X-CSRF-Token": csrf}
    status, state = _call(opener, "GET", f"{base}/api/state")
    if status != 200:
        raise HubError(f"pulse: reading state failed ({status})")
    chosen = [m for m in pulse_agents(state) if only is None or m[0] in only]
    if not chosen:
        out("pulse: nothing to forget")
    for host, agents, dockers in sorted(chosen):
        ids = ", ".join(i[:8] + "…" for i in agents + dockers)
        if dry_run:
            out(f"pulse: would forget {host} ({ids})")
            continue
        for did in dockers:   # the Docker runtime first: its token binding is what blocks the next box
            status, body = _call(opener, "DELETE", f"{base}/api/agents/docker/runtimes/{did}?force=true", headers=hdr)
            if status != 200 or body.get("success") is False:
                raise HubError(f"pulse: removing the Docker runtime of {host} failed ({status})")
        for aid in agents:
            status, body = _call(opener, "DELETE", f"{base}/api/agents/agent/{aid}", headers=hdr)
            if status != 200 or body.get("success") is False:
                raise HubError(f"pulse: removing the agent of {host} failed ({status})")
        out(f"pulse: forgot {host} ({ids})")
    if not token_name:
        return None
    if dry_run:
        out(f"pulse: would create agent token {token_name!r} with scopes {' '.join(PULSE_AGENT_SCOPES)}")
        return None
    status, body = _call(opener, "POST", f"{base}/api/security/tokens", {"name": token_name, "scopes": PULSE_AGENT_SCOPES}, headers=hdr)
    raw = body.get("token") if status == 200 else None
    if not raw:
        raise HubError(f"pulse: creating agent token {token_name!r} failed ({status})")
    out(f"pulse: created agent token {token_name!r}")
    return raw


def main(argv):
    dry_run = "--dry-run" in argv
    allow_skip = "--allow-skip" in argv
    token_name = argv[argv.index("--pulse-token") + 1] if "--pulse-token" in argv else ""
    rest = [a for i, a in enumerate(argv) if not a.startswith("--") and not (i > 0 and argv[i - 1] == "--pulse-token")]
    if "--all" in argv:
        only = None
    elif rest:
        only = set(rest)
    else:
        raise HubError("name the hosts to forget, or --all (usage in the file header)")
    lines = [sys.stdin.readline().rstrip("\n") for _ in range(5)]
    b_email, b_pass, b_token, p_user, p_pass = lines

    def out(msg):
        print(msg, flush=True)

    beszel(os.environ.get("BESZEL_URL", "http://127.0.0.1:8090"), b_email, b_pass, b_token, only, dry_run, allow_skip, out)
    raw = pulse(os.environ.get("PULSE_URL", "http://127.0.0.1:7655"), p_user, p_pass, only, dry_run, allow_skip, token_name, out)
    if raw:
        print(f"PULSE_TOKEN={raw}", flush=True)


if __name__ == "__main__":
    main(sys.argv[1:])
