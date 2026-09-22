#!/usr/bin/env python3
"""Loopback-only profile server; live generations are published by the manager."""

import argparse
import hashlib
import json
import re
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{32,128}$")


class Handler(BaseHTTPRequestHandler):
    root: Path
    # Bound request line/header processing and idle keep-alive sockets.
    timeout = 10

    def log_message(self, fmt: str, *args: object) -> None:
        # Never log request paths because they contain bearer tokens.
        print(f"subscription request from {self.client_address[0]}: {args[1]}")

    def do_HEAD(self) -> None:
        self._serve(False)

    def do_GET(self) -> None:
        self._serve(True)

    def _serve(self, include_body: bool) -> None:
        if len(self.path) > 512:
            self.send_error(414)
            return
        request_url = urlsplit(self.path)
        prefix = "/sub/"
        if not request_url.path.startswith(prefix):
            self.send_error(404)
            return
        token = request_url.path[len(prefix) :]
        if not TOKEN_RE.fullmatch(token):
            self.send_error(404)
            return
        formats = parse_qs(request_url.query).get("format", ["sing-box"])
        if len(formats) != 1 or formats[0] not in {"sing-box", "substore"}:
            self.send_error(400, "Unsupported subscription format")
            return
        output_format = formats[0]
        digest = hashlib.sha256(token.encode()).hexdigest()
        meta_path = self.root / f"{digest}.meta.json"
        if output_format == "substore":
            profile_path = self.root / f"{digest}.substore.txt"
            content_type = "text/plain; charset=utf-8"
        else:
            profile_path = self.root / f"{digest}.profile.json"
            content_type = "application/json; charset=utf-8"
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            live = meta.get("live") is True
            expires = meta["expires_at_epoch"]
            if expires is None and not live:
                raise ValueError("only live subscriptions may have no expiry")
            if expires is not None and int(expires) <= int(time.time()):
                self.send_error(410, "Subscription expired")
                return
            if live:
                bundle = json.loads((self.root / "live.json").read_text(encoding="utf-8"))
                if output_format == "substore":
                    data = bundle["substore"].encode("utf-8")
                else:
                    mode = meta["mode"]
                    if mode not in {"mixed", "tun"} or not isinstance(bundle["profiles"][mode], dict):
                        raise ValueError("missing live profile")
                    data = json.dumps(bundle["profiles"][mode], ensure_ascii=False).encode("utf-8")
            else:
                data = profile_path.read_bytes()
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            self.send_error(404)
            return
        if len(data) > 10 * 1024 * 1024:
            self.send_error(500)
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if include_body:
            self.wfile.write(data)


class LimitedThreadingHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 32

    def __init__(self, *args: object, max_workers: int = 32, **kwargs: object) -> None:
        super().__init__(*args, **kwargs)
        self._slots = threading.BoundedSemaphore(max_workers)

    def process_request(self, request: socket.socket, client_address: object) -> None:
        if not self._slots.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self._slots.release()
            raise

    def process_request_thread(self, request: socket.socket, client_address: object) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._slots.release()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--listen", default="127.0.0.1")
    parser.add_argument("--port", required=True, type=int)
    args = parser.parse_args()
    if args.listen not in {"127.0.0.1", "::1"}:
        raise SystemExit("subscription server may only bind loopback")
    Handler.root = Path(args.root).resolve(strict=True)
    server = LimitedThreadingHTTPServer((args.listen, args.port), Handler)
    server.timeout = 10
    server.serve_forever()


if __name__ == "__main__":
    main()
