// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import XCTest
@testable import VPlayerPlayback

final class SDKFixedRangeReleaseTests: XCTestCase {
    func testFixedRangeKernel() {
        func range(_ start: Int64, _ duration: Int64, scale: Int32 = 1) -> CMTimeRange {
            CMTimeRange(start: CMTime(value: start, timescale: scale),
                        duration: CMTime(value: duration, timescale: scale))
        }
        func check(_ ranges: [CMTimeRange], _ requested: CMTimeRange, _ code: UInt32,
                   file: StaticString = #filePath, line: UInt = #line) {
            let result = ranges.withUnsafeBufferPointer {
                VPScanLoadedRangeBuffer($0.baseAddress, $0.count, requested)
            }
            XCTAssertEqual(result.code, code, file: file, line: line)
            XCTAssertEqual(result.count, UInt32(ranges.count), file: file, line: line)
        }

        // 0=覆盖，1=未覆盖，2=容量，3=非法时间。这里只测试同步生产扫描内核。
        check([], range(0, 3), 1)
        check([range(0, 3)], range(0, 3), 0)
        check(Array(repeating: range(0, 3), count: 128), range(0, 3), 0)
        check(Array(repeating: range(0, 3), count: 129), range(0, 3), 2)
        check([range(2, 1), range(0, 1), range(1, 1)], range(0, 3), 0)
        check([range(1, 2), range(0, 2), range(1, 2)], range(0, 3), 0)
        check([range(0, 1), range(2, 1)], range(0, 3), 1)
        check([range(0, 3)], range(1, 1), 0)
        check([range(0, 3)], range(3, 1), 1)
        check([range(1, 3)], range(0, 3), 1)
        check([range(0, 3), .invalid], range(0, 3), 3)
        check([range(-1, 4)], range(0, 3), 3)
        check([range(0, 0)], range(0, 3), 3)
        check([CMTimeRange(start: .indefinite,
                           duration: CMTime(value: 3, timescale: 1))], range(0, 3), 3)
        check([CMTimeRange(start: CMTime(value: 0, timescale: 1, flags: .valid, epoch: 1),
                           duration: CMTime(value: 3, timescale: 1))], range(0, 3), 3)
        check([range(0, 3)], .invalid, 3)
        check([range(Int64.max, 1)], range(0, 3), 3)

        // 不同分母的精确约分：1/3 + 1/6 = 1/2。
        check([range(1, 1, scale: 3)],
              CMTimeRange(start: CMTime(value: 1, timescale: 3),
                          duration: CMTime(value: 1, timescale: 6)), 0)

        // 约分后分母 2,147,673,613 超过 Int32.max，必须拒绝而非降精度。
        check([CMTimeRange(start: CMTime(value: 1, timescale: 46_337),
                           duration: CMTime(value: 1, timescale: 46_349))],
              CMTimeRange(start: CMTime(value: 1, timescale: 46_337),
                          duration: CMTime(value: 1, timescale: 46_349)), 3)

        // 两段之间恰有 1/48,000 秒缺口，不能被分数换标或并集扫描填平。
        check([
            CMTimeRange(start: CMTime(value: 1, timescale: 3),
                        duration: CMTime(value: 1, timescale: 6)),
            CMTimeRange(start: CMTime(value: 24_001, timescale: 48_000),
                        duration: CMTime(value: 1, timescale: 6)),
        ], CMTimeRange(start: CMTime(value: 1, timescale: 3),
                       duration: CMTime(value: 1, timescale: 3)), 1)
    }
}
