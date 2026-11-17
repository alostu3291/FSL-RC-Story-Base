"""
Opens the Verdant cards as pages in the presenter's browser, for chat apps that can't show cards inline.

A small web server on 127.0.0.1 serves the same card pages with a browser stand-in for the MCP Apps
client. Card actions (sign, upload a photo) come back to /api/<tool> and run on the MCP server's own
event loop, so they use the same Salesforce session. Every request needs the per-run token in the URL.
"""

import asyncio
import json
import logging
import secrets
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlparse

from mcp.server.mcpserver.exceptions import ToolError

from verdant_assistant import views

log = logging.getLogger("verdant.browser")
MAX_BODY = 25 * 1024 * 1024


class Pages:
    def __init__(self, actions: dict):
        self.actions = actions
        self.token = secrets.token_urlsafe(16)
        self.loop = None
        self.server = None
        self.results = {}

    def open(self, view: str, args: dict, result: dict | None = None) -> str:
        """Starts the page server on first use (from inside a tool call) and opens the page in the browser."""
        if self.server is None:
            self.loop = asyncio.get_running_loop()
            self.server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
            threading.Thread(target=self.server.serve_forever, daemon=True).start()
            log.info("Verdant pages at http://127.0.0.1:%s", self.server.server_port)
        query = {"t": self.token, "args": json.dumps(args)}
        if result is not None:
            query["r"] = secrets.token_hex(6)
            self.results[query["r"]] = result
        url = f"http://127.0.0.1:{self.server.server_port}/{view}?" + urlencode(query)
        webbrowser.open(url)
        return url

    def _run(self, name: str, args: dict):
        future = asyncio.run_coroutine_threadsafe(self.actions[name](**args), self.loop)
        return future.result(timeout=180)

    def _handler(self):
        pages = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format, *args):
                log.debug(format, *args)

            def _authorized(self, query) -> bool:
                if query.get("t", [""])[0] != pages.token:
                    self._send(403, "text/plain", b"This Verdant page has expired. Ask Claude to open it again.")
                    return False
                return True

            def _send(self, status: int, content_type: str, body: bytes):
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                url = urlparse(self.path)
                query = parse_qs(url.query)
                view = url.path.strip("/")
                if view not in views.CARDS or not self._authorized(query):
                    if view not in views.CARDS:
                        self._send(404, "text/plain", b"Not found")
                    return
                args = json.loads(query.get("args", ["{}"])[0])
                result = pages.results.get(query.get("r", [""])[0])
                html = views.browser_page(view, args, pages.token, result)
                self._send(200, "text/html; charset=utf-8", html.encode())

            def do_POST(self):
                url = urlparse(self.path)
                name = url.path.removeprefix("/api/")
                if name not in pages.actions:
                    self._send(404, "application/json", b'{"error": "Unknown action"}')
                    return
                if not self._authorized(parse_qs(url.query)):
                    return
                length = int(self.headers.get("Content-Length") or 0)
                if length > MAX_BODY:
                    self._send(413, "application/json", b'{"error": "That file is too large."}')
                    return
                try:
                    result = pages._run(name, json.loads(self.rfile.read(length) or b"{}"))
                    self._send(200, "application/json", json.dumps(result, default=str).encode())
                except ToolError as e:
                    self._send(400, "application/json", json.dumps({"error": str(e)}).encode())
                except Exception:
                    log.exception("Page action %s failed", name)
                    self._send(500, "application/json", json.dumps({"error": f"{name} failed; see the server log."}).encode())

        return Handler
