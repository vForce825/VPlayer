#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Execute the portable CPU kernels against committed independently generated goldens."""
from pathlib import Path
import ctypes as C
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
SOURCE=ROOT/'Sources/VPlayerPlayback/ProcessingCPU/VPVideoProcessingCPU.c'

class CPUVideoProcessingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary=tempfile.TemporaryDirectory()
        cls.library=None
        if SOURCE.exists():
            compiler=shutil.which('cc')
            if not compiler: raise unittest.SkipTest('C compiler unavailable')
            output=Path(cls.temporary.name)/'video.so'
            subprocess.run([compiler,'-std=c11','-O3','-Wall','-Wextra','-Werror','-shared','-fPIC',str(SOURCE),'-o',str(output)],check=True)
            cls.library=C.CDLL(str(output))
            cls.library.VPYADIFProcessPlane.argtypes=[C.c_void_p,C.c_size_t]*4+[C.c_int]*7
            cls.library.VPYADIFProcessPlane.restype=C.c_int
            cls.library.VPProbeLumaCPU.argtypes=[C.c_void_p,C.c_size_t]*2+[C.c_int]*3+[C.POINTER(C.c_uint64)]*2
            cls.library.VPProbeLumaCPU.restype=C.c_int
    @classmethod
    def tearDownClass(cls): cls.temporary.cleanup()
    def require_kernel(self): self.assertIsNotNone(self.library,'CPU video kernels are not implemented')
    def run_plane(self, frames, width,height,components,depth,index,top,spatial=False,padding=0):
        self.require_kernel()
        row=width*components*(2 if depth==10 else 1);stride=row+padding
        inputs=[]
        for frame in frames:
            data=bytearray([0xED])*(stride*height)
            for y in range(height): data[y*stride:y*stride+row]=frame[y*row:(y+1)*row]
            inputs.append(C.create_string_buffer(bytes(data)))
        output=C.create_string_buffer(bytes([0xA5])*(stride*height))
        result=self.library.VPYADIFProcessPlane(inputs[0],stride,inputs[1],stride,inputs[2],stride,output,stride,width,height,components,depth,index,top,int(spatial))
        self.assertEqual(result,0)
        for y in range(height): self.assertEqual(output.raw[y*stride+row:(y+1)*stride],bytes([0xA5])*padding)
        return b''.join(output.raw[y*stride:y*stride+row] for y in range(height))
    def test_all_committed_yadif_golden_frames_match_exactly(self):
        self.require_kernel()
        for stem,depth,bpf in [('nv12',8,3456),('p010',10,6912)]:
            for order,top in [('tff',1),('bff',0)]:
                with self.subTest(format=stem,order=order):
                    base=ROOT/'Tests/Fixtures/Video'
                    source=(base/f'yadif-{stem}-{order}-input.bin').read_bytes()
                    expected=(base/f'yadif-{stem}-{order}.bin').read_bytes()
                    frames=[source[i*bpf:(i+1)*bpf] for i in range(5)]
                    ysize=64*36*(2 if depth==10 else 1)
                    actual=bytearray()
                    for current in range(1,4):
                        for index in range(2):
                            window=frames[current-1:current+2]
                            actual+=self.run_plane([x[:ysize] for x in window],64,36,1,depth,index,top,padding=14)
                            actual+=self.run_plane([x[ysize:] for x in window],32,18,2,depth,index,top,padding=10)
                    self.assertEqual(bytes(actual),expected)
    def test_spatial_only_constant_planes_preserve_codes_and_borders(self):
        for depth in [8,10]:
            sample=bytes([123]) if depth==8 else (777<<6).to_bytes(2,'little')
            for width,height in [(2,2),(5,3),(7,7)]:
                plane=sample*(width*height)
                for index in [0,1]:
                    self.assertEqual(self.run_plane([plane]*3,width,height,1,depth,index,1,True,6),plane)
    def test_invalid_dimensions_depth_and_stride_fail_without_writing(self):
        self.require_kernel();sample=C.create_string_buffer(bytes(64));output=C.create_string_buffer(bytes([0xA5])*64)
        for width,height,components,depth,stride in [(0,4,1,8,8),(4,1,1,8,8),(4,4,3,8,16),(4,4,1,12,16),(4,4,2,10,8)]:
            self.assertNotEqual(self.library.VPYADIFProcessPlane(sample,stride,sample,stride,sample,stride,output,stride,width,height,components,depth,0,1,0),0)
            self.assertEqual(output.raw[:64],bytes([0xA5])*64)
    def test_partitioned_rows_match_whole_plane_without_overlap(self):
        self.require_kernel()
        self.assertTrue(hasattr(self.library, 'VPYADIFProcessPlaneRows'), 'bounded row partitioning is missing')
        function=self.library.VPYADIFProcessPlaneRows
        function.argtypes=[C.c_void_p,C.c_size_t]*4+[C.c_int]*9
        from concurrent.futures import ThreadPoolExecutor
        for depth in [8,10]:
            width,height,components=17,13,2
            b=2 if depth==10 else 1;stride=width*components*b
            frames=[bytes((i*17+n)%256 for i in range(stride*height)) for n in [1,2,3]]
            expected=self.run_plane(frames,width,height,components,depth,0,1)
            inputs=[C.create_string_buffer(frame) for frame in frames]
            output=C.create_string_buffer(stride*height)
            with ThreadPoolExecutor(max_workers=4) as pool:
                tasks=[pool.submit(function,inputs[0],stride,inputs[1],stride,inputs[2],stride,output,stride,width,height,components,depth,0,1,0,start,min(4,height-start)) for start in range(0,height,4)]
                self.assertEqual([task.result() for task in tasks],[0]*len(tasks))
            self.assertEqual(output.raw,expected)

    def test_scan_flat_and_full_motion_are_exact(self):
        self.require_kernel()
        for depth,value in [(8,255),(10,65535)]:
            current=C.create_string_buffer((value.to_bytes(2,'little') if depth==10 else bytes([value]))*64*36)
            previous=C.create_string_buffer(bytes(len(current.raw)))
            comb=C.c_uint64();motion=C.c_uint64();stride=64*(2 if depth==10 else 1)
            self.assertEqual(self.library.VPProbeLumaCPU(current,stride,previous,stride,64,36,depth,C.byref(comb),C.byref(motion)),0)
            self.assertEqual(comb.value,0)
            self.assertEqual(motion.value,64*36*65535)

if __name__=='__main__': unittest.main()
