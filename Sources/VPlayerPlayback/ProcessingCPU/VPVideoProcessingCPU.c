// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
#include "../include/VPVideoProcessingCPU.h"
#include <string.h>

static int vp_min(int a, int b) { return a < b ? a : b; }
static int vp_max(int a, int b) { return a > b ? a : b; }
static int vp_abs(int a) { return a < 0 ? -a : a; }
static int vp_clamp(int a, int low, int high) { return vp_min(vp_max(a, low), high); }
static int valid_plane(int width, int height, int components, int depth, size_t stride) {
    if (width <= 0 || width > 16384 || height < 2 || height > 16384 ||
        (components != 1 && components != 2) || (depth != 8 && depth != 10)) return 0;
    size_t row = (size_t)width * (size_t)components * (depth == 10 ? 2u : 1u);
    return stride >= row && stride <= SIZE_MAX / (size_t)height;
}
static int raw_code(const uint8_t *plane, size_t stride, int x, int y,
                    int component, int components, int depth) {
    const uint8_t *address = plane + (size_t)y * stride +
        ((size_t)x * (size_t)components + (size_t)component) * (depth == 10 ? 2u : 1u);
    if (depth == 8) return *address;
    uint16_t value;
    memcpy(&value, address, sizeof(value));
    return (int)value;
}
static int code(const uint8_t *plane, size_t stride, int x, int y,
                int component, int components, int depth) {
    int value = raw_code(plane, stride, x, y, component, components, depth);
    return depth == 10 ? value >> 6 : value;
}
static void store_code(uint8_t *plane, size_t stride, int x, int y,
                       int component, int components, int depth, int value) {
    uint8_t *address = plane + (size_t)y * stride +
        ((size_t)x * (size_t)components + (size_t)component) * (depth == 10 ? 2u : 1u);
    if (depth == 8) { *address = (uint8_t)value; return; }
    uint16_t word = (uint16_t)((unsigned)value << 6);
    memcpy(address, &word, sizeof(word));
}

int VPYADIFProcessPlaneRows(const uint8_t *previous, size_t previousStride,
                       const uint8_t *current, size_t currentStride,
                       const uint8_t *next, size_t nextStride,
                       uint8_t *output, size_t outputStride,
                       int width, int height, int components, int bitDepth,
                       int outputIndex, int topFieldFirst, int spatialOnly, int firstRow, int rowCount) {
    if (firstRow < 0 || rowCount < 0 || firstRow > height || rowCount > height-firstRow ||
        !previous || !current || !next || !output || (outputIndex != 0 && outputIndex != 1) ||
        (topFieldFirst != 0 && topFieldFirst != 1) || (spatialOnly != 0 && spatialOnly != 1) ||
        !valid_plane(width,height,components,bitDepth,previousStride) ||
        !valid_plane(width,height,components,bitDepth,currentStride) ||
        !valid_plane(width,height,components,bitDepth,nextStride) ||
        !valid_plane(width,height,components,bitDepth,outputStride)) return -1;
    int copiedParity = outputIndex == 0 ? (topFieldFirst ? 0 : 1) : (topFieldFirst ? 1 : 0);
    const uint8_t *before = outputIndex == 0 ? previous : current;
    const uint8_t *after = outputIndex == 0 ? current : next;
    size_t beforeStride = outputIndex == 0 ? previousStride : currentStride;
    size_t afterStride = outputIndex == 0 ? currentStride : nextStride;
    for (int y=firstRow; y<firstRow+rowCount; ++y) {
        if ((y & 1) == copiedParity && bitDepth == 8) {
            memcpy(output+(size_t)y*outputStride, current+(size_t)y*currentStride,
                   (size_t)width*(size_t)components);
            continue;
        }
        int aboveY = y == 0 ? 1 : y-1;
        int belowY = y+1 == height ? height-2 : y+1;
        for (int x=0; x<width; ++x) for (int component=0; component<components; ++component) {
            if ((y & 1) == copiedParity) {
                store_code(output,outputStride,x,y,component,components,bitDepth,
                    code(current,currentStride,x,y,component,components,bitDepth));
                continue;
            }
            int above[7], below[7];
            for (int k=-3; k<=3; ++k) {
                int sx=vp_clamp(x+k,0,width-1);
                above[k+3]=code(current,currentStride,sx,aboveY,component,components,bitDepth);
                below[k+3]=code(current,currentStride,sx,belowY,component,components,bitDepth);
            }
            int prediction=(above[3]+below[3])>>1;
            if (x>=3 && x+3<width) {
                int score=vp_abs(above[2]-below[2])+vp_abs(above[3]-below[3])+vp_abs(above[4]-below[4])-1;
                for (int sign=-1; sign<=1; sign+=2) {
                    for (int distance=1; distance<=2; ++distance) {
                        int direction=sign*distance;
                        int candidate=vp_abs(above[2+direction]-below[2-direction])+
                            vp_abs(above[3+direction]-below[3-direction])+
                            vp_abs(above[4+direction]-below[4-direction]);
                        if (candidate >= score) break;
                        score=candidate;
                        prediction=(above[3+direction]+below[3-direction])>>1;
                    }
                }
            }
            if (!spatialOnly) {
                int temporalBefore=code(before,beforeStride,x,y,component,components,bitDepth);
                int temporalAfter=code(after,afterStride,x,y,component,components,bitDepth);
                int center=(temporalBefore+temporalAfter)>>1;
                int previousDifference=(vp_abs(code(previous,previousStride,x,aboveY,component,components,bitDepth)-above[3])+
                    vp_abs(code(previous,previousStride,x,belowY,component,components,bitDepth)-below[3]))>>1;
                int nextDifference=(vp_abs(code(next,nextStride,x,aboveY,component,components,bitDepth)-above[3])+
                    vp_abs(code(next,nextStride,x,belowY,component,components,bitDepth)-below[3]))>>1;
                int bound=vp_max(vp_abs(temporalBefore-temporalAfter)>>1,vp_max(previousDifference,nextDifference));
                if (y!=1 && y+2!=height) {
                    int farAboveY=y+2*(aboveY-y),farBelowY=y+2*(belowY-y);
                    int farAbove=(code(before,beforeStride,x,farAboveY,component,components,bitDepth)+
                        code(after,afterStride,x,farAboveY,component,components,bitDepth))>>1;
                    int farBelow=(code(before,beforeStride,x,farBelowY,component,components,bitDepth)+
                        code(after,afterStride,x,farBelowY,component,components,bitDepth))>>1;
                    int upper=vp_max(center-below[3],vp_max(center-above[3],vp_min(farAbove-above[3],farBelow-below[3])));
                    int lower=vp_min(center-below[3],vp_min(center-above[3],vp_max(farAbove-above[3],farBelow-below[3])));
                    bound=vp_max(bound,vp_max(lower,-upper));
                }
                prediction=vp_clamp(prediction,center-bound,center+bound);
            }
            store_code(output,outputStride,x,y,component,components,bitDepth,prediction);
        }
    }
    return 0;
}

