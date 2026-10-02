// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

// Diagnostic only: collect native encoder capabilities without changing the app's
// fail-closed configuration or treating unsupported settings as test success.
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const int32_t width = 1280, height = 720;

static void describe(CFTypeRef value, char *buffer, size_t size) {
    if (!value) { snprintf(buffer, size, "<nil>"); return; }
    CFStringRef description = CFCopyDescription(value);
    if (!CFStringGetCString(description, buffer, size, kCFStringEncodingUTF8))
        snprintf(buffer, size, "<description-too-long>");
    CFRelease(description);
    for (char *p = buffer; *p; ++p) if (*p == '\n' || *p == '\r') *p = ' ';
}

static void copy_property(VTCompressionSessionRef session, const char *label,
                          const char *phase, CFStringRef key) {
    CFTypeRef value = NULL;
    OSStatus status = VTSessionCopyProperty(session, key, NULL, &value);
    char name[128], text[8192];
    describe(key, name, sizeof(name)); describe(value, text, sizeof(text));
    printf("VT_PROBE case=%s phase=%s copy=%s status=%d value=%s\n",
           label, phase, name, (int)status, text);
    if (value) CFRelease(value);
}

static void supported_properties(VTCompressionSessionRef session,
                                 const char *label, const char *phase) {
    CFDictionaryRef supported = NULL;
    OSStatus status = VTSessionCopySupportedPropertyDictionary(session, &supported);
    printf("VT_PROBE case=%s phase=%s supported_status=%d count=%ld\n", label,
           phase, (int)status, supported ? (long)CFDictionaryGetCount(supported) : -1L);
    const CFStringRef keys[] = {
        kVTCompressionPropertyKey_AllowOpenGOP,
        kVTCompressionPropertyKey_AllowFrameReordering,
        kVTCompressionPropertyKey_ProfileLevel,
        kVTCompressionPropertyKey_OutputBitDepth,
        kVTCompressionPropertyKey_FieldCount,
        kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
        CFSTR("EncoderID")
    };
    for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); ++i) {
        char name[128], text[8192];
        describe(keys[i], name, sizeof(name));
        describe(supported ? CFDictionaryGetValue(supported, keys[i]) : NULL,
                 text, sizeof(text));
        printf("VT_PROBE case=%s phase=%s supported=%s detail=%s\n",
               label, phase, name, text);
        copy_property(session, label, phase, keys[i]);
    }
    if (supported) CFRelease(supported);
}

static OSStatus set_property(VTCompressionSessionRef session, const char *label,
                             CFStringRef key, CFTypeRef value) {
    char name[128], text[512];
    describe(key, name, sizeof(name)); describe(value, text, sizeof(text));
    OSStatus status = VTSessionSetProperty(session, key, value);
    printf("VT_PROBE case=%s set=%s value=%s status=%d\n",
           label, name, text, (int)status);
    return status;
}

static void set_int(VTCompressionSessionRef session, const char *label,
                    CFStringRef key, int64_t value) {
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt64Type, &value);
    set_property(session, label, key, number);
    CFRelease(number);
}

