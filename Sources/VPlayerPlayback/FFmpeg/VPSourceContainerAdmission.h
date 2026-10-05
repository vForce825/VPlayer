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
