// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import CoreVideo

/// 某些 VideoToolbox 实现只把兼容 SPS 的 SDR 曲线写回像素附件，忽略已经
/// 结合 SEI 确认的 HLG。解码没有执行色调映射，不能让显示层把原始 HDR 当成 SDR。
struct VideoHDRMetadata: Sendable {
    let transfer: String

    init?(format: CMFormatDescription?) {
        guard let format,
              CMFormatDescriptionGetExtension(format,
                extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
                == kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String,
              CMFormatDescriptionGetExtension(format,
                extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String
                == kCMFormatDescriptionYCbCrMatrix_ITU_R_2020 as String,
              let transfer = CMFormatDescriptionGetExtension(format,
                extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
              transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
                || transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String else { return nil }
        self.transfer = transfer
    }

    func restoreTransferIfNeeded(on pixelBuffer: CVPixelBuffer) {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                || pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
              attachment(kCVImageBufferColorPrimariesKey, on: pixelBuffer)
                == kCVImageBufferColorPrimaries_ITU_R_2020 as String,
              attachment(kCVImageBufferYCbCrMatrixKey, on: pixelBuffer)
                == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String else { return }
        let decodedTransfer = attachment(kCVImageBufferTransferFunctionKey, on: pixelBuffer)
        guard decodedTransfer == nil
                || decodedTransfer == kCVImageBufferTransferFunction_ITU_R_709_2 as String
                || decodedTransfer == kCVImageBufferTransferFunction_ITU_R_2020 as String else { return }

        // 仅修复标签；不做像素转换，不覆盖解码器已有的 HDR/线性输出。
        // 清除旧曲线派生的颜色空间与 gamma，避免它们优先于修正后的三项色彩附件。
        CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferCGColorSpaceKey)
        CVBufferRemoveAttachment(pixelBuffer, kCVImageBufferGammaLevelKey)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey,
            transfer as CFString, .shouldPropagate)
    }

    private func attachment(_ key: CFString, on pixelBuffer: CVPixelBuffer) -> String? {
        CVBufferCopyAttachment(pixelBuffer, key, nil) as? String
    }
}
