// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
#include "VPSourceContainerAdmission.h"
#include <errno.h>
#include <limits.h>
#include <string.h>

#define MAX_BYTES (8u * 1024u * 1024u)
#define MAX_METADATA (256u * 1024u)
#define MAX_SAMPLE (1024u * 1024u)
#define MAX_COUNT 16384u
#define COUNT_BUDGET (4u * 1024u * 1024u)
#define TAG(a,b,c,d) (((uint32_t)(a)<<24)|((uint32_t)(b)<<16)|((uint32_t)(c)<<8)|(uint32_t)(d))
static uint16_t be16(const uint8_t *p) { return (uint16_t)((p[0]<<8)|p[1]); }
static uint32_t be32(const uint8_t *p) { return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3]; }
static uint64_t be64(const uint8_t *p) { return ((uint64_t)be32(p)<<32)|be32(p+4); }
typedef struct { size_t metadata, counts; unsigned boxes, tracks, video, moofs, runs; int moov, mvex, mdat; int (*interrupt)(void *); void *context; } Admission;
static int count(Admission *a, uint64_t n) {
    if (n > MAX_COUNT || n > (COUNT_BUDGET-a->counts)/128) return -EFBIG;
    a->counts += (size_t)n*128; return 0;
}
static int table(Admission *a, const uint8_t *p, size_t n, unsigned width) {
    if (n < 8) return -EINVAL;
    uint32_t entries = be32(p+4);
    if (count(a,entries)<0 || entries > (n-8)/width || n != 8+(size_t)entries*width) return -EFBIG;
    return 0;
}
static int descriptors(const uint8_t *p, size_t n, unsigned depth) {
    if (depth > 4) return -EINVAL;
    size_t o=0;
    while (o<n) {
        unsigned tag=p[o++], length=0, used=0;
        uint8_t b;
        do { if (o==n || used++==4) return -EINVAL; b=p[o++]; length=(length<<7)|(b&127); } while (b&128);
        if (length>n-o) return -EINVAL;
        const uint8_t *d=p+o; size_t head=0;
        if (tag==3) {
            if (length<3) return -EINVAL;
            head=3;
            if (d[2]&128) head+=2;
            if (d[2]&64) { if (head>=length) return -EINVAL; head+=1+d[head]; }
            if (d[2]&32) head+=2;
        } else if (tag==4) { if (length<13) return -EINVAL; head=13; }
        else if (tag==5) { if (!length || length>64) return -EFBIG; }
        else if (tag!=6 || length>16) return -EINVAL;
        if (head) { if (head>length || descriptors(d+head,length-head,depth+1)<0) return -EINVAL; }
        o+=length;
    }
    return 0;
}
static int boxes(Admission *a, const uint8_t *p, size_t n, unsigned depth, uint32_t parent);
static int sample_entries(Admission *a, const uint8_t *p, size_t n, unsigned depth) {
    if (n<8 || be32(p+4)!=1) return -EINVAL;
    p+=8; n-=8;
    if (n<8 || be32(p)!=n) return -EINVAL;
    uint32_t type=be32(p+4); size_t header;
    switch(type) {
    case TAG('a','v','c','1'): case TAG('a','v','c','3'): case TAG('h','v','c','1'): case TAG('h','e','v','1'):
        if (++a->video>1) return -EFBIG;
        header=78; break;
    case TAG('m','p','4','a'): case TAG('a','c','-','3'): case TAG('e','c','-','3'): case TAG('.','m','p','3'):
        if (n<36 || be16(p+16)>1) return -EINVAL;
        header=be16(p+16)==1?44:28;
        if (header==44) { if (n<52) return -EINVAL; for (size_t o=36;o<52;o+=4) if (be32(p+o)>MAX_SAMPLE) return -EFBIG; }
        break;
    default: return -EINVAL;
    }
    if (n<8+header || be16(p+14)!=1) return -EINVAL;
    return boxes(a,p+8+header,n-8-header,depth+1,type);
}
static int box(Admission *a, uint32_t t, const uint8_t *p, size_t n, unsigned depth, uint32_t parent) {
    switch(t) {
    case TAG('m','o','o','v'): a->moov=1; return boxes(a,p,n,depth+1,t);
    case TAG('t','r','a','k'): if (++a->tracks>8) return -EFBIG; return boxes(a,p,n,depth+1,t);
    case TAG('m','v','e','x'): a->mvex=1; return boxes(a,p,n,depth+1,t);
    case TAG('m','o','o','f'): if (++a->moofs>32) return -EFBIG; return boxes(a,p,n,depth+1,t);
    case TAG('m','d','i','a'): case TAG('m','i','n','f'): case TAG('s','t','b','l'): case TAG('d','i','n','f'):
    case TAG('e','d','t','s'): case TAG('t','r','a','f'): case TAG('u','d','t','a'): case TAG('i','l','s','t'):
    case TAG(0xa9,'t','o','o'): case TAG('w','a','v','e'): return boxes(a,p,n,depth+1,t);
    case TAG('m','e','t','a'): if (n<4 || be32(p)) return -EINVAL; return boxes(a,p+4,n-4,depth+1,t);
    case TAG('m','d','a','t'): if (depth!=0) return -EINVAL; a->mdat=1; return 0;
    case TAG('s','t','s','d'): return sample_entries(a,p,n,depth);
    case TAG('s','t','t','s'): case TAG('c','t','t','s'):
        if (table(a,p,n,8)<0) return -EFBIG;
        for (size_t o=8;o<n;o+=8) if (count(a,be32(p+o))<0) return -EFBIG;
        return 0;
    case TAG('s','t','s','c'):
        if (table(a,p,n,12)<0) return -EFBIG;
        for (size_t o=8;o<n;o+=12) if (!be32(p+o) || be32(p+o)>MAX_COUNT || !be32(p+o+4) || count(a,be32(p+o+4))<0 || be32(p+o+8)!=1) return -EINVAL;
        return 0;
    case TAG('s','t','c','o'): case TAG('s','t','s','s'): case TAG('s','t','p','s'): return table(a,p,n,4);
    case TAG('c','o','6','4'): return table(a,p,n,8);
    case TAG('s','t','s','z'): {
        if (n<12) return -EINVAL;
        uint32_t size=be32(p+4), entries=be32(p+8);
        if (size>MAX_SAMPLE || count(a,entries)<0) return -EFBIG;
        if (size) return n==12 && (uint64_t)size*entries<=MAX_BYTES ? 0 : -EFBIG;
        if (entries>(n-12)/4 || n!=12+(size_t)entries*4) return -EINVAL;
        uint64_t total=0;
        for (size_t o=12;o<n;o+=4) { uint32_t v=be32(p+o); if (v>MAX_SAMPLE) return -EFBIG; total+=v; }
        return total<=MAX_BYTES?0:-EFBIG;
    }
    case TAG('s','t','z','2'): {
        if (n<12 || !(p[7]==4 || p[7]==8 || p[7]==16)) return -EINVAL;
        uint32_t entries=be32(p+8);
        if (count(a,entries)<0 || n!=12+((size_t)entries*p[7]+7)/8) return -EFBIG;
        return 0;
    }
    case TAG('s','d','t','p'): return n>=4 ? count(a,n-4) : -EINVAL;
    case TAG('t','r','u','n'): {
        if (++a->runs>256 || n<8) return -EINVAL;
        uint32_t flags=be32(p)&0xffffff, entries=be32(p+4);
        if (flags & ~0x000f05u || count(a,entries)<0) return -EFBIG;
        size_t head=8+((flags&1)?4:0)+((flags&4)?4:0);
        unsigned width=4*((!!(flags&0x100))+(!!(flags&0x200))+(!!(flags&0x400))+(!!(flags&0x800)));
        if (head>n || (width && entries>(n-head)/width) || n!=head+(size_t)entries*width) return -EINVAL;
        if (flags&0x200) for (uint32_t i=0;i<entries;i++) if (be32(p+head+(size_t)i*width+((flags&0x100)?4:0))>MAX_SAMPLE) return -EFBIG;
        return 0;
    }
    case TAG('t','f','h','d'): {
        if (n<8) return -EINVAL;
        uint32_t flags=be32(p)&0xffffff;
        if (flags&~0x03003bu) return -EINVAL;
        size_t o=8+((flags&1)?8:0)+((flags&2)?4:0)+((flags&8)?4:0);
        if (o>n) return -EINVAL;
        if (flags&0x10) { if (n-o<4 || be32(p+o)>MAX_SAMPLE) return -EFBIG; o+=4; }
        if (flags&0x20) o+=4;
        return o==n?0:-EINVAL;
    }
    case TAG('t','r','e','x'): return n==24 && be32(p+16)<=MAX_SAMPLE ? 0 : -EINVAL;
    case TAG('e','l','s','t'): {
        if (n<8 || p[0]>1) return -EINVAL;
        return table(a,p,n,p[0]?20:12);
    }
    case TAG('s','i','d','x'): {
        if (n<24 || p[0]>1) return -EINVAL;
        size_t o=p[0]?28:20;
        if (n<o+4) return -EINVAL;
        uint16_t entries=be16(p+o+2); o+=4;
        if (entries>32 || count(a,entries)<0 || entries>(n-o)/12 || n!=o+(size_t)entries*12) return -EFBIG;
        for (;o<n;o+=12) if (be32(p+o)&0x80000000u) return -EINVAL;
        return 0;
    }
    case TAG('d','r','e','f'):
        if (n!=20 || be32(p+4)!=1 || be32(p+8)!=12 || be32(p+12)!=TAG('u','r','l',' ') || be32(p+16)!=1) return -EINVAL;
        return 0;
    case TAG('e','s','d','s'): return n>=4 && n<=16*1024 ? descriptors(p+4,n-4,0) : -EINVAL;
    case TAG('a','v','c','C'): case TAG('h','v','c','C'): return n>0 && n<=16*1024 ? 0 : -EFBIG;
    case TAG('c','o','l','r'):
        return n>=10 && n<=11 && (be32(p)==TAG('n','c','l','x') || be32(p)==TAG('n','c','l','c')) ? 0 : -EINVAL;
    case TAG('c','h','a','n'):
        if (n<16 || be32(p+12)>8 || n!=16+(size_t)be32(p+12)*20) return -EINVAL;
        return count(a,be32(p+12));
    case TAG('s','g','p','d'): {
        if (n<12 || p[0]>1 || be32(p+4)!=TAG('r','o','l','l')) return -EINVAL;
        size_t o=8; uint32_t length=2;
        if (p[0]) { if (n<16) return -EINVAL; length=be32(p+o); o+=4; }
        uint32_t entries=be32(p+o); o+=4;
        if (count(a,entries)<0 || length!=2 || entries>(n-o)/2 || n!=o+(size_t)entries*2) return -EFBIG;
        return 0; /* Pinned native reader ignores non-sync groups. */
    }
    case TAG('s','b','g','p'): {
        if (n<12 || p[0]>1 || be32(p+4)!=TAG('r','o','l','l')) return -EINVAL;
        size_t o=p[0]?12:8;
        if (n-o<4) return -EINVAL;
        uint32_t entries=be32(p+o); o+=4;
        if (count(a,entries)<0 || entries>(n-o)/8 || n!=o+(size_t)entries*8) return -EFBIG;
        for (;o<n;o+=8) if (count(a,be32(p+o))<0) return -EFBIG;
        return 0;
    }
    case TAG('f','t','y','p'): case TAG('s','t','y','p'): return n>=8 && n<=256 && n%4==0 ? 0:-EINVAL;
    case TAG('m','v','h','d'): return (n==100 || n==112) ? 0:-EINVAL;
    case TAG('t','k','h','d'): return (n==84 || n==96) ? 0:-EINVAL;
    case TAG('m','d','h','d'): return (n==24 || n==36) ? 0:-EINVAL;
    case TAG('h','d','l','r'): return n>=24 && n<=4096 ? 0:-EINVAL;
    case TAG('v','m','h','d'): return n==12?0:-EINVAL;
    case TAG('s','m','h','d'): return n==8?0:-EINVAL;
    case TAG('n','m','h','d'): return n==4?0:-EINVAL;
    case TAG('m','f','h','d'): return n==8?0:-EINVAL;
    case TAG('t','f','d','t'): return n>=8 && ((p[0]==0 && n==8)||(p[0]==1 && n==12))?0:-EINVAL;
    case TAG('p','a','s','p'): return n==8?0:-EINVAL;
    case TAG('c','l','a','p'): return n==32?0:-EINVAL;
    case TAG('f','i','e','l'): return n==2?0:-EINVAL;
    case TAG('c','h','r','m'):
        /* CoreMedia's two-byte chroma-location sample-description extension.
         * The pinned MOV reader skips it; it supplies no format/scan facts. */
        return n==2 && (parent==TAG('a','v','c','1') || parent==TAG('a','v','c','3') ||
            parent==TAG('h','v','c','1') || parent==TAG('h','e','v','1')) ? 0:-EINVAL;
    case TAG('b','t','r','t'): return n==12?0:-EINVAL;
    case TAG('f','r','m','a'): return parent==TAG('w','a','v','e') && n==4 && (be32(p)==TAG('a','c','-','3') || be32(p)==TAG('e','c','-','3') || be32(p)==TAG('m','p','4','a') || be32(p)==TAG('.','m','p','3'))?0:-EINVAL;
    case 0: return parent==TAG('w','a','v','e') && n==0?0:-EINVAL;
    case TAG('d','a','c','3'): return n==3?0:-EINVAL;
    case TAG('d','e','c','3'): return n>=5 && n<=64?0:-EINVAL;
    case TAG('m','d','c','v'): return n==24?0:-EINVAL;
    case TAG('c','l','l','i'): return n==4?0:-EINVAL;
    case TAG('d','a','t','a'): return parent==TAG(0xa9,'t','o','o') && n>=8 && n<=4096?0:-EINVAL;
    case TAG('w','i','d','e'): return n==0?0:-EINVAL;
    case TAG('f','r','e','e'): case TAG('s','k','i','p'): return 0;
    default: return -EINVAL; /* Includes protection boxes, MFRA and compressed moov. */
    }
}
static int boxes(Admission *a, const uint8_t *p, size_t n, unsigned depth, uint32_t parent) {
    if (depth>12) return -EFBIG;
    size_t o=0;
    while (o<n) {
        if (a->interrupt && a->interrupt(a->context)) return -ECANCELED;
        if (n-o<8 || ++a->boxes>2048) return -EINVAL;
        uint64_t size=be32(p+o); uint32_t type=be32(p+o+4); size_t head=8;
        if (size==1) { if (n-o<16) return -EINVAL; size=be64(p+o+8); head=16; }
        if (!size && type==TAG('m','d','a','t') && depth==0) size=n-o;
        if (size<head || size>n-o || size>SIZE_MAX) return -EINVAL;
        size_t body=(size_t)size-head;
        /* Conservative metadata admission includes nested headers. Only large
         * media payload and inert padding are excluded from this scalar budget. */
        size_t charge=head;
        switch(type) {
        case TAG('m','d','a','t'): case TAG('f','r','e','e'): case TAG('s','k','i','p'): break;
        case TAG('m','o','o','v'): case TAG('t','r','a','k'): case TAG('m','d','i','a'): case TAG('m','i','n','f'):
        case TAG('s','t','b','l'): case TAG('d','i','n','f'): case TAG('e','d','t','s'): case TAG('m','v','e','x'):
        case TAG('m','o','o','f'): case TAG('t','r','a','f'): case TAG('u','d','t','a'): case TAG('m','e','t','a'):
        case TAG('i','l','s','t'): case TAG(0xa9,'t','o','o'): break;
        default: charge+=body; break;
        }
        if (charge>MAX_METADATA-a->metadata) return -EFBIG;
        a->metadata+=charge;
        int r=box(a,type,p+o+head,body,depth,parent);
        if (r<0) return r;
        o+=(size_t)size;
    }
    return 0;
}

