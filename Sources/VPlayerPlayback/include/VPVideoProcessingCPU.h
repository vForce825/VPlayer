// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
#ifndef VP_VIDEO_PROCESSING_CPU_H
#define VP_VIDEO_PROCESSING_CPU_H
#include <stddef.h>
#include <stdint.h>

// Allocation-free equivalents of the project's Metal YADIF and scan kernels.
// Each pointer must address at least stride * height bytes; planes may not alias
// outputs. Width is in pixels, components is 1 (Y) or 2 (interleaved UV).
// 10-bit code values use the most-significant bits of little-endian uint16 words.
int VPYADIFProcessPlane(const uint8_t *previous, size_t previousStride,
                       const uint8_t *current, size_t currentStride,
                       const uint8_t *next, size_t nextStride,
                       uint8_t *output, size_t outputStride,
                       int width, int height, int components, int bitDepth,
                       int outputIndex, int topFieldFirst, int spatialOnly);
// Disjoint output row ranges may execute concurrently. At most a fixed number
// of workers is selected by the Swift adapter; no kernel-owned queue exists.
int VPYADIFProcessPlaneRows(const uint8_t *previous, size_t previousStride,
                           const uint8_t *current, size_t currentStride,
                           const uint8_t *next, size_t nextStride,
                           uint8_t *output, size_t outputStride,
                           int width, int height, int components, int bitDepth,
                           int outputIndex, int topFieldFirst, int spatialOnly,
                           int firstRow, int rowCount);
// Same equations and compiler settings as the automatic entry point, with the
// explicit SIMD path disabled. Useful for exact parity and controlled A/B runs.
int VPYADIFProcessPlaneRowsScalar(const uint8_t *previous, size_t previousStride,
                           const uint8_t *current, size_t currentStride,
                           const uint8_t *next, size_t nextStride,
                           uint8_t *output, size_t outputStride,
                           int width, int height, int components, int bitDepth,
                           int outputIndex, int topFieldFirst, int spatialOnly,
                           int firstRow, int rowCount);
enum VPYADIFBackend { VPYADIFBackendScalar = 0, VPYADIFBackendNEON = 1 };
// Reports whether this binary includes the little-endian AArch64 NEON kernel.
int VPYADIFNEONAvailable(void);
// Diagnostic execution: Scalar forces the baseline; NEON requires at least one
// actual eight-sample synthesis block. Returns -2, with no pixel writes, when
// NEON is unavailable, valid-size plane address intervals overlap/overflow, or
// the row range has no vector work. Invalid arguments (including stride*height
// overflow) return -1. The optional caller-owned block count is
// cleared on entry, stays zero on failure/scalar, and requires a distinct slot
// per concurrent invocation. It must not alias any pixel storage. No global
// mutable state or extra buffers are used; ordinary entry points fall back.
int VPYADIFProcessPlaneRowsWithBackend(const uint8_t *previous, size_t previousStride,
                           const uint8_t *current, size_t currentStride,
                           const uint8_t *next, size_t nextStride,
                           uint8_t *output, size_t outputStride,
                           int width, int height, int components, int bitDepth,
                           int outputIndex, int topFieldFirst, int spatialOnly,
                           int firstRow, int rowCount, int requestedBackend,
                           size_t *vectorBlockCount);
int VPProbeLumaCPU(const uint8_t *current, size_t currentStride,
                   const uint8_t *previous, size_t previousStride,
                   int width, int height, int bitDepth,
                   uint64_t *combTotal, uint64_t *motionTotal);
#endif
