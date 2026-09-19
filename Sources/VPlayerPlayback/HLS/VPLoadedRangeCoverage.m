// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#import <VPlayerPlayback/VPLoadedRangeCoverage.h>
#include <limits.h>
#include <malloc/malloc.h>
#include <mach/mach.h>

typedef CMTimeRange (*VPRangeReader)(const void *, size_t);

static uint64_t VPGCD(uint64_t a, uint64_t b) {
    while (b) { uint64_t next = a % b; a = b; b = next; }
    return a;
}

static BOOL VPValidTime(CMTime time) {
    return CMTIME_IS_NUMERIC(time) && time.epoch == 0 && time.timescale > 0;
}

// 与 ExactMediaTime 的约分后表示一致；禁止 CMTimeAdd 的溢出降精度填平缺口。
static BOOL VPRangeEnd(CMTimeRange range, CMTime *end) {
    if (!VPValidTime(range.start) || !VPValidTime(range.duration)
        || range.start.value < 0 || range.duration.value <= 0) return NO;
    uint64_t scale = (uint64_t)range.start.timescale * range.duration.timescale;
    __int128 value = (__int128)range.start.value * range.duration.timescale
        + (__int128)range.duration.value * range.start.timescale;
    uint64_t divisor = VPGCD((uint64_t)(value % scale), scale);
    value /= divisor;
    scale /= divisor;
    if (value > INT64_MAX || scale > INT32_MAX) return NO;
    *end = CMTimeMake((int64_t)value, (int32_t)scale);
    return YES;
}

static VPLoadedRangeCoverage VPScan(const void *context, size_t count,
                                   VPRangeReader read, CMTimeRange requested) {
    VPLoadedRangeCoverage result = { 1, (uint32_t)(count > UINT32_MAX ? UINT32_MAX : count), kCMTimeInvalid };
    if (count > 128) { result.code = 2; return result; }
    CMTime requestedEnd;
    if (!VPRangeEnd(requested, &requestedEnd)) { result.code = 3; return result; }
    // 即使前项已覆盖，也校验其余项，不能隐藏后部非法时间。
    for (size_t i = 0; i < count; ++i) {
        CMTime end;
        if (!VPRangeEnd(read(context, i), &end)) { result.code = 3; return result; }
    }
    CMTime cursor = requested.start;
    for (size_t pass = 0; pass < count; ++pass) {
        CMTime next = cursor;
        for (size_t i = 0; i < count; ++i) {
            CMTimeRange range = read(context, i);
            CMTime end;
            if (!VPRangeEnd(range, &end)) { result.code = 3; return result; }
            if (CMTimeCompare(range.start, cursor) <= 0 && CMTimeCompare(end, next) > 0) next = end;
        }
        if (CMTimeCompare(next, cursor) == 0) break;
        cursor = next;
        if (CMTimeCompare(cursor, requestedEnd) >= 0) { result.code = 0; break; }
    }
    result.coveredEnd = cursor;
    return result;
}

static CMTimeRange VPReadArray(const void *context, size_t index) {
    NSArray<NSValue *> *values = (__bridge NSArray<NSValue *> *)context;
    NSValue *value = [values objectAtIndex:index];
    return value.CMTimeRangeValue;
}

static CMTimeRange VPReadBuffer(const void *context, size_t index) {
    return ((const CMTimeRange *)context)[index];
}

VPLoadedRangeCoverage VPReadLoadedRangeCoverage(AVPlayerItem *item, CMTimeRange requested) {
    @autoreleasepool {
        NSArray<NSValue *> *values = item.loadedTimeRanges;
        return VPScan((__bridge const void *)values, values.count, VPReadArray, requested);
    }
}

VPLoadedRangeCoverage VPScanLoadedRangeBuffer(const CMTimeRange *ranges, size_t count,
                                            CMTimeRange requested) {
    if (!ranges && count) {
        VPLoadedRangeCoverage invalid = { 3, (uint32_t)count, kCMTimeInvalid };
        return invalid;
    }
    return VPScan(ranges, count, VPReadBuffer, requested);
}

