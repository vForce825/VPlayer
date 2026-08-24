// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import ImageIO
import UIKit

struct DecodedChannelLogo: @unchecked Sendable {
    let image: UIImage
    let cost: Int
}

protocol ChannelLogoImageDecoding: Sendable {
    func decodeThumbnail(from data: Data) -> DecodedChannelLogo?
}

struct ChannelLogoImageDecoder: ChannelLogoImageDecoding {
    let maximumAxis: Int
    let maximumPixels: Int
    let thumbnailMaxPixelSize: Int

    init(
        maximumAxis: Int = 8_192,
        maximumPixels: Int = 16_777_216,
        thumbnailMaxPixelSize: Int = 1_024
    ) {
        self.maximumAxis = maximumAxis
        self.maximumPixels = maximumPixels
        self.thumbnailMaxPixelSize = thumbnailMaxPixelSize
    }

    func accepts(width: Int, height: Int) -> Bool {
        guard width > 0,
              height > 0,
              width <= maximumAxis,
              height <= maximumAxis,
              height <= maximumPixels else {
            return false
        }
        return width <= maximumPixels / height
    }

    func decodeThumbnail(from data: Data) -> DecodedChannelLogo? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              accepts(width: width, height: height) else {
            return nil
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions
        ) else {
            return nil
        }
        let (cost, overflow) = thumbnail.bytesPerRow.multipliedReportingOverflow(
            by: thumbnail.height
        )
        return DecodedChannelLogo(
            image: UIImage(cgImage: thumbnail, scale: 1, orientation: .up),
            cost: overflow ? Int.max : cost
        )
    }
}
