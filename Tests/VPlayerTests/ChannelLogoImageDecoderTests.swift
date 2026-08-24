// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import VPlayer

final class ChannelLogoImageDecoderTests: XCTestCase {
    func testDimensionPredicateRejectsOversizedAndOverflowingImages() {
        let decoder = ChannelLogoImageDecoder()

        XCTAssertTrue(decoder.accepts(width: 8_192, height: 2_048))
        XCTAssertFalse(decoder.accepts(width: 8_193, height: 1))
        XCTAssertFalse(decoder.accepts(width: 4_097, height: 4_096))
        XCTAssertFalse(decoder.accepts(width: Int.max, height: 2))
    }

    func testMalformedDataIsRejected() {
        XCTAssertNil(
            ChannelLogoImageDecoder().decodeThumbnail(
                from: Data("not-an-image".utf8)
            )
        )
    }

    func testRealOversizedPNGMetadataIsRejectedBeforeThumbnailDecode() throws {
        let decoder = ChannelLogoImageDecoder()
        let axisOversized = try FixtureLoader.data("Images/logo-axis-8193x1.png")
        let pixelOversized = try FixtureLoader.data("Images/logo-pixels-4097x4096.png")

        XCTAssertNil(decoder.decodeThumbnail(from: axisOversized))
        XCTAssertNil(decoder.decodeThumbnail(from: pixelOversized))
    }

    func testValidWideImageIsDownsampledToThumbnailLimit() throws {
        let encoded = try makePNG(width: 2_048, height: 1)

        let decoded = try XCTUnwrap(
            ChannelLogoImageDecoder().decodeThumbnail(from: encoded)
        )

        XCTAssertEqual(decoded.image.cgImage?.width, 1_024)
        XCTAssertEqual(decoded.image.cgImage?.height, 1)
        let cgImage = try XCTUnwrap(decoded.image.cgImage)
        XCTAssertEqual(
            decoded.cost,
            cgImage.bytesPerRow * cgImage.height
        )
    }

    func testOnePixelPNGRemainsDecodable() throws {
        let data = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))

        let decoded = try XCTUnwrap(
            ChannelLogoImageDecoder().decodeThumbnail(from: data)
        )

        XCTAssertEqual(decoded.image.cgImage?.width, 1)
        XCTAssertEqual(decoded.image.cgImage?.height, 1)
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            encoded,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return encoded as Data
    }
}