typedef struct {
    vm_address_t target;
    vm_size_t requiredBytes;
    vm_address_t allocation;
    vm_size_t allocationBytes;
} VPMallocRangeLookup;

static kern_return_t VPReadCurrentTaskMemory(task_t task, vm_address_t address,
                                            vm_size_t size, void **memory) {
    (void)task; (void)size;
    *memory = (void *)address;
    return KERN_SUCCESS;
}

static void VPRecordContainingMallocRange(task_t task, void *context, unsigned type,
                                          vm_range_t *ranges, unsigned count) {
    (void)task; (void)type;
    VPMallocRangeLookup *lookup = context;
    for (unsigned index = 0; index < count; ++index) {
        vm_address_t rangeEnd;
        vm_address_t borrowedEnd;
        if (__builtin_add_overflow(ranges[index].address, ranges[index].size, &rangeEnd)
            || __builtin_add_overflow(lookup->target, lookup->requiredBytes,
                                      &borrowedEnd)) continue;
        if (lookup->target >= ranges[index].address && borrowedEnd <= rangeEnd) {
            lookup->allocation = ranges[index].address;
            lookup->allocationBytes = ranges[index].size;
        }
    }
}

VPMallocAllocationRange VPInspectMallocAllocationContainingRange(
    const void *borrowedAddress, size_t borrowedBytes) {
    VPMallocAllocationRange result = { .status = 1 };
    if (!borrowedAddress || borrowedBytes == 0) return result;
    vm_address_t target = (vm_address_t)borrowedAddress;
    vm_address_t borrowedEnd;
    if (__builtin_add_overflow(target, (vm_size_t)borrowedBytes, &borrowedEnd)) {
        return result;
    }
    (void)borrowedEnd;
    VPMallocRangeLookup lookup = {
        .target = target,
        .requiredBytes = (vm_size_t)borrowedBytes,
        .allocation = 0,
        .allocationBytes = 0
    };
    vm_address_t *zoneAddresses = NULL;
    unsigned zoneCount = 0;
    kern_return_t listed = malloc_get_all_zones(
        mach_task_self(), VPReadCurrentTaskMemory, &zoneAddresses, &zoneCount);
    if (listed != KERN_SUCCESS || !zoneAddresses || zoneCount == 0) {
        result.status = 2; return result;
    }
    BOOL inspectedZone = NO;
    for (unsigned index = 0; index < zoneCount && lookup.allocation == 0; ++index) {
        malloc_zone_t *zone = (malloc_zone_t *)zoneAddresses[index];
        if (!zone || !zone->introspect || !zone->introspect->enumerator
            || !zone->introspect->force_lock || !zone->introspect->force_unlock) continue;
        inspectedZone = YES;
        zone->introspect->force_lock(zone);
        kern_return_t scanned = zone->introspect->enumerator(
            mach_task_self(), &lookup, MALLOC_PTR_IN_USE_RANGE_TYPE,
            (vm_address_t)zone, VPReadCurrentTaskMemory,
            VPRecordContainingMallocRange);
        zone->introspect->force_unlock(zone);
        if (scanned != KERN_SUCCESS) { result.status = 4; return result; }
    }
    if (!inspectedZone) { result.status = 3; return result; }
    if (lookup.allocation == 0 || lookup.allocationBytes == 0) {
        result.status = 5; return result;
    }
    result.status = 0;
    result.allocation = (uintptr_t)lookup.allocation;
    result.bytes = (size_t)lookup.allocationBytes;
    return result;
}

#if DEBUG
#include <mach-o/loader.h>
#include <dlfcn.h>
#include <string.h>
#include <stdbool.h>

