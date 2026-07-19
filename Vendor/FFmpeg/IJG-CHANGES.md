# IJG-derived FFmpeg source adaptations

The following files in the pinned FFmpeg source are FFmpeg-adapted derivatives of IJG originals, not verbatim copies:

- `libavcodec/jfdctfst.c` uses FFmpeg and libavutil headers and types, including
  `libavutil/attributes.h`, `fdctdsp.h`, and `int16_t`, and exposes the FFmpeg
  DCT entry points `ff_fdct_ifast` and `ff_fdct_ifast248`.
- `libavcodec/jfdctint_template.c` uses `libavutil/common.h`, `fdctdsp.h`, and
  FFmpeg's `bit_depth_template.c`; its bit-depth-templated `FUNC(...)` entry
  points include `FUNC(ff_jpeg_fdct_islow)` and `FUNC(ff_fdct248_islow)`.
- `libavcodec/jrevdct.c` uses FFmpeg/libavutil headers and types, including
  `libavutil/intreadwrite.h`, `dct.h`, and `idctdsp.h`; it provides FFmpeg's
  `ff_j_rev_dct`, reduced-size `ff_j_rev_dct4`, `ff_j_rev_dct2`, and
  `ff_j_rev_dct1` functions plus `ff_jref_idct_put` and `ff_jref_idct_add`
  entry points that call FFmpeg pixel put/add helpers.

These statements describe adaptations directly present in the source pinned at
FFmpeg tag `n8.1.2`, exact commit
`38b88335f99e76ed89ff3c93f877fdefce736c13`. The pinned source files and their
headers are the complete authoritative code and license terms. No further
additions, deletions, or changes are made by VPlayer relative to that pinned
FFmpeg source. This notice does not identify an original IJG version or
baseline and does not claim a complete line-by-line history between IJG and
FFmpeg.

The executable attribution requirement remains: "this software is based in
part on the work of the Independent JPEG Group". FFmpeg's byte-identical
upstream license map is preserved at `Vendor/FFmpeg/UPSTREAM-LICENSE.md`.