static int ts_descriptors(const uint8_t *p,size_t n) {
    size_t o=0;
    while (o<n) {
        if (n-o<2 || p[o+1]>n-o-2 || p[o]==9) return -EINVAL;
        o+=2+p[o+1];
    }
    return 0;
}
static int ts_section(const uint8_t *p,size_t n,uint8_t table_id,size_t *length) {
    if (n<3 || p[0]!=table_id || (p[1]&0xb0)!=0xb0) return -EINVAL;
    size_t size=3+(((size_t)p[1]&15)<<8)+p[2];
    if (size<12 || size>n || size>1024 || p[6] || p[7]) return -EINVAL;
    uint32_t crc=0xffffffffu;
    for (size_t i=0;i<size;i++) {
        crc^=(uint32_t)p[i]<<24;
        for (int j=0;j<8;j++) crc=(crc<<1)^((crc&0x80000000u)?0x04c11db7u:0);
    }
    if (crc) return -EINVAL;
    *length=size; return 0;
}
static int ts_failure(VPSourceAdmission *view,int reason,int result) {
    view->reason=reason; return result;
}
static int ts_payload(const uint8_t *q,size_t *head,unsigned *pid) {
    if (q[0]!=0x47 || (q[1]&0x80) || (q[3]&0xc0) || !(q[3]&0x30)) return -EINVAL;
    *pid=((q[1]&31u)<<8)|q[2]; *head=4;
    if (q[3]&0x20) { if (q[4]>183) return -EINVAL; *head+=1+q[4]; }
    if (*head>188) return -EINVAL;
    /* Native auto-guess observes PUSI before payload flags. A packet claiming
     * a payload-unit start must actually contain payload bytes. */
    if ((!(q[3]&0x10) || *head==188) && (q[1]&0x40)) return -EINVAL;
    return (q[3]&0x10) && *head<188;
}
static int ts_single_section(const uint8_t *q,size_t head,uint8_t table,const uint8_t **section,size_t *length) {
    /* Split PSI and additional sections remain outside this bounded subset.
     * FFmpeg processes trailing sections, so none may escape admission. */
    if (!(q[1]&0x40)) return -EINVAL;
    size_t pointer=q[head++];
    if (pointer>188-head) return -EINVAL;
    for (size_t i=0;i<pointer;i++) if (q[head+i]!=0xff) return -EINVAL;
    head+=pointer;
    if (head>=188 ||
        ts_section(q+head,188-head,table,length)<0 || *length>184 || !(q[head+5]&1)) return -EINVAL;
    for (size_t i=head+*length;i<188;i++) if (q[i]!=0xff) return -EINVAL;
    *section=q+head; return 0;
}
typedef struct { unsigned pid,type; } TSVideo;
static int ts_admit(const uint8_t *p,size_t n,int prefix,int (*interrupt)(void *),void *context,VPSourceAdmission *view,TSVideo *selected) {
    unsigned pmt=8192, program=0, streams=0, video=0, observed_count=0;
    uint8_t pat_copy[184],pmt_copy[184]; size_t pat_size=0,pmt_size=0;
    unsigned stream_pids[8]={0},observed_pids[8]={0};
    size_t latest_pat=SIZE_MAX, acquisition=SIZE_MAX;
    /* Discover one exact PAT before interpreting any other PID. No bytes are
     * forwarded to native code until BOTH bounded passes have succeeded. */
    for (size_t o=0;o<n;o+=188) {
        view->packet_offset=o; view->pid=-1;
        if (interrupt && interrupt(context)) return ts_failure(view,VP_SOURCE_ADMISSION_CANCELLED,-ECANCELED);
        const uint8_t *q=p+o; size_t head; unsigned pid;
        int payload=ts_payload(q,&head,&pid);
        if (payload<0) return ts_failure(view,VP_SOURCE_ADMISSION_STRUCTURE,-EINVAL);
        view->pid=(int)pid;
        if (!payload || pid!=0) continue;
        const uint8_t *section; size_t length;
        if (ts_single_section(q,head,0,&section,&length)<0) return ts_failure(view,VP_SOURCE_ADMISSION_STRUCTURE,-EINVAL);
        if (pat_size) {
            if (pat_size!=length || memcmp(pat_copy,section,length)) return ts_failure(view,VP_SOURCE_ADMISSION_CHANGED_PAT,-EINVAL);
            continue;
        }
        unsigned programs=0;
        for (size_t k=8;k<length-4;k+=4) {
            if (length-4-k<4) return ts_failure(view,VP_SOURCE_ADMISSION_STRUCTURE,-EINVAL);
            if (be16(section+k)) {
                if (++programs>1) return ts_failure(view,VP_SOURCE_ADMISSION_TOPOLOGY,-EINVAL);
                program=be16(section+k); pmt=be16(section+k+2)&8191;
            }
        }
        if (programs!=1 || pmt==0 || pmt==8191 || vp_source_ignored_si(pmt)) return ts_failure(view,VP_SOURCE_ADMISSION_TOPOLOGY,-EINVAL);
        memcpy(pat_copy,section,length); pat_size=length;
    }
    if (!pat_size) return ts_failure(view,VP_SOURCE_ADMISSION_MISSING_PAT,-EINVAL);
    /* Learn the selected PMT and at most eight observed media PIDs regardless
     * of their order. A fixed final membership check rejects undeclared media. */
    for (size_t o=0;o<n;o+=188) {
        view->packet_offset=o; view->pid=-1;
        if (interrupt && interrupt(context)) return ts_failure(view,VP_SOURCE_ADMISSION_CANCELLED,-ECANCELED);
        const uint8_t *q=p+o; size_t head; unsigned pid;
        int payload=ts_payload(q,&head,&pid);
        if (payload<0) return ts_failure(view,VP_SOURCE_ADMISSION_STRUCTURE,-EINVAL);
        view->pid=(int)pid;
        if (!payload) continue;
        if (pid==0) { latest_pat=o; continue; }
        if (pid==pmt) {
            const uint8_t *section; size_t length;
            if (ts_single_section(q,head,2,&section,&length)<0) return ts_failure(view,VP_SOURCE_ADMISSION_STRUCTURE,-EINVAL);
            if (be16(section+3)!=program) return ts_failure(view,VP_SOURCE_ADMISSION_TOPOLOGY,-EINVAL);
            if (pmt_size) {
                if (pmt_size!=length || memcmp(pmt_copy,section,length)) return ts_failure(view,VP_SOURCE_ADMISSION_CHANGED_PMT,-EINVAL);
            } else {
                if (length<16) return ts_failure(view,VP_SOURCE_ADMISSION_STRUCTURE,-EINVAL);
                size_t info=be16(section+10)&4095,k=12;
                if (info>length-4-k || ts_descriptors(section+k,info)<0) return ts_failure(view,VP_SOURCE_ADMISSION_STRUCTURE,-EINVAL);
                k+=info;
                while (k<length-4) {
                    if (length-4-k<5 || streams==8) return ts_failure(view,VP_SOURCE_ADMISSION_TOPOLOGY,-EINVAL);
                    uint8_t type=section[k]; unsigned stream=be16(section+k+1)&8191;
                    size_t extra=be16(section+k+3)&4095; k+=5;
                    if (extra>length-4-k || ts_descriptors(section+k,extra)<0 || stream==0 || stream==8191 || stream==pmt || vp_source_ignored_si(stream))
                        return ts_failure(view,VP_SOURCE_ADMISSION_TOPOLOGY,-EINVAL);
                    for (unsigned j=0;j<streams;j++) if (stream_pids[j]==stream) return ts_failure(view,VP_SOURCE_ADMISSION_TOPOLOGY,-EINVAL);
                    stream_pids[streams++]=stream;
                    if (type==0x1b || type==0x24) {
                        if (++video>1) return ts_failure(view,VP_SOURCE_ADMISSION_TOPOLOGY,-EINVAL);
                        if (selected) *selected=(TSVideo){.pid=stream,.type=type};
                    }
                    k+=extra;
                }
                if (!streams) return ts_failure(view,VP_SOURCE_ADMISSION_TOPOLOGY,-EINVAL);
                memcpy(pmt_copy,section,length); pmt_size=length;
            }
            /* Pinned handle_packets stops before packet number nb_packets:
             * with 32768/188=174, only indexes 0...172 are inspected. */
            if (acquisition==SIZE_MAX && latest_pat!=SIZE_MAX &&
                o-latest_pat<(VP_SOURCE_TS_HEADER_BYTES/188-1)*188) acquisition=latest_pat;
        } else if (pid!=17 && pid!=8191 && !vp_source_ignored_si(pid)) {
            unsigned j=0;
            while (j<observed_count && observed_pids[j]!=pid) j++;
            if (j==observed_count) {
                if (observed_count==8) return ts_failure(view,VP_SOURCE_ADMISSION_UNKNOWN_PID,-EINVAL);
                observed_pids[observed_count++]=pid;
            }
        }
    }
    if (!pmt_size) return ts_failure(view,VP_SOURCE_ADMISSION_MISSING_PMT,-EINVAL);
    for (unsigned i=0;i<observed_count;i++) {
        unsigned j=0;
        while (j<streams && stream_pids[j]!=observed_pids[i]) j++;
        if (j==streams) { view->pid=(int)observed_pids[i]; view->packet_offset=SIZE_MAX; return ts_failure(view,VP_SOURCE_ADMISSION_UNKNOWN_PID,-EINVAL); }
    }
    if (prefix && acquisition==SIZE_MAX) return ts_failure(view,VP_SOURCE_ADMISSION_ACQUISITION,-EINVAL);
    view->start_offset=prefix?acquisition:0;
    view->packet_offset=0; view->pid=-1; return 0;
}
int vp_source_admit_container_with_view(const uint8_t *bytes,size_t size,int is_prefix,int32_t *kind,size_t *usable_size,
    int (*interrupt)(void *),void *context,VPSourceAdmission *supplied) {
    VPSourceAdmission local={0},*view=supplied?supplied:&local;
    *view=(VPSourceAdmission){.pid=-1};
    if (!bytes || !kind || !usable_size || !size || size>MAX_BYTES) return ts_failure(view,VP_SOURCE_ADMISSION_LIMIT,-EFBIG);
    *kind=0; *usable_size=size;
    if (bytes[0]==0x47) {
        if (!is_prefix && size%188) return ts_failure(view,VP_SOURCE_ADMISSION_STRUCTURE,-EINVAL);
        *usable_size=size-size%188;
        if (*usable_size<188*2) return ts_failure(view,VP_SOURCE_ADMISSION_STRUCTURE,-EINVAL);
        int result=ts_admit(bytes,*usable_size,!!is_prefix,interrupt,context,view,NULL);
        if (result<0) return result;
        *kind=1; return 0;
    }
    if (is_prefix || size<8) return ts_failure(view,VP_SOURCE_ADMISSION_STRUCTURE,-EINVAL);
    Admission a={.interrupt=interrupt,.context=context};
    int result=boxes(&a,bytes,size,0,0);
    if (result<0 || !a.moov || !a.tracks || !a.mdat) {
        view->reason=result==-ECANCELED?VP_SOURCE_ADMISSION_CANCELLED:result==-EFBIG?VP_SOURCE_ADMISSION_LIMIT:VP_SOURCE_ADMISSION_STRUCTURE;
        return result<0?result:-EINVAL;
    }
    *kind=a.mvex && a.moofs?2:3;
    return 0;
}
int vp_source_admit_container_with_interrupt(const uint8_t *bytes,size_t size,int is_prefix,int32_t *kind,size_t *usable_size,
    int (*interrupt)(void *),void *context) {
    return vp_source_admit_container_with_view(bytes,size,is_prefix,kind,usable_size,interrupt,context,NULL);
}
int vp_source_admit_container(const uint8_t *bytes,size_t size,int is_prefix,int32_t *kind,size_t *usable_size) {
    return vp_source_admit_container_with_interrupt(bytes,size,is_prefix,kind,usable_size,NULL,NULL);
}

