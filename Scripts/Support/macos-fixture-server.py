#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""向 Mac 播放验收提供真实媒体；连续 TS 按直播速率发送，HLS 保留分段突发。"""

from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import time


class LiveFixtureHandler(SimpleHTTPRequestHandler):
    def translate_path(self, path):
        name = path.split("?", 1)[0].lstrip("/")
        if name in {"macos-progressive-h264-aac-live.ts", "macos-interlaced-h264-mp2-live.ts"}:
            return str(Path(__file__).resolve().parents[2] / "build/macos-test-fixtures" / name)
        return super().translate_path(path)

    def copyfile(self, source, outputfile):
        size = Path(self.translate_path(self.path)).stat().st_size
        name = self.path.split("?", 1)[0]
        duration = 60 if name.endswith("-live.ts") else (16 if name.endswith("-16s.ts") else None)
        bytes_per_second = size / duration if duration else None
        started = time.monotonic()
        sent = 0
        try:
            while True:
                chunk = source.read(188 * 128)
                if not chunk:
                    return
                outputfile.write(chunk)
                outputfile.flush()
                sent += len(chunk)
                if bytes_per_second:
                    remaining = sent / bytes_per_second - (time.monotonic() - started)
                    if remaining > 0:
                        time.sleep(remaining)
        except (BrokenPipeError, ConnectionResetError):
            return


if __name__ == "__main__":
    root = Path(__file__).resolve().parents[2] / "Tests/VPlayerTests/Fixtures/Media"
    server = ThreadingHTTPServer(("127.0.0.1", 18765), partial(LiveFixtureHandler, directory=str(root)))
    server.daemon_threads = True
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
