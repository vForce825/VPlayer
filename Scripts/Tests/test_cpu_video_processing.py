#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Execute the portable CPU kernels against committed independently generated goldens."""
from pathlib import Path
import ctypes as C
import mmap
import os
import platform
import random
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
    def backend_function(self):
        self.require_kernel()
        self.assertTrue(hasattr(self.library, 'VPYADIFProcessPlaneRowsWithBackend'),
                        'explicit scalar/NEON execution and a per-call block report are missing')
        function = self.library.VPYADIFProcessPlaneRowsWithBackend
        function.argtypes = [C.c_void_p, C.c_size_t] * 4 + [C.c_int] * 10 + [C.POINTER(C.c_size_t)]
        function.restype = C.c_int
        return function

    def test_explicit_backend_contract_requires_real_vector_execution(self):
        function = self.backend_function()
        self.assertTrue(hasattr(self.library, 'VPYADIFProcessPlaneRowsScalar'))
        self.assertTrue(hasattr(self.library, 'VPYADIFNEONAvailable'))
        available = self.library.VPYADIFNEONAvailable()
        self.assertEqual(available, int(platform.machine().lower() in ['arm64', 'aarch64']))
        width, height = 32, 7
        frames = [C.create_string_buffer(data) for data in boundary_frames(width, height, 1, 8)]
        output = C.create_string_buffer(bytes([0xA5]) * (width * height))
        blocks = C.c_size_t(999)
        arguments = [frames[0], width, frames[1], width, frames[2], width,
                     output, width, width, height, 1, 8, 0, 1, 0, 0, height]
        result = function(*arguments, 1, C.byref(blocks))
        self.assertEqual(result, 0 if available else -2)
        self.assertEqual(blocks.value, 9 if available else 0)
        if not available:
            self.assertEqual(output.raw[:width * height], bytes([0xA5]) * (width * height))
        self.assertEqual(function(*arguments, 0, C.byref(blocks)), 0)
        self.assertEqual(blocks.value, 0)
        self.assertEqual(output.raw[:width * height], scalar_yadif_reference(
            [data.raw[:width * height] for data in frames], width, height, 1, 8, 0, 1, False))
        original = output.raw
        self.assertEqual(function(*arguments, 8, C.byref(blocks)), -1)
        self.assertEqual(output.raw, original)
        self.assertEqual(blocks.value, 0)
    def run_plane(self, frames, width,height,components,depth,index,top,spatial=False,padding=0,backend=None):
        self.require_kernel()
        row=width*components*(2 if depth==10 else 1);stride=row+padding
        inputs=[]
        for frame in frames:
            data=bytearray([0xED])*(stride*height)
            for y in range(height): data[y*stride:y*stride+row]=frame[y*row:(y+1)*row]
            inputs.append(C.create_string_buffer(bytes(data)))
        output=C.create_string_buffer(bytes([0xA5])*(stride*height))
        arguments = [inputs[0],stride,inputs[1],stride,inputs[2],stride,output,stride,width,height,components,depth,index,top,int(spatial)]
        if backend is None:
            result=self.library.VPYADIFProcessPlane(*arguments)
        else:
            blocks = C.c_size_t(999)
            result=self.backend_function()(*arguments,0,height,backend,C.byref(blocks))
            synthesized = sum(y % 2 != ((0 if top else 1) ^ index) for y in range(height))
            self.assertEqual(blocks.value, max(0, (width - 6) * components // 8) * synthesized if backend == 1 else 0)
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
                    self.backend_function()
                    for backend in [None, 0] + ([1] if self.library.VPYADIFNEONAvailable() else []):
                        actual=bytearray()
                        for current in range(1,4):
                            for index in range(2):
                                window=frames[current-1:current+2]
                                actual+=self.run_plane([x[:ysize] for x in window],64,36,1,depth,index,top,padding=14,backend=backend)
                                actual+=self.run_plane([x[ysize:] for x in window],32,18,2,depth,index,top,padding=10,backend=backend)
                        self.assertEqual(bytes(actual),expected)

    def test_backends_match_independent_oracle_for_vector_boundaries_random_and_ties(self):
        self.backend_function()
        rng = random.Random(0x5941444946)
        for width in [6, 7, 9, 10, 13, 14, 15, 17, 21, 22, 23, 30, 31, 37]:
            for height in [2, 3, 8, 9]:
                for components in [1, 2]:
                    for depth in [8, 10]:
                        maximum = (1 << depth) - 1
                        for pattern in ['random', 'ties']:
                            frames = []
                            for frame in range(3):
                                data = bytearray()
                                for sample in range(width * height * components):
                                    code = rng.randrange(maximum + 1) if pattern == 'random' else rng.choice([0, 0, maximum, maximum // 2])
                                    word = code if depth == 8 else (code << 6) | rng.randrange(64)
                                    data.extend(word.to_bytes(1 if depth == 8 else 2, 'little'))
                                frames.append(bytes(data))
                            for top, index, spatial in [(0,0,0),(0,1,1),(1,0,1),(1,1,0)]:
                                with self.subTest(width=width, height=height, components=components,
                                                  depth=depth, pattern=pattern, top=top, index=index, spatial=spatial):
                                    expected = scalar_yadif_reference(frames,width,height,components,depth,index,top,spatial)
                                    backends = [None, 0]
                                    if self.library.VPYADIFNEONAvailable() and (width - 6) * components >= 8:
                                        backends.append(1)
                                    for backend in backends:
                                        self.assertEqual(self.run_plane(frames,width,height,components,depth,index,top,spatial,7,backend),expected)

    def test_required_neon_rejects_narrow_copied_only_overlap_and_overflow_without_writes(self):
        function = self.backend_function()
        width, height = 32, 7
        buffers = [C.create_string_buffer(bytes([value]) * (width * height + 64)) for value in [71,93,111,0xA5]]
        base = [buffers[0],width,buffers[1],width,buffers[2],width,buffers[3],width,
                width,height,1,8,0,1,0,0,height]
        cases = []
        narrow = base.copy(); narrow[8] = 13; cases.append(narrow)
        copied = base.copy(); copied[16] = 1; cases.append(copied)
        empty = base.copy(); empty[16] = 0; cases.append(empty)
        for source in [0,2,4]:
            overlap = base.copy(); overlap[6] = C.byref(buffers[source // 2],1); cases.append(overlap)
        overflow = base.copy(); overflow[0] = C.c_void_p(C.c_size_t(-1).value - 16); cases.append(overflow)
        for arguments in cases:
            originals = [buffer.raw for buffer in buffers]
            blocks = C.c_size_t(999)
            self.assertEqual(function(*arguments,1,C.byref(blocks)),-2)
            self.assertEqual(blocks.value,0)
            self.assertEqual([buffer.raw for buffer in buffers],originals)
        for stride_index in [1,3,5,7]:
            invalid = base.copy()
            invalid[stride_index] = C.c_size_t(-1).value // height + 1
            for backend in [0,1]:
                blocks = C.c_size_t(999)
                originals = [buffer.raw for buffer in buffers]
                self.assertEqual(function(*invalid,backend,C.byref(blocks)),-1)
                self.assertEqual(blocks.value,0)
                self.assertEqual([buffer.raw for buffer in buffers],originals)

    def test_directional_ties_and_near_gate_have_distinct_expected_pixels(self):
        self.backend_function()
        cases = [([1,3,2,2,1,1,2], [0,0,3,0,2,2,4], 1),
                 ([3,2,3,4,3,1,1], [2,1,0,4,4,0,2], 4)]
        for depth in [8,10]:
            for components in [1,2]:
                for above,below,expected in cases:
                    width,height = 22,5
                    size = 1 if depth == 8 else 2
                    plane = bytearray(width*height*components*size)
                    for y,taps in [(1,above),(3,below)]:
                        for x,code in enumerate(taps):
                            for component in range(components):
                                word = code if depth == 8 else (code << 6) | 63
                                start = ((y*width+x)*components+component)*size
                                plane[start:start+size] = word.to_bytes(size,'little')
                    for backend in [None,0] + ([1] if self.library.VPYADIFNEONAvailable() else []):
                        result = self.run_plane([plane]*3,width,height,components,depth,1,1,True,3,backend)
                        for component in range(components):
                            start = ((2*width+3)*components+component)*size
                            self.assertEqual(int.from_bytes(result[start:start+size],'little'),
                                             expected if depth == 8 else expected << 6)

    @unittest.skipUnless(hasattr(os, 'fork') and os.name == 'posix', 'POSIX guard pages unavailable')
    def test_row_guard_pages_for_random_vector_boundaries(self):
        self.backend_function()
        # Isolate a potential protection fault so a regression is reported as a
        # failed test instead of terminating the entire Python test runner.
        child = os.fork()
        if child == 0:
            try:
                libc = C.CDLL(None)
                libc.mprotect.argtypes = [C.c_void_p,C.c_size_t,C.c_int]
                libc.mprotect.restype = C.c_int
                page = mmap.PAGESIZE
                rng = random.Random(0x4755415244)
                for depth in [8,10]:
                    for components in [1,2]:
                        for width in [10,13,14,15,21,22,23,31]:
                            height = 7
                            row = width*components*(1 if depth == 8 else 2)
                            stride = 2*page
                            total = (2*height+2)*page
                            frames = [bytes(rng.randrange(256) for _ in range(row*height)) for _ in range(3)]
                            for align_right in [False,True]:
                                offset = page-row if align_right else 0
                                regions = [mmap.mmap(-1,total) for _ in range(4)]
                                bases = [C.addressof(C.c_char.from_buffer(region)) for region in regions]
                                pointers = [base+page+offset for base in bases]
                                for base in bases:
                                    C.memset(base,0xA5,total)
                                    for guard_page in range(0,2*height+1,2):
                                        if libc.mprotect(base+guard_page*page,page,0) != 0:
                                            raise RuntimeError('mprotect failed')
                                for pointer,frame in zip(pointers,frames):
                                    for y in range(height): C.memmove(pointer+y*stride,frame[y*row:(y+1)*row],row)
                                arguments = []
                                for pointer in pointers: arguments.extend([pointer,stride])
                                for top,index,spatial in [(0,0,0),(0,1,1),(1,0,1),(1,1,0)]:
                                    expected = scalar_yadif_reference(frames,width,height,components,depth,index,top,spatial)
                                    backends = [0] + ([1] if self.library.VPYADIFNEONAvailable() and (width-6)*components >= 8 else [])
                                    for backend in backends:
                                        blocks = C.c_size_t()
                                        result = self.backend_function()(*arguments,width,height,components,depth,index,top,spatial,0,height,backend,C.byref(blocks))
                                        if result != 0: raise AssertionError(result)
                                        actual = b''.join(C.string_at(pointers[3]+y*stride,row) for y in range(height))
                                        if actual != expected: raise AssertionError('guard-page pixel mismatch')
                                        for y in range(height):
                                            accessible = C.string_at(bases[3]+(2*y+1)*page,page)
                                            if accessible[:offset] != bytes([0xA5])*offset or accessible[offset+row:] != bytes([0xA5])*(page-offset-row):
                                                raise AssertionError('guard-page padding overwrite')
                                for region in regions: region.close()
                os._exit(0)
            except BaseException:
                import traceback
                traceback.print_exc()
                os._exit(1)
        _,status = os.waitpid(child,0)
        self.assertTrue(os.WIFEXITED(status), f'guard-page child terminated by signal: {status}')
        self.assertEqual(os.WEXITSTATUS(status),0)

    def test_scalar_and_automatic_preserve_incidental_overlap_traversal(self):
        function = self.backend_function()
        scalar = self.library.VPYADIFProcessPlaneRowsScalar
        scalar.argtypes = [C.c_void_p,C.c_size_t] * 4 + [C.c_int] * 9
        auto = self.library.VPYADIFProcessPlaneRows
        auto.argtypes = scalar.argtypes
        for depth in [8,10]:
            width,height,components = 32,7,2
            stride = width * components * (1 if depth == 8 else 2)
            frames = boundary_frames(width,height,components,depth)
            for alias in range(3):
                # Synthesize a single row so this compatibility check does not
                # depend on memcpy's undefined partial-overlap behavior.
                results = []
                for kernel in [scalar,auto]:
                    inputs = [C.create_string_buffer(frame + bytes(32)) for frame in frames]
                    self.assertEqual(kernel(inputs[0],stride,inputs[1],stride,inputs[2],stride,
                        C.byref(inputs[alias],1),stride,width,height,components,depth,0,1,0,1,1),0)
                    results.append([value.raw for value in inputs])
                self.assertEqual(results[0],results[1])
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
        height, guard = 7, 17
        for width in [1, 6, 7, 8, 13, 14, 17, 22, 31]:
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
