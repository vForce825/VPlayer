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

// A row is addressed in component samples. UV neighbors remain two samples
// apart; memcpy keeps P010 access valid even when a row address is unaligned.
static inline int sample_code(const uint8_t *plane, size_t stride,
                              int i, int y, int depth) {
    const uint8_t *address = plane + (size_t)y * stride +
        (size_t)i * (depth == 10 ? 2u : 1u);
    if (depth == 8) return *address;
    uint16_t value;
    memcpy(&value, address, sizeof(value));
    return value >> 6;
}
static inline void sample_store(uint8_t *plane, size_t stride,
                                int i, int y, int depth, int value) {
    uint8_t *address = plane + (size_t)y * stride +
        (size_t)i * (depth == 10 ? 2u : 1u);
    if (depth == 8) { *address = (uint8_t)value; return; }
    uint16_t word = (uint16_t)((unsigned)value << 6);
    memcpy(address, &word, sizeof(word));
}

// Keep one set of equations while specializing depth, component spacing and
// border handling at the call sites below. No restrict aliasing is introduced.
static inline __attribute__((always_inline)) int vp_synthesize(
    const uint8_t *previous, size_t previousStride,
    const uint8_t *current, size_t currentStride,
    const uint8_t *next, size_t nextStride,
    const uint8_t *before, size_t beforeStride,
    const uint8_t *after, size_t afterStride,
    int i, int y, int aboveY, int belowY, int height,
    int components, int bitDepth, int spatialOnly, int interior) {
    int above[7], below[7];
    if (interior) {
        for (int k=-3;k<=3;++k) {
            above[k+3]=sample_code(current,currentStride,i+k*components,aboveY,bitDepth);
            below[k+3]=sample_code(current,currentStride,i+k*components,belowY,bitDepth);
        }
    } else {
        above[3]=sample_code(current,currentStride,i,aboveY,bitDepth);
        below[3]=sample_code(current,currentStride,i,belowY,bitDepth);
    }
    int prediction=(above[3]+below[3])>>1;
    if (interior) {
        // Preserve the scalar search: far may improve only if near improved;
        // ties retain the prior prediction, with negative directions first.
        int score=vp_abs(above[2]-below[2])+vp_abs(above[3]-below[3])+vp_abs(above[4]-below[4])-1;
        {
            int nearScore=vp_abs(above[1]-below[3])+vp_abs(above[2]-below[4])+vp_abs(above[3]-below[5]);
            int nearPrediction=(above[2]+below[4])>>1;
            int farScore=vp_abs(above[0]-below[4])+vp_abs(above[1]-below[5])+vp_abs(above[2]-below[6]);
            int farPrediction=(above[1]+below[5])>>1;
            int takeNear=nearScore<score;
            int takeFar=takeNear && farScore<nearScore;
            prediction=takeNear ? nearPrediction : prediction;
            score=takeNear ? nearScore : score;
            prediction=takeFar ? farPrediction : prediction;
            score=takeFar ? farScore : score;
        }
        {
            int nearScore=vp_abs(above[3]-below[1])+vp_abs(above[4]-below[2])+vp_abs(above[5]-below[3]);
            int nearPrediction=(above[4]+below[2])>>1;
            int farScore=vp_abs(above[4]-below[0])+vp_abs(above[5]-below[1])+vp_abs(above[6]-below[2]);
            int farPrediction=(above[5]+below[1])>>1;
            int takeNear=nearScore<score;
            int takeFar=takeNear && farScore<nearScore;
            prediction=takeNear ? nearPrediction : prediction;
            score=takeNear ? nearScore : score;
            prediction=takeFar ? farPrediction : prediction;
            score=takeFar ? farScore : score;
        }

    }
    if (!spatialOnly) {
        int temporalBefore=sample_code(before,beforeStride,i,y,bitDepth);
        int temporalAfter=sample_code(after,afterStride,i,y,bitDepth);
        int center=(temporalBefore+temporalAfter)>>1;
        int previousDifference=(vp_abs(sample_code(previous,previousStride,i,aboveY,bitDepth)-above[3])+
            vp_abs(sample_code(previous,previousStride,i,belowY,bitDepth)-below[3]))>>1;
        int nextDifference=(vp_abs(sample_code(next,nextStride,i,aboveY,bitDepth)-above[3])+
            vp_abs(sample_code(next,nextStride,i,belowY,bitDepth)-below[3]))>>1;
        int bound=vp_max(vp_abs(temporalBefore-temporalAfter)>>1,vp_max(previousDifference,nextDifference));
        if (y!=1 && y+2!=height) {
            int farAboveY=y+2*(aboveY-y),farBelowY=y+2*(belowY-y);
            int farAbove=(sample_code(before,beforeStride,i,farAboveY,bitDepth)+
                sample_code(after,afterStride,i,farAboveY,bitDepth))>>1;
            int farBelow=(sample_code(before,beforeStride,i,farBelowY,bitDepth)+
                sample_code(after,afterStride,i,farBelowY,bitDepth))>>1;
            int upper=vp_max(center-below[3],vp_max(center-above[3],vp_min(farAbove-above[3],farBelow-below[3])));
            int lower=vp_min(center-below[3],vp_min(center-above[3],vp_max(farAbove-above[3],farBelow-below[3])));
            bound=vp_max(bound,vp_max(lower,-upper));
        }
        prediction=vp_clamp(prediction,center-bound,center+bound);
    }
    return prediction;
}
static inline __attribute__((always_inline)) int vp_yadif_specialized(
                       const uint8_t *previous, size_t previousStride,
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
        if ((y & 1) == copiedParity) {
            for (int i=0;i<width*components;++i)
                sample_store(output,outputStride,i,y,bitDepth,
                    sample_code(current,currentStride,i,y,bitDepth));
            continue;
        }
        int aboveY = y == 0 ? 1 : y-1;
        int belowY = y+1 == height ? height-2 : y+1;
        // Only the three-pixel borders need the nondirectional average. The
        // interior's seven taps are all in range, so no clamp is necessary.
        int edge=width<6 ? width : 3;
        for(int i=0;i<edge*components;++i) {
            int prediction=vp_synthesize(
                previous,previousStride,current,currentStride,next,nextStride,
                before,beforeStride,after,afterStride,i,y,aboveY,belowY,height,
                components,bitDepth,spatialOnly,0);
            sample_store(output,outputStride,i,y,bitDepth,prediction);
        }
        for(int i=edge*components;i<(width-3)*components;++i) {
            int prediction=vp_synthesize(
                previous,previousStride,current,currentStride,next,nextStride,
                before,beforeStride,after,afterStride,i,y,aboveY,belowY,height,
                components,bitDepth,spatialOnly,1);
            sample_store(output,outputStride,i,y,bitDepth,prediction);
        }
        for(int i=(width<6 ? width : width-3)*components;i<width*components;++i) {
            int prediction=vp_synthesize(
                previous,previousStride,current,currentStride,next,nextStride,
                before,beforeStride,after,afterStride,i,y,aboveY,belowY,height,
                components,bitDepth,spatialOnly,0);
            sample_store(output,outputStride,i,y,bitDepth,prediction);
        }

    }
    return 0;
}
int VPYADIFProcessPlaneRows(const uint8_t *previous, size_t previousStride,
                       const uint8_t *current, size_t currentStride,
                       const uint8_t *next, size_t nextStride,
                       uint8_t *output, size_t outputStride,
                       int width, int height, int components, int bitDepth,
                       int outputIndex, int topFieldFirst, int spatialOnly, int firstRow, int rowCount) {
    if (bitDepth==8 && components==1) {
        return vp_yadif_specialized(previous,previousStride,current,currentStride,
            next,nextStride,output,outputStride,width,height,1,8,outputIndex,
            topFieldFirst,spatialOnly,firstRow,rowCount);
    }
    if (bitDepth==8 && components==2) {
        return vp_yadif_specialized(previous,previousStride,current,currentStride,
            next,nextStride,output,outputStride,width,height,2,8,outputIndex,
            topFieldFirst,spatialOnly,firstRow,rowCount);
    }
    if (bitDepth==10 && components==1) {
        return vp_yadif_specialized(previous,previousStride,current,currentStride,
            next,nextStride,output,outputStride,width,height,1,10,outputIndex,
            topFieldFirst,spatialOnly,firstRow,rowCount);
    }
    if (bitDepth==10 && components==2) {
        return vp_yadif_specialized(previous,previousStride,current,currentStride,
            next,nextStride,output,outputStride,width,height,2,10,outputIndex,
            topFieldFirst,spatialOnly,firstRow,rowCount);
    }
    return -1;
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
