// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CoreFoundation
import Foundation
import Security

/// 只替代最底层同步SDK；步骤准入及真实结果提升属于Registry。
protocol PlaybackAudioSessionSDK: AnyObject, Sendable {
    func setPlaybackCategory(policy: AudioSessionActualPolicy) throws
    func setSupportsMultichannelContent() throws
    func activate() throws
    func deactivate() throws
    func currentRoute() -> any AudioSessionRouteSnapshot
    func fillRandomBytes(_ bytes: UnsafeMutableRawBufferPointer) -> Bool
}

/// 仅显式注入系统实例；Task9才建立唯一App runtime，本类型不调用sharedInstance。
final class SystemPlaybackAudioSessionSDK: PlaybackAudioSessionSDK, @unchecked Sendable {
    private let session: AVAudioSession
    init(session: AVAudioSession) { self.session = session }
    func setPlaybackCategory(policy: AudioSessionActualPolicy) throws {
        try session.setCategory(.playback, mode: .moviePlayback,
            policy: policy == .longFormAudio ? .longFormAudio : .default, options: [])
    }
    func setSupportsMultichannelContent() throws { try session.setSupportsMultichannelContent(true) }
    func activate() throws { try session.setActive(true) }
    func deactivate() throws { try session.setActive(false, options: .notifyOthersOnDeactivation) }
    func currentRoute() -> any AudioSessionRouteSnapshot {
        // 恰好一次系统route getter；不读latency/buffer/rate/channel标量。
        SystemAudioSessionRouteSnapshot(route: session.currentRoute)
    }
    func fillRandomBytes(_ bytes: UnsafeMutableRawBufferPointer) -> Bool {
        guard let base = bytes.baseAddress else { return false }
        return SecRandomCopyBytes(kSecRandomDefault, bytes.count, base) == errSecSuccess
    }
}

/// 系统描述仅活在lane投影栈；不复制UID集合，也不进入Cell、record或日志。
final class SystemAudioSessionRouteSnapshot: AudioSessionRouteSnapshot, @unchecked Sendable {
    private let route: NSObject
    private let outputs: NSArray?
    init(route: NSObject) {
        self.route = route
        let selector = #selector(getter: AVAudioSessionRouteDescription.outputs)
        if route.responds(to: selector), let outputs = route.perform(selector)?.takeUnretainedValue() as? NSArray,
           outputs.count <= 32 { self.outputs = outputs }
        else { outputs = nil }
    }
    var endpointCount: Int { outputs?.count ?? -1 }
    func endpoint(at index: Int) -> AudioSessionRouteEndpoint {
        guard let outputs, index >= 0, index < outputs.count,
              let endpoint = outputs.object(at: index) as? NSObject,
              let uid = Self.read(endpoint, #selector(getter: AVAudioSessionPortDescription.uid)) as? NSString,
              let port = Self.read(endpoint, #selector(getter: AVAudioSessionPortDescription.portType)) as? NSString else {
            return .init(uid: "", portType: "", dataSource: .invalid)
        }
        let dataSource: AudioSessionDataSourceEvidence
        let sourceSelector = #selector(getter: AVAudioSessionPortDescription.selectedDataSource)
        guard endpoint.responds(to: sourceSelector) else { return .init(uid: "", portType: "", dataSource: .invalid) }
        if let source = Self.read(endpoint, sourceSelector) {
            guard let source = source as? NSObject,
                  let number = Self.read(source, #selector(getter: AVAudioSessionDataSourceDescription.dataSourceID)) as? NSNumber else {
                return .init(uid: "", portType: "", dataSource: .invalid)
            }
            // 直接借原NSNumber做无损固定Int64转换；不分配第二个NSNumber作比较。
            let type = CFGetTypeID(number)
            if type == CFBooleanGetTypeID() {
                dataSource = .integer(number.boolValue ? 1 : 0)
            } else if type == CFNumberGetTypeID() {
                // NSNumber的无符号64位桥接可回绕成CFNumber有符号值；先按公开类型编码检查原值。
                // objCType为inner pointer，只在number强局部存活时借首字节，不扫描或构造String。
                let encoding = number.objCType.pointee
                let unsigned = encoding == 67 || encoding == 83 || encoding == 73 || encoding == 76 || encoding == 81 // C/S/I/L/Q
                if unsigned && number.uint64Value > UInt64(Int64.max) { dataSource = .invalid }
                else {
                    let value = unsafeBitCast(number, to: CFNumber.self)
                    var integer: Int64 = 0
                    dataSource = CFNumberGetValue(value, .sInt64Type, &integer) ? .integer(integer) : .invalid
                }
            } else { dataSource = .invalid }
        } else { dataSource = .missing }
        return .init(uid: uid, portType: port, dataSource: dataSource)
    }

    /// selector仅来自此文件的编译期公开getter；+0返回先由强局部接管，原route/NSArray持续存活。
    private static func read(_ object: NSObject, _ selector: Selector) -> AnyObject? {
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }
}

enum AudioSessionCallStart: Sendable, Equatable { case started, parked, rejected }

/// 接收已结清结果及准确原permit；不提供caller授权或读取current补票的能力。
protocol PlaybackAudioSessionCompletionReceiving: AnyObject, Sendable {
    func receiveAudioSessionCompletion(permit: AudioSessionBlockingCallPermit,
        completion: AudioSessionBlockingCallCompletion)
}

class PlaybackAudioSessionOwner: PlaybackAudioSessionCompletionReceiving, @unchecked Sendable {
    let registry: ControlTaskRegistry
    let monitor: SystemAudioEventMonitor
    private let lane: AudioSessionBlockingCallLane