int vp_source_prepare_ts_tails(const uint8_t *bytes,size_t size,int prefix,
    int (*interrupt)(void *),void *context,VPSourceTSTails *tails,VPSourceAdmission *view) {
    for (size_t o=0;o<size;o+=188) {
        if (interrupt && interrupt(context)) return -ECANCELED;
        const uint8_t *p=bytes+o; size_t head=4;
        if (p[3]&0x20) head+=1+p[4];
        if (!(p[3]&0x10) || head>=188) continue;
        unsigned pid=((p[1]&31u)<<8)|p[2]; VPSourceTSTail *tail=NULL;
        if (vp_source_ignored_si(pid)) continue;
        if (view) { view->packet_offset=o; view->pid=(int)pid; }
        for (unsigned j=0;j<tails->count;j++) if (tails->tails[j].pid==pid) tail=&tails->tails[j];
        if (p[1]&0x40) {
            size_t available=188-head;
            int possible=p[head]==0 && (available<2 || p[head+1]==0) && (available<3 || p[head+2]==1);
            if (!possible) continue;
            if (tail && tail->active && (tail->header_size<6 || (tail->expected && tail->bytes<tail->expected))) return -EINVAL;
            if (!tail) { if (tails->count==VP_SOURCE_TS_MAX_TAILS) return -EFBIG; tail=&tails->tails[tails->count++]; }
            *tail=(VPSourceTSTail){.pid=pid,.start=o,.active=1};
        }
        if (tail && tail->active) {
            size_t available=188-head, copy=6-tail->header_size;
            if (copy>available) copy=available;
            if (copy) { memcpy(tail->header+tail->header_size,p+head,copy); tail->header_size+=copy; }
            if (tail->header_size>=3 && (tail->header[0] || tail->header[1] || tail->header[2]!=1)) return -EINVAL;
            if (tail->header_size==6) { unsigned length=be16(tail->header+4); tail->expected=length?length+6:0; }
            tail->bytes+=available;
        }
    }
    for (unsigned j=0;j<tails->count;j++) {
        VPSourceTSTail *tail=&tails->tails[j];
        int incomplete=tail->header_size<6 || (tail->expected && tail->bytes<tail->expected);
        if (incomplete && !prefix) {
            if (view) { view->packet_offset=tail->start; view->pid=(int)tail->pid; }
            return -EINVAL;
        }
        tail->withhold=prefix && (incomplete || !tail->expected);
    }
    return 0;
}
int vp_source_ts_packet_withheld(const VPSourceTSTails *tails,unsigned pid,size_t packet) {
    if (vp_source_ignored_si(pid)) return 1;
    for (unsigned j=0;j<tails->count;j++)
        if (tails->tails[j].pid==pid && tails->tails[j].withhold && packet>=tails->tails[j].start) return 1;
    return 0;
}

