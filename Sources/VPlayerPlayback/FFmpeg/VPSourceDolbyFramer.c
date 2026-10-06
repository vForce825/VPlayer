// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
#include "VPSourceDolbyFramer.h"
#include <libavcodec/ac3_parser.h>
#include <errno.h>
#include <string.h>

static unsigned bits(const uint8_t *p,unsigned *position,unsigned count) {
    unsigned value=0;
    for (unsigned i=0;i<count;i++,(*position)++) value=(value<<1)|((p[*position/8]>>(7-*position%8))&1);
    return value;
}
static int header(VPSourceDolbyFramer *f) {
    static const int rates[3]={48000,44100,32000}, channels[8]={2,1,2,3,3,4,4,5}, blocks[4]={1,2,3,6};
    uint8_t bsid=0; uint16_t size=0;
    if (av_ac3_parse_header(f->bytes,7,&bsid,&size)<0 || size<7 || size>VP_SOURCE_DOLBY_MAX_FRAME) return -EINVAL;
    if ((!f->enhanced && bsid>10) || (f->enhanced && (bsid<11 || bsid>16))) return -EINVAL;
    VPSourceDolbyFrameInfo info={.frame_size=size,.bsid=bsid,.bsmod=-1};
    if (!f->enhanced) {
        unsigned rate=f->bytes[4]>>6;
        if (rate==3) return -EINVAL;
        info.sample_rate=rates[rate]>>(bsid>8?bsid-8:0); info.sample_count=1536;
        unsigned position=40; (void)bits(f->bytes,&position,5);
        info.bsmod=(int)bits(f->bytes,&position,3);
        unsigned acmod=bits(f->bytes,&position,3);
        if ((acmod&1) && acmod!=1) (void)bits(f->bytes,&position,2);
        if (acmod&4) (void)bits(f->bytes,&position,2);
        if (acmod==2) (void)bits(f->bytes,&position,2);
        info.channels=channels[acmod]+(int)bits(f->bytes,&position,1);
        if (acmod==0) info.bsmod=-1;
    } else {
        info.stream_type=f->bytes[2]>>6; info.substream_id=(f->bytes[2]>>3)&7;
        if (info.stream_type==3) return -EINVAL;
        unsigned rate=f->bytes[4]>>6, code=(f->bytes[4]>>4)&3;
        if (rate==3) { if (code==3) return -EINVAL; info.sample_rate=rates[code]/2; info.sample_count=1536; }
        else { info.sample_rate=rates[rate]; info.sample_count=blocks[code]*256; }
        info.channels=channels[(f->bytes[4]>>1)&7]+(f->bytes[4]&1);
    }
    f->info=info; f->expected_size=size; return 0;
}
void vp_source_dolby_init(VPSourceDolbyFramer *f,int enhanced) {
    memset(f,0,sizeof(*f)); f->enhanced=!!enhanced;
}
int vp_source_dolby_append(VPSourceDolbyFramer *f,const uint8_t *bytes,size_t size,VPSourceDolbyFrameCallback callback,void *context) {
    if (!f || (!bytes && size) || !callback || size>8u*1024u*1024u) return -EINVAL;
    size_t position=0, start=f->pending_size?SIZE_MAX:0;
    if (f->pending_size) f->crossed_input=1;
    while (position<size) {
        size_t target=f->expected_size?f->expected_size:7;
        if (f->pending_size>target || target>VP_SOURCE_DOLBY_MAX_FRAME) return -EINVAL;
        size_t count=target-f->pending_size;
        if (count>size-position) count=size-position;
        memcpy(f->bytes+f->pending_size,bytes+position,count); f->pending_size+=count; position+=count;
        if (!f->expected_size && f->pending_size==7 && header(f)<0) return -EINVAL;
        if (f->expected_size && f->pending_size==f->expected_size) {
            memset(f->bytes+f->pending_size,0,VP_SOURCE_DOLBY_PADDING);
            int result=callback(context,f->bytes,f->pending_size,&f->info,f->crossed_input?SIZE_MAX:start);
            if (result<0) return result;
            f->pending_size=f->expected_size=0; f->crossed_input=0; start=position;
        }
    }
    return 0;
}
int vp_source_dolby_finish(const VPSourceDolbyFramer *f,int complete_input) {
    return f && (!complete_input || !f->pending_size)?0:-EINVAL;
}
