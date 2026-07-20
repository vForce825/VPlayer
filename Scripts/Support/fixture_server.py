#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

from __future__ import annotations

import argparse
from functools import partial
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from urllib.parse import unquote_to_bytes, urlsplit


class ReadOnlyFixtureRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def __init__(self, *args: object, fixture_root: Path, **kwargs: object) -> None:
        self.fixture_root = fixture_root
        super().__init__(*args, **kwargs)

    def do_GET(self) -> None:
        self._serve(include_body=True)

    def do_HEAD(self) -> None:
        self._serve(include_body=False)

    def do_POST(self) -> None:
        self._reject_mutation()

    def do_PUT(self) -> None:
        self._reject_mutation()

    def do_PATCH(self) -> None:
        self._reject_mutation()

    def do_DELETE(self) -> None:
        self._reject_mutation()

    def do_CONNECT(self) -> None:
        self._reject_mutation()

    def do_OPTIONS(self) -> None:
        self._reject_mutation()

    def do_TRACE(self) -> None:
        self._reject_mutation()

    def log_message(self, format: str, *args: object) -> None:
        del format, args

    def _reject_mutation(self) -> None:
        self._empty_response(405, {"Allow": "GET, HEAD"})

    def _serve(self, *, include_body: bool) -> None:
        try:
            target = self._resolve_target()
            data = target.read_bytes()
        except (UnicodeDecodeError, ValueError):
            self._empty_response(400)
            return
        except PermissionError:
            self._empty_response(403)
            return
        except (FileNotFoundError, IsADirectoryError, OSError):
            self._empty_response(404)
            return

        content_type = {
            ".m3u8": "application/vnd.apple.mpegurl",
            ".ts": "video/mp2t",
        }.get(target.suffix.lower(), "application/octet-stream")
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if include_body:
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

    def _resolve_target(self) -> Path:
        parsed = urlsplit(self.path)
        if parsed.query or parsed.fragment:
            raise ValueError("query and fragment are not fixture paths")
        decoded = unquote_to_bytes(parsed.path).decode("utf-8", errors="strict")
        if not decoded.startswith("/") or "\x00" in decoded or "\\" in decoded:
            raise ValueError("unsafe fixture path")
        components = decoded[1:].split("/")
        if not components or any(component in ("", ".", "..") for component in components):
            if components == [""]:
                raise FileNotFoundError(decoded)
            raise PermissionError(decoded)

        current = self.fixture_root
        for component in components:
            current = current / component
            if current.is_symlink():
                raise PermissionError(decoded)
        resolved = current.resolve(strict=True)
        try:
            resolved.relative_to(self.fixture_root)
        except ValueError as error:
            raise PermissionError(decoded) from error
        if not resolved.is_file():
            raise FileNotFoundError(decoded)
        return resolved

    def _empty_response(self, status_code: int, headers: dict[str, str] | None = None) -> None:
        self.send_response(status_code)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("Content-Length", "0")
        self.end_headers()


class FixtureHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False


def create_server(root: Path) -> FixtureHTTPServer:
    resolved = root.resolve(strict=True)
    if not resolved.is_dir():
        raise NotADirectoryError(resolved)
    handler = partial(ReadOnlyFixtureRequestHandler, fixture_root=resolved)
    return FixtureHTTPServer(("127.0.0.1", 0), handler)


def write_port_file(path: Path, port: int) -> tuple[int, int]:
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
        raise ValueError("port file must be an existing regular file")
    with path.open("r+", encoding="ascii") as stream:
        descriptor_metadata = os.fstat(stream.fileno())
        if (descriptor_metadata.st_dev, descriptor_metadata.st_ino) != (
            metadata.st_dev,
            metadata.st_ino,
        ):
            raise ValueError("port file changed before readiness")
        if stream.read() != "":
            raise ValueError("port file must be empty")
        stream.seek(0)
        stream.write(f"{port}\n")
        stream.truncate()
        stream.flush()
        os.fsync(stream.fileno())
    return metadata.st_dev, metadata.st_ino


def remove_exact_port_file(path: Path, identity: tuple[int, int], port: int) -> None:
    try:
        metadata = path.lstat()
        if (metadata.st_dev, metadata.st_ino) != identity or path.is_symlink():
            return
        if path.read_text(encoding="ascii") != f"{port}\n":
            return
        path.unlink()
    except FileNotFoundError:
        pass


