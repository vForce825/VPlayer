# FFmpeg build record

VPlayer pins the official FFmpeg `n8.1.2` annotated tag at commit
`38b88335f99e76ed89ff3c93f877fdefce736c13` and builds it in
`LGPL-2.1-or-later` mode for tvOS 18.0. The generated XCFramework is not
committed.

Rebuild and audit it from the repository root:

```sh
./Scripts/build-ffmpeg.sh
./Scripts/audit-ffmpeg.sh Vendor/FFmpeg/Artifacts/FFmpeg.xcframework
```

The behavioral audit tests require that real artifact and its bounded `Work`
inputs already exist. Run them in this order; they fail with the actionable
build command instead of skipping when those inputs are absent:

```sh
./Scripts/build-ffmpeg.sh
bash Scripts/Tests/test_ffmpeg_lock.sh
bash Scripts/Tests/test_ffmpeg_audit.sh
```

The build acquires the ignored, exclusive `Vendor/FFmpeg/Work/.build-lock`
before cleaning, fetching, or building and holds it through audit and
promotion. Each owner/token gets a unique private staging path ending in
`.xcframework`. A concurrent or stale-looking lock fails closed with bounded
manual cleanup instructions; it is never stolen automatically. Promotion
requires the current build owner/token/candidate, an audit-before-and-after tree fingerprint and directory identity match, and a same-filesystem rename.

The build contains only `libavcodec`, `libavformat`, `libavutil`, and
`libswresample`. It enables HTTP/HTTPS over Secure Transport, the exact
protocol/parser/bitstream-filter/audio-decoder inventory in
`component-manifest.json`, and the HLS-required AAC, AC-3, and E-AC-3 child
demuxers. No FFmpeg video decoder, encoder, muxer, filter, device, GPL,
nonfree, or version-3 component is enabled.

The combined archives include FFmpeg's pinned IJG-derived files
`libavcodec/jfdctfst.c`, `libavcodec/jfdctint_template.c`, and
`libavcodec/jrevdct.c`. For executable distributions, the accompanying
documentation must state:
"this software is based in part on the work of the Independent JPEG Group".
These are FFmpeg-adapted derivatives of IJG originals, not verbatim copies;
their directly evidenced adaptations are recorded in
`Vendor/FFmpeg/IJG-CHANGES.md`. No further additions, deletions, or changes are made by VPlayer relative to the pinned FFmpeg source. FFmpeg's upstream
licensing map is preserved byte-for-byte at
`Vendor/FFmpeg/UPSTREAM-LICENSE.md`; the three pinned source files and their
headers are the complete authoritative code and license terms.

FFmpeg 8.1.2 removed the old `--disable-postproc` configure option, so the
pin uses `--disable-everything`, `--disable-avfilter`, and explicit library
and component allowlists instead. It also explicitly disables `swscale`,
which FFmpeg otherwise enables as a library despite `--disable-everything`.
Xcode 26 does not include NASM or YASM; the x86_64 simulator compatibility
slice therefore records `--disable-x86asm`, while both arm64 slices retain
their normal assembly path.

The audit reads each architecture's real `config.h` and
`config_components.h`, checks the source/tag/license and input archive
hashes, validates the XCFramework platform/architectures, and independently
subtracts archive definitions from undefined references for each thin
architecture. The remaining exact symbols are recorded in
`system-symbol-allowlist.txt`; they are Apple libc/libm/pthread/BSD system
interfaces, CoreFoundation and Security/Secure Transport interfaces, zlib,
and compiler runtime interfaces. Consumers must link CoreFoundation,
Security, and zlib (`-lz`). Wildcards are not accepted by the audit.

For checkout-independent output, each Clang slice uses file, macro, and debug
prefix maps. Immediately after configure and before make, the build
deterministically normalizes FFMPEG_CONFIGURATION, FFMPEG_DATADIR, and AVCONV_DATADIR to stable virtual roots under `/VPlayer/FFmpeg`. The mapping and
per-slice virtual install prefix are recorded in each `ffmpeg-build.json`.
The audit rejects either the logical or physical checkout root in generated
headers, build records, every installed archive, and every final thin archive;
target triples and LGPL gates remain unchanged.

## Redistribution and relinking

FFmpeg is statically linked under LGPL-2.1-or-later. Every distributed
VPlayer binary must include the FFmpeg copyright and license notice, provide
the corresponding FFmpeg source for this exact revision and build scripts,
and provide the relinkable VPlayer object material needed for a recipient to
replace the LGPL library with a modified compatible build. Preserve that
material and clear relinking instructions for every release; the ignored
`Work` and `Artifacts` directories are build outputs, not a release-compliance
archive.

Release and EULA terms must permit customers to modify the application for their own use
and permit reverse engineering for debugging those modifications.
Source, object material, and relinking instructions alone are not sufficient
when distribution terms prohibit either activity. The VPlayer App Store
exception does not alter FFmpeg's LGPL terms. Every App Store release must
pass an App Store release/legal gate that checks the actual distribution
terms and delivery mechanism against these obligations; this documentation
does not by itself guarantee App Store acceptance or legal compliance.