int VPYADIFProcessPlane(const uint8_t *previous, size_t previousStride,
                       const uint8_t *current, size_t currentStride,
                       const uint8_t *next, size_t nextStride,
                       uint8_t *output, size_t outputStride,
                       int width, int height, int components, int bitDepth,
                       int outputIndex, int topFieldFirst, int spatialOnly) {
    return VPYADIFProcessPlaneRows(previous,previousStride,current,currentStride,next,nextStride,
        output,outputStride,width,height,components,bitDepth,outputIndex,topFieldFirst,spatialOnly,0,height);
}

int VPProbeLumaCPU(const uint8_t *current, size_t currentStride,
                   const uint8_t *previous, size_t previousStride,
                   int width, int height, int bitDepth,
                   uint64_t *combTotal, uint64_t *motionTotal) {
    if (!current || !previous || !combTotal || !motionTotal || height<3 ||
        !valid_plane(width,height,1,bitDepth,currentStride) ||
        !valid_plane(width,height,1,bitDepth,previousStride)) return -1;
    uint64_t comb=0,motion=0;
    float divisor=bitDepth==10 ? 65535.0f : 255.0f;
    for (int gy=0; gy<36; ++gy) for (int gx=0; gx<64; ++gx) {
        int x=vp_min((int)(((float)gx+0.5f)*(float)width/64.0f),width-1);
        int y=vp_clamp((int)(((float)gy+0.5f)*(float)height/36.0f),1,height-2);
        float center=(float)raw_code(current,currentStride,x,y,0,1,bitDepth)/divisor;
        float above=(float)raw_code(current,currentStride,x,y-1,0,1,bitDepth)/divisor;
        float below=(float)raw_code(current,currentStride,x,y+1,0,1,bitDepth)/divisor;
        float prior=(float)raw_code(previous,previousStride,x,y,0,1,bitDepth)/divisor;
        float c=center-0.5f*(above+below),m=center-prior;
        if (c<0) c=-c;
        if (m<0) m=-m;
        comb+=(uint16_t)(c*65535.0f);
        motion+=(uint16_t)(m*65535.0f);
    }
    *combTotal=comb;*motionTotal=motion;
    return 0;
}
