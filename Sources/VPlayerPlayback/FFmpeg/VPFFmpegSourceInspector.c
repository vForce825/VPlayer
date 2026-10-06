// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
#include "VPFFmpegSourceInspector.h"
#include "VPSourceContainerAdmission.h"
#include "VPSourceDolbyFramer.h"
#include <errno.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <string.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavformat/avformat.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/mem.h>
#include <libavutil/samplefmt.h>
#include <libavutil/time.h>
#pragma clang diagnostic pop

#define SOURCE_MAX_BYTES (8u*1024u*1024u)
#define SOURCE_MAX_TRACKS 8
#define SOURCE_MAX_SAMPLE (256u*1024u)
#define SOURCE_MAX_AU (1024u*1024u)
#define SOURCE_MAX_FILTERED_AU (SOURCE_MAX_AU+64u*1024u)
#define SOURCE_MAX_EXTRADATA (64u*1024u)
#define SOURCE_MAX_PACKETS 512
_Static_assert(VP_SOURCE_DOLBY_PADDING>=AV_INPUT_BUFFER_PADDING_SIZE,"native padding");

typedef struct { unsigned pid; size_t start,bytes,header_size,expected; uint8_t header[6]; int active,withhold; } SourceTail;
typedef struct {
    const uint8_t *bytes; size_t size,position;
    int64_t deadline;
    VPFFSourceInterrupt interrupt; void *context;
    SourceTail tails[SOURCE_MAX_TRACKS]; unsigned tail_count;
} SourceInput;
static int source_interrupt(void *opaque) {
    SourceInput *i=opaque;
    return av_gettime_relative()>=i->deadline || (i->interrupt && i->interrupt(i->context));
}
static int prepare_ts_tails(SourceInput *input,int prefix) {
    for (size_t o=0;o<input->size;o+=188) {
        const uint8_t *p=input->bytes+o; size_t head=4;
        if (p[3]&0x20) head+=1+p[4];
        if (!(p[3]&0x10) || head>=188) continue;
        unsigned pid=((p[1]&31u)<<8)|p[2]; SourceTail *tail=NULL;
        for (unsigned j=0;j<input->tail_count;j++) if (input->tails[j].pid==pid) tail=&input->tails[j];
        if (p[1]&0x40) {
            size_t available=188-head;
            int possible=p[head]==0 && (available<2 || p[head+1]==0) && (available<3 || p[head+2]==1);
            if (!possible) continue;
            if (tail && tail->active && (tail->header_size<6 || (tail->expected && tail->bytes<tail->expected))) return AVERROR_INVALIDDATA;
            if (!tail) { if (input->tail_count==SOURCE_MAX_TRACKS) return AVERROR(EFBIG); tail=&input->tails[input->tail_count++]; }
            *tail=(SourceTail){.pid=pid,.start=o,.active=1};
        }
        if (tail && tail->active) {
            size_t available=188-head, copy=6-tail->header_size;
            if (copy>available) copy=available;
            if (copy) { memcpy(tail->header+tail->header_size,p+head,copy); tail->header_size+=copy; }
            if (tail->header_size>=3 && (tail->header[0] || tail->header[1] || tail->header[2]!=1)) return AVERROR_INVALIDDATA;
            if (tail->header_size==6) { unsigned length=AV_RB16(tail->header+4); tail->expected=length?length+6:0; }
            tail->bytes+=available;
        }
    }
    for (unsigned j=0;j<input->tail_count;j++) {
        SourceTail *tail=&input->tails[j];
        int incomplete=tail->header_size<6 || (tail->expected && tail->bytes<tail->expected);
        if (incomplete && !prefix) return AVERROR_INVALIDDATA;
        tail->withhold=prefix && (incomplete || !tail->expected);
    }
    return 0;
}
static int source_read(void *opaque,uint8_t *buffer,int capacity) {
    SourceInput *input=opaque;
    if (source_interrupt(input)) return AVERROR_EXIT;
    if (input->position>=input->size) return AVERROR_EOF;
    size_t count=input->size-input->position;
    if (count>(size_t)capacity) count=(size_t)capacity;
    if (!input->tail_count) memcpy(buffer,input->bytes+input->position,count);
    else {
        size_t copied=0;
        while (copied<count) {
            size_t absolute=input->position+copied, packet=absolute-absolute%188, within=absolute%188;
            size_t amount=188-within; if (amount>count-copied) amount=count-copied;
            unsigned pid=((input->bytes[packet+1]&31u)<<8)|input->bytes[packet+2]; int withheld=0;
            for (unsigned j=0;j<input->tail_count;j++) if (input->tails[j].pid==pid && input->tails[j].withhold && packet>=input->tails[j].start) withheld=1;
            if (!withheld) memcpy(buffer+copied,input->bytes+absolute,amount);
            else for (size_t j=0;j<amount;j++) { size_t k=within+j; buffer[copied+j]=k==0?0x47:k==1?0x1f:k==2?0xff:k==3?0x10:0xff; }
            copied+=amount;
        }
    }
    input->position+=count; return (int)count;
}
static int64_t source_seek(void *opaque,int64_t offset,int whence) {
    SourceInput *i=opaque;
    if (source_interrupt(i)) return AVERROR_EXIT;
    if (whence==AVSEEK_SIZE) return (int64_t)i->size;
    whence&=~AVSEEK_FORCE;
    int64_t base=whence==SEEK_SET?0:whence==SEEK_CUR?(int64_t)i->position:whence==SEEK_END?(int64_t)i->size:-1;
    if (base<0 || offset < -base || offset>(int64_t)i->size-base) return AVERROR(EINVAL);
    i->position=(size_t)(base+offset); return (int64_t)i->position;
}
static int deny_io(AVFormatContext *f,AVIOContext **io,const char *url,int flags,AVDictionary **options) {
    (void)f;(void)io;(void)url;(void)flags;(void)options; return AVERROR(EACCES);
}
static pthread_once_t log_once=PTHREAD_ONCE_INIT;
static void silent_log(void *context,int level,const char *format,va_list args) { (void)context;(void)level;(void)format;(void)args; }
static void install_log(void) { av_log_set_callback(silent_log); }
static VPFFCodec source_codec(enum AVCodecID codec) {
    switch(codec) {
    case AV_CODEC_ID_H264:return VPFF_CODEC_H264; case AV_CODEC_ID_HEVC:return VPFF_CODEC_HEVC;
    case AV_CODEC_ID_AAC:return VPFF_CODEC_AAC; case AV_CODEC_ID_AC3:return VPFF_CODEC_AC3; case AV_CODEC_ID_EAC3:return VPFF_CODEC_EAC3;
    case AV_CODEC_ID_MP1:return VPFF_CODEC_MP1; case AV_CODEC_ID_MP2:return VPFF_CODEC_MP2; case AV_CODEC_ID_MP3:return VPFF_CODEC_MP3;
    default:return VPFF_CODEC_UNSUPPORTED;
    }
}
static int field_order(enum AVFieldOrder value) { return value==AV_FIELD_PROGRESSIVE?1:value==AV_FIELD_UNKNOWN?0:2; }
typedef enum { REPRESENTATION_UNSET, REPRESENTATION_ANNEX_B, REPRESENTATION_LENGTH_PREFIXED } SourceRepresentation;
typedef struct {
    VPFFSourceTrack facts;
    AVBSFContext *bsf; AVCodecParserContext *parser; AVCodecContext *codec;
    SourceRepresentation representation; unsigned length_size;
    size_t parameter_cache;
    uint8_t *sample,*header,*adts,*format_sample;
    size_t header_size,header_zeros,adts_size,adts_expected,format_size;
    int header_active,header_collect; unsigned header_count,format_frames;
    size_t header_offsets[64],header_lengths[64];
    VPSourceDolbyFramer *dolby;
    int64_t audio_next_pts; int audio_pts_known;
    int audio_format_seen; int32_t audio_profile,audio_rate,audio_channels;
    AVRational packet_rate, rate_time_base; unsigned packet_rate_count; int packet_rate_conflict, packet_rate_quantized;
    uint32_t minimum_delta,maximum_delta;
    int64_t video_last_dts; int video_has_dts;
} SourceTrack;

