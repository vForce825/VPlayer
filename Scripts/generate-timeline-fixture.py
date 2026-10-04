#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Generate/verify synthetic 3840x2160, 25fps H.264/AAC TS lasting 900 seconds.

Only two seconds of solid-color video are encoded; stream copying repeats those
real frames with continuous timestamps while audio is synthesized for all 900
seconds. This covers long timeline/remux behavior, not picture-content diversity.
No source media is downloaded. Output and intermediate files are job-local.
"""
import argparse
from fractions import Fraction
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

MAX_BYTES = 128 * 1024 * 1024
GENERATION_SECONDS = 300
FFMPEG = os.environ.get("FFMPEG", "ffmpeg")
FFPROBE = os.environ.get("FFPROBE", "ffprobe")


def run(command, deadline, phase_limit):
    remaining = min(phase_limit, deadline - time.monotonic())
    if remaining <= 0:
        raise ValueError("fixture generation exceeded its 300-second wall-time limit")
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        stdout, stderr = process.communicate(timeout=remaining)
    except BaseException:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        raise
    finally:
        process.stdout.close()
        process.stderr.close()
    if process.returncode:
        raise ValueError(f"{command[0]} failed ({process.returncode}): {stderr.strip()}")
    return stdout


def verify(path, deadline):
    if not path.is_file() or not 0 < path.stat().st_size <= MAX_BYTES:
        raise ValueError("fixture must be a nonempty regular file no larger than 128 MiB")
    document = json.loads(run([
        FFPROBE, "-v", "error", "-show_packets", "-show_entries",
        "stream=index,codec_type,codec_name,width,height,r_frame_rate,sample_rate,channels:"
        "format=duration,format_name:packet=stream_index,pts_time,dts_time,duration_time",
        "-of", "json", str(path)
    ], deadline, 60))
    streams = document.get("streams", [])
    videos = [stream for stream in streams if stream.get("codec_type") == "video"]
    audios = [stream for stream in streams if stream.get("codec_type") == "audio"]
    if len(streams) != 2 or len(videos) != 1 or len(audios) != 1:
        raise ValueError("fixture must have exactly one video and one audio stream")
    video, audio = videos[0], audios[0]
    if (video.get("codec_name"), video.get("width"), video.get("height"),
            Fraction(video.get("r_frame_rate", "0"))) != ("h264", 3840, 2160, Fraction(25)):
        raise ValueError("fixture video must be 3840x2160 H.264 at 25 fps")
    if (audio.get("codec_name"), audio.get("sample_rate"), audio.get("channels")) != ("aac", "48000", 2):
        raise ValueError("fixture audio must be AAC, 48000 Hz, stereo")
    duration = Fraction(document["format"]["duration"])
    if document["format"]["format_name"] != "mpegts" or not 900 <= duration < Fraction("900.1"):
        raise ValueError(f"fixture MPEG-TS duration must be 900 seconds (got {float(duration)})")
    spans = {}
    counts = {}
    for stream in (video, audio):
        packets = [packet for packet in document["packets"] if packet["stream_index"] == stream["index"]]
        previous_pts = previous_dts = None
        first = end = None
        expected_step = Fraction(1, 25) if stream is video else Fraction(1024, 48000)
        for packet in packets:
            pts, dts, length = (Fraction(packet[key]) for key in ("pts_time", "dts_time", "duration_time"))
            if previous_pts is not None and (pts <= previous_pts or dts <= previous_dts):
                raise ValueError("fixture packet timestamps must be strictly monotonic")
            # ffprobe prints six fractional digits, so allow only rounding error.
            if previous_pts is not None and abs(pts - previous_pts - expected_step) > Fraction(2, 1_000_000):
                raise ValueError("fixture packet timeline has a gap or overlap")
            if length <= 0:
                raise ValueError("fixture packet duration must be positive")
            first = pts if first is None else first
            end = pts + length
            previous_pts, previous_dts = pts, dts
        if first is None or not 900 <= end - first < Fraction("900.1"):
            raise ValueError("fixture packet duration must cover all 900 seconds")
        spans[stream["codec_type"]] = float(end - first)
        counts[stream["codec_type"]] = len(packets)
    if counts["video"] != 22_500:
        raise ValueError("fixture must contain all 22500 video packets, not a sparse long-duration header")
    return {"width": 3840, "height": 2160, "video_packets": counts["video"],
            "audio_packets": counts["audio"], "video_span_seconds": spans["video"],
            "audio_span_seconds": spans["audio"], "bytes": path.stat().st_size}


def generate(path):
    if path.exists():
        raise ValueError(f"output already exists: {path}")
    deadline = time.monotonic() + GENERATION_SECONDS
    common = [FFMPEG, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-filter_threads", "2"]
    # Keep the temporary output on the same filesystem for no-clobber publication.
    with tempfile.TemporaryDirectory(prefix=".vplayer-timeline-", dir=path.parent) as directory:
        seed = Path(directory) / "seed.mp4"
        output = Path(directory) / "timeline.ts"
        run(common + ["-f", "lavfi", "-i", "color=c=blue:size=3840x2160:rate=25:duration=2",
                      "-an", "-c:v", "libx264", "-threads:v", "2", "-preset", "ultrafast",
                      "-crf", "35", "-pix_fmt", "yuv420p", "-g", "50", "-keyint_min", "50",
                      "-bf", "0", "-sc_threshold", "0", "-t", "2", "-fs", str(MAX_BYTES), str(seed)],
            deadline, 120)
        run(common + ["-stream_loop", "-1", "-i", str(seed), "-f", "lavfi", "-i",
                      "sine=frequency=440:sample_rate=48000:duration=900", "-map", "0:v:0", "-map", "1:a:0",
                      "-c:v", "copy", "-c:a", "aac", "-threads:a", "2", "-b:a", "64k", "-ar", "48000",
                      "-ac", "2", "-t", "900", "-fs", str(MAX_BYTES), "-f", "mpegts", str(output)],
            deadline, 120)
        summary = verify(output, deadline)
        os.link(output, path)
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", action="store_true", help="validate existing media without generating it")
    parser.add_argument("path", type=Path, help="job-local destination or existing fixture")
    args = parser.parse_args()
    path = args.path.absolute()
    def interrupted(number, _frame):
        raise SystemExit(128 + number)
    for number in (signal.SIGTERM, signal.SIGINT):
        signal.signal(number, interrupted)
    try:
        summary = verify(path, time.monotonic() + 60) if args.verify else generate(path)
    except (ValueError, OSError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"timeline fixture: {error}", file=sys.stderr)
        return 1
    print(json.dumps(summary, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
