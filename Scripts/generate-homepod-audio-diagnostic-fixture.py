#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Generate synthetic media only. Never reads or publishes user recordings.

The deliberately low-complexity 4K picture tests timestamps/packaging, not 38 Mbps
network load. Distinct, uninterrupted tones exercise all six AC-3 channels.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def run(*args):
    subprocess.run(args, check=True)


def generate(output):
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="vplayer-synthetic-ac3-") as directory:
        video = str(Path(directory) / "one-second-hlg.mp4")
        run("ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
            "color=c=gray:s=3840x2160:r=50:d=1,format=yuv420p10le",
            "-c:v", "libx265", "-preset", "ultrafast", "-x265-params",
            "keyint=50:min-keyint=50:scenecut=0:open-gop=0:repeat-headers=1:bframes=2:"
            "pools=2:frame-threads=2:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc",
            "-an", video)
        tones = "|".join(f"0.12*sin(2*PI*{frequency}*t)" for frequency in [997, 1511, 509, 60, 701, 809])
        run("ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-stream_loop", "63",
            "-itsoffset", "0.6512", "-i", video, "-f", "lavfi", "-i",
            f"aevalsrc={tones}:s=48000:d=64.6512:c=5.1(side)",
            "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", "-c:a", "ac3", "-b:a", "384k",
            "-ar", "48000", "-ac", "6", "-output_ts_offset", "74190", "-muxdelay", "0",
            "-muxpreload", "0", "-f", "mpegts", str(output))
    probe = json.loads(subprocess.check_output(["ffprobe", "-v", "error", "-show_streams",
        "-show_format", "-of", "json", str(output)]))
    video = next(stream for stream in probe["streams"] if stream["codec_type"] == "video")
    audio = next(stream for stream in probe["streams"] if stream["codec_type"] == "audio")
    assert (video["codec_name"], video["profile"], video["width"], video["height"], video["r_frame_rate"],
            video["color_transfer"]) == ("hevc", "Main 10", 3840, 2160, "50/1", "arib-std-b67")
    assert (audio["codec_name"], audio["sample_rate"], audio["channels"]) == ("ac3", "48000", 6)
    assert float(video["duration"]) >= 64
    print("SYNTHETIC_HOMEPOD_FIXTURE=" + json.dumps({"bytes": output.stat().st_size,
        "video_seconds": video["duration"], "audio_rate": audio["sample_rate"], "channels": 6,
        "source": "lavfi-generated color and tones; no user media"}, sort_keys=True))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path("Tests/Fixtures/Video/synthetic-hlg50-ac3-64s.ts"))
    generate(parser.parse_args().output)
