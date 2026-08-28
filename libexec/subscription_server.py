#!/usr/bin/env python3
"""Loopback-only, token-gated static profile server for sb-manager."""

import argparse
import hashlib
import json
import os
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{32,128}$")


class Handler(BaseHTTPRequestHandler):
    root: Path

    def log_message(self, fmt: str, *args: object) -> None:
        # Never log request paths because they contain bearer tokens.
        print(f"subscription request from {self.client_address[0]}: {args[1]}")

    def do_HEAD(self) -> None:
        self._serve(False)

    def do_GET(self) -> None:
        self._serve(True)

    def _serve(self, include_body: bool) -> None:
        prefix = "/sub/"
        if not self.path.startswith(prefix):
            self.send_error(404)
            return
        token = self.path[len(prefix) :].split("?", 1)[0]
        if not TOKEN_RE.fullmatch(token):
            self.send_error(404)
            return
        digest = hashlib.sha256(token.encode()).hexdigest()
        meta_path = self.root / f"{digest}.meta.json"
        profile_path = self.root / f"{digest}.profile.json"
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            if int(meta["expires_at_epoch"]) <= int(time.time()):
                self.send_error(410, "Subscription expired")
                return
            data = profile_path.read_bytes()
        except (OSError, ValueError, KeyError, json.JSONDecodeError):
            self.send_error(404)
            return
        if len(data) > 10 * 1024 * 1024:
            self.send_error(500)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if include_body:
            self.wfile.write(data)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", required=True, type=int)
    args = parser.parse_args()
    if args.listen not in {"127.0.0.1", "::1"}:
        raise SystemExit("subscription server may only bind loopback")
    Handler.root = Path(args.root).resolve(strict=True)
    server = ThreadingHTTPServer((args.listen, args.port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
