// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#include <malloc/malloc.h>
#include <stdint.h>
#include <TargetConditionals.h>
#include <unistd.h>

#if !TARGET_OS_SIMULATOR || !TARGET_OS_TV
#error "计费探针仅允许构建为 tvOS 模拟器动态库"
#endif

// 仅替换计费查询，不替换 malloc/malloc_size；这不是真实 allocator 测试。
// 档位来自 Apple libmalloc-812.100.31 的 tvOS xzone step1 表：
// https://github.com/apple-oss-distributions/libmalloc/blob/c49dafa25f1efe8607701ae6014a663ad2ee437f/src/xzone_malloc/xzone_malloc.c#L7145-L7170
static size_t tvos_step1_good_size(size_t size) {
    static const size_t bins[] = {
        16, 32, 48, 64, 80, 96, 112, 128, 192, 256, 384, 512,
        768, 1024, 1536, 2048, 3072, 4096, 6144, 8192,
        12288, 16384, 24576, 32768
    };
    for (unsigned i = 0; i < sizeof(bins) / sizeof(bins[0]); ++i) {
        if (size <= bins[i]) return bins[i];
    }
    // 较大请求按 16KiB slice 取整；溢出时返回原请求，与 xzm_good_size 一致。
    if (size > SIZE_MAX - 16383) return size;
    return (size + 16383) & ~(size_t)16383;
}

__attribute__((used, section("__DATA,__interpose")))
static struct { const void *replacement; const void *replacee; } budget_interpose = {
    (const void *)&tvos_step1_good_size, (const void *)&malloc_good_size
};

__attribute__((constructor)) static void budget_probe_loaded(void) {
    static const char notice[] = "VPlayer 启动回归：仅模拟 tvOS xzone step1 计费取整\n";
    (void)write(STDERR_FILENO, notice, sizeof(notice) - 1);
}