typedef struct { vm_address_t target; vm_size_t size; } VPAllocationLookup;
static kern_return_t VPReadLocalAllocation(task_t task, vm_address_t address,
                                         vm_size_t size, void **memory) {
    (void)task; (void)size;
    *memory = (void *)address;
    return KERN_SUCCESS;
}
static void VPRecordLocalAllocation(task_t task, void *context, unsigned type,
                                   vm_range_t *ranges, unsigned count) {
    (void)task; (void)type;
    VPAllocationLookup *lookup = context;
    for (unsigned index = 0; index < count; ++index) {
        if (ranges[index].address == lookup->target) { lookup->size = ranges[index].size; }
    }
}

VPPreparationWeakSideTable VPInspectPreparationWeakSideTable(const void *object) {
    VPPreparationWeakSideTable result = { .status = 2 };
#if defined(__arm64__) && defined(__LP64__)
    // 记录实际载入runtime的Mach-O UUID；不把compiler版本当成runtime版本。
    Dl_info runtime;
    void *retain = dlsym(RTLD_DEFAULT, "swift_retain");
    if (!retain || !dladdr(retain, &runtime)) { result.status = 5; return result; }
    const struct mach_header_64 *header = runtime.dli_fbase;
    if (!header || header->magic != MH_MAGIC_64) { result.status = 5; return result; }
    const uint8_t *command = (const uint8_t *)(header + 1);
    bool foundUUID = false;
    for (uint32_t index = 0; index < header->ncmds; ++index) {
        const struct load_command *load = (const struct load_command *)command;
        if (load->cmd == LC_UUID && load->cmdsize >= sizeof(struct uuid_command)) {
            memcpy(result.runtimeUUID, ((const struct uuid_command *)load)->uuid, 16);
            foundUUID = true;
            break;
        }
        command += load->cmdsize;
    }
    if (!foundUUID) { result.status = 5; return result; }
    // Swift 6.2 RefCount.h：原refcount为atomic；侧表指针占低62位、左移3还原。
    // 强持原对象的调用方保证对象寿命。只读，不制造weak reference。
    const uint64_t *counts = (const uint64_t *)object + 1;
    uint64_t bits = __atomic_load_n(counts, __ATOMIC_ACQUIRE);
    if ((bits & UINT64_C(0x8000000000000000)) == 0) { result.status = 1; return result; }
    if ((bits & UINT64_C(0xc000000000000000)) != UINT64_C(0xc000000000000000)
        || (bits & UINT64_C(0xffffffff)) == UINT64_C(0xffffffff)) { return result; }
    uintptr_t candidate = (uintptr_t)((bits & UINT64_C(0x3fffffffffffffff)) << 3);
    malloc_zone_t *zone = malloc_zone_from_ptr((void *)candidate);
    if (!zone || !zone->introspect || !zone->introspect->enumerator
        || !zone->introspect->force_lock || !zone->introspect->force_unlock) {
        result.status = 3; return result;
    }
    VPAllocationLookup lookup = { .target = candidate, .size = 0 };
    zone->introspect->force_lock(zone);
    kern_return_t scanned = zone->introspect->enumerator(mach_task_self(), &lookup,
        MALLOC_PTR_IN_USE_RANGE_TYPE, (vm_address_t)zone, VPReadLocalAllocation, VPRecordLocalAllocation);
    zone->introspect->force_unlock(zone);
    if (scanned != KERN_SUCCESS || lookup.size < sizeof(uintptr_t)) {
        result.status = 3; return result;
    }
    size_t actual = malloc_size((void *)candidate);
    if (actual != lookup.size) { result.status = 3; return result; }
    // 仅在allocator证明这是原allocation基址/范围后，原子读首字验证原对象回指。
    uintptr_t original = __atomic_load_n((const uintptr_t *)candidate, __ATOMIC_ACQUIRE);
    if (original != (uintptr_t)object) { result.status = 4; return result; }
    result.status = 0;
    result.allocation = candidate;
    result.bytes = actual;
#else
    (void)object;
#endif
    return result;
}
#endif