static int config_unit(const uint8_t *p,size_t size,size_t *position,size_t *expanded,int hevc,unsigned type) {
    if (size-*position<2) return AVERROR_INVALIDDATA;
    size_t length=AV_RB16(p+*position); *position+=2;
    if (length<(hevc?2u:1u) || length>size-*position || length+4>SOURCE_MAX_EXTRADATA-*expanded) return AVERROR_INVALIDDATA;
    unsigned observed=hevc?((p[*position]>>1)&63):(p[*position]&31);
    if (observed!=type || p[*position]&0x80 || (hevc && !(p[*position+1]&7))) return AVERROR_INVALIDDATA;
    *expanded+=length+4; *position+=length; return 0;
}
/* Admitted configurations are a canonical subset of the actual pinned filter
 * predicates. Never infer Annex B from extradata[0] != 1. */
static int classify_representation(SourceTrack *track,const AVCodecParameters *par) {
    const uint8_t *p=par->extradata; size_t n=(size_t)par->extradata_size;
    if (!n || (n>=3 && AV_RB24(p)==1) || (n>=4 && AV_RB32(p)==1)) { track->representation=REPRESENTATION_ANNEX_B; return 0; }
    if (p[0]!=1) return AVERROR_INVALIDDATA;
    size_t position,expanded=0;
    if (par->codec_id==AV_CODEC_ID_H264) {
        if (n<7 || (p[4]&0xfc)!=0xfc || (p[5]&0xe0)!=0xe0) return AVERROR_INVALIDDATA;
        track->length_size=(p[4]&3)+1; position=6;
        unsigned count=p[5]&31;
        for (unsigned i=0;i<count;i++) if (config_unit(p,n,&position,&expanded,0,7)<0) return AVERROR_INVALIDDATA;
        if (position>=n) return AVERROR_INVALIDDATA;
        count=p[position++];
        for (unsigned i=0;i<count;i++) if (config_unit(p,n,&position,&expanded,0,8)<0) return AVERROR_INVALIDDATA;
        if (position<n) {
            if (n-position<4 || (p[position]&0xfc)!=0xfc || (p[position+1]&0xf8)!=0xf8 || (p[position+2]&0xf8)!=0xf8) return AVERROR_INVALIDDATA;
            count=p[position+3]; position+=4;
            size_t ignored=0;
            for (unsigned i=0;i<count;i++) if (config_unit(p,n,&position,&ignored,0,13)<0) return AVERROR_INVALIDDATA;
        }
    } else {
        if (n<23 || (p[13]&0xf0)!=0xf0 || (p[15]&0xfc)!=0xfc || (p[16]&0xfc)!=0xfc ||
            (p[17]&0xf8)!=0xf8 || (p[18]&0xf8)!=0xf8) return AVERROR_INVALIDDATA;
        track->length_size=(p[21]&3)+1; position=23;
        for (unsigned i=0;i<p[22];i++) {
            if (n-position<3) return AVERROR_INVALIDDATA;
            unsigned type=p[position]&63, count=AV_RB16(p+position+1); position+=3;
            if (!(type==32 || type==33 || type==34 || type==39 || type==40)) return AVERROR_INVALIDDATA;
            for (unsigned j=0;j<count;j++) if (config_unit(p,n,&position,&expanded,1,type)<0) return AVERROR_INVALIDDATA;
        }
    }
    if (position!=n || track->length_size==3) return AVERROR_INVALIDDATA;
    track->parameter_cache=expanded; track->representation=REPRESENTATION_LENGTH_PREFIXED; return 0;
}
static int admit_bsf_packet(SourceTrack *track,const AVPacket *packet,size_t *admitted) {
    size_t extra=0;
    if (av_packet_get_side_data(packet,AV_PKT_DATA_NEW_EXTRADATA,&extra)) return AVERROR_INVALIDDATA;
    if (packet->size<=0 || packet->size>(int)SOURCE_MAX_AU) return AVERROR(EFBIG);
    if (track->representation==REPRESENTATION_ANNEX_B) { *admitted=(size_t)packet->size; return 0; }
    if (track->representation!=REPRESENTATION_LENGTH_PREFIXED) return AVERROR_INVALIDDATA;
    size_t o=0,total=0,nals=0,cache=track->parameter_cache,n=(size_t)packet->size;
    while (o<n) {
        if (n-o<track->length_size) return AVERROR_INVALIDDATA;
        uint32_t length=0; for (unsigned i=0;i<track->length_size;i++) length=(length<<8)|packet->data[o++];
        if (length<(track->facts.codec==VPFF_CODEC_HEVC?2u:1u) || length>n-o || length+4>SOURCE_MAX_FILTERED_AU-total) return AVERROR_INVALIDDATA;
        unsigned type=packet->data[o]&31;
        if (track->facts.codec==VPFF_CODEC_H264 && (type==7 || type==8)) {
            if (length+4>SOURCE_MAX_EXTRADATA-cache) return AVERROR(EFBIG);
            cache+=length+4;
        }
        total+=length+4; nals++; o+=length;
    }
    if (track->facts.codec==VPFF_CODEC_H264) {
        /* Pinned AVC can inject at repeated insertion sites in one packet.
         * Charge the full cumulative SPS/PPS cache for EVERY admitted NAL. */
        if (cache && nals>(SOURCE_MAX_FILTERED_AU-total)/cache) return AVERROR(EFBIG);
        total+=nals*cache;
    } else {
        /* Pinned HEVC got_ps/got_irap state is monotonic per packet: at most one injection. */
        if (cache>SOURCE_MAX_FILTERED_AU-total) return AVERROR(EFBIG);
        total+=cache;
    }
    track->parameter_cache=cache; *admitted=total; return 0;
}

