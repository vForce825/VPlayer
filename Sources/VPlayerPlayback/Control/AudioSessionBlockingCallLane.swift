// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AVFoundation
import CommonCrypto
import CoreFoundation
import Dispatch
import Foundation

enum AudioSessionBlockingCallOperation: Sendable, Equatable {
    case longFormCategory, defaultCategory, multichannel, activate, deactivate, currentRoute
}

struct AudioSessionBlockingCallPermit: Sendable, Equatable {
    let record: ControlTaskTicket
    let operation: AudioSessionBlockingCallOperation
}

struct AudioSessionBlockingCallRequest: Sendable, Equatable {
    let permit: AudioSessionBlockingCallPermit
    let registration: PlaybackAudioSessionRegistration?
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.permit == rhs.permit && lhs.registration === rhs.registration
    }
}

enum AudioSessionBlockingCallResult: Sendable, Equatable {
    case configuration(AudioSessionConfigurationCallResult)
    case activation(AudioSessionFixedFailure?)
    case deactivation(AudioSessionDeactivationResult)
    case route(AudioSessionRouteSampleEvidence)
}

struct AudioSessionBlockingCallReturned: Sendable, Equatable {
    let permit: AudioSessionBlockingCallPermit
    let result: AudioSessionBlockingCallResult
}

enum AudioSessionBlockingCallAction: Sendable, Equatable {
    case claim(
        ControlTaskTicket, lane: AudioSessionBlockingCallLane,
        family: AudioSessionCallFamily = .audio)
    case complete(AudioSessionBlockingCallReturned, lane: AudioSessionBlockingCallLane)
}

struct AudioSessionBlockingCallCompletion: Sendable, Equatable {
    enum Disposition: Sendable, Equatable { case accepted, settled, failed }
    let disposition: Disposition
    let followUp: ControlTaskTicket?
    let failure: PlaybackSafetyFailure?
    var reactivationReceipt: AudioSessionReactivationCompletionReceipt? = nil
    var terminalOwner: OutputTransitionOwnerTicket? = nil
}

/// 唯一Authority在真实SDK activation完成CAS中签发；不能用当前快照补造成功。
struct AudioSessionReactivationCompletionReceipt: Sendable, Equatable {
    let sourceRecordNonce: UInt64
    let contextNonce: UInt64
    let proofNonce: UInt64
    let leaseID: UInt64
    let activationNonce: UInt64
    let interruptionEpoch: UInt64
    let mediaServicesEpoch: UInt64
    let audioAdmissionFenceRevision: UInt64
}

/// 只缩窄可领类别；具体SDK操作仍由Registry的准确record/policy派生。
enum AudioSessionCallFamily: Sendable, Equatable { case audio, sampler }

/// 仅把原单次request与接收者转移到队列；不是第二份permit、Registry或等待状态。
final class AudioSessionCallDelivery: Sendable {
    let request: AudioSessionBlockingCallRequest
    let owner: PlaybackAudioSessionOwner
    let receiver: any PlaybackAudioSessionCompletionReceiving
    init(
        request: AudioSessionBlockingCallRequest, owner: PlaybackAudioSessionOwner,
        receiver: any PlaybackAudioSessionCompletionReceiving
    ) {
        self.request = request
        self.owner = owner
        self.receiver = receiver
    }
}

enum AudioSessionPreparedDelivery: Sendable {
    case ready(AudioSessionCallDelivery)
    case parked, rejected
}

enum AudioSessionBlockingCallApplication: Sendable, Equatable {
    case rejected
    case parked
    case claimed(AudioSessionBlockingCallRequest)
    /// claim没有SDK结果；此更新只供Cell在原锁内应用，再向调用者返回普通拒绝。
    case claimRejected(
        PlaybackOutputSafetyState, freezeGeneration: UInt64,
        audioAdmissionFenceRevision: UInt64, failure: PlaybackSafetyFailure?)
    case completed(
        AudioSessionBlockingCallCompletion, PlaybackOutputSafetyState,
        freezeGeneration: UInt64, audioAdmissionFenceRevision: UInt64)
}

/// 不拥有另一份permit或等待队列；只有Registry已claim的单次SDK操作才进入此串行域。
final class AudioSessionBlockingCallLane: Sendable, Equatable {
    static func == (lhs: AudioSessionBlockingCallLane, rhs: AudioSessionBlockingCallLane) -> Bool {
        lhs === rhs
    }
    private let queue = DispatchQueue(
        label: "org.vplayer.playback.audio-session", qos: .userInitiated)
    private let sdk: any PlaybackAudioSessionSDK