def serve(root: Path, port_file: Path) -> int:
    server = create_server(root)
    port = int(server.server_address[1])
    port_identity: tuple[int, int] | None = None
    stopping = threading.Event()

    def stop(_signal_number: int, _frame: object) -> None:
        if stopping.is_set():
            return
        stopping.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    previous_sigterm = signal.signal(signal.SIGTERM, stop)
    try:
        port_identity = write_port_file(port_file, port)
        server.serve_forever(poll_interval=0.05)
        return 0
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm)
        server.server_close()
        if port_identity is not None:
            remove_exact_port_file(port_file, port_identity, port)


def main(arguments: list[str]) -> int:
    parser = argparse.ArgumentParser(description="read-only VPlayer fixture server")
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--port-file", required=True, type=Path)
    options = parser.parse_args(arguments)
    return serve(options.root, options.port_file)


class FixtureServerContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="vplayer-fixture-server-test.")
        self.root = Path(self.temporary.name) / "fixture root"
        self.root.mkdir()
        (self.root / "sample.ts").write_bytes(b"fixture-bytes")
        (self.root / "hls").mkdir()
        (self.root / "hls" / "master.m3u8").write_text(
            "#EXTM3U\n#EXT-X-ENDLIST\n",
            encoding="utf-8",
        )
        self.outside = Path(self.temporary.name) / "outside.txt"
        self.outside.write_text("secret", encoding="utf-8")
        (self.root / "escape.ts").symlink_to(self.outside)
        self.server = create_server(self.root)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.temporary.cleanup()

    def request(self, method: str, path: str) -> tuple[int, dict[str, str], bytes]:
        connection = http.client.HTTPConnection(
            self.server.server_address[0],
            self.server.server_address[1],
            timeout=5,
        )
        connection.request(method, path, body=b"mutation" if method == "POST" else None)
        response = connection.getresponse()
        body = response.read()
        headers = {name.lower(): value for name, value in response.getheaders()}
        connection.close()
        return response.status, headers, body

    def test_binds_only_loopback_on_an_ephemeral_port(self) -> None:
        self.assertEqual(self.server.server_address[0], "127.0.0.1")
        self.assertGreater(self.server.server_address[1], 0)

    def test_get_and_head_serve_only_regular_fixture_files(self) -> None:
        status, headers, body = self.request("GET", "/sample.ts")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"fixture-bytes")
        self.assertEqual(headers["content-length"], str(len(body)))
        self.assertEqual(headers["content-type"], "video/mp2t")

        status, headers, body = self.request("HEAD", "/sample.ts")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"")
        self.assertEqual(headers["content-length"], str(len(b"fixture-bytes")))

    def test_mutation_directory_traversal_and_symlink_escape_are_rejected(self) -> None:
        self.assertEqual(self.request("POST", "/sample.ts")[0], 405)
        self.assertEqual(self.request("GET", "/")[0], 404)
        for path in (
            "/../outside.txt",
            "/%2e%2e/outside.txt",
            "/hls/../../outside.txt",
            "/hls%2f..%2f..%2foutside.txt",
            "/escape.ts",
            "/hls\\..\\outside.txt",
        ):
            with self.subTest(path=path):
                self.assertIn(self.request("GET", path)[0], (400, 403, 404))

    def test_sigterm_stops_server_and_removes_its_exact_port_file(self) -> None:
        port_file = Path(self.temporary.name) / "server.port"
        port_file.touch(mode=0o600)
        process = subprocess.Popen(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "--root",
                str(self.root),
                "--port-file",
                str(port_file),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and not port_file.read_text().strip():
                if process.poll() is not None:
                    self.fail(f"server exited before readiness: {process.stderr.read()}")
                time.sleep(0.02)
            self.assertRegex(port_file.read_text(), r"^[1-9][0-9]*\n$")
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(timeout=5), 0)
            self.assertFalse(port_file.exists())
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)


def run_self_tests() -> int:
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(FixtureServerContractTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        raise SystemExit(run_self_tests())
    raise SystemExit(main(sys.argv[1:]))