static int finish_header(SourceTrack *track) {
    if (!track->header_collect || !track->header_size) return 0;
    for (unsigned i=0;i<track->header_count;i++)
        if (track->header_lengths[i]==track->header_size && !memcmp(track->sample+track->header_offsets[i],track->header,track->header_size)) return 0;
    if (track->header_count==64 || track->header_size+4>SOURCE_MAX_SAMPLE-track->facts.sample_size) return AVERROR(EFBIG);
    if (!track->sample) { track->sample=av_mallocz(SOURCE_MAX_SAMPLE+AV_INPUT_BUFFER_PADDING_SIZE); if (!track->sample) return AVERROR(ENOMEM); }
    size_t o=track->facts.sample_size;
    AV_WB32(track->sample+o,1); memcpy(track->sample+o+4,track->header,track->header_size);
    track->header_offsets[track->header_count]=o+4; track->header_lengths[track->header_count++]=track->header_size;
    track->facts.sample=track->sample; track->facts.sample_size+=track->header_size+4; return 0;
}
static int parameter_bytes(SourceTrack *track,const uint8_t *bytes,size_t size) {
    for (size_t i=0;i<size;i++) {
        uint8_t byte=bytes[i];
        if (!byte) { track->header_zeros++; continue; }
        if (byte==1 && track->header_zeros>=2) {
            int r=finish_header(track); if (r<0) return r;
            track->header_active=1; track->header_collect=0; track->header_size=0; track->header_zeros=0; continue;
        }
        if (track->header_active && !track->header_size) {
            unsigned kind=track->facts.codec==VPFF_CODEC_H264?byte&31:(byte>>1)&63;
            track->header_collect=track->facts.codec==VPFF_CODEC_H264?(kind==7 || kind==8):(kind>=32 && kind<=34);
            if (track->header_collect && !track->header) { track->header=av_malloc(SOURCE_MAX_EXTRADATA); if (!track->header) return AVERROR(ENOMEM); }
            /* The first header byte is nonzero for admitted parameter types. */
            track->header_size=1;
            if (track->header_collect) track->header[0]=byte;
        } else if (track->header_collect) {
            if (track->header_zeros>=SOURCE_MAX_EXTRADATA-track->header_size) return AVERROR(EFBIG);
            memset(track->header+track->header_size,0,track->header_zeros); track->header_size+=track->header_zeros;
            track->header[track->header_size++]=byte;
        }
        track->header_zeros=0;
    }
    return 0;
}
static int audio_sample(SourceTrack *track,const uint8_t *bytes,size_t size) {
    if (track->facts.sample_size) return 0;
    if (!size || size>SOURCE_MAX_SAMPLE) return AVERROR(EFBIG);
    track->sample=av_mallocz(size+AV_INPUT_BUFFER_PADDING_SIZE);
    if (!track->sample) return AVERROR(ENOMEM);
    memcpy(track->sample,bytes,size); track->facts.sample=track->sample; track->facts.sample_size=size; return 0;
}
static int audio_format(SourceTrack *track,int profile,int rate,int channels) {
    if (track->audio_format_seen && (track->audio_profile!=profile || track->audio_rate!=rate || track->audio_channels!=channels)) return AVERROR_INVALIDDATA;
    if ((track->facts.sample_rate>0 && track->facts.sample_rate!=rate) || (track->facts.channels>0 && track->facts.channels!=channels)) return AVERROR_INVALIDDATA;
    track->audio_format_seen=1; track->audio_profile=profile; track->audio_rate=rate; track->audio_channels=channels;
    track->facts.profile=profile; track->facts.sample_rate=rate; track->facts.channels=channels; return 0;
}
static void audio_timing(SourceTrack *track,const AVPacket *packet,AVRational time_base,int rate,int samples,int64_t before,int crossed) {
    track->facts.observed_audio_packets++;
    if (crossed || packet->pts==AV_NOPTS_VALUE || rate<=0 || time_base.num<=0 || time_base.den<=0 || (packet->flags&AV_PKT_FLAG_CORRUPT)) {
        track->facts.invalid_audio_timestamps++; track->audio_pts_known=0; return;
    }
    int64_t delta=av_rescale_q(before,(AVRational){1,rate},time_base);
    if (delta<0 || packet->pts>INT64_MAX-delta) { track->facts.invalid_audio_timestamps++; track->audio_pts_known=0; return; }
    int64_t pts=packet->pts+delta;
    if (track->audio_pts_known && ((pts<track->audio_next_pts && pts+1<track->audio_next_pts) || (pts>track->audio_next_pts && pts-1>track->audio_next_pts))) track->facts.invalid_audio_timestamps++;
    int64_t duration=av_rescale_q(samples,(AVRational){1,rate},time_base);
    if (duration<=0 || pts>INT64_MAX-duration) { track->facts.invalid_audio_timestamps++; track->audio_pts_known=0; return; }
    track->audio_next_pts=pts+duration; track->audio_pts_known=1;
}
typedef struct { SourceTrack *track; const AVPacket *packet; AVRational time_base; SourceInput *input; int64_t samples; int crossed; } AudioPacket;
static int dolby_frame(void *opaque,const uint8_t *data,size_t size,const VPSourceDolbyFrameInfo *info,size_t offset) {
    AudioPacket *packet=opaque; SourceTrack *track=packet->track;
    if (source_interrupt(packet->input)) return AVERROR_EXIT;
    if (audio_format(track,info->bsid,info->sample_rate,info->channels)<0) return AVERROR_INVALIDDATA;
    if (info->stream_type==1) track->facts.is_dependent=1;
    if (info->substream_id || info->stream_type==2 || (!track->dolby->enhanced && info->bsmod<0)) track->facts.has_unclassified_role=1;
    if (info->bsmod>0) track->facts.is_commentary=1;
    if (offset==SIZE_MAX) packet->crossed=1;
    audio_timing(track,packet->packet,packet->time_base,info->sample_rate,info->sample_count,packet->samples,packet->crossed);
    packet->samples+=info->sample_count;
    return audio_sample(track,data,size);
}
static int adts_header(const uint8_t *p,size_t *size,int *rate,int *channels,int *profile) {
    static const int rates[13]={96000,88200,64000,48000,44100,32000,24000,22050,16000,12000,11025,8000,7350};
    static const int counts[8]={0,1,2,3,4,5,6,8};
    if (p[0]!=255 || (p[1]&0xf6)!=0xf0 || (p[6]&3)) return AVERROR_INVALIDDATA;
    unsigned frequency=(p[2]>>2)&15, layout=((p[2]&1)<<2)|(p[3]>>6);
    if (frequency>=13 || !layout) return AVERROR_INVALIDDATA;
    size_t length=((size_t)(p[3]&3)<<11)|((size_t)p[4]<<3)|(p[5]>>5);
    if (length<((p[1]&1)?7u:9u) || length>8191) return AVERROR_INVALIDDATA;
    *size=length; *rate=rates[frequency]; *channels=counts[layout]; *profile=p[2]>>6; return 0;
}
static int adts_packet(SourceTrack *track,const AVPacket *packet,AVRational time_base,SourceInput *input) {
    if (!track->adts) { track->adts=av_mallocz(8192+AV_INPUT_BUFFER_PADDING_SIZE); if (!track->adts) return AVERROR(ENOMEM); }
    size_t position=0; int crossed=track->adts_size!=0; int64_t samples=0;
    while (position<(size_t)packet->size) {
        if (source_interrupt(input)) return AVERROR_EXIT;
        size_t target=track->adts_expected?track->adts_expected:7, amount=target-track->adts_size;
        if (amount>(size_t)packet->size-position) amount=(size_t)packet->size-position;
        memcpy(track->adts+track->adts_size,packet->data+position,amount); track->adts_size+=amount; position+=amount;
        int rate,channels,profile; size_t expected;
        if (track->adts_size>=7 && !track->adts_expected) {
            if (adts_header(track->adts,&expected,&rate,&channels,&profile)<0 || audio_format(track,profile,rate,channels)<0) return AVERROR_INVALIDDATA;
            track->adts_expected=expected;
        }
        if (track->adts_expected && track->adts_size==track->adts_expected) {
            if (audio_sample(track,track->adts,track->adts_size)<0) return AVERROR(ENOMEM);
            audio_timing(track,packet,time_base,track->audio_rate,1024,samples,crossed); samples+=1024;
            if (track->format_frames<8 && track->audio_profile==1) {
                if (track->adts_size>65536-track->format_size) return AVERROR(EFBIG);
                if (!track->format_sample) { track->format_sample=av_mallocz(65536+AV_INPUT_BUFFER_PADDING_SIZE); if (!track->format_sample) return AVERROR(ENOMEM); }
                memcpy(track->format_sample+track->format_size,track->adts,track->adts_size);
                track->format_size+=track->adts_size; track->format_frames++;
            }
            track->adts_size=track->adts_expected=0;
        }
    }
    return 0;
}
static void record_video_delta(SourceTrack *track,uint32_t delta,AVRational time_base) {
    if (!delta || time_base.num<=0 || time_base.den<=0) return;
    if (!track->packet_rate_count) { track->minimum_delta=track->maximum_delta=delta; track->rate_time_base=time_base; }
    else if (av_cmp_q(track->rate_time_base,time_base)) track->packet_rate_conflict=1;
    if (delta<track->minimum_delta) track->minimum_delta=delta;
    if (delta>track->maximum_delta) track->maximum_delta=delta;
    if (track->maximum_delta-track->minimum_delta>1) track->packet_rate_conflict=1;
    else if (track->maximum_delta!=track->minimum_delta) track->packet_rate_quantized=1;
    av_reduce(&track->packet_rate.num,&track->packet_rate.den,time_base.den,(int64_t)time_base.num*delta,INT32_MAX);
    track->packet_rate_count++;
}
static void packet_video_rate(SourceTrack *track,const AVPacket *packet,AVRational time_base) {
    if (packet->duration>0 && packet->duration<=INT32_MAX) record_video_delta(track,(uint32_t)packet->duration,time_base);
}
static void frame_video_rate(SourceTrack *track,int64_t dts,AVRational time_base) {
    if (dts==AV_NOPTS_VALUE) { track->video_has_dts=0; return; }
    uint64_t delta=(uint64_t)dts-(uint64_t)track->video_last_dts;
    if (track->video_has_dts && dts>track->video_last_dts && delta<=INT32_MAX) record_video_delta(track,(uint32_t)delta,time_base);
    else if (track->video_has_dts) track->packet_rate_conflict=1;
    track->video_last_dts=dts; track->video_has_dts=1;
}
static int consume_video(SourceTrack *track,const AVPacket *packet,SourceInput *input) {
    int result=parameter_bytes(track,packet->data,(size_t)packet->size);
    if (result<0 || !track->parser) return result;
    const uint8_t *p=packet->data; int remaining=packet->size; unsigned attempts=0;
    while (remaining>0) {
        if (source_interrupt(input)) return AVERROR_EXIT;
        if (++attempts>1024) return AVERROR(EFBIG);
        uint8_t *out=NULL; int size=0;
        int used=av_parser_parse2(track->parser,track->codec,&out,&size,p,remaining,packet->pts,packet->dts,packet->pos);
        if (used<0 || used>remaining || (!used && !size)) return AVERROR_INVALIDDATA;
        if (size>0) {
            frame_video_rate(track,track->parser->dts,track->bsf->time_base_out);
            if (track->parser->field_order==AV_FIELD_PROGRESSIVE) track->facts.progressive_frames++;
            else if (track->parser->field_order!=AV_FIELD_UNKNOWN || track->parser->picture_structure==AV_PICTURE_STRUCTURE_TOP_FIELD || track->parser->picture_structure==AV_PICTURE_STRUCTURE_BOTTOM_FIELD) track->facts.interlaced_frames++;
        }
        p+=used; remaining-=used;
    }
    return 0;
}

