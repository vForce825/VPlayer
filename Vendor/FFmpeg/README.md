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

The build contains only `libavcodec`, `libavformat`, `libavutil`, and
`libswresample`. It enables HTTP/HTTPS over Secure Transport, the exact
protocol/parser/bitstream-filter/audio-decoder inventory in
`component-manifest.json`, and the HLS-required AAC, AC-3, and E-AC-3 child
demuxers. No FFmpeg video decoder, encoder, muxer, filter, device, GPL,
nonfree, or version-3 component is enabled.

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

## Redistribution and relinking

FFmpeg is statically linked under LGPL-2.1-or-later. Every distributed
VPlayer binary must include the FFmpeg copyright and license notice, provide
the corresponding FFmpeg source for this exact revision and build scripts,
and provide the relinkable VPlayer object material needed for a recipient to
replace the LGPL library with a modified compatible build. Preserve that
material and clear relinking instructions for every release; the ignored
`Work` and `Artifacts` directories are build outputs, not a release-compliance
archive.
