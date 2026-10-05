#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Add a legal AVC filler NAL to the first AU of the generated single-track fMP4.

Supports only the reviewed unindexed, one-moof/one-mdat, four-byte AVC length form.
No media decode is claimed by this container transformation.
"""
from pathlib import Path
import struct
import sys


def require(condition,message):
    if not condition:raise ValueError(message)


def u32(data,offset):return struct.unpack_from('>I',data,offset)[0]


def boxes(data,start=0,end=None):
    end=len(data) if end is None else end
    result=[];position=start
    while position<end:
        require(position+8<=end and len(result)<256,'invalid bounded MP4 box header')
        size=u32(data,position);header=8
        if size==1:
            require(position+16<=end,'short extended box');size=struct.unpack_from('>Q',data,position+8)[0];header=16
        elif size==0:size=end-position
        require(header<=size<=end-position,'truncated or invalid MP4 box')
        result.append(dict(kind=data[position+4:position+8],start=position,payload=position+header,end=position+size,header=header))
        position+=size
    return result


def one(values,kind):
    matches=[value for value in values if value['kind']==kind]
    require(len(matches)==1,f'missing/duplicate {kind!r}')
    return matches[0]


def children(data,box):return boxes(data,box['payload'],box['end'])


def first_sample(data):
    require(0<len(data)<=8*1024**2,'source fixture exceeds bounded input size')
    top=boxes(data)
    require(not any(value['kind'] in (b'sidx',b'mfra') for value in top),'indexed layout is unsupported')
    moov=one(top,b'moov')
    parent=moov
    for kind in (b'trak',b'mdia',b'minf',b'stbl',b'stsd'):parent=one(children(data,parent),kind)
    require(parent['payload']+8<=parent['end'] and u32(data,parent['payload']+4)==1,'one sample entry required')
    entry=one(boxes(data,parent['payload']+8,parent['end']),b'avc1')
    require(entry['payload']+78<=entry['end'],'short AVC sample entry')
    avcc=one(boxes(data,entry['payload']+78,entry['end']),b'avcC')
    require(avcc['payload']+5<=avcc['end'] and (data[avcc['payload']+4]&3)==3,'four-byte AVC NAL lengths required')
    moof=one(top,b'moof');mdat=one(top,b'mdat');traf=one(children(data,moof),b'traf')
    tfhd=one(children(data,traf),b'tfhd');trun=one(children(data,traf),b'trun')
    require(tfhd['payload']+8<=tfhd['end'],'short tfhd')
    tfhd_flags=u32(data,tfhd['payload'])&0xffffff
    require(tfhd_flags&0x020000 and not tfhd_flags&1,'default-base-is-moof is required')
    require(trun['payload']+12<=trun['end'],'short trun')
    flags=u32(data,trun['payload'])&0xffffff
    require(flags&1 and flags&0x200,'explicit data offset and sample sizes required')
    count=u32(data,trun['payload']+4);require(1<=count<=256,'invalid sample count')
    offset=moof['start']+struct.unpack_from('>i',data,trun['payload']+8)[0]
    cursor=trun['payload']+12+(4 if flags&4 else 0)
    stride=sum(4 for flag in (0x100,0x200,0x400,0x800) if flags&flag)
    require(cursor+count*stride<=trun['end'],'short sample table')
    size_field=cursor+(4 if flags&0x100 else 0);size=u32(data,size_field)
    require(offset==mdat['payload'] and size>=6 and offset+size<=mdat['end'],'unsupported first sample position')
    return dict(offset=offset,size=size,size_field=size_field,mdat=mdat)


def pad(data,target):
    require(target in (1_048_576,1_048_577),'unreviewed first-AU target')
    info=first_sample(data);extra=target-info['size'];require(extra>=6,'existing AU is too large for legal filler')
    # AVCC length excludes its own four bytes; NAL type12 is filler_data and the
    # final0x80 is rbsp_trailing_bits. No original VCL byte is modified.
    filler=struct.pack('>I',extra-4)+b'\x0c'+b'\xff'*(extra-6)+b'\x80'
    result=bytearray(data)
    struct.pack_into('>I',result,info['size_field'],target)
    mdat=info['mdat'];new_size=mdat['end']-mdat['start']+extra
    if mdat['header']==16:struct.pack_into('>Q',result,mdat['start']+8,new_size)
    else:struct.pack_into('>I',result,mdat['start'],new_size)
    end=info['offset']+info['size'];result[end:end]=filler
    require(first_sample(result)['size']==target,'padded sample size verification failed')
    return bytes(result)


def main():
    require(len(sys.argv)==4,'Usage: pad_source_fixture_au.py input.mp4 output.mp4 1048576|1048577')
    source,destination=map(Path,sys.argv[1:3])
    require(source.resolve()!=destination.resolve(),'cannot overwrite original sample')
    destination.write_bytes(pad(source.read_bytes(),int(sys.argv[3])))

if __name__=='__main__':
    try:main()
    except (ValueError,OSError,struct.error) as error:raise SystemExit(f'public fixture padding failed: {error}')