int32_t vp_ffmpeg_inspect_source_bytes(const uint8_t *bytes,size_t size,int64_t timeout_us,
    VPFFSourceInterrupt interrupt,VPFFSourceTrackCallback callback,void *context,int32_t *kind) {
    return vp_ffmpeg_inspect_source_bytes_with_completeness(bytes,size,0,timeout_us,interrupt,callback,context,kind);
}
int32_t vp_ffmpeg_inspect_source_bytes_with_completeness(const uint8_t *bytes,size_t size,int32_t prefix,int64_t timeout_us,
    VPFFSourceInterrupt interrupt,VPFFSourceTrackCallback callback,void *context,int32_t *kind) {
    if (!callback || !kind || timeout_us<=0 || timeout_us>10000000) return AVERROR(EINVAL);
    SourceInput input={.bytes=bytes,.size=size,.deadline=av_gettime_relative()+timeout_us,.interrupt=interrupt,.context=context};
    size_t usable=0;
    int result=vp_source_admit_container_with_interrupt(bytes,size,!!prefix,kind,&usable,source_interrupt,&input);
    if (result<0) return result;
    input.size=usable;
    if (*kind==1 && (result=prepare_ts_tails(&input,!!prefix))<0) return result;
    if (source_interrupt(&input)) return AVERROR_EXIT;
    pthread_once(&log_once,install_log);
    AVFormatContext *format=avformat_alloc_context(); AVIOContext *io=NULL;
    AVPacket *packet=NULL,*filtered=NULL; AVDictionary *options=NULL;
    SourceTrack *tracks=av_calloc(SOURCE_MAX_TRACKS,sizeof(*tracks));
    uint8_t *buffer=av_malloc(32768);
    if (!format || !tracks || !buffer) { av_free(buffer); result=AVERROR(ENOMEM); goto cleanup; }
    io=avio_alloc_context(buffer,32768,0,&input,source_read,NULL,source_seek);
    if (!io) { av_free(buffer); result=AVERROR(ENOMEM); goto cleanup; }
    io->seekable=*kind==1?0:AVIO_SEEKABLE_NORMAL;
    format->pb=io; format->flags|=AVFMT_FLAG_CUSTOM_IO|AVFMT_FLAG_NOPARSE|AVFMT_FLAG_NOFILLIN;
    format->interrupt_callback=(AVIOInterruptCB){source_interrupt,&input}; format->io_open=deny_io;
    format->max_streams=SOURCE_MAX_TRACKS; format->probesize=32768; format->format_probesize=2048;
    format->max_analyze_duration=0; format->max_index_size=1024*1024; format->max_picture_buffer=SOURCE_MAX_BYTES;
    av_dict_set(&options,"protocol_whitelist","",0); av_dict_set(&options,"codec_whitelist","",0);
    if (*kind==1) { av_dict_set(&options,"max_packet_size","262144",0); av_dict_set(&options,"resync_size","188",0); av_dict_set(&options,"scan_all_pmts","0",0); }
    else { av_dict_set(&options,"ignore_editlist","1",0); av_dict_set(&options,"use_mfra_for","0",0); }
    const AVInputFormat *input_format=av_find_input_format(*kind==1?"mpegts":"mov");
    if (!input_format) { result=AVERROR_DEMUXER_NOT_FOUND; goto cleanup; }
    result=avformat_open_input(&format,NULL,input_format,&options); av_dict_free(&options);
    if (result<0) goto cleanup;
    if (!format->nb_streams || format->nb_streams>SOURCE_MAX_TRACKS) { result=AVERROR(EFBIG); goto cleanup; }
    unsigned track_count=format->nb_streams;
    int audio_count=0;
    for (unsigned i=0;i<format->nb_streams;i++) if (format->streams[i]->codecpar->codec_type==AVMEDIA_TYPE_AUDIO) audio_count++;
    for (unsigned i=0;i<format->nb_streams;i++) {
        AVStream *stream=format->streams[i]; AVCodecParameters *par=stream->codecpar; SourceTrack *track=&tracks[i];
        if (source_interrupt(&input)) { result=AVERROR_EXIT; goto cleanup; }
        if (par->extradata_size<0 || par->extradata_size>(int)SOURCE_MAX_EXTRADATA) { result=AVERROR(EFBIG); goto cleanup; }
        for (int j=0;j<par->nb_coded_side_data;j++) {
            enum AVPacketSideDataType type=par->coded_side_data[j].type;
            if (type==AV_PKT_DATA_ENCRYPTION_INFO || type==AV_PKT_DATA_ENCRYPTION_INIT_INFO || type==AV_PKT_DATA_NEW_EXTRADATA) { result=AVERROR_INVALIDDATA; goto cleanup; }
        }
        track->facts=(VPFFSourceTrack){.stream_index=(int32_t)i,
            .media_type=par->codec_type==AVMEDIA_TYPE_VIDEO?1:par->codec_type==AVMEDIA_TYPE_AUDIO?2:0,
            .codec=source_codec(par->codec_id),.profile=par->profile,.sample_entry=*kind==1?0:par->codec_tag,
            .width=par->width,.height=par->height,.color_primaries=par->color_primaries,.color_transfer=par->color_trc,.color_matrix=par->color_space,
            .parser_color_primaries=AVCOL_PRI_UNSPECIFIED,.parser_color_transfer=AVCOL_TRC_UNSPECIFIED,.parser_color_matrix=AVCOL_SPC_UNSPECIFIED,
            .sample_rate=par->sample_rate,.channels=par->ch_layout.nb_channels,
            .channel_mask=par->ch_layout.order==AV_CHANNEL_ORDER_NATIVE?par->ch_layout.u.mask:0,
            .container_field_order=field_order(par->field_order),.audio_stream_count=audio_count,
            .is_default=!!(stream->disposition&AV_DISPOSITION_DEFAULT),.is_dependent=!!(stream->disposition&AV_DISPOSITION_DEPENDENT),
            .is_commentary=!!(stream->disposition&(AV_DISPOSITION_COMMENT|AV_DISPOSITION_VISUAL_IMPAIRED|AV_DISPOSITION_HEARING_IMPAIRED)),
            .extradata=par->extradata,.extradata_size=(size_t)par->extradata_size};
        if (par->initial_padding>0 || par->trailing_padding>0) {
            track->facts.has_explicit_priming=1;
            track->facts.leading_samples=par->initial_padding>0?(uint32_t)par->initial_padding:0;
            track->facts.trailing_samples=par->trailing_padding>0?(uint32_t)par->trailing_padding:0;
        }
        if (av_dict_get(stream->metadata,"role",NULL,0) || av_dict_get(stream->metadata,"service",NULL,0) || av_dict_get(stream->metadata,"audio_service_type",NULL,0)) track->facts.has_unclassified_role=1;
        if (par->codec_id==AV_CODEC_ID_H264 || par->codec_id==AV_CODEC_ID_HEVC) {
            if ((result=classify_representation(track,par))<0) goto cleanup;
            const AVBitStreamFilter *filter=av_bsf_get_by_name(par->codec_id==AV_CODEC_ID_H264?"h264_mp4toannexb":"hevc_mp4toannexb");
            if (!filter) { result=AVERROR_BSF_NOT_FOUND; goto cleanup; }
            if ((result=av_bsf_alloc(filter,&track->bsf))<0 || (result=avcodec_parameters_copy(track->bsf->par_in,par))<0) goto cleanup;
            track->bsf->time_base_in=stream->time_base;
            if ((result=av_bsf_init(track->bsf))<0) goto cleanup;
            if (track->bsf->par_out->extradata_size>0 && (result=parameter_bytes(track,track->bsf->par_out->extradata,(size_t)track->bsf->par_out->extradata_size))<0) goto cleanup;
            if (par->codec_id==AV_CODEC_ID_H264) {
                /* Pinned AVC rejects FMO; SPS/PPS tables are fixed. No native
                 * HEVC parser or pixel decoder is opened in this phase. */
                track->parser=av_parser_init(par->codec_id); track->codec=avcodec_alloc_context3(NULL);
                if (!track->parser || !track->codec) { result=AVERROR(ENOMEM); goto cleanup; }
                if ((result=avcodec_parameters_to_context(track->codec,track->bsf->par_out))<0) goto cleanup;
                track->codec->color_primaries=AVCOL_PRI_UNSPECIFIED; track->codec->color_trc=AVCOL_TRC_UNSPECIFIED; track->codec->colorspace=AVCOL_SPC_UNSPECIFIED;
            }
        } else if (par->codec_id==AV_CODEC_ID_AC3 || par->codec_id==AV_CODEC_ID_EAC3) {
            track->dolby=av_malloc(sizeof(*track->dolby));
            if (!track->dolby) { result=AVERROR(ENOMEM); goto cleanup; }
            vp_source_dolby_init(track->dolby,par->codec_id==AV_CODEC_ID_EAC3);
        }
    }
    packet=av_packet_alloc(); filtered=av_packet_alloc();
    if (!packet || !filtered) { result=AVERROR(ENOMEM); goto cleanup; }
    size_t packet_bytes=0,elementary_bytes=0; int reached_eof=0;
    for (unsigned read=0;read<SOURCE_MAX_PACKETS;read++) {
        if (source_interrupt(&input)) { result=AVERROR_EXIT; goto cleanup; }
        result=av_read_frame(format,packet);
        if (result==AVERROR_EOF) { reached_eof=1; break; }
        if (result<0) goto cleanup;
        if (format->nb_streams!=track_count || packet->stream_index<0 || (unsigned)packet->stream_index>=format->nb_streams || packet->size<=0 ||
            packet->size>(int)SOURCE_MAX_AU || (size_t)packet->size>SOURCE_MAX_BYTES-packet_bytes || (packet->flags&AV_PKT_FLAG_CORRUPT)) { result=AVERROR_INVALIDDATA; goto cleanup; }
        packet_bytes+=(size_t)packet->size;
        SourceTrack *track=&tracks[packet->stream_index]; AVStream *stream=format->streams[packet->stream_index];
        for (int j=0;j<packet->side_data_elems;j++) {
            enum AVPacketSideDataType type=packet->side_data[j].type;
            if (type==AV_PKT_DATA_ENCRYPTION_INFO || type==AV_PKT_DATA_ENCRYPTION_INIT_INFO || type==AV_PKT_DATA_NEW_EXTRADATA) { result=AVERROR_INVALIDDATA; goto cleanup; }
        }
        size_t skip_size=0; uint8_t *skip=av_packet_get_side_data(packet,AV_PKT_DATA_SKIP_SAMPLES,&skip_size);
        if (skip) {
            if (skip_size<10) { result=AVERROR_INVALIDDATA; goto cleanup; }
            track->facts.has_explicit_priming=1;
            track->facts.leading_samples=AV_RL32(skip); track->facts.trailing_samples=AV_RL32(skip+4);
        }
        size_t admitted=(size_t)packet->size;
        if (track->bsf && (result=admit_bsf_packet(track,packet,&admitted))<0) goto cleanup;
        /* Expanded elementary allowance is charged BEFORE native BSF allocation. */
        if (admitted>SOURCE_MAX_BYTES-elementary_bytes) { result=AVERROR(EFBIG); goto cleanup; }
        elementary_bytes+=admitted;
        if (track->bsf) {
            packet_video_rate(track,packet,stream->time_base);
            if ((result=av_bsf_send_packet(track->bsf,packet))<0) goto cleanup;
            while ((result=av_bsf_receive_packet(track->bsf,filtered))>=0) {
                if (filtered->size<=0 || (size_t)filtered->size>admitted) { result=AVERROR_INVALIDDATA; goto cleanup; }
                if ((result=consume_video(track,filtered,&input))<0) goto cleanup;
                av_packet_unref(filtered);
            }
            if (result!=AVERROR(EAGAIN) && result!=AVERROR_EOF) goto cleanup;
        } else if (track->dolby) {
            AudioPacket audio={.track=track,.packet=packet,.time_base=stream->time_base,.input=&input};
            if ((result=vp_source_dolby_append(track->dolby,packet->data,(size_t)packet->size,dolby_frame,&audio))<0) goto cleanup;
        } else if (track->facts.codec==VPFF_CODEC_AAC && !track->facts.extradata_size) {
            if ((result=adts_packet(track,packet,stream->time_base,&input))<0) goto cleanup;
        } else if (track->facts.media_type==2) {
            if ((result=audio_sample(track,packet->data,(size_t)packet->size))<0) goto cleanup;
            track->facts.observed_audio_packets++;
            if (packet->pts==AV_NOPTS_VALUE) track->facts.invalid_audio_timestamps++;
        }
        av_packet_unref(packet);
    }
    if (source_interrupt(&input)) { result=AVERROR_EXIT; goto cleanup; }
    for (unsigned i=0;i<format->nb_streams;i++) {
        SourceTrack *track=&tracks[i];
        if (track->dolby && vp_source_dolby_finish(track->dolby,reached_eof && !prefix)<0) { result=AVERROR_INVALIDDATA; goto cleanup; }
        if (track->adts_size && reached_eof && !prefix) { result=AVERROR_INVALIDDATA; goto cleanup; }
        if ((track->dolby && track->dolby->pending_size) || track->adts_size) { track->facts.invalid_audio_timestamps++; track->facts.has_unclassified_role=1; }
        if ((result=finish_header(track))<0) goto cleanup;
        if (track->codec) {
            track->facts.parser_width=track->codec->width; track->facts.parser_height=track->codec->height;
            track->facts.parser_color_primaries=track->codec->color_primaries; track->facts.parser_color_transfer=track->codec->color_trc; track->facts.parser_color_matrix=track->codec->colorspace;
        }
        if (track->facts.frame_rate_num<=0 && track->packet_rate_count>=2 && !track->packet_rate_conflict && !track->packet_rate_quantized) {
            track->facts.frame_rate_num=track->packet_rate.num; track->facts.frame_rate_den=track->packet_rate.den;
        }
        track->facts.video_timing_conflict=track->packet_rate_conflict;
        track->facts.audio_format_sample=track->format_sample; track->facts.audio_format_sample_size=track->format_size;
    }
    for (unsigned i=0;i<format->nb_streams;i++) callback(context,&tracks[i].facts);
    result=0;
cleanup:
    av_dict_free(&options); av_packet_free(&packet); av_packet_free(&filtered);
    if (tracks) for (unsigned i=0;i<SOURCE_MAX_TRACKS;i++) {
        av_bsf_free(&tracks[i].bsf); if (tracks[i].parser) av_parser_close(tracks[i].parser); avcodec_free_context(&tracks[i].codec);
        av_free(tracks[i].sample); av_free(tracks[i].header); av_free(tracks[i].adts); av_free(tracks[i].format_sample); av_free(tracks[i].dolby);
    }
    av_free(tracks); avformat_close_input(&format);
    if (io) { av_freep(&io->buffer); avio_context_free(&io); }
    return result;
}

