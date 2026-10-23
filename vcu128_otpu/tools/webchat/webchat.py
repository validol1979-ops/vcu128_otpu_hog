#!/usr/bin/env python3
"""A chat page for the local network in front of the board's API server (serve_board.sh).

GET / serves index.html; POST /api/chat forwards an OpenAI-style chat request to the API server
(API, default http://127.0.0.1:8000/v1) with its key (OTPU_API_KEY, or ~/.otpu_api_key) added here,
so visitors need no key, and streams the answer back (server-sent events) as it is generated;
GET /api/models lists the served model; GET /api/status[?id=] the requests in flight here (generating,
waiting) and a request's place in the queue (the API server runs them one at a time: --max-running 1).
Standard library only.

    vcu128_otpu/tools/webchat/webchat.py [--host 0.0.0.0] [--port 8001] [--api http://127.0.0.1:8000/v1]
"""
import argparse
import http.server
import json
import os
import pathlib
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

HERE = pathlib.Path(__file__).resolve().parent
MAX_BODY = 1 << 20
ACTIVE = {}                 # request id -> {"t0": start, "gen": first token seen}, in arrival order
LOCK = threading.Lock()


def status(rid: str | None) -> dict:
    with LOCK:
        items = list(ACTIVE.items())
    gen = sum(1 for _, v in items if v["gen"])
    out = {"active": len(items), "generating": gen, "waiting": len(items) - gen}
    if rid is not None:
        ids = [k for k, _ in items]
        if rid in ids:
            me = ACTIVE.get(rid, {})
            out.update(known=True, ahead=ids.index(rid), generating_me=bool(me.get("gen")),
                       waited=round(time.time() - me.get("t0", time.time()), 1))
        else:
            out["known"] = False
    return out


def api_key() -> str:
    k = os.environ.get("OTPU_API_KEY")
    if not k:
        p = pathlib.Path.home() / ".otpu_api_key"
        k = p.read_text().strip() if p.exists() else ""
    return k


class Handler(http.server.BaseHTTPRequestHandler):
    api = "http://127.0.0.1:8000/v1"
    key = ""
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print(f"{self.client_address[0]} {fmt % args}", flush=True)

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _upstream(self, path: str, data: bytes | None = None):
        req = urllib.request.Request(self.api + path, data=data, method="POST" if data else "GET")
        req.add_header("Authorization", f"Bearer {self.key}")
        if data:
            req.add_header("Content-Type", "application/json")
        return urllib.request.urlopen(req, timeout=600)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            return self._send(200, (HERE / "index.html").read_bytes(), "text/html; charset=utf-8")
        if path == "/api/status":
            q = urllib.parse.parse_qs(self.path.partition("?")[2])
            return self._send(200, json.dumps(status((q.get("id") or [None])[0])).encode(),
                              "application/json")
        if path == "/api/info":             # the model, the card and its configuration (no paths)
            try:
                with self._upstream("/stats") as r:          # (/v1/stats = /get_server_info)
                    d = json.loads(r.read())
            except (urllib.error.URLError, OSError, ValueError) as e:
                return self._send(502, json.dumps({"error": str(e)}).encode(), "application/json")
            keep = ("model", "weights", "cap", "backend", "config", "device", "throughput", "uptime_s",
                    "requests", "finished", "generated", "prompt_tokens", "running", "waiting")
            return self._send(200, json.dumps({k: d[k] for k in keep if k in d}).encode(),
                              "application/json")
        if path == "/api/models":
            try:
                with self._upstream("/models") as r:
                    return self._send(200, r.read(), "application/json")
            except (urllib.error.URLError, OSError) as e:
                return self._send(502, json.dumps({"error": str(e)}).encode(), "application/json")
        self._send(404, b"not found", "text/plain")

    def do_POST(self):
        if self.path.split("?")[0] != "/api/chat":
            return self._send(404, b"not found", "text/plain")
        n = int(self.headers.get("Content-Length") or 0)
        if not 0 < n <= MAX_BODY:
            return self._send(413, b"bad request size", "text/plain")
        try:
            body = json.loads(self.rfile.read(n))
            req = {"model": body.get("model", ""), "messages": body["messages"], "stream": True,
                   "temperature": float(body.get("temperature", 0.7)),
                   "max_tokens": int(body.get("max_tokens", 4096)),
                   "stream_options": {"include_usage": True}}
        except (ValueError, KeyError, TypeError) as e:
            return self._send(400, json.dumps({"error": f"bad request: {e}"}).encode(), "application/json")
        rid = uuid.uuid4().hex[:12]
        with LOCK:
            ACTIVE[rid] = {"t0": time.time(), "gen": False}
        try:
            # the visitor gets its id (and the stream's headers) at once, before the API answers, to
            # poll /api/status while the request waits for its turn
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Req-Id", rid)
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True
            self.wfile.write(f"data: {json.dumps({'otpu_req': rid})}\n\n".encode())
            self.wfile.flush()
            try:
                up = self._upstream("/chat/completions", json.dumps(req).encode())
            except urllib.error.HTTPError as e:
                err = (e.read() or b"").decode(errors="replace")[:300]
                self.wfile.write(f"data: {json.dumps({'otpu_error': f'HTTP {e.code}: {err}'})}\n\n".encode())
                return
            except (urllib.error.URLError, OSError) as e:
                self.wfile.write(f"data: {json.dumps({'otpu_error': f'API server: {e}'})}\n\n".encode())
                return
            with up:
                for line in up:                      # SSE lines, passed through as they arrive
                    if b'"content":"' in line and not ACTIVE[rid]["gen"] and b'"content":""' not in line:
                        ACTIVE[rid]["gen"] = True
                    self.wfile.write(line)
                    if line in (b"\n", b"\r\n"):
                        self.wfile.flush()
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass                                     # the visitor closed the page
        finally:
            with LOCK:
                ACTIVE.pop(rid, None)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8001)
    ap.add_argument("--api", default="http://127.0.0.1:8000/v1")
    a = ap.parse_args()
    Handler.api, Handler.key = a.api.rstrip("/"), api_key()
    if not Handler.key:
        raise SystemExit("no API key: OTPU_API_KEY or ~/.otpu_api_key")
    srv = http.server.ThreadingHTTPServer((a.host, a.port), Handler)
    print(f"chat page on http://{a.host}:{a.port}/ -> {Handler.api}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