/* Candidate presence only. The actual parser/format proof remains native.
 * Retain scalar Annex B state across packets and PES without copying media. */
typedef struct {
    size_t zeros,bytes;
    unsigned candidate,seen;
    int active,valid,hevc;
} TSParameters;
static int ts_parameter_byte(TSParameters *s,uint8_t byte) {
    if (!byte) { s->zeros++; return 0; }
    if (byte==1 && s->zeros>=2) {
        if (s->active && s->valid && s->bytes>(s->hevc?2u:1u)) s->seen|=s->candidate;
        s->active=1; s->valid=1; s->bytes=0; s->candidate=0; s->zeros=0;
        return 0;
    }
    if (s->active) {
        if (!s->bytes) {
            unsigned type=s->hevc?(byte>>1)&63:byte&31;
            s->valid=!s->zeros && !(byte&0x80);
            s->candidate=s->hevc?(type>=32 && type<=34?1u<<(type-32):0):
                type==7?1u:type==8?2u:0;
        }
        if (s->hevc && s->bytes<=1 && s->bytes+s->zeros>=1)
            s->valid=s->valid && s->bytes+s->zeros==1 && (byte&7);
        s->bytes+=s->zeros+1;
        if (s->candidate && s->bytes>64u*1024u) return -EFBIG;
    }
    s->zeros=0; return 0;
}
int32_t vp_source_ts_acquisition_hint(const uint8_t *bytes,size_t size,int (*interrupt)(void *),void *context) {
    if (interrupt && interrupt(context)) return VP_SOURCE_ACQUISITION_CANCELLED;
    if (!bytes || !size || size>MAX_BYTES || bytes[0]!=0x47) return VP_SOURCE_ACQUISITION_STOP;
    size_t usable=size-size%188;
    VPSourceAdmission view={.pid=-1}; TSVideo video={0};
    int result=ts_admit(bytes,usable,1,interrupt,context,&view,&video);
    if (result<0) {
        if (view.reason==VP_SOURCE_ADMISSION_CANCELLED) return VP_SOURCE_ACQUISITION_CANCELLED;
        return view.reason==VP_SOURCE_ADMISSION_MISSING_PAT || view.reason==VP_SOURCE_ADMISSION_MISSING_PMT ||
            view.reason==VP_SOURCE_ADMISSION_ACQUISITION?VP_SOURCE_ACQUISITION_NEEDS_MORE:VP_SOURCE_ACQUISITION_STOP;
    }
    if (!video.type) return VP_SOURCE_ACQUISITION_STOP;
    bytes+=view.start_offset; usable-=view.start_offset;
    VPSourceTSTails tails={0};
    result=vp_source_prepare_ts_tails(bytes,usable,1,interrupt,context,&tails,NULL);
    if (result<0) return result==-ECANCELED?VP_SOURCE_ACQUISITION_CANCELLED:VP_SOURCE_ACQUISITION_STOP;
    TSParameters parameters={.hevc=video.type==0x24};
    size_t position=0,expected=0,header=9; unsigned length=0; int active=0;
    for (size_t o=0;o<usable;o+=188) {
        if (interrupt && interrupt(context)) return VP_SOURCE_ACQUISITION_CANCELLED;
        const uint8_t *q=bytes+o; size_t head; unsigned pid;
        int payload=ts_payload(q,&head,&pid);
        if (!payload || pid!=video.pid || vp_source_ts_packet_withheld(&tails,pid,o)) continue;
        if (q[1]&0x40) { active=1; position=0; expected=0; length=0; header=9; }
        if (!active) continue; /* Orphan continuation before the first PES. */
        for (;head<188;head++) {
            uint8_t byte=q[head];
            if (expected && position>=expected) break;
            if (position<9) {
                if ((position<2 && byte) || (position==2 && byte!=1) ||
                    (position==3 && (byte&0xf0)!=0xe0) || (position==6 && (byte&0xc0)!=0x80))
                    return VP_SOURCE_ACQUISITION_STOP;
                if (position==4) length=(unsigned)byte<<8;
                if (position==5) {
                    length|=byte;
                    if (length && length<3) return VP_SOURCE_ACQUISITION_STOP;
                    expected=length?length+6:0;
                }
                if (position==8) { header=9+byte; if (expected && header>expected) return VP_SOURCE_ACQUISITION_STOP; }
            } else if (position>=header && ts_parameter_byte(&parameters,byte)<0) return VP_SOURCE_ACQUISITION_STOP;
            position++;
        }
    }
    return parameters.seen==(parameters.hevc?7u:3u)?VP_SOURCE_ACQUISITION_READY:VP_SOURCE_ACQUISITION_NEEDS_MORE;
}