typedef struct { SourceInput input; size_t requested_output; } AACBudget;
static int aac_get_buffer(AVCodecContext *codec,AVFrame *frame,int flags) {
    AACBudget *budget=codec->opaque;
    if (source_interrupt(&budget->input)) return AVERROR_EXIT;
    int channels=frame->ch_layout.nb_channels, bytes=av_get_bytes_per_sample((enum AVSampleFormat)frame->format);
    if (channels<1 || channels>8 || frame->nb_samples<1 || frame->nb_samples>2048 || bytes<1 || bytes>8) return AVERROR(EFBIG);
    size_t requested=(size_t)channels*(size_t)frame->nb_samples*(size_t)bytes+4096;
    if (requested>1024u*1024u-budget->requested_output) return AVERROR(EFBIG);
    budget->requested_output+=requested;
    return avcodec_default_get_buffer2(codec,frame,flags);
}
int32_t vp_ffmpeg_inspect_adts_format(const uint8_t *bytes,size_t size,int64_t timeout_us,
    VPFFSourceInterrupt interrupt,void *context,VPFFSourceAACFormat *out) {
    if (!bytes || !out || !size || size>65536 || timeout_us<=0 || timeout_us>500000) return AVERROR(EINVAL);
    memset(out,0,sizeof(*out));
    AACBudget budget={.input={.deadline=av_gettime_relative()+timeout_us,.interrupt=interrupt,.context=context}};
    size_t offsets[8],sizes[8],position=0; unsigned packets=0;
    int expected_rate=0,expected_channels=0;
    while (position<size) {
        if (packets==8 || size-position<7 || source_interrupt(&budget.input)) return AVERROR_INVALIDDATA;
        int rate,channels,profile; size_t length;
        if (adts_header(bytes+position,&length,&rate,&channels,&profile)<0 || profile!=1 || length>size-position ||
            (packets && (expected_rate!=rate || expected_channels!=channels))) return AVERROR_INVALIDDATA;
        expected_rate=rate; expected_channels=channels; offsets[packets]=position; sizes[packets++]=length; position+=length;
    }
    /* Pinned LC raw-data element tags/PCE references are four bits; AAC core
     * configuration excludes USAC. Native channel/SBR slots and transforms are
     * bounded by that domain. The 48 MiB phase allowance is a source-audit
     * estimate, not a scoped allocator or measured native/Swift/RSS guarantee. */
    const AVCodec *decoder=avcodec_find_decoder(AV_CODEC_ID_AAC);
    if (!decoder) return AVERROR_DECODER_NOT_FOUND;
    AVCodecContext *codec=avcodec_alloc_context3(decoder); AVPacket *packet=av_packet_alloc(); AVFrame *frame=av_frame_alloc();
    int result=AVERROR(ENOMEM); unsigned observed=0;
    if (!codec || !packet || !frame) goto done;
    codec->thread_count=1; codec->thread_type=0; codec->max_samples=8*2048;
    codec->opaque=&budget; codec->get_buffer2=aac_get_buffer;
    if (source_interrupt(&budget.input)) { result=AVERROR_EXIT; goto done; }
    if ((result=avcodec_open2(codec,decoder,NULL))<0) goto done;
    for (unsigned i=0;i<packets;i++) {
        if (source_interrupt(&budget.input)) { result=AVERROR_EXIT; goto done; }
        if ((result=av_new_packet(packet,(int)sizes[i]))<0) goto done;
        memcpy(packet->data,bytes+offsets[i],sizes[i]);
        result=avcodec_send_packet(codec,packet); av_packet_unref(packet);
        if (result<0) goto done;
        while ((result=avcodec_receive_frame(codec,frame))>=0) {
            if (source_interrupt(&budget.input)) { result=AVERROR_EXIT; goto done; }
            if (++observed>8 || frame->nb_samples<1 || frame->nb_samples>2048 || frame->ch_layout.nb_channels<1 ||
                frame->ch_layout.nb_channels>8 || frame->ch_layout.order!=AV_CHANNEL_ORDER_NATIVE ||
                frame->sample_rate<=0 || frame->sample_rate>192000) { result=AVERROR_INVALIDDATA; goto done; }
            VPFFSourceAACFormat format={.profile=codec->profile,.sample_rate=frame->sample_rate,.channels=frame->ch_layout.nb_channels,.channel_mask=frame->ch_layout.u.mask};
            if (observed>1 && (out->profile!=format.profile || out->sample_rate!=format.sample_rate || out->channels!=format.channels || out->channel_mask!=format.channel_mask)) { result=AVERROR_INVALIDDATA; goto done; }
            *out=format; av_frame_unref(frame);
        }
        if (result!=AVERROR(EAGAIN) && result!=AVERROR_EOF) goto done;
    }
    result=observed && !source_interrupt(&budget.input)?0:AVERROR_INVALIDDATA;
done:
    av_frame_free(&frame); av_packet_free(&packet); avcodec_free_context(&codec);
    if (result<0) memset(out,0,sizeof(*out));
    return result;
}