static void output_callback(void *refcon, void *source_refcon, OSStatus status,
                            VTEncodeInfoFlags flags, CMSampleBufferRef sample) {
    const char *label = refcon;
    if (!sample) {
        printf("VT_PROBE case=%s callback_frame=%" PRIdPTR " status=%d flags=%u sample=nil\n",
               label, (intptr_t)source_refcon, (int)status, (unsigned)flags);
        return;
    }
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sample);
    CMTime dts = CMSampleBufferGetDecodeTimeStamp(sample);
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
    CFDictionaryRef first = attachments && CFArrayGetCount(attachments)
        ? CFArrayGetValueAtIndex(attachments, 0) : NULL;
    bool not_sync = first && CFDictionaryGetValue(first, kCMSampleAttachmentKey_NotSync) == kCFBooleanTrue;
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    CMVideoCodecType codec = CMFormatDescriptionGetMediaSubType(format);
    int length_size = 0;
    if (codec == kCMVideoCodecType_H264)
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, 0, NULL, NULL, NULL, &length_size);
    else if (codec == kCMVideoCodecType_HEVC)
        CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, 0, NULL, NULL, NULL, &length_size);
    char types[256] = "";
    size_t used = 0;
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
    size_t total = block ? CMBlockBufferGetDataLength(block) : 0;
    if (length_size > 0 && length_size <= 4) {
        for (size_t offset = 0; offset + (size_t)length_size < total;) {
            uint8_t length_bytes[4] = {0}, first_byte = 0;
            if (CMBlockBufferCopyDataBytes(block, offset, length_size, length_bytes) != noErr) break;
            size_t length = 0;
            for (int i = 0; i < length_size; ++i) length = (length << 8) | length_bytes[i];
            offset += length_size;
            if (!length || length > total - offset) break;
            if (CMBlockBufferCopyDataBytes(block, offset, 1, &first_byte) != noErr) break;
            unsigned type = codec == kCMVideoCodecType_H264 ? first_byte & 31 : (first_byte >> 1) & 63;
            if (used < sizeof(types) - 16)
                used += (size_t)snprintf(types + used, sizeof(types) - used, "%s%u", used ? "," : "", type);
            offset += length;
        }
    }
    printf("VT_PROBE case=%s callback_frame=%" PRIdPTR " status=%d flags=%u sync=%d pts=%lld/%d dts=%lld/%d dts_valid=%d bytes=%zu nal_types=%s\n",
           label, (intptr_t)source_refcon, (int)status, (unsigned)flags, !not_sync,
           (long long)pts.value, pts.timescale, (long long)dts.value, dts.timescale,
           CMTIME_IS_VALID(dts), total, types);
}

