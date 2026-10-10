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


def scalar_yadif_reference(frames, width, height, components, depth, index, top, spatial):
    """Scalar field rules, independent of the optimized C traversal/specialization."""
    size = 2 if depth == 10 else 1
    def at(frame, x, y, component):
        x = min(max(x, 0), width - 1)
        offset = ((y * width + x) * components + component) * size
        word = int.from_bytes(frames[frame][offset:offset + size], 'little')
        return word >> 6 if depth == 10 else word
    result = bytearray()
    copied = (0 if top else 1) ^ index
    before, after = (0, 1) if index == 0 else (1, 2)
    for y in range(height):
        above_y = 1 if y == 0 else y - 1
        below_y = height - 2 if y + 1 == height else y + 1
        for x in range(width):
            for component in range(components):
                def read(frame, xx, yy): return at(frame, xx, yy, component)
                if y % 2 == copied:
                    prediction = read(1, x, y)
                else:
                    above, below = read(1, x, above_y), read(1, x, below_y)
                    prediction = (above + below) >> 1
                    if 3 <= x < width - 3:
                        score = sum(abs(read(1, x + k, above_y) - read(1, x + k, below_y))
                                    for k in [-1, 0, 1]) - 1
                        for sign in [-1, 1]:
                            for distance in [1, 2]:
                                direction = sign * distance
                                candidate = sum(abs(read(1, x + k + direction, above_y) -
                                                    read(1, x + k - direction, below_y))
                                                for k in [-1, 0, 1])
                                if candidate >= score: break
                                score = candidate
                                prediction = (read(1, x + direction, above_y) +
                                              read(1, x - direction, below_y)) >> 1
                    if not spatial:
                        a, b = read(before, x, y), read(after, x, y)
                        center = (a + b) >> 1
                        differences = [(abs(read(frame, x, above_y) - above) +
                                        abs(read(frame, x, below_y) - below)) >> 1
                                       for frame in [0, 2]]
                        bound = max(abs(a - b) >> 1, *differences)
                        if y != 1 and y + 2 != height:
                            far_above_y, far_below_y = y + 2 * (above_y - y), y + 2 * (below_y - y)
                            far_above = (read(before, x, far_above_y) + read(after, x, far_above_y)) >> 1
                            far_below = (read(before, x, far_below_y) + read(after, x, far_below_y)) >> 1
                            upper = max(center - below, center - above, min(far_above - above, far_below - below))
                            lower = min(center - below, center - above, max(far_above - above, far_below - below))
                            bound = max(bound, lower, -upper)
                        prediction = min(max(prediction, center - bound), center + bound)
                word = prediction << 6 if depth == 10 else prediction
                result.extend(word.to_bytes(size, 'little'))
    return bytes(result)


def boundary_frames(width, height, components, depth):
    frames = []
    for frame in range(3):
        data = bytearray()
        for y in range(height):
            for x in range(width):
                for component in range(components):
                    code = ((x * 71 + y * 193 + component * 307 + frame * 109) ^
                            ((x + frame * 3) * (y + 5) * 13)) & ((1 << depth) - 1)
                    low_bits = (x * 11 + y * 7 + component + frame * 17) & 63
                    word = (code << 6) | low_bits if depth == 10 else code
                    data.extend(word.to_bytes(2 if depth == 10 else 1, 'little'))
        frames.append(bytes(data))
    return frames


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


    def test_narrow_planes_match_scalar_field_rules_and_p010_storage(self):
        for width in range(1, 9):
            for height in [2, 3, 7]:
                for depth in [8, 10]:
                    for components in [1, 2]:
                        frames = boundary_frames(width, height, components, depth)
                        for top in [0, 1]:
                            for index in [0, 1]:
                                for spatial in [False, True]:
                                    with self.subTest(width=width, height=height, depth=depth,
                                                      components=components, top=top, index=index, spatial=spatial):
                                        expected = scalar_yadif_reference(frames, width, height, components,
                                                                          depth, index, top, spatial)
                                        actual = self.run_plane(frames, width, height, components, depth,
                                                                index, top, spatial, padding=7)
                                        self.assertEqual(actual, expected)

    def test_row_subsets_preserve_guards_padding_and_aliased_inputs(self):
        self.require_kernel()
        function = self.library.VPYADIFProcessPlaneRows
        function.argtypes = [C.c_void_p, C.c_size_t] * 4 + [C.c_int] * 9
        height, guard = 7, 16
        for width in [1, 6, 7, 8, 17]:
            for depth in [8, 10]:
                for components in [1, 2]:
                    row = width * components * (2 if depth == 10 else 1)
                    for alias in ['distinct', 'previous-current', 'all']:
                        frames = boundary_frames(width, height, components, depth)
                        strides = [row + padding for padding in [1, 7, 13, 9]]
                        inputs = []
                        for frame, stride in zip(frames, strides):
                            data = bytearray([0xED]) * (guard + stride * height + guard)
                            for y in range(height):
                                start = guard + y * stride
                                data[start:start + row] = frame[y * row:(y + 1) * row]
                            inputs.append(C.create_string_buffer(bytes(data)))
                        if alias != 'distinct':
                            frames[0], inputs[0], strides[0] = frames[1], inputs[1], strides[1]
                        if alias == 'all':
                            frames[2], inputs[2], strides[2] = frames[1], inputs[1], strides[1]
                        original_inputs = [value.raw for value in inputs]
                        for top in [0, 1]:
                            for index in [0, 1]:
                                for spatial in [False, True]:
                                    with self.subTest(width=width, depth=depth, components=components,
                                                      alias=alias, top=top, index=index, spatial=spatial):
                                        expected = scalar_yadif_reference(frames, width, height, components,
                                                                          depth, index, top, spatial)
                                        total = guard + strides[3] * height + guard
                                        output = C.create_string_buffer(bytes([0xA5]) * total)
                                        expected_storage = bytearray([0xA5]) * total
                                        for start, count in [(1, 3), (0, 1), (4, 3)]:
                                            arguments = []
                                            for value, stride in zip(inputs, strides):
                                                arguments.extend([C.byref(value, guard), stride])
                                            arguments.extend([C.byref(output, guard), strides[3], width, height,
                                                              components, depth, index, top, int(spatial), start, count])
                                            self.assertEqual(function(*arguments), 0)
                                            for y in range(start, start + count):
                                                offset = guard + y * strides[3]
                                                expected_storage[offset:offset + row] = expected[y * row:(y + 1) * row]
                                            self.assertEqual(output.raw[:total], bytes(expected_storage))
                                            self.assertEqual([value.raw for value in inputs], original_inputs)

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
