// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
// Read-only acceptance context: synthetic host audio, never an iOS gate.
import AVFoundation
import Foundation

let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vplayer-host-control-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: directory) }
let url = directory.appendingPathComponent("synthetic-pcm.caf")
let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
let frames: AVAudioFrameCount = 96_000
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
buffer.frameLength = frames
for channel in 0..<2 {
    for frame in 0..<Int(frames) { buffer.floatChannelData![channel][frame] = Float(0.01 * sin(Double(frame) * 2 * .pi * 440 / 48_000)) }
}
do {
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}
let item = AVPlayerItem(url: url)
let player = AVPlayer(playerItem: item)
var ended = false
let observer = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { _ in ended = true }
defer { NotificationCenter.default.removeObserver(observer); player.pause(); player.replaceCurrentItem(with: nil) }
let began = ProcessInfo.processInfo.systemUptime
player.play()
var maximumTime = 0.0
while !ended && ProcessInfo.processInfo.systemUptime - began < 10 {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    let current = player.currentTime().seconds
    if current.isFinite { maximumTime = max(maximumTime, current) }
}
print("HOST_AUDIO_CONTROL outcome=\(ended && maximumTime >= 1.9 ? "passed" : "unverified") itemStatus=\(item.status.rawValue) playerStatus=\(player.status.rawValue) timeControl=\(player.timeControlStatus.rawValue) progressed=\(maximumTime > 0.25) maximumTime=\(maximumTime) eos=\(ended) elapsed=\(ProcessInfo.processInfo.systemUptime-began) syntheticDuration=2 qualification=host-control-not-ios-acceptance")
