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
int VPProbeLumaCPU(const uint8_t *current, size_t currentStride,
                   const uint8_t *previous, size_t previousStride,
                   int width, int height, int bitDepth,
                   uint64_t *combTotal, uint64_t *motionTotal);
#endif