    init(sdk: any PlaybackAudioSessionSDK) { self.sdk = sdk }

    /// 唯一绑定SDK的固定随机源；不领取AudioSession permit，也不签发receipt。
    func makeEndpointSalt() -> AudioSessionEndpointSalt? {
        AudioSessionEndpointSalt.make(using: sdk)
    }

    func execute(_ delivery: AudioSessionCallDelivery) {
        queue.async { [self] in
            // 完整原票只存一次于投递对象；队列只持该对象与lane引用。
            let result = autoreleasepool {
                invoke(
                    operation: delivery.request.permit.operation,
                    registration: delivery.request.registration)
            }
            delivery.owner.receive(result, delivery: delivery)
        }
    }

    private func invoke(
        operation: AudioSessionBlockingCallOperation,
        registration: PlaybackAudioSessionRegistration?
    ) -> AudioSessionBlockingCallResult {
        switch operation {
        case .longFormCategory, .defaultCategory:
            do {
                try sdk.setPlaybackCategory(
                    policy: operation == .longFormCategory ? .longFormAudio : .default)
                return .configuration(.categorySucceeded)
            } catch { return .configuration(.failed(Self.failure(error))) }
        case .multichannel:
            do {
                try sdk.setSupportsMultichannelContent()
                return .configuration(.multichannelCapability(true))
            } catch { return .configuration(.multichannelCapability(false)) }
        case .activate:
            do {
                try sdk.activate()
                return .activation(nil)
            } catch { return .activation(Self.failure(error)) }
        case .deactivate:
            do {
                try sdk.deactivate()
                return .deactivation(.succeeded)
            } catch { return .deactivation(.failed(Self.failure(error))) }
        case .currentRoute:
            guard let registration else { return .route(.invalid) }
            return .route(Self.project(sdk.currentRoute(), salt: registration.salt))
        }
    }

    private static func failure(_ error: any Error) -> AudioSessionFixedFailure {
        let value = error as NSError
        // 只借公开+0 NSString；未知长度domain不先桥接成Swift String或进入结果。
        let selector = #selector(getter: NSError.domain)
        let domain = value.responds(to: selector) ? value.perform(selector)?.takeUnretainedValue() as? NSString : nil
        return .init(
            domain: domain?.isEqual(to: NSOSStatusErrorDomain) == true ? .osStatus : .unknown,
            code: Int32(clamping: value.code))
    }

