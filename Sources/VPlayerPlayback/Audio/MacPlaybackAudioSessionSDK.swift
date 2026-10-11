// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
#if os(macOS)
import CoreAudio
import Foundation
import ObjectiveC
import Security

/// Mac 没有需要激活的全局 AVAudioSession，输出租约仍由现有 Registry 管理。
final class MacPlaybackAudioSessionSDK: PlaybackAudioSessionSDK, @unchecked Sendable {
    func setPlaybackCategory(policy: AudioSessionActualPolicy) throws {}
    func setSupportsMultichannelContent() throws {}
    func activate() async throws -> Bool { true }
    func deactivate() async throws -> Bool { true }
    func currentRoute() -> any AudioSessionRouteSnapshot { MacAudioRouteSnapshot() }
    func fillRandomBytes(_ bytes: UnsafeMutableRawBufferPointer) -> Bool {
        guard let base = bytes.baseAddress else { return false }
        return SecRandomCopyBytes(kSecRandomDefault, bytes.count, base) == errSecSuccess
    }
}

typealias SystemPlaybackAudioSessionSDK = MacPlaybackAudioSessionSDK
typealias SystemAudioSessionRouteSnapshot = MacAudioRouteSnapshot

enum MacAudioDeviceProperties {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func integer(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var property = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = withUnsafeMutableBytes(of: &value) {
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? value : nil
    }
    static func rate(_ object: AudioObjectID) -> Double {
        var property = address(kAudioDevicePropertyNominalSampleRate)
        var value: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = withUnsafeMutableBytes(of: &value) {
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr && value.isFinite && value > 0 ? value : 0
    }
    static var defaultOutput: AudioObjectID {
        integer(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) ?? kAudioObjectUnknown
    }
    static func uid(_ object: AudioObjectID) -> String? {
        var property = address(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutableBytes(of: &value) {
            AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
    static func portName(transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: PlaybackAudioPortNames.builtInSpeaker
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: PlaybackAudioPortNames.HDMI
        case kAudioDeviceTransportTypeBluetooth: PlaybackAudioPortNames.bluetoothA2DP
        case kAudioDeviceTransportTypeBluetoothLE: PlaybackAudioPortNames.bluetoothLE
        case kAudioDeviceTransportTypeAirPlay: PlaybackAudioPortNames.airPlay
        default: "MacAudioOutput"
        }
    }
}

final class MacAudioRouteSnapshot: AudioSessionRouteSnapshot, @unchecked Sendable {
    private let endpoint: AudioSessionRouteEndpoint?
    let outputLatency: TimeInterval
    let ioBufferDuration: TimeInterval
    var endpointCount: Int { endpoint == nil ? 0 : 1 }
    init() {
        let device = MacAudioDeviceProperties.defaultOutput
        let rate = MacAudioDeviceProperties.rate(device)
        let latency = MacAudioDeviceProperties.integer(device, kAudioDevicePropertyLatency,
            scope: kAudioObjectPropertyScopeOutput) ?? 0
        let safety = MacAudioDeviceProperties.integer(device, kAudioDevicePropertySafetyOffset,
            scope: kAudioObjectPropertyScopeOutput) ?? 0
        let buffer = MacAudioDeviceProperties.integer(device, kAudioDevicePropertyBufferFrameSize) ?? 0
        outputLatency = rate > 0 ? (Double(latency) + Double(safety)) / rate : 0
        ioBufferDuration = rate > 0 ? Double(buffer) / rate : 0
        if device != kAudioObjectUnknown, let uid = MacAudioDeviceProperties.uid(device), !uid.isEmpty {
            let transport = MacAudioDeviceProperties.integer(device, kAudioDevicePropertyTransportType) ?? 0
            endpoint = .init(uid: uid as NSString,
                portType: MacAudioDeviceProperties.portName(transport: transport) as NSString, dataSource: .missing)
        } else { endpoint = nil }
    }
    func endpoint(at index: Int) -> AudioSessionRouteEndpoint {
        guard index == 0, let endpoint else { return .init(uid: "", portType: "", dataSource: .invalid) }
        return endpoint
    }
}

/// 使用固定监听集合，设备切换时重绑设备属性；突发回调由现有安全入口合并。
final class MacAudioDeviceObserver: @unchecked Sendable {
    private struct Listener {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    static var allocationReservationBytes: Int {
        // 固定的两个系统监听与五个设备监听；含原生 block、Swift 捕获及数组峰值容量。
        malloc_good_size(class_getInstanceSize(MacAudioDeviceObserver.self)) + 128 + 48 +
            malloc_good_size(32 + 8 * MemoryLayout<Listener>.stride) + 7 * (64 + 48 + 32) + 80
    }
    private let queue = DispatchQueue(label: "com.vplayer.macos.audio-device")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let changed: @Sendable () -> Void
    private var listeners: [Listener] = []
    private var stopped = false
    private var device: AudioObjectID = kAudioObjectUnknown

    init(changed: @escaping @Sendable () -> Void) {
        self.changed = changed
        listeners.reserveCapacity(8)
        queue.setSpecific(key: queueKey, value: true)
        queue.sync { bind() }
    }
    deinit { stop() }
    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == true { remove(); stopped = true }
        else { queue.sync { remove(); stopped = true } }
    }
    private func remove() {
        for var listener in listeners {
            AudioObjectRemovePropertyListenerBlock(listener.object, &listener.address, queue, listener.block)
        }
        listeners.removeAll(keepingCapacity: true)
    }
    private func bind() {
        remove()
        device = MacAudioDeviceProperties.defaultOutput
        add(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        add(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        if device != kAudioObjectUnknown {
            add(device, kAudioDevicePropertyNominalSampleRate)
            add(device, kAudioDevicePropertyBufferFrameSize)
            add(device, kAudioDevicePropertyDeviceIsAlive)
            add(device, kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeOutput)
            add(device, kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        }
    }
    private func add(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) {
        var address = MacAudioDeviceProperties.address(selector, scope: scope)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.stopped else { return }
            if self.device != MacAudioDeviceProperties.defaultOutput { self.bind() }
            self.changed()
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
            listeners.append(.init(object: object, address: address, block: block))
        }
    }
}
#endif
