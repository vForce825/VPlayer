// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia

public protocol PlaybackClock: AnyObject {
    var currentTime: CMTime { get }
    func pause()
    func anchor(mediaTime: CMTime, atHostTime hostTime: CMTime, rate: Float)
    func setRate(_ rate: Float)
}

/// 音频供给余量守卫：直播源时钟与本机音频时钟存在微小偏差时，已接纳音频领先
/// 共享时钟的余量会缓慢耗尽。这里只在余量即将耗尽时给出一次普通暂停的时长。
///
/// 绝不通过改变同步器名义速率来补偿：`AVSampleBufferRenderSynchronizer` 在两个
/// 非零速率之间切换时，系统 audio renderer 可能自动清空已排队音频，造成周期性断音。
/// 普通暂停（非零→0）与按原速率恢复（0→同一非零速率）不会触发这种清空。
enum PlaybackAudioSupplyHoldPolicy {
    /// 在输出延迟之上保留的最低余量；低于它时音频即将晚于输出所需时刻。
    static let lowWaterMargin = CMTime(value: 40, timescale: 1_000)
    /// 暂停结束时希望达到的、超过起播锚点提前量的余量。
    static let refillMargin = CMTime(value: 200, timescale: 1_000)
    static let minimumHold = CMTime(value: 50, timescale: 1_000)
    static let maximumHold = CMTime(value: 1, timescale: 1)

    /// 返回需要暂停共享时钟的时长；余量健康或输入无效时返回 nil。
    static func holdDuration(
        lead: CMTime,
        outputLatency: CMTime,
        anchorLeadTime: CMTime
    ) -> CMTime? {
        guard lead.isNumeric, outputLatency.isNumeric, anchorLeadTime.isNumeric else {
            return nil
        }
        let lowWater = CMTimeAdd(CMTimeMaximum(outputLatency, .zero), lowWaterMargin)
        guard CMTimeCompare(lead, lowWater) < 0 else { return nil }
        let target = CMTimeAdd(CMTimeMaximum(anchorLeadTime, lowWater), refillMargin)
        let deficit = CMTimeSubtract(target, lead)
        guard deficit.isNumeric else { return nil }
        if CMTimeCompare(deficit, minimumHold) < 0 { return minimumHold }
        if CMTimeCompare(deficit, maximumHold) > 0 { return maximumHold }
        return deficit
    }
}