    init(
        registry: ControlTaskRegistry = ControlTaskRegistry(),
        sdk: (any PlaybackAudioSessionSDK)? = nil,
        monitor: SystemAudioEventMonitor? = nil
    ) throws {
        let actualSdk = sdk ?? NullPlaybackAudioSessionSDK()
        let lane = AudioSessionBlockingCallLane(sdk: actualSdk)
        guard registry.bindAudioSessionLane(lane) else { throw ControlTaskRegistry.Failure.invalidGroup }
        self.registry = registry
        self.lane = lane
        self.monitor = monitor ?? SystemAudioEventMonitor(safetyIngress: registry.executor.safetyIngress)
    }

    convenience init(registry: ControlTaskRegistry, sdk: any PlaybackAudioSessionSDK) throws {
        try self.init(registry: registry, sdk: sdk, monitor: nil)
    }

    func startAcquisition(_ ticket: ControlTaskTicket, receiver: any PlaybackAudioSessionCompletionReceiving) -> Bool {
        switch dispatch(prepareAcquisition(ticket, receiver: receiver)) {
        case .started, .parked: true
        case .rejected: false
        }
    }

    var isInterruptedAtAcquisition: Bool { false }

    func releaseLease(_ lease: PlaybackAudioSessionLease) {}

    @discardableResult
    func requestResume(for lease: PlaybackAudioSessionLease) -> Bool {
        guard let ticket = registry.prepareExplicitResume(for: lease) else { return false }
        return invoke(ticket, receiver: self) == .started
    }

    func receiveAudioSessionCompletion(permit: AudioSessionBlockingCallPermit,
        completion: AudioSessionBlockingCallCompletion) {
        guard permit.operation == .activate, completion.disposition == .accepted,
              let receipt = completion.reactivationReceipt, receipt.sourceRecordNonce == permit.record.nonce,
              let event = registry.recoveryCompletionEvent(receipt) else { return }
        monitor.emitReactivationCompletion(receipt, event: event)
    }

    func emit(_ event: PlaybackAudioSessionEvent) {
        monitor.emit(event)
    }

