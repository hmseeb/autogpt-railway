#!/usr/bin/env python3
"""End-to-end check against a live deploy of the template.

    ANTHROPIC_API_KEY=... python3 -I test/e2e.py https://<frontend> https://<backend>

1. sign-up + sign-in through Better Auth on the frontend, JWT minted
2. the backend accepts that JWT (JWKS over the public domain)
3. an agent built from blocks runs: input -> AI Text Generator (Anthropic,
   cheapest model, the user's own key stored as a credential) -> output
4. the copilot chat answers through the server-level ANTHROPIC_API_KEY

The key is read from the environment and only ever sent to the deploy.
"""
import http.cookiejar
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.request

FE, BE = sys.argv[1].rstrip("/"), sys.argv[2].rstrip("/")
MODEL = os.environ.get("E2E_MODEL", "claude-haiku-5-5")
KEY = os.environ.get("ANTHROPIC_API_KEY", "")
jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
failed = []


def req(method, url, body=None, headers=None, raw=False, timeout=60):
    h = {"content-type": "application/json", "Origin": FE, **(headers or {})}
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with opener.open(r, timeout=timeout) as resp:
            text = resp.read().decode()
            return resp.status, (text if raw else (json.loads(text) if text else None))
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:500]


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}: {name}{(' - ' + str(detail)[:300]) if detail else ''}")
    if not ok:
        failed.append(name)
    return ok


email = f"e2e-{secrets.token_hex(4)}@example.com"
pw = "E2e-" + secrets.token_urlsafe(12) + "a1"
s, b = req("POST", f"{FE}/api/auth/sign-up/email", {"email": email, "password": pw, "name": "E2E"})
check("sign-up", s == 200, s if s != 200 else "")
s, b = req("POST", f"{FE}/api/auth/sign-in/email", {"email": email, "password": pw})
check("sign-in", s == 200, s if s != 200 else "")
s, b = req("GET", f"{FE}/api/auth/token")
jwt = b.get("token") if s == 200 and isinstance(b, dict) else None
if not check("JWT minted", bool(jwt), s):
    sys.exit(1)
A = {"Authorization": f"Bearer {jwt}"}
s, b = req("GET", f"{BE}/api/credits", headers=A)
check("backend accepts the JWT", s == 200, b)

if not KEY:
    print("SKIP: ANTHROPIC_API_KEY not set, no agent run and no chat")
    sys.exit(1 if failed else 0)

# --- agent run from blocks, on the user's own credential ---
s, cred = req("POST", f"{BE}/api/integrations/anthropic/credentials", headers=A,
              body={"type": "api_key", "provider": "anthropic", "title": "e2e", "api_key": KEY})
check("store anthropic credential", s in (200, 201), s)
blocks = {x["name"]: x["id"] for x in req("GET", f"{BE}/api/blocks", headers=A)[1]}
ids = {k: secrets.token_hex(16) for k in ("in", "ai", "out")}
nodes = [
    {"id": ids["in"], "block_id": blocks["AgentInputBlock"], "input_default": {"name": "question"}},
    {"id": ids["ai"], "block_id": blocks["AITextGeneratorBlock"], "input_default": {
        "model": MODEL, "max_tokens": 50, "sys_prompt": "Answer with only the number.",
        "credentials": {"id": cred["id"], "provider": "anthropic", "type": "api_key", "title": "e2e"}}},
    {"id": ids["out"], "block_id": blocks["AgentOutputBlock"], "input_default": {"name": "answer"}},
]
links = [
    {"source_id": ids["in"], "sink_id": ids["ai"], "source_name": "result", "sink_name": "prompt"},
    {"source_id": ids["ai"], "sink_id": ids["out"], "source_name": "response", "sink_name": "value"},
]
s, g = req("POST", f"{BE}/api/graphs", headers=A, body={"graph": {
    "name": "e2e adder", "description": "e2e", "nodes": nodes, "links": links}})
check("create agent", s == 200, s if s != 200 else "")
s, ex = req("POST", f"{BE}/api/graphs/{g['id']}/execute/{g['version']}", headers=A,
            body={"inputs": {"question": "What is 17+25?"}, "credentials_inputs": {}})
check("start run", s == 200, ex)
exec_id = ex.get("id") or ex.get("graph_exec_id")
st, res = None, None
for _ in range(60):
    time.sleep(3)
    s, res = req("GET", f"{BE}/api/graphs/{g['id']}/executions/{exec_id}", headers=A)
    st = res.get("status") if isinstance(res, dict) else None
    if st in ("COMPLETED", "FAILED", "TERMINATED", "INCOMPLETE"):
        break
out = json.dumps((res or {}).get("outputs", {}))
check(f"agent run {st}, output has 42", st == "COMPLETED" and "42" in out, out if st == "COMPLETED" else res)

# --- copilot chat on the server-level key ---
s, sess = req("POST", f"{BE}/api/chat/sessions", headers=A, body=None)
sid = sess.get("id") if isinstance(sess, dict) else None
check("chat session", bool(sid), sess)
if sid:
    s, text = req("POST", f"{BE}/api/chat/sessions/{sid}/stream", headers=A, raw=True, timeout=180,
                  body={"message": "What is 17+25? Reply with only the number, no tools."})
    deltas = []
    for line in (text or "").splitlines():
        if line.startswith("data:"):
            try:
                ev = json.loads(line[5:])
            except ValueError:
                continue
            if isinstance(ev, dict) and isinstance(ev.get("delta"), str):
                deltas.append(ev["delta"])
            elif isinstance(ev, dict) and ev.get("type") == "error":
                deltas.append("ERROR " + json.dumps(ev))
    reply = "".join(deltas)
    check("chat reply has 42", s == 200 and "42" in reply, reply or (s, (text or "")[:300]))

print("ALL E2E PASS" if not failed else f"E2E FAILED: {failed}")
sys.exit(1 if failed else 0)
