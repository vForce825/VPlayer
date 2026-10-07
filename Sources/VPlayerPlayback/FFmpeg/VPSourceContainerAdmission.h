// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
#pragma once
#include <stddef.h>
#include <stdint.h>
/* Closed, allocation-free structural admission before native demux. The limits
 * bound admitted counts and byte expansions; they are not a process RSS proof. */
int vp_source_admit_container(const uint8_t *bytes, size_t size, int is_prefix,
                              int32_t *kind, size_t *usable_size);

int vp_source_admit_container_with_interrupt(const uint8_t *,size_t,int,int32_t *,size_t *,int (*)(void *),void *);

#define VP_SOURCE_TS_HEADER_BYTES 32768u
enum {
    VP_SOURCE_ADMISSION_NONE=0, VP_SOURCE_ADMISSION_STRUCTURE,
    VP_SOURCE_ADMISSION_MISSING_PAT, VP_SOURCE_ADMISSION_MISSING_PMT,
    VP_SOURCE_ADMISSION_CHANGED_PAT, VP_SOURCE_ADMISSION_CHANGED_PMT,
    VP_SOURCE_ADMISSION_TOPOLOGY, VP_SOURCE_ADMISSION_UNKNOWN_PID,
    VP_SOURCE_ADMISSION_ACQUISITION, VP_SOURCE_ADMISSION_LIMIT, VP_SOURCE_ADMISSION_CANCELLED
};
typedef struct {
    size_t start_offset, packet_offset;
    int reason, pid;
} VPSourceAdmission;
/* Reserved non-media DVB SI is ignored only by the private preflight byte view.
 * The input and subsequent playback/proxy transmissions are never modified. */
static inline int vp_source_ignored_si(unsigned pid) { return pid==0x10 || pid==0x12 || pid==0x14; }
int vp_source_admit_container_with_view(const uint8_t *,size_t,int,int32_t *,size_t *,
    int (*)(void *),void *,VPSourceAdmission *);

/* Fixed borrowed-input tail view, shared by native AVIO and acquisition only.
 * Offsets are relative to the admitted byte view. Call after TS admission. */
#define VP_SOURCE_TS_MAX_TAILS 8u
typedef struct {
    unsigned pid;
    size_t start,bytes,header_size,expected;
    uint8_t header[6];
    int active,withhold;
} VPSourceTSTail;
typedef struct { VPSourceTSTail tails[VP_SOURCE_TS_MAX_TAILS]; unsigned count; } VPSourceTSTails;
int vp_source_prepare_ts_tails(const uint8_t *,size_t,int,int (*)(void *),void *,
    VPSourceTSTails *,VPSourceAdmission *);
int vp_source_ts_packet_withheld(const VPSourceTSTails *,unsigned,size_t);
enum {
    VP_SOURCE_ACQUISITION_READY=0, VP_SOURCE_ACQUISITION_NEEDS_MORE=1,
    VP_SOURCE_ACQUISITION_STOP=2, VP_SOURCE_ACQUISITION_CANCELLED=3
};
int32_t vp_source_ts_acquisition_hint(const uint8_t *,size_t,int (*)(void *),void *);
