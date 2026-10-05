// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
#pragma once
#include <stddef.h>
#include <stdint.h>
#define VP_SOURCE_DOLBY_MAX_FRAME 4096
#define VP_SOURCE_DOLBY_PADDING 64

typedef struct {
    int frame_size,sample_rate,sample_count,channels,bsid,stream_type,substream_id,bsmod;
} VPSourceDolbyFrameInfo;
typedef struct {
    uint8_t bytes[VP_SOURCE_DOLBY_MAX_FRAME+VP_SOURCE_DOLBY_PADDING];
    size_t pending_size,expected_size;
    int enhanced,crossed_input;
    VPSourceDolbyFrameInfo info;
} VPSourceDolbyFramer;
typedef int (*VPSourceDolbyFrameCallback)(void *,const uint8_t *,size_t,const VPSourceDolbyFrameInfo *,size_t);
void vp_source_dolby_init(VPSourceDolbyFramer *,int);
int vp_source_dolby_append(VPSourceDolbyFramer *,const uint8_t *,size_t,VPSourceDolbyFrameCallback,void *);
int vp_source_dolby_finish(const VPSourceDolbyFramer *,int complete_input);
