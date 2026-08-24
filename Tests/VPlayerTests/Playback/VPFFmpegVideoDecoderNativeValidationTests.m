// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

@import XCTest;
@import VPlayerPlayback;

#if DEBUG
extern int32_t vp_ffmpeg_video_decoder_debug_deliver_synthetic_frame(
    int32_t format,
    const uint8_t *luma,
    int32_t luma_stride,
    const uint8_t *chroma_b,
    int32_t chroma_b_stride,
    const uint8_t *chroma_r,
    int32_t chroma_r_stride,
    int32_t width,
    int32_t height,
    VPFFVideoFrameCallback callback,
    void *context
);
#endif

static void vpff_record_validation_callback(void *context, const VPFFVideoFrame *frame) {
    NSUInteger *count = context;
    *count += 1;
}

@interface VPFFmpegVideoDecoderNativeValidationTests : XCTestCase
@end

@implementation VPFFmpegVideoDecoderNativeValidationTests

- (void)testSyntheticFrameValidationRejectsEachInvalidLayoutIndependently {
#if DEBUG
    uint8_t luma[16 * 16] = {0};
    uint8_t chroma_b[8 * 8] = {0};
    uint8_t chroma_r[8 * 8] = {0};
    const int32_t unsupported = VPFF_VIDEO_DECODER_ERROR_UNSUPPORTED_OUTPUT;
    struct ValidationCase {
        const char *name;
        int32_t format;
        const uint8_t *luma;
        int32_t luma_stride;
        const uint8_t *chroma_b;
        int32_t chroma_b_stride;
        const uint8_t *chroma_r;
        int32_t chroma_r_stride;
        int32_t width;
        int32_t height;
    } cases[] = {
        {"non-yuv420p", -1, luma, 16, chroma_b, 8, chroma_r, 8, 16, 16},
        {"null-luma", 0, NULL, 16, chroma_b, 8, chroma_r, 8, 16, 16},
        {"null-chroma-b", 0, luma, 16, NULL, 8, chroma_r, 8, 16, 16},
        {"null-chroma-r", 0, luma, 16, chroma_b, 8, NULL, 8, 16, 16},
        {"zero-width", 0, luma, 16, chroma_b, 8, chroma_r, 8, 0, 16},
        {"negative-width", 0, luma, 16, chroma_b, 8, chroma_r, 8, -2, 16},
        {"odd-width", 0, luma, 16, chroma_b, 8, chroma_r, 8, 15, 16},
        {"zero-height", 0, luma, 16, chroma_b, 8, chroma_r, 8, 16, 0},
        {"negative-height", 0, luma, 16, chroma_b, 8, chroma_r, 8, 16, -2},
        {"odd-height", 0, luma, 16, chroma_b, 8, chroma_r, 8, 16, 15},
        {"zero-luma-stride", 0, luma, 0, chroma_b, 8, chroma_r, 8, 16, 16},
        {"negative-luma-stride", 0, luma, -16, chroma_b, 8, chroma_r, 8, 16, 16},
        {"short-luma-stride", 0, luma, 15, chroma_b, 8, chroma_r, 8, 16, 16},
        {"zero-chroma-b-stride", 0, luma, 16, chroma_b, 0, chroma_r, 8, 16, 16},
        {"negative-chroma-b-stride", 0, luma, 16, chroma_b, -8, chroma_r, 8, 16, 16},
        {"short-chroma-b-stride", 0, luma, 16, chroma_b, 7, chroma_r, 8, 16, 16},
        {"zero-chroma-r-stride", 0, luma, 16, chroma_b, 8, chroma_r, 0, 16, 16},
        {"negative-chroma-r-stride", 0, luma, 16, chroma_b, 8, chroma_r, -8, 16, 16},
        {"short-chroma-r-stride", 0, luma, 16, chroma_b, 8, chroma_r, 7, 16, 16},
    };

    for (NSUInteger index = 0; index < sizeof(cases) / sizeof(cases[0]); ++index) {
        NSUInteger callback_count = 0;
        const struct ValidationCase value = cases[index];
        const int32_t status = vp_ffmpeg_video_decoder_debug_deliver_synthetic_frame(
            value.format,
            value.luma,
            value.luma_stride,
            value.chroma_b,
            value.chroma_b_stride,
            value.chroma_r,
            value.chroma_r_stride,
            value.width,
            value.height,
            vpff_record_validation_callback,
            &callback_count
        );
        XCTAssertEqual(status, unsupported, @"%s", value.name);
        XCTAssertEqual(callback_count, 0u, @"%s", value.name);
    }
#else
    XCTFail(@"native validation tests require a Debug build");
#endif
}

- (void)testSyntheticFrameValidationAcceptsExactBoundaryStrides {
#if DEBUG
    uint8_t luma[16 * 16] = {0};
    uint8_t chroma_b[8 * 8] = {0};
    uint8_t chroma_r[8 * 8] = {0};
    NSUInteger callback_count = 0;
    const int32_t status = vp_ffmpeg_video_decoder_debug_deliver_synthetic_frame(
        0,
        luma,
        16,
        chroma_b,
        8,
        chroma_r,
        8,
        16,
        16,
        vpff_record_validation_callback,
        &callback_count
    );

    XCTAssertEqual(status, 0);
    XCTAssertEqual(callback_count, 1u);
#else
    XCTFail(@"native validation tests require a Debug build");
#endif
}

@end
