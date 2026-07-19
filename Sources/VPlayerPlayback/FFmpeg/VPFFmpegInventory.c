// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

#include "VPFFmpegInventory.h"

#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#pragma clang diagnostic pop

typedef struct {
    char **names;
    size_t count;
} VPFFInventory;

typedef struct {
    const char *name;
    enum AVCodecID codec_id;
} VPFFParserProbe;

static VPFFInventory vp_inventories[4];
static dispatch_once_t vp_inventory_once;

static bool vp_append_name(VPFFInventory *inventory, const char *name, size_t length) {
    if (name == NULL || length == 0 || length == SIZE_MAX ||
        inventory->count == SIZE_MAX / sizeof(*inventory->names)) {
        return false;
    }

    char *copy = malloc(length + 1);
    if (copy == NULL) {
        return false;
    }
    memcpy(copy, name, length);
    copy[length] = '\0';

    char **names = realloc(
        inventory->names,
        (inventory->count + 1) * sizeof(*inventory->names)
    );
    if (names == NULL) {
        free(copy);
        return false;
    }

    inventory->names = names;
    inventory->names[inventory->count] = copy;
    inventory->count += 1;
    return true;
}

static bool vp_append_full_name(VPFFInventory *inventory, const char *name) {
    return name != NULL && vp_append_name(inventory, name, strlen(name));
}

static int vp_compare_names(const void *left, const void *right) {
    const char *left_name = *(const char *const *)left;
    const char *right_name = *(const char *const *)right;
    return strcmp(left_name, right_name);
}

static void vp_sort_and_deduplicate(VPFFInventory *inventory) {
    if (inventory->count < 2) {
        return;
    }

    qsort(inventory->names, inventory->count, sizeof(*inventory->names), vp_compare_names);

    size_t destination = 1;
    for (size_t source = 1; source < inventory->count; source += 1) {
        if (strcmp(inventory->names[destination - 1], inventory->names[source]) == 0) {
            free(inventory->names[source]);
        } else {
            inventory->names[destination] = inventory->names[source];
            destination += 1;
        }
    }
    inventory->count = destination;
}

static void vp_collect_protocols(void) {
    void *opaque = NULL;
    const char *name = NULL;
    while ((name = avio_enum_protocols(&opaque, 0)) != NULL) {
        if (!vp_append_full_name(&vp_inventories[VPFF_COMPONENT_PROTOCOL], name)) {
            break;
        }
    }
}

static void vp_collect_demuxers(void) {
    void *opaque = NULL;
    const AVInputFormat *format = NULL;
    while ((format = av_demuxer_iterate(&opaque)) != NULL) {
        size_t canonical_name_length = strcspn(format->name, ",");
        if (!vp_append_name(
                &vp_inventories[VPFF_COMPONENT_DEMUXER],
                format->name,
                canonical_name_length
            )) {
            break;
        }
    }
}

static void vp_collect_parsers(void) {
    static const VPFFParserProbe probes[] = {
        {"aac", AV_CODEC_ID_AAC},
        {"aac_latm", AV_CODEC_ID_AAC_LATM},
        {"ac3", AV_CODEC_ID_AC3},
        {"h264", AV_CODEC_ID_H264},
        {"hevc", AV_CODEC_ID_HEVC},
        {"mpegaudio", AV_CODEC_ID_MP3},
    };

    for (size_t index = 0; index < sizeof(probes) / sizeof(probes[0]); index += 1) {
        AVCodecParserContext *parser = av_parser_init(probes[index].codec_id);
        if (parser == NULL) {
            continue;
        }
        av_parser_close(parser);
        if (!vp_append_full_name(&vp_inventories[VPFF_COMPONENT_PARSER], probes[index].name)) {
            break;
        }
    }
}

static void vp_collect_decoders(void) {
    void *opaque = NULL;
    const AVCodec *codec = NULL;
    while ((codec = av_codec_iterate(&opaque)) != NULL) {
        if (!av_codec_is_decoder(codec)) {
            continue;
        }
        if (!vp_append_full_name(&vp_inventories[VPFF_COMPONENT_DECODER], codec->name)) {
            break;
        }
    }
}

static void vp_initialize_inventories(void) {
    vp_collect_protocols();
    vp_collect_demuxers();
    vp_collect_parsers();
    vp_collect_decoders();

    for (size_t index = 0; index < sizeof(vp_inventories) / sizeof(vp_inventories[0]); index += 1) {
        vp_sort_and_deduplicate(&vp_inventories[index]);
    }
}

static const VPFFInventory *vp_inventory(VPFFComponentKind kind) {
    if (kind < VPFF_COMPONENT_PROTOCOL || kind > VPFF_COMPONENT_DECODER) {
        return NULL;
    }

    dispatch_once(&vp_inventory_once, ^{
        vp_initialize_inventories();
    });
    return &vp_inventories[kind];
}

size_t vp_ffmpeg_component_count(VPFFComponentKind kind) {
    const VPFFInventory *inventory = vp_inventory(kind);
    return inventory == NULL ? 0 : inventory->count;
}

const char *vp_ffmpeg_component_name(VPFFComponentKind kind, size_t index) {
    const VPFFInventory *inventory = vp_inventory(kind);
    if (inventory == NULL || index >= inventory->count) {
        return NULL;
    }
    return inventory->names[index];
}

const char *vp_ffmpeg_configuration(void) {
    return avcodec_configuration();
}

unsigned vp_ffmpeg_version(void) {
    return avcodec_version();
}