static void probe(CMVideoCodecType codec, CFStringRef profile,
                  const char *label, bool profile_first) {
    const void *spec_keys[] = {kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder};
    const void *spec_values[] = {kCFBooleanTrue};
    CFDictionaryRef specification = CFDictionaryCreate(NULL, spec_keys, spec_values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    int32_t pixel_format = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CFNumberRef pixel_number = CFNumberCreate(NULL, kCFNumberSInt32Type, &pixel_format);
    CFNumberRef width_number = CFNumberCreate(NULL, kCFNumberSInt32Type, &width);
    CFNumberRef height_number = CFNumberCreate(NULL, kCFNumberSInt32Type, &height);
    CFDictionaryRef io_surface = CFDictionaryCreate(NULL, NULL, NULL, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *attr_keys[] = {kCVPixelBufferPixelFormatTypeKey, kCVPixelBufferWidthKey,
        kCVPixelBufferHeightKey, kCVPixelBufferMetalCompatibilityKey, kCVPixelBufferIOSurfacePropertiesKey};
    const void *attr_values[] = {pixel_number, width_number, height_number, kCFBooleanTrue, io_surface};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, attr_keys, attr_values, 5,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    VTCompressionSessionRef session = NULL;
    OSStatus status = VTCompressionSessionCreate(NULL, width, height, codec, specification,
        attributes, NULL, output_callback, (void *)label, &session);
    printf("VT_PROBE case=%s create_status=%d session=%d require_hardware=1\n", label, (int)status, session != NULL);
    if (status != noErr || !session) goto cleanup;
    supported_properties(session, label, "created");
    if (profile_first) set_property(session, label, kVTCompressionPropertyKey_ProfileLevel, profile);
    set_property(session, label, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    set_int(session, label, kVTCompressionPropertyKey_ExpectedFrameRate, 30);
    set_property(session, label, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    set_property(session, label, kVTCompressionPropertyKey_AllowOpenGOP, kCFBooleanFalse);
    set_int(session, label, kVTCompressionPropertyKey_MaxKeyFrameInterval, 30);
    set_int(session, label, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 1);
    set_int(session, label, kVTCompressionPropertyKey_FieldCount, 1);
    if (!profile_first) set_property(session, label, kVTCompressionPropertyKey_ProfileLevel, profile);
    set_int(session, label, kVTCompressionPropertyKey_OutputBitDepth, 8);
    set_int(session, label, kVTCompressionPropertyKey_AverageBitRate, 5000000);
    int64_t byte_limit = 1125000, seconds = 1;
    CFNumberRef limit = CFNumberCreate(NULL, kCFNumberSInt64Type, &byte_limit);
    CFNumberRef duration = CFNumberCreate(NULL, kCFNumberSInt64Type, &seconds);
    const void *rate_values[] = {limit, duration};
    CFArrayRef rate_limits = CFArrayCreate(NULL, rate_values, 2, &kCFTypeArrayCallBacks);
    set_property(session, label, kVTCompressionPropertyKey_DataRateLimits, rate_limits);
    CFRelease(rate_limits); CFRelease(limit); CFRelease(duration);
    set_property(session, label, kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2);
    set_property(session, label, kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2);
    set_property(session, label, kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
    supported_properties(session, label, "configured");
    // A second explicit set isolates whether profile/configuration ordering matters.
    set_property(session, label, kVTCompressionPropertyKey_AllowOpenGOP, kCFBooleanFalse);
    status = VTCompressionSessionPrepareToEncodeFrames(session);
    printf("VT_PROBE case=%s prepare_status=%d\n", label, (int)status);
    copy_property(session, label, "prepared", kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder);
    if (status != noErr) goto cleanup;
    printf("VT_PROBE case=%s diagnostic_encoding_after_collecting_property_errors=1 not_production_approval=1\n", label);
    for (intptr_t frame = 0; frame < 61; ++frame) {
        CVPixelBufferRef image = NULL;
        CVReturn created = CVPixelBufferCreate(NULL, width, height, pixel_format, attributes, &image);
        if (created != kCVReturnSuccess || !image) {
            printf("VT_PROBE case=%s frame=%" PRIdPTR " pixel_status=%d\n", label, frame, (int)created);
            break;
        }
        CVPixelBufferLockBaseAddress(image, 0);
        for (size_t plane = 0; plane < CVPixelBufferGetPlaneCount(image); ++plane)
            memset(CVPixelBufferGetBaseAddressOfPlane(image, plane), plane ? 128 : 16 + frame % 200,
                   CVPixelBufferGetBytesPerRowOfPlane(image, plane) * CVPixelBufferGetHeightOfPlane(image, plane));
        CVPixelBufferUnlockBaseAddress(image, 0);
        CVBufferSetAttachment(image, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(image, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(image, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left, kCVAttachmentMode_ShouldPropagate);
        CVBufferSetAttachment(image, kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Left, kCVAttachmentMode_ShouldPropagate);
        VTEncodeInfoFlags flags = 0;
        const void *frame_keys[] = {kVTEncodeFrameOptionKey_ForceKeyFrame};
        const void *frame_values[] = {kCFBooleanTrue};
        CFDictionaryRef frame_properties = frame == 0 ? CFDictionaryCreate(NULL, frame_keys, frame_values, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks) : NULL;
        status = VTCompressionSessionEncodeFrame(session, image, CMTimeMake(frame, 30), CMTimeMake(1, 30),
            frame_properties, (void *)frame, &flags);
        printf("VT_PROBE case=%s encode_frame=%" PRIdPTR " status=%d flags=%u\n", label, frame, (int)status, (unsigned)flags);
        if (frame_properties) CFRelease(frame_properties);
        CVPixelBufferRelease(image);
        if (status != noErr) break;
    }
    status = VTCompressionSessionCompleteFrames(session, kCMTimeInvalid);
    printf("VT_PROBE case=%s complete_status=%d\n", label, (int)status);
cleanup:
    if (session) { VTCompressionSessionInvalidate(session); CFRelease(session); }
    CFRelease(attributes); CFRelease(pixel_number); CFRelease(width_number);
    CFRelease(height_number); CFRelease(io_surface); CFRelease(specification);
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("VT_PROBE constants property_not_supported=%d property_read_only=%d parameter_error=%d\n",
           (int)kVTPropertyNotSupportedErr, (int)kVTPropertyReadOnlyErr, (int)kVTParameterErr);
    probe(kCMVideoCodecType_H264, kVTProfileLevel_H264_High_AutoLevel, "h264-production-order", false);
    probe(kCMVideoCodecType_H264, kVTProfileLevel_H264_High_AutoLevel, "h264-profile-first", true);
    probe(kCMVideoCodecType_HEVC, kVTProfileLevel_HEVC_Main_AutoLevel, "hevc-production-order", false);
    probe(kCMVideoCodecType_HEVC, kVTProfileLevel_HEVC_Main_AutoLevel, "hevc-profile-first", true);
    return 0;
}
