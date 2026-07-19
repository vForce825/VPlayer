// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    VPFF_COMPONENT_PROTOCOL,
    VPFF_COMPONENT_DEMUXER,
    VPFF_COMPONENT_PARSER,
    VPFF_COMPONENT_DECODER
} VPFFComponentKind;

size_t vp_ffmpeg_component_count(VPFFComponentKind kind);
const char *vp_ffmpeg_component_name(VPFFComponentKind kind, size_t index);
const char *vp_ffmpeg_configuration(void);
unsigned vp_ffmpeg_version(void);

#ifdef __cplusplus
}
#endif
