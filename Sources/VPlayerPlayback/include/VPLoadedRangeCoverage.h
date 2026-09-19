// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#pragma once
#import <AVFoundation/AVFoundation.h>
#include <stdint.h>
#include <stddef.h>

// 固定返回值不持有集合；code: 0覆盖、1未覆盖、2容量、3非法时间。
typedef struct {
    uint32_t code;
    uint32_t count;
    CMTime coveredEnd;
} VPLoadedRangeCoverage;

// 一次直接 getter，NSArray/NSValue 仅在同步调用内借用。
VPLoadedRangeCoverage VPReadLoadedRangeCoverage(AVPlayerItem * _Nonnull item,
                                                CMTimeRange requested);
// 同一生产扫描内核的同步入口，buffer 仅借用；不模拟 SDK getter 的分配。
VPLoadedRangeCoverage VPScanLoadedRangeBuffer(const CMTimeRange * _Nullable ranges,
                                              size_t count, CMTimeRange requested);

// 公开malloc zone枚举对“原借用地址+完整元素跨度”的同步定位结果。
// status=0时allocation/bytes是包含整个借用跨度的原allocation；其余状态均为unknown。
typedef struct {
    uint32_t status;
    uintptr_t allocation;
    size_t bytes;
} VPMallocAllocationRange;
VPMallocAllocationRange VPInspectMallocAllocationContainingRange(
    const void * _Nullable borrowedAddress, size_t borrowedBytes);

#if DEBUG
// 仅诊断原纯Swift对象：0原基址/回指已验证、1无侧表，其余为未验证。
typedef struct {
    uint32_t status;
    uintptr_t allocation;
    size_t bytes;
    uint8_t runtimeUUID[16];
} VPPreparationWeakSideTable;
VPPreparationWeakSideTable VPInspectPreparationWeakSideTable(const void * _Nonnull object);
#endif
