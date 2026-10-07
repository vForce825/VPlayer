#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Independent, valid large-I/small-P video. Never consumes captured media.

Generate with the repository's fixture-only FFmpeg tooling (libx264/libx265).
The committed manifest records the actual generating CLI version and hashes;
verification reads committed bytes and never regenerates them in acceptance CI.
"""
import argparse
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DIRECTORY = ROOT / "Tests/Fixtures/Video"
MANIFEST = "homepod-large-idr-provenance.json"
SEED = b"VPlayer independent large-IDR regression v1"
CASES = (
    dict(name="homepod-large-idr-h264-1080p30-aac44100.mp4", codec="h264", profile="High",
         width=1920, height=1080, fps=30, tile=2, crf=18, rate=44100, minimum_idr=600000,
         transfer="bt709", pixel_format="yuv420p"),
    dict(name="homepod-large-idr-hevc-hlg-2160p50-aac48000.mp4", codec="hevc", profile="Main 10",
         width=3840, height=2160, fps=50, tile=8, crf=28, rate=48000, minimum_idr=500000,
         transfer="arib-std-b67", pixel_format="yuv420p10le"),
)


def tool(name):
    return os.environ.get(name.upper(), name)


def run(*args):
    subprocess.run(args, check=True)


def probe(path):
    return json.loads(subprocess.check_output([tool("ffprobe"), "-v", "error", "-show_streams",
        "-show_packets", "-show_format", "-of", "json", str(path)]))


def inspect(path, case, decode=False):
    facts = probe(path)
    video = next(s for s in facts["streams"] if s["codec_type"] == "video")
    audio = next(s for s in facts["streams"] if s["codec_type"] == "audio")
    expected = (case["codec"], case["profile"], case["width"], case["height"],
                f'{case["fps"]}/1', case["pixel_format"], case["transfer"])
    actual = tuple(video[k] for k in ("codec_name", "profile", "width", "height", "r_frame_rate",
                                    "pix_fmt", "color_transfer"))
    if actual != expected:
        raise ValueError(f"Video format differs: {actual} != {expected}")
    if (audio["codec_name"], audio["profile"], int(audio["sample_rate"]), audio["channels"]) != (
            "aac", "LC", case["rate"], 2):
        raise ValueError("Expected genuine stereo source AAC-LC at its original rate")
    audio_packets = [p for p in facts["packets"] if p["stream_index"] == audio["index"]]
    if any(p.get("side_data_list") for p in audio_packets) or float(audio_packets[0]["pts_time"]) != 0:
        raise ValueError("Source-AAC control must preserve original ADTS timing without skip/trim metadata")
    if len(audio_packets) != (15 * case["rate"] + 1023) // 1024:
        raise ValueError("Source AAC must contain the exact complete-AU coverage of the video endpoint")
    def verify_cadence(packets, stream, step):
        time_base = Fraction(stream["time_base"])
        for index, packet in enumerate(packets):
            if any(int(packet[field]) * time_base != index * step for field in ("pts", "dts")):
                raise ValueError("Source packet timeline must start at zero without gaps or shifts")
            if int(packet["duration"]) * time_base != step:
                raise ValueError("Source packet duration must preserve exact frame/AU cadence")
    verify_cadence(audio_packets, audio, Fraction(1024, case["rate"]))
    packets = [p for p in facts["packets"] if p["stream_index"] == video["index"]]
    verify_cadence(packets, video, Fraction(1, case["fps"]))
    keys = [p for p in packets if "K" in p["flags"]]
    nonkeys = [int(p["size"]) for p in packets if "K" not in p["flags"]]
    sizes = [int(p["size"]) for p in keys]
    if len(packets) != case["fps"] * 15 or len(keys) != 3:
        raise ValueError("Expected exactly three complete five-second GOPs")
    if [float(p["pts_time"]) for p in keys] != [0, 5, 10]:
        raise ValueError("GOP cadence differs from the real long-GOP regression")
    if min(sizes) < case["minimum_idr"] or max(sizes) > 1024 * 1024:
        raise ValueError(f"IDRs must be naturally large and individually below 1 MiB: {sizes}")
    if max(nonkeys) > min(sizes) // 20:
        raise ValueError("Fixture must have small inter frames, not a uniformly huge bitrate")
    # This is the rejected old projection, not a replacement admission rule.
    old_projected_bytes = max(sizes) * (2 * 6 * case["fps"] + 2)
    if old_projected_bytes <= 64 * 1024 * 1024:
        raise ValueError("Fixture no longer reproduces the old production-default false rejection")
    if decode:
        run(tool("ffmpeg"), "-hide_banner", "-v", "error", "-xerror", "-threads", "1",
            "-i", str(path), "-map", "0:v:0", "-map", "0:a:0", "-f", "null", "-")
    return dict(bytes=path.stat().st_size, sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                video_packets=len(packets), idr_bytes=sizes, largest_p_bytes=max(nonkeys),
                old_six_second_projection_bytes=old_projected_bytes,
                video_duration=video["duration"], audio_sample_rate=audio["sample_rate"],
                audio_packets=len(audio_packets), audio_duration=audio["duration"])


def generate(directory):
    directory.mkdir(parents=True, exist_ok=True)
    measurements = {}
    with tempfile.TemporaryDirectory(prefix="vplayer-large-idr-") as temporary:
        temporary = Path(temporary)
        for case in CASES:
            tile = case["tile"]
            width, height = case["width"] // tile, case["height"] // tile
            noise = hashlib.shake_256(SEED).digest(width * height)
            pixels = b"".join(b"".join(bytes([16 + value % 220]) * tile
                for value in noise[y * width:(y + 1) * width]) * tile for y in range(height))
            pattern = temporary / "pattern.pgm"
            pattern.write_bytes(f'P5\n{case["width"]} {case["height"]}\n255\n'.encode() + pixels)
            gop = case["fps"] * 5
            common = f"keyint={gop}:min-keyint={gop}:scenecut=0:bframes=0:"
            if case["codec"] == "h264":
                encoder = ["-c:v", "libx264", "-preset", "veryfast", "-profile:v", "high", "-level:v", "4.0",
                    "-x264-params", common + "force-cfr=1:colorprim=bt709:transfer=bt709:colormatrix=bt709:fullrange=off"]
            else:
                encoder = ["-c:v", "libx265", "-preset", "ultrafast", "-tag:v", "hvc1", "-x265-params",
                    common + "open-gop=0:repeat-headers=1:pools=none:frame-threads=1:wpp=0:"
                    "colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc:log-level=error"]
            video = temporary / "gop.mp4"
            run(tool("ffmpeg"), "-hide_banner", "-v", "error", "-y", "-loop", "1", "-framerate",
                str(case["fps"]), "-i", str(pattern), "-frames:v", str(gop), *encoder,
                "-crf", str(case["crf"]), "-pix_fmt", case["pixel_format"], "-threads", "1", str(video))
            output = directory / case["name"]
            # Broadcast-style source AAC has complete AUs and no MP4 encoder
            # priming edit. Encode an independent ADTS stream, then copy whole
            # AUs; do not remove edit lists or alter timestamps after muxing.
            audio = temporary / "source.aac"
            run(tool("ffmpeg"), "-hide_banner", "-v", "error", "-y", "-f", "lavfi", "-i",
                f'sine=frequency=997:sample_rate={case["rate"]}:duration=15',
                "-c:a", "aac", "-b:a", "128k", "-ar", str(case["rate"]), "-ac", "2", "-f", "adts", str(audio))
            # Repeat one independently encoded GOP; do not retime tiny IDRs, copy
            # captured headers, inject filler NALs, or pad compressed payloads.
            run(tool("ffmpeg"), "-hide_banner", "-v", "error", "-y", "-stream_loop", "2", "-i", str(video),
                "-i", str(audio), "-map", "0:v:0", "-map", "1:a:0", "-c", "copy", "-bsf:a", "aac_adtstoasc",
                "-frames:a", str((15 * case["rate"] + 1023) // 1024), "-movflags", "+faststart", str(output))
            measurements[case["name"]] = inspect(output, case, decode=True)
    version = subprocess.check_output([tool("ffmpeg"), "-version"], text=True).splitlines()[0]
    manifest = dict(source="Independent SHAKE-256 grayscale pattern and lavfi sine; no captured media or headers",
                    audio="Original complete ADTS AAC-LC access units remuxed without skip/trim metadata",
                    pattern_seed=SEED.decode(), ffmpeg_version=version, duration_seconds=15,
                    gop_seconds=5, generation="Scripts/generate-homepod-large-idr-fixtures.py --generate",
                    cases=list(CASES), measurements=measurements)
    (directory / MANIFEST).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")


def verify(directory, decode=False):
    manifest = json.loads((directory / MANIFEST).read_text())
    if manifest["cases"] != list(CASES):
        raise ValueError("Manifest scenario parameters differ from the reviewed generator")
    for case in CASES:
        actual = inspect(directory / case["name"], case, decode=decode)
        if actual != manifest["measurements"][case["name"]]:
            raise ValueError(f'Committed fixture differs from provenance: {case["name"]}')
        print("HOMEPOD_LARGE_IDR=" + json.dumps({"name": case["name"], **actual}, sort_keys=True))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--generate", action="store_true")
    modes.add_argument("--verify", action="store_true")
    parser.add_argument("--decode", action="store_true", help="Also decode every original video/audio packet")
    parser.add_argument("--directory", type=Path, default=DIRECTORY)
    args = parser.parse_args()
    if args.generate:
        generate(args.directory)
    verify(args.directory, decode=args.decode)