    /// 端点数32、UID256字节、port64字节；固定scratch，不复制或排序原始标识集合。
    static func project(_ snapshot: any AudioSessionRouteSnapshot, salt: AudioSessionEndpointSalt)
        -> AudioSessionRouteSampleEvidence
    {
        let count = snapshot.endpointCount
        guard count >= 0, count <= 32 else { return .invalid }
        guard count > 0 else { return .none }
        // 两个固定块各自在所有返回路径释放；不把指针或原始SDK对象带进completion。
        let digestStorage = UnsafeMutableRawPointer.allocate(
            byteCount: 1024, alignment: MemoryLayout<SessionEndpointFingerprint>.alignment)
        defer { digestStorage.deallocate() }
        let fieldStorage = UnsafeMutableRawPointer.allocate(byteCount: 256, alignment: MemoryLayout<UInt8>.alignment)
        defer { fieldStorage.deallocate() }
        let digests = UnsafeMutableBufferPointer(
            start: digestStorage.bindMemory(to: SessionEndpointFingerprint.self, capacity: 32), count: 32)
        let scratch = UnsafeMutableBufferPointer(
            start: fieldStorage.bindMemory(to: UInt8.self, capacity: 256), count: 256)
        var ports = PlaybackRoutePorts()
        for index in 0..<count {
            let endpoint = snapshot.endpoint(at: index)
            var context = CC_SHA256_CTX()
            CC_SHA256_Init(&context)
            withUnsafeBytes(of: salt) {
                _ = CC_SHA256_Update(&context, $0.baseAddress, CC_LONG($0.count))
            }
            var domain: UInt8 = 1
            _ = CC_SHA256_Update(&context, &domain, 1)
            guard hash(endpoint.uid, field: 1, maximum: 256, context: &context, scratch: scratch),
                hash(endpoint.portType, field: 2, maximum: 64, context: &context, scratch: scratch)
            else { return .invalid }
            var dataSourceField: UInt8 = 3
            _ = CC_SHA256_Update(&context, &dataSourceField, 1)
            switch endpoint.dataSource {
            case .missing:
                var tag: UInt8 = 0
                var length: UInt16 = 0
                _ = CC_SHA256_Update(&context, &tag, 1)
                _ = CC_SHA256_Update(&context, &length, 2)
            case .integer(let value):
                var tag: UInt8 = 1
                var length = UInt16(8).bigEndian
                var encoded = value.bigEndian
                _ = CC_SHA256_Update(&context, &tag, 1)
                _ = CC_SHA256_Update(&context, &length, 2)
                _ = CC_SHA256_Update(&context, &encoded, 8)
            case .invalid: return .invalid
            }
            var digest = SessionEndpointFingerprint()
            withUnsafeMutableBytes(of: &digest) {
                _ = CC_SHA256_Final($0.baseAddress?.assumingMemoryBound(to: UInt8.self), &context)
            }
            // 每个已处理位置只初始化一次；摘要只有四个UInt64，无需保留或销毁对象引用。
            digests.baseAddress!.advanced(by: index).initialize(to: digest)
            if endpoint.portType.isEqual(to: AVAudioSession.Port.airPlay.rawValue) {
                ports.insert(.airPlay)
            } else if endpoint.portType.isEqual(to: AVAudioSession.Port.HDMI.rawValue) {
                ports.insert(.hdmi)
            } else if endpoint.portType.isEqual(to: AVAudioSession.Port.bluetoothA2DP.rawValue)
                || endpoint.portType.isEqual(to: AVAudioSession.Port.bluetoothLE.rawValue)
                || endpoint.portType.isEqual(to: AVAudioSession.Port.bluetoothHFP.rawValue)
            {
                ports.insert(.bluetooth)
            } else if endpoint.portType.isEqual(to: AVAudioSession.Port.builtInSpeaker.rawValue)
                || endpoint.portType.isEqual(to: AVAudioSession.Port.builtInMic.rawValue)
            {
                ports.insert(.builtIn)
            } else {
                ports.insert(.other)
            }
        }
        // 固定有界插入排序，保留重复端点的多成员语义。
        for index in 1..<count {
            var position = index
            while position > 0 && digests[position].precedes(digests[position - 1]) {
                digests.swapAt(position, position - 1)
                position -= 1
            }
        }
        var aggregate = CC_SHA256_CTX()
        CC_SHA256_Init(&aggregate)
        withUnsafeBytes(of: salt) {
            _ = CC_SHA256_Update(&aggregate, $0.baseAddress, CC_LONG($0.count))
        }
        var domain: UInt8 = 2
        var encodedCount = UInt16(count).bigEndian
        _ = CC_SHA256_Update(&aggregate, &domain, 1)
        _ = CC_SHA256_Update(&aggregate, &encodedCount, 2)
        _ = CC_SHA256_Update(&aggregate, digests.baseAddress, CC_LONG(count * 32))
        var result = SessionEndpointFingerprint()
        withUnsafeMutableBytes(of: &result) {
            _ = CC_SHA256_Final($0.baseAddress?.assumingMemoryBound(to: UInt8.self), &aggregate)
        }
        return .available(ports: ports, endpointFingerprint: result)
    }

    private static func hash(
        _ value: NSString, field: UInt8, maximum: Int, context: inout CC_SHA256_CTX,
        scratch: UnsafeMutableBufferPointer<UInt8>
    ) -> Bool {
        let characterCount = value.length
        guard characterCount > 0, characterCount <= maximum else { return false }
        // NSString/CFString是系统保证的toll-free桥接；借同一对象，绝不先构造Swift String或NSData。
        let string = unsafeBitCast(value, to: CFString.self)
        var usedBytes = 0
        let converted = CFStringGetBytes(
            string, CFRange(location: 0, length: characterCount),
            CFStringBuiltInEncodings.UTF8.rawValue, 0, false, scratch.baseAddress, maximum,
            &usedBytes)
        guard converted == characterCount, usedBytes > 0, usedBytes <= maximum else { return false }
        var tag = field
        var length = UInt16(usedBytes).bigEndian
        _ = CC_SHA256_Update(&context, &tag, 1)
        _ = CC_SHA256_Update(&context, &length, 2)
        _ = CC_SHA256_Update(&context, scratch.baseAddress, CC_LONG(usedBytes))
        return true
    }
}