    /// 握手/配置准备和装箱完整返回后才enqueue；salt/registration/first不会跨入本次SDK投影。
    private func prepareAcquisition(_ ticket: ControlTaskTicket,
        receiver: any PlaybackAudioSessionCompletionReceiving) -> AudioSessionPreparedDelivery {
        guard registry.claimStart(ticket) else { return .rejected }
        guard let salt = lane.makeEndpointSalt() else {
            _ = registry.completeOutputAcquisitionWithoutLease(ticket)
            return .rejected
        }
        do {
            guard let registration = try registry.registerAudioSessionLease(ticket, salt: salt) else {
                _ = registry.completeOutputAcquisitionWithoutLease(ticket)
                return .rejected
            }
            guard let first = try registry.beginRegisteredAudioSessionConfiguration(registration) else {
                return registry.acquisitionIsParkedForPhysicalResume(registration) ? .parked : .rejected
            }
            return prepare(first, family: .audio, receiver: receiver)
        } catch {
            // checked注册失败没有产生lease；准确原票必须结清。若已安装lease，原入口明确拒绝而不伪造no-lease。
            _ = registry.completeOutputAcquisitionWithoutLease(ticket)
            return .rejected
        }
    }

    /// Task7把底层通知源绑定此真实handle；它每次回调仍须通过同锁资源核验。
    func registration(for acquisition: ControlTaskTicket) -> PlaybackAudioSessionRegistration? {
        registry.audioSessionRegistration(for: acquisition)
    }

    func sample(_ ticket: ControlTaskTicket, receiver: any PlaybackAudioSessionCompletionReceiving) -> AudioSessionCallStart {
        dispatch(prepare(ticket, family: .sampler, receiver: receiver))
    }

    /// 音频固定步骤入口不能领取sampler；跨family后继由同一具名接收者取得准确结果。
    @discardableResult
    func invoke(_ ticket: ControlTaskTicket, receiver: any PlaybackAudioSessionCompletionReceiving) -> AudioSessionCallStart {
        dispatch(prepare(ticket, family: .audio, receiver: receiver))
    }

    /// 本函数完整返回后才enqueue；record/application/request准备栈不会与本次SDK投影并存。
    private func prepare(_ ticket: ControlTaskTicket, family: AudioSessionCallFamily,
        receiver: any PlaybackAudioSessionCompletionReceiving) -> AudioSessionPreparedDelivery {
        switch registry.executor.performAudioSessionCall(.claim(ticket, lane: lane, family: family)) {
        case .claimed(let request):
            return .ready(.init(request: request, owner: self, receiver: receiver))
        case .parked: return .parked
        default: return .rejected
        }
    }

    private func dispatch(_ prepared: AudioSessionPreparedDelivery) -> AudioSessionCallStart {
        switch prepared {
        case .ready(let delivery): lane.execute(delivery); return .started
        case .parked: return .parked
        case .rejected: return .rejected
        }
    }

    func receive(_ result: AudioSessionBlockingCallResult, delivery: AudioSessionCallDelivery) {
        registry.executor.sync {
            guard case .completed(let completion, _, _, _) = registry.executor.performAudioSessionCall(
                .complete(.init(permit: delivery.request.permit, result: result), lane: lane)) else { return }
            // completion已离Cell锁；跨family后继也须用准确入口重新claim。
            if let next = completion.followUp {
                if delivery.request.permit.operation == .currentRoute {
                    if completion.disposition == .settled {
                        _ = sample(next, receiver: delivery.receiver)
                    }
                } else {
                    _ = invoke(next, receiver: delivery.receiver)
                }
            }
            if let owner = completion.terminalOwner {
                registry.startAudioSessionFailureCleanup(owner: owner)
            }
            delivery.receiver.receiveAudioSessionCompletion(permit: delivery.request.permit, completion: completion)
        }
    }
}

final class NullPlaybackAudioSessionSDK: PlaybackAudioSessionSDK, @unchecked Sendable {
    func setPlaybackCategory(policy: AudioSessionActualPolicy) throws {}
    func setSupportsMultichannelContent() throws {}
    func activate() throws {}
    func deactivate() throws {}
    func currentRoute() -> any AudioSessionRouteSnapshot {
        NullAudioSessionRouteSnapshot()
    }
    func fillRandomBytes(_ bytes: UnsafeMutableRawBufferPointer) -> Bool { true }
}

final class NullAudioSessionRouteSnapshot: AudioSessionRouteSnapshot, @unchecked Sendable {
    var endpointCount: Int { 0 }
    func endpoint(at index: Int) -> AudioSessionRouteEndpoint {
        .init(uid: "", portType: "", dataSource: .missing)
    }
}
