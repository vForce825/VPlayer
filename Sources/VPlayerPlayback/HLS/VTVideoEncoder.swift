// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct VTCompressionSessionID: RawRepresentable, Sendable, Hashable {
    let rawValue: UInt64
}

protocol VTCompressionSessionHandle: AnyObject, Sendable {
    var id: VTCompressionSessionID { get }
}

enum VTCompressionPropertyValue: Sendable, Equatable {
    case boolean(Bool)
    case signed(Int64)
    case unsigned(UInt64)
    case rational(Int64, Int64)
    case string(String)
    case data(Data)
    case array([VTCompressionPropertyValue])
    case dictionary([String: VTCompressionPropertyValue])

    fileprivate var propertyListObject: Any? {
        switch self {
        case let .boolean(value):
            return value ? kCFBooleanTrue : kCFBooleanFalse
        case let .signed(value):
            return NSNumber(value: value)
        case let .unsigned(value):
            return NSNumber(value: value)
        case let .rational(numerator, denominator):
            guard denominator != 0 else { return nil }
            return NSNumber(value: Double(numerator) / Double(denominator))
        case let .string(value):
            return value as CFString
        case let .data(value):
            return value as CFData
        case let .array(values):
            var objects: [Any] = []
            for value in values {
                guard let object = value.propertyListObject else { return nil }
                objects.append(object)
            }
            return objects as CFArray
        case let .dictionary(values):
            var objects: [String: Any] = [:]
            for (key, value) in values {
                guard let object = value.propertyListObject else { return nil }
                objects[key] = object
            }
            return objects as CFDictionary
        }
    }
}

struct VTCompressionSessionCreationConfiguration: Sendable {
    let width: Int32
    let height: Int32
    let codecType: CMVideoCodecType
    let encoderSpecification: [String: VTCompressionPropertyValue]
    let sourceImageBufferAttributes: [String: VTCompressionPropertyValue]
}

struct VTCompressionPropertyCopyResult: Sendable, Equatable {
    let status: OSStatus
    let value: VTCompressionPropertyValue?
}

struct VTCompressionSubmissionResult: @unchecked Sendable, Equatable {
    let status: OSStatus
    let infoFlags: VTEncodeInfoFlags
}

struct VTCompressionOutput: @unchecked Sendable {
    let status: OSStatus
    let infoFlags: VTEncodeInfoFlags
    let sampleBuffer: CMSampleBuffer?

    static func success(sampleBuffer: CMSampleBuffer) -> Self {
        Self(status: noErr, infoFlags: [], sampleBuffer: sampleBuffer)
    }
}

protocol VTCompressionAPI: AnyObject, Sendable {
    func createSession(
        configuration: VTCompressionSessionCreationConfiguration
    ) -> (status: OSStatus, session: (any VTCompressionSessionHandle)?)
    func setProperty(
        _ session: any VTCompressionSessionHandle,
        key: String,
        value: VTCompressionPropertyValue
    ) -> OSStatus
    func copyProperty(
        _ session: any VTCompressionSessionHandle,
        key: String
    ) -> VTCompressionPropertyCopyResult
    func prepare(_ session: any VTCompressionSessionHandle) -> OSStatus
    func encode(
        _ session: any VTCompressionSessionHandle,
        frame: VideoEncodingFrame,
        forceKeyFrame: Bool,
        output: @escaping @Sendable (VTCompressionOutput) -> Void
    ) -> VTCompressionSubmissionResult
    func completeFrames(_ session: any VTCompressionSessionHandle) -> OSStatus
    func invalidate(_ session: any VTCompressionSessionHandle)
}

private final class VTCompressionSessionIDAllocator: @unchecked Sendable {
    static let shared = VTCompressionSessionIDAllocator()
    private let lock = NSLock()
    private var next: UInt64 = 1

    func allocate() -> VTCompressionSessionID {
        lock.withLock {
            defer { next &+= 1 }
            return VTCompressionSessionID(rawValue: next)
        }
    }
}

private final class SystemVTCompressionSession: VTCompressionSessionHandle, @unchecked Sendable {
    let id: VTCompressionSessionID
    let rawSession: VTCompressionSession

    init(id: VTCompressionSessionID, rawSession: VTCompressionSession) {
        self.id = id
        self.rawSession = rawSession
    }
}

final class SystemVTCompressionAPI: VTCompressionAPI, @unchecked Sendable {
    func createSession(
        configuration: VTCompressionSessionCreationConfiguration
    ) -> (status: OSStatus, session: (any VTCompressionSessionHandle)?) {
        guard let encoderSpecification = dictionary(configuration.encoderSpecification),
              let imageAttributes = dictionary(configuration.sourceImageBufferAttributes) else {
            return (kVTParameterErr, nil)
        }
        var rawSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: configuration.width,
            height: configuration.height,
            codecType: configuration.codecType,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: imageAttributes,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &rawSession
        )
        return (
            status,
            rawSession.map {
                SystemVTCompressionSession(
                    id: VTCompressionSessionIDAllocator.shared.allocate(),
                    rawSession: $0
                ) as any VTCompressionSessionHandle
            }
        )
    }

    func setProperty(
        _ session: any VTCompressionSessionHandle,
        key: String,
        value: VTCompressionPropertyValue
    ) -> OSStatus {
        guard let session = session as? SystemVTCompressionSession,
              let object = value.propertyListObject else { return kVTParameterErr }
        return VTSessionSetProperty(
            session.rawSession,
            key: key as CFString,
            value: object as CFTypeRef
        )
    }

    func copyProperty(
        _ session: any VTCompressionSessionHandle,
        key: String
    ) -> VTCompressionPropertyCopyResult {
        guard let session = session as? SystemVTCompressionSession else {
            return VTCompressionPropertyCopyResult(status: kVTInvalidSessionErr, value: nil)
        }
        var copied: Unmanaged<CFTypeRef>?
        let status = withUnsafeMutablePointer(to: &copied) { pointer in
            VTSessionCopyProperty(
                session.rawSession,
                key: key as CFString,
                allocator: kCFAllocatorDefault,
                valueOut: UnsafeMutableRawPointer(pointer)
            )
        }
        let value = copied?.takeRetainedValue()
        let copiedValue: VTCompressionPropertyValue?
        if status == noErr,
           let value,
           CFGetTypeID(value) == CFBooleanGetTypeID() {
            copiedValue = .boolean(CFEqual(value, kCFBooleanTrue))
        } else {
            copiedValue = nil
        }
        return VTCompressionPropertyCopyResult(status: status, value: copiedValue)
    }

    func prepare(_ session: any VTCompressionSessionHandle) -> OSStatus {
        guard let session = session as? SystemVTCompressionSession else {
            return kVTInvalidSessionErr
        }
        return VTCompressionSessionPrepareToEncodeFrames(session.rawSession)
    }

    func encode(
        _ session: any VTCompressionSessionHandle,
        frame: VideoEncodingFrame,
        forceKeyFrame: Bool,
        output: @escaping @Sendable (VTCompressionOutput) -> Void
    ) -> VTCompressionSubmissionResult {
        guard let session = session as? SystemVTCompressionSession else {
            return VTCompressionSubmissionResult(status: kVTInvalidSessionErr, infoFlags: [])
        }
        let properties: CFDictionary? = forceKeyFrame
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            : nil
        var flags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            session.rawSession,
            imageBuffer: frame.pixelBuffer,
            presentationTimeStamp: frame.presentationTimeStamp,
            duration: frame.duration,
            frameProperties: properties,
            infoFlagsOut: &flags
        ) { status, infoFlags, sampleBuffer in
            output(VTCompressionOutput(
                status: status,
                infoFlags: infoFlags,
                sampleBuffer: sampleBuffer
            ))
        }
        return VTCompressionSubmissionResult(status: status, infoFlags: flags)
    }

    func completeFrames(_ session: any VTCompressionSessionHandle) -> OSStatus {
        guard let session = session as? SystemVTCompressionSession else {
            return kVTInvalidSessionErr
        }
        return VTCompressionSessionCompleteFrames(
            session.rawSession,
            untilPresentationTimeStamp: .invalid
        )
    }

    func invalidate(_ session: any VTCompressionSessionHandle) {
        guard let session = session as? SystemVTCompressionSession else { return }
        VTCompressionSessionInvalidate(session.rawSession)
    }

    private func dictionary(
        _ values: [String: VTCompressionPropertyValue]
    ) -> CFDictionary? {
        var objects: [String: Any] = [:]
        for (key, value) in values {
            guard let object = value.propertyListObject else { return nil }
            objects[key] = object
        }
        return objects as CFDictionary
    }
}

final class VTVideoEncoder: HLSVideoEncoding, @unchecked Sendable {
    private enum State {
        case running
        case finishing
        case terminal(HLSVideoEncoderTerminal)
    }

    private struct PendingFrame: @unchecked Sendable {
        let frame: VideoEncodingFrame
        let completion: @Sendable (
            Result<HLSVideoEncodedOutput, VTVideoEncoderFailure>
        ) -> Void
    }

    private final class TerminalSnapshot: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: HLSVideoEncoderTerminal?
        var value: HLSVideoEncoderTerminal? { lock.withLock { stored } }
        func set(_ value: HLSVideoEncoderTerminal) { lock.withLock { stored = value } }
    }

    /// VideoToolbox 允许编码回调在提交调用返回前同步发生。先暂存这类回调，
    /// 让提交状态拥有优先裁决权；提交返回后的回调仍回到编码器串行队列处理。
    private final class SubmissionOutputGate: @unchecked Sendable {
        enum CallbackClaim {
            case beforeSubmissionReturns
            case afterSubmissionReturns
        }

        private enum State {
            case open
            case capturingBeforeReturn
            case buffered(VTCompressionOutput)
            case closed
            case closedWhileCapturing
            case asynchronousClaimed
        }

        private let lock = NSLock()
        private var state = State.open

        /// SDK 的一次提交最多有一个可裁决输出。必须先 claim，再做可能等待的
        /// owned copy，避免重复/迟到 callback 在复制后才被丢弃。
        func claimCallback() -> CallbackClaim? {
            lock.withLock {
                switch state {
                case .open:
                    state = .capturingBeforeReturn
                    return .beforeSubmissionReturns
                case .closed:
                    state = .asynchronousClaimed
                    return .afterSubmissionReturns
                default:
                    return nil
                }
            }
        }

        /// 返回 true 表示 encode 已返回，捕获结果须投递到串行队列。
        func finishSynchronousCapture(_ output: VTCompressionOutput) -> Bool {
            lock.withLock {
                switch state {
                case .capturingBeforeReturn:
                    state = .buffered(output)
                    return false
                case .closedWhileCapturing:
                    state = .asynchronousClaimed
                    return true
                default:
                    return false
                }
            }
        }

        func closeSubmission() -> [VTCompressionOutput] {
            lock.withLock {
                switch state {
                case .open:
                    state = .closed
                    return []
                case .capturingBeforeReturn:
                    state = .closedWhileCapturing
                    return []
                case let .buffered(output):
                    state = .asynchronousClaimed
                    return [output]
                default:
                    return []
                }
            }
        }
    }

    let selectedProfile: VTVideoCodecProfile

    private let configuration: VTVideoEncoderConfiguration
    private let api: any VTCompressionAPI
    private let workQueue: DispatchQueue
    private let session: any VTCompressionSessionHandle
    private let compressedOutputOwnership: HLSVideoCopyOwnership?
    private let terminalSnapshot = TerminalSnapshot()

    /// 以下状态只在 workQueue 访问。
    private var state = State.running
    private var waiting: [PendingFrame] = []
    private var active: [VideoEncodingFrameIdentity: PendingFrame] = [:]
    private var driveIsActive = false
    private var lastAcceptedPTS: CMTime?
    private var hardwareProof: VTHardwareEncoderProof?
    private var encodedFrameCount: UInt64 = 0
    private var finishCompletions: [@Sendable (
        Result<HLSVideoEncoderFinishReceipt, VTVideoEncoderFailure>
    ) -> Void] = []
    /// requested 只防止 work lane 重入；只有 `api.invalidate` 返回后才能作为实际
    /// native receipt 对外可见。
    private var sessionInvalidationRequested = false
    private var sessionInvalidated = false
    private var completeFramesCalled = false

    convenience init(
        configuration: VTVideoEncoderConfiguration,
        compressedOutputOwnership: HLSVideoCopyOwnership? = nil
    ) throws {
        try self.init(
            configuration: configuration,
            api: SystemVTCompressionAPI(),
            workQueue: DispatchQueue(
                label: "org.vplayer.playback.hls.video-encoder",
                qos: .userInitiated
            ),
            compressedOutputOwnership: compressedOutputOwnership
        )
    }

    init(
        configuration: VTVideoEncoderConfiguration,
        api: any VTCompressionAPI,
        workQueue: DispatchQueue,
        compressedOutputOwnership: HLSVideoCopyOwnership? = nil
    ) throws {
        try Self.validate(configuration)
        self.configuration = configuration
        self.api = api
        self.workQueue = workQueue
        self.compressedOutputOwnership = compressedOutputOwnership

        let preferred = Self.preferredProfile(for: configuration.inputFormat)
        var candidates = [preferred]
        if preferred == .h264High { candidates.append(.hevcMain) }

        var selected: (any VTCompressionSessionHandle)?
        var selectedProfile: VTVideoCodecProfile?
        var lastFailure = VTVideoEncoderFailure.hardwareEncoderNotActive
        for (index, profile) in candidates.enumerated() {
            let mayFallback = index + 1 < candidates.count
            let creation = api.createSession(configuration: Self.creationConfiguration(
                configuration,
                profile: profile
            ))
            guard creation.status == noErr, let candidate = creation.session else {
                if let session = creation.session { api.invalidate(session) }
                lastFailure = .sessionCreate(creation.status)
                if mayFallback { continue }
                throw lastFailure
            }
            do {
                try Self.configure(
                    candidate,
                    profile: profile,
                    configuration: configuration,
                    api: api
                )
            } catch let failure as VTVideoEncoderFailure {
                api.invalidate(candidate)
                lastFailure = failure
                if mayFallback, Self.isCapabilityPropertyFailure(failure) { continue }
                throw failure
            } catch {
                api.invalidate(candidate)
                throw error
            }
            let prepareStatus = api.prepare(candidate)
            guard prepareStatus == noErr else {
                api.invalidate(candidate)
                lastFailure = .prepare(prepareStatus)
                if mayFallback { continue }
                throw lastFailure
            }
            let hardware = api.copyProperty(
                candidate,
                key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder as String
            )
            guard hardware.status == noErr, hardware.value == .boolean(true) else {
                api.invalidate(candidate)
                lastFailure = .hardwareEncoderNotActive
                if mayFallback { continue }
                throw lastFailure
            }
            selected = candidate
            selectedProfile = profile
            break
        }
        guard let selected, let selectedProfile else { throw lastFailure }
        session = selected
        self.selectedProfile = selectedProfile
    }

    var terminal: HLSVideoEncoderTerminal? { terminalSnapshot.value }

    func encode(
        frame: VideoEncodingFrame,
        completion: @escaping @Sendable (
            Result<HLSVideoEncodedOutput, VTVideoEncoderFailure>
        ) -> Void
    ) {
        workQueue.async { [self] in
            encodeIsolated(frame: frame, completion: completion)
        }
    }

    func finish(
        completion: @escaping @Sendable (
            Result<HLSVideoEncoderFinishReceipt, VTVideoEncoderFailure>
        ) -> Void
    ) {
        workQueue.async { [self] in
            switch state {
            case .running:
                state = .finishing
                finishCompletions.append(completion)
                driveIsolated()
            case .finishing:
                finishCompletions.append(completion)
            case let .terminal(.failed(failure)):
                completion(.failure(failure))
            case .terminal(.cancelled):
                completion(.failure(.cancelled))
            case .terminal(.finished):
                if let hardwareProof {
                    completion(.success(HLSVideoEncoderFinishReceipt(
                        generation: configuration.generation,
                        encodedFrameCount: encodedFrameCount,
                        hardwareProof: hardwareProof
                    )))
                } else {
                    completion(.failure(.noEncodedOutput))
                }
            }
        }
    }

    func cancel(completion: @escaping @Sendable (Bool) -> Void) {
        // callback 可能正阻塞在独立 copy admission；若只把 cancel 排到
        // workQueue，native invalidate 会排在它之后而永远到不了。
        compressedOutputOwnership?.cancelCompressedOutputAdmission()
        workQueue.async { [self] in cancelIsolated(completion: completion) }
    }

    private func encodeIsolated(
        frame: VideoEncodingFrame,
        completion: @escaping @Sendable (
            Result<HLSVideoEncodedOutput, VTVideoEncoderFailure>
        ) -> Void
    ) {
        guard case .running = state else {
            frame.surfaceLease.release()
            completion(.failure(.cancelled))
            return
        }
        do {
            try validate(frame)
        } catch let failure as VTVideoEncoderFailure {
            frame.surfaceLease.release()
            completion(.failure(failure))
            failIsolated(failure)
            return
        } catch {
            frame.surfaceLease.release()
            completion(.failure(.invalidPixelBuffer))
            failIsolated(.invalidPixelBuffer)
            return
        }
        guard waiting.count + active.count
            < max(1, configuration.maximumPendingFrameCount) else {
            frame.surfaceLease.release()
            completion(.failure(.backpressureExceeded))
            return
        }
        lastAcceptedPTS = frame.presentationTimeStamp
        waiting.append(PendingFrame(frame: frame, completion: completion))
        driveIsolated()
    }

    private func driveIsolated() {
        guard !driveIsActive else { return }
        driveIsActive = true
        defer { driveIsActive = false }

        // 一个 25i access unit 对应两个 50p 场。同时在途两帧即可
        // 隐藏单次 VT callback 延迟；更大数量仍留在已计费 waiting
        // FIFO，避免硬件 session 内部形成另一个不可见的深队列。
        let maximumInFlight = min(
            2,
            max(1, configuration.maximumPendingFrameCount)
        )
        while active.count < maximumInFlight, !waiting.isEmpty {
            let pending = waiting.removeFirst()
            let identity = pending.frame.identity
            guard active[identity] == nil else {
                pending.frame.surfaceLease.release()
                pending.completion(.failure(.unexpectedOutputFormat))
                failIsolated(.unexpectedOutputFormat)
                return
            }
            active[identity] = pending
            let forcesKeyFrame = hardwareProof == nil && active.count == 1
            let outputGate = SubmissionOutputGate()
            // native callback 单独持有 lease；即使外部先释放 encoder，surface 预算也不会
            // 在 VideoToolbox 使用结束前归还。终态仍可通过幂等 release 提前关闭它。
            let callbackLease = pending.frame.surfaceLease
            let submission = api.encode(
                session,
                frame: pending.frame,
                forceKeyFrame: forcesKeyFrame
            ) { [weak self] output in
                _ = callbackLease
                // encoder 已析构或已失去 HLS publish 权时，native borrowed sample
                // 只能在本 callback 内丢弃，绝不能回退投递未收费的原对象。
                guard let self, let claim = outputGate.claimCallback() else { return }
                let captured = self.captureCompressedOutput(output)
                switch claim {
                case .beforeSubmissionReturns:
                    if outputGate.finishSynchronousCapture(captured) {
                        self.enqueueCapturedOutput(captured, expected: identity)
                    }
                case .afterSubmissionReturns:
                    self.enqueueCapturedOutput(captured, expected: identity)
                }
            }
            let synchronousOutputs = outputGate.closeSubmission()
            guard submission.status == noErr,
                  !submission.infoFlags.contains(.frameDropped) else {
                active.removeValue(forKey: identity)
                let failure: VTVideoEncoderFailure = submission.status == noErr
                    ? .frameDropped
                    : .encode(submission.status)
                pending.frame.surfaceLease.release()
                pending.completion(.failure(failure))
                failIsolated(failure)
                return
            }
            for output in synchronousOutputs {
                handleIsolated(output, expected: identity)
            }
            if case .terminal = state { return }
        }
        if case .finishing = state, waiting.isEmpty, active.isEmpty {
            finishIsolated()
        }
    }

    private func enqueueCapturedOutput(
        _ output: VTCompressionOutput,
        expected identity: VideoEncodingFrameIdentity
    ) {
        workQueue.async { [weak self] in
            self?.handleIsolated(output, expected: identity)
        }
    }

    private func captureCompressedOutput(_ output: VTCompressionOutput) -> VTCompressionOutput {
        guard let compressedOutputOwnership else { return output }
        guard output.status == noErr,
              !output.infoFlags.contains(.frameDropped),
              let sampleBuffer = output.sampleBuffer else {
            // HLS 路径已越过 native callback 边界；即使原生同时给出 sample，
            // status/flags 仍是裁决事实，但未收费的 borrowed sample 不可入 gate。
            return VTCompressionOutput(status: output.status, infoFlags: output.infoFlags,
                                       sampleBuffer: nil)
        }
        do {
            return VTCompressionOutput(
                status: output.status,
                infoFlags: output.infoFlags,
                sampleBuffer: try SampleBufferBuilder.copyHLSOwnedCompressedVideoSample(
                    sampleBuffer, ownership: compressedOutputOwnership
                )
            )
        } catch {
            return VTCompressionOutput(status: kCMBlockBufferBadPointerParameterErr,
                                       infoFlags: output.infoFlags, sampleBuffer: nil)
        }
    }

    private func handleIsolated(
        _ output: VTCompressionOutput,
        expected identity: VideoEncodingFrameIdentity
    ) {
        guard let pending = active[identity],
              pending.frame.identity == identity else {
            // 重复或终态后的迟到 callback 没有任何提交权。
            return
        }
        guard output.status == noErr else {
            failIsolated(.callback(output.status))
            return
        }
        guard !output.infoFlags.contains(.frameDropped) else {
            failIsolated(.frameDropped)
            return
        }
        guard let sampleBuffer = output.sampleBuffer else {
            failIsolated(.missingSampleBuffer)
            return
        }
        do {
            try validate(sampleBuffer, for: pending.frame)
            if hardwareProof == nil {
                guard Self.isSync(sampleBuffer) else {
                    throw VTVideoEncoderFailure.firstOutputNotSync
                }
                let hardware = api.copyProperty(
                    session,
                    key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder as String
                )
                guard hardware.status == noErr,
                      hardware.value == .boolean(true) else {
                    throw VTVideoEncoderFailure.hardwareEncoderNotActive
                }
                hardwareProof = VTHardwareEncoderProof(
                    sessionID: session.id,
                    generation: configuration.generation,
                    firstOutputIdentity: identity,
                    profile: selectedProfile
                )
            }
        } catch let failure as VTVideoEncoderFailure {
            failIsolated(failure)
            return
        } catch {
            failIsolated(.unexpectedOutputFormat)
            return
        }
        guard let hardwareProof else {
            failIsolated(.hardwareEncoderNotActive)
            return
        }

        active.removeValue(forKey: identity)
        encodedFrameCount &+= 1
        pending.frame.surfaceLease.release()
        pending.completion(.success(HLSVideoEncodedOutput(
            sourceIdentity: identity,
            sampleBuffer: sampleBuffer,
            presentationOrigin: pending.frame.presentationOrigin,
            inputFormatSignature: pending.frame.inputFormatSignature,
            hardwareProof: hardwareProof
        )))
        driveIsolated()
    }

    private func finishIsolated() {
        guard !completeFramesCalled else { return }
        completeFramesCalled = true
        let status = api.completeFrames(session)
        guard status == noErr else {
            failIsolated(.complete(status), excludingActive: true)
            return
        }
        guard let hardwareProof, encodedFrameCount > 0 else {
            failIsolated(.noEncodedOutput, excludingActive: true)
            return
        }
        invalidateSessionIsolated()
        state = .terminal(.finished)
        terminalSnapshot.set(.finished)
        let receipt = HLSVideoEncoderFinishReceipt(
            generation: configuration.generation,
            encodedFrameCount: encodedFrameCount,
            hardwareProof: hardwareProof
        )
        let completions = finishCompletions
        finishCompletions.removeAll(keepingCapacity: false)
        for completion in completions { completion(.success(receipt)) }
    }

    private func cancelIsolated(completion: @escaping @Sendable (Bool) -> Void = { _ in }) {
        guard case .terminal = state else {
            let active = Array(active.values)
            self.active.removeAll(keepingCapacity: false)
            let waiting = waiting
            self.waiting.removeAll(keepingCapacity: false)
            state = .terminal(.cancelled)
            terminalSnapshot.set(.cancelled)
            invalidateSessionIsolated()
            for pending in active {
                pending.frame.surfaceLease.release()
                pending.completion(.failure(.cancelled))
            }
            for pending in waiting {
                pending.frame.surfaceLease.release()
                pending.completion(.failure(.cancelled))
            }
            let completions = finishCompletions
            finishCompletions.removeAll(keepingCapacity: false)
            for completion in completions { completion(.failure(.cancelled)) }
            // invalidateSessionIsolated 同步调用真实 VT API；此处才是 native lane 的
            // cancel receipt，绝不能以 terminalSnapshot 代替。
            completion(true)
            return
        }
        // finished/failed 路径均通过 invalidateSessionIsolated 记录了同一 native
        // lane 已完成的事实；不是由 terminal 名称推断。未 invalidate 才 fail-closed。
        completion(sessionInvalidated)
    }

    private func failIsolated(
        _ failure: VTVideoEncoderFailure,
        excludingActive: Bool = false
    ) {
        guard case .terminal = state else {
            let active = excludingActive ? [] : Array(active.values)
            self.active.removeAll(keepingCapacity: false)
            let waiting = waiting
            self.waiting.removeAll(keepingCapacity: false)
            state = .terminal(.failed(failure))
            terminalSnapshot.set(.failed(failure))
            invalidateSessionIsolated()
            for pending in active {
                pending.frame.surfaceLease.release()
                pending.completion(.failure(failure))
            }
            for pending in waiting {
                pending.frame.surfaceLease.release()
                pending.completion(.failure(failure))
            }
            let completions = finishCompletions
            finishCompletions.removeAll(keepingCapacity: false)
            for completion in completions { completion(.failure(failure)) }
            return
        }
    }

    private func invalidateSessionIsolated() {
        guard !sessionInvalidationRequested else { return }
        sessionInvalidationRequested = true
        api.invalidate(session)
        sessionInvalidated = true
    }

    private func validate(_ frame: VideoEncodingFrame) throws {
        guard frame.identity.generation == configuration.generation else {
            throw VTVideoEncoderFailure.generationMismatch
        }
        guard frame.inputFormatSignature == configuration.inputFormat else {
            throw VTVideoEncoderFailure.inputFormatChanged
        }
        guard CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
                == configuration.inputFormat.pixelFormat,
              CVPixelBufferGetWidth(frame.pixelBuffer) == Int(configuration.inputFormat.width),
              CVPixelBufferGetHeight(frame.pixelBuffer) == Int(configuration.inputFormat.height) else {
            throw VTVideoEncoderFailure.invalidPixelBuffer
        }
        guard Self.inputPixelBufferMatchesFrozenFormat(
            frame.pixelBuffer,
            expected: configuration.inputFormat
        ) else {
            throw VTVideoEncoderFailure.inputFormatChanged
        }
        guard frame.presentationTimeStamp.isNumeric,
              frame.presentationTimeStamp.epoch == 0,
              frame.duration.isNumeric,
              frame.duration.epoch == 0,
              CMTimeCompare(frame.duration, .zero) > 0 else {
            throw VTVideoEncoderFailure.invalidTime
        }
        if let lastAcceptedPTS,
           CMTimeCompare(frame.presentationTimeStamp, lastAcceptedPTS) <= 0 {
            throw VTVideoEncoderFailure.nonIncreasingPresentationTimestamp
        }
        if case .metalYADIF = frame.presentationOrigin {
            guard let order = frame.reliableFieldOrder,
                  order.confidence != .assumed,
                  order.source != .none else {
                throw VTVideoEncoderFailure.unreliableFieldOrder
            }
        }
    }

    private func validate(
        _ sampleBuffer: CMSampleBuffer,
        for frame: VideoEncodingFrame
    ) throws {
        guard CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferGetNumSamples(sampleBuffer) == 1,
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              CMFormatDescriptionGetMediaSubType(format) == selectedProfile.codecType else {
            throw VTVideoEncoderFailure.unexpectedOutputFormat
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        guard dimensions.width == configuration.inputFormat.width,
              dimensions.height == configuration.inputFormat.height else {
            throw VTVideoEncoderFailure.unexpectedOutputFormat
        }
        guard Self.codecConfigurationMatches(
            format,
            profile: selectedProfile,
            expectedBitDepth: configuration.inputFormat.bitDepth,
            expectedWidth: configuration.inputFormat.width,
            expectedHeight: configuration.inputFormat.height
        ), Self.outputExtensionsMatchFrozenFormat(
            format,
            profile: selectedProfile,
            expected: configuration.inputFormat
        ) else {
            throw VTVideoEncoderFailure.unexpectedOutputFormat
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        guard pts.isNumeric,
              CMTimeCompare(pts, frame.presentationTimeStamp) == 0,
              duration.isNumeric,
              CMTimeCompare(duration, frame.duration) == 0 else {
            throw VTVideoEncoderFailure.outputTimingMismatch
        }
        let dts = CMSampleBufferGetDecodeTimeStamp(sampleBuffer)
        guard !dts.isNumeric || CMTimeCompare(dts, pts) == 0 else {
            throw VTVideoEncoderFailure.outputTimingMismatch
        }
    }

    private static func inputPixelBufferMatchesFrozenFormat(
        _ pixelBuffer: CVPixelBuffer,
        expected: VideoEncodingInputFormatSignature
    ) -> Bool {
        exactString(
            CVBufferCopyAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, nil),
            equals: expected.primaries.vtValue
        ) && transferMatches(
            CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil),
            expected: expected.transfer
        ) && exactString(
            CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil),
            equals: expected.matrix.vtValue
        ) && optionalString(
            CVBufferCopyAttachment(pixelBuffer, kCVImageBufferChromaLocationTopFieldKey, nil),
            equals: expected.chromaLocation.topField
        ) && optionalString(
            CVBufferCopyAttachment(pixelBuffer, kCVImageBufferChromaLocationBottomFieldKey, nil),
            equals: expected.chromaLocation.bottomField
        ) && optionalAspectRatio(
            CVBufferCopyAttachment(pixelBuffer, kCVImageBufferPixelAspectRatioKey, nil),
            equals: expected.sampleAspectRatio
        ) && optionalCleanAperture(
            CVBufferCopyAttachment(pixelBuffer, kCVImageBufferCleanApertureKey, nil),
            equals: expected.cleanAperture
        ) && optionalData(
            CVBufferCopyAttachment(
                pixelBuffer,
                kCVImageBufferMasteringDisplayColorVolumeKey,
                nil
            ),
            equals: expected.masteringDisplayColorVolume
        ) && optionalData(
            CVBufferCopyAttachment(pixelBuffer, kCVImageBufferContentLightLevelInfoKey, nil),
            equals: expected.contentLightLevelInfo
        )
    }

    private static func codecConfigurationMatches(
        _ format: CMFormatDescription,
        profile: VTVideoCodecProfile,
        expectedBitDepth: UInt8,
        expectedWidth: Int32,
        expectedHeight: Int32
    ) -> Bool {
        guard let extensions = formatExtensions(format),
              let atoms = strictDictionary(extensions[
                  kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String
              ]) else {
            return false
        }
        switch profile {
        case .h264High:
            guard expectedBitDepth == 8,
                  let data = strictData(atoms["avcC"]) else {
                return false
            }
            return h264ConfigurationMatches(
                data,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight
            )
        case .hevcMain:
            guard expectedBitDepth == 8,
                  let data = strictData(atoms["hvcC"]) else {
                return false
            }
            return hevcConfigurationMatches(
                data,
                profileIDC: 1,
                bitDepthMinus8: 0,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight
            )
        case .hevcMain10:
            guard expectedBitDepth == 10,
                  let data = strictData(atoms["hvcC"]) else {
                return false
            }
            return hevcConfigurationMatches(
                data,
                profileIDC: 2,
                bitDepthMinus8: 2,
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight
            )
        }
    }

    private static func outputExtensionsMatchFrozenFormat(
        _ format: CMFormatDescription,
        profile: VTVideoCodecProfile,
        expected: VideoEncodingInputFormatSignature
    ) -> Bool {
        guard let extensions = formatExtensions(format),
              let sequenceProofs = sequenceParameterSetProofs(format, profile: profile),
              !sequenceProofs.isEmpty,
              let spsChroma = sequenceProofs.first?.effectiveChromaLocation,
              sequenceProofs.allSatisfy({ $0.effectiveChromaLocation == spsChroma }),
              let expectedTop = typedChromaLocation(expected.chromaLocation.topField),
              let expectedBottom = typedChromaLocation(expected.chromaLocation.bottomField),
              expectedTop == spsChroma,
              expectedBottom == spsChroma,
              explicitChromaLocationMatches(
                  extensions[kCMFormatDescriptionExtension_ChromaLocationTopField as String],
                  sps: spsChroma
              ),
              explicitChromaLocationMatches(
                  extensions[kCMFormatDescriptionExtension_ChromaLocationBottomField as String],
                  sps: spsChroma
              ),
              compressedRangeMatches(
                  extensions[kCMFormatDescriptionExtension_FullRangeVideo as String],
                  expected: expected.range
              ),
              sequenceProofs.allSatisfy({ proof in
                  guard let range = proof.range else { return true }
                  switch expected.range {
                  case .video: return range == .limited
                  case .full: return range == .full
                  case .unknown: return false
                  }
              }),
              exactString(
                  extensions[kCMFormatDescriptionExtension_ColorPrimaries as String],
                  equals: expected.primaries.vtValue
              ), transferMatches(
                  extensions[kCMFormatDescriptionExtension_TransferFunction as String],
                  expected: expected.transfer
              ), exactString(
                  extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String],
                  equals: expected.matrix.vtValue
              ), optionalAspectRatio(
                  extensions[kCMFormatDescriptionExtension_PixelAspectRatio as String],
                  equals: expected.sampleAspectRatio
              ), optionalCleanAperture(
                  extensions[kCMFormatDescriptionExtension_CleanAperture as String],
                  equals: expected.cleanAperture
              ), optionalData(
                  extensions[
                      kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String
                  ],
                  equals: expected.masteringDisplayColorVolume
              ), optionalData(
                  extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo as String],
                  equals: expected.contentLightLevelInfo
              ) else {
            return false
        }
        return true
    }

    private static func sequenceParameterSetProofs(
        _ format: CMFormatDescription,
        profile: VTVideoCodecProfile
    ) -> [VideoSequenceParameterSetProof]? {
        guard let extensions = formatExtensions(format),
              let atoms = strictDictionary(extensions[
                  kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String
              ]) else { return nil }
        switch profile {
        case .h264High:
            guard let data = strictData(atoms["avcC"]) else { return nil }
            let bytes = [UInt8](data)
            guard bytes.count >= 7 else { return nil }
            var offset = 6
            guard let units = readLengthPrefixedUnits(
                bytes,
                count: Int(bytes[5] & 0x1F),
                offset: &offset
            ) else { return nil }
            let proofs = units.compactMap {
                try? VideoSequenceParameterSetInspector.inspectH264($0)
            }
            return proofs.count == units.count ? proofs : nil
        case .hevcMain, .hevcMain10:
            guard let data = strictData(atoms["hvcC"]) else { return nil }
            let bytes = [UInt8](data)
            guard bytes.count >= 23 else { return nil }
            var offset = 23
            var units: [[UInt8]] = []
            for _ in 0..<Int(bytes[22]) {
                guard offset + 3 <= bytes.count else { return nil }
                let type = bytes[offset] & 0x3F
                offset += 1
                guard let count = unsigned16(bytes, at: offset) else { return nil }
                offset += 2
                guard let arrayUnits = readLengthPrefixedUnits(
                    bytes,
                    count: count,
                    offset: &offset
                ) else { return nil }
                if type == 33 { units.append(contentsOf: arrayUnits) }
            }
            guard offset == bytes.count, !units.isEmpty else { return nil }
            let proofs = units.compactMap {
                try? VideoSequenceParameterSetInspector.inspectHEVC($0)
            }
            return proofs.count == units.count ? proofs : nil
        }
    }

    private static func compressedRangeMatches(
        _ value: Any?,
        expected: VideoFormatMetadata.Range
    ) -> Bool {
        if value == nil {
            // CMFormatDescription规定YCbCr压缩格式缺省为video range。
            return expected == .video
        }
        switch expected {
        case .video: return exactBoolean(value, equals: false)
        case .full: return exactBoolean(value, equals: true)
        case .unknown: return false
        }
    }

    private static func explicitChromaLocationMatches(
        _ value: Any?,
        sps: DemuxChromaLocation
    ) -> Bool {
        guard value != nil else { return true }
        return typedChromaLocation(value) == sps
    }

    private static func typedChromaLocation(_ value: Any?) -> DemuxChromaLocation? {
        guard let value = strictString(value) else { return nil }
        if value == kCMFormatDescriptionChromaLocation_Left as String { return .left }
        if value == kCMFormatDescriptionChromaLocation_Center as String { return .center }
        if value == kCMFormatDescriptionChromaLocation_TopLeft as String { return .topLeft }
        return nil
    }

    private static func h264ConfigurationMatches(
        _ data: Data,
        expectedWidth: Int32,
        expectedHeight: Int32
    ) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 7,
              bytes[0] == 1,
              bytes[1] == 100,
              bytes[4] & 0xFC == 0xFC,
              bytes[5] & 0xE0 == 0xE0 else {
            return false
        }
        var offset = 6
        let sequenceParameterSetCount = Int(bytes[5] & 0x1F)
        guard sequenceParameterSetCount > 0,
              let sequenceParameterSets = readLengthPrefixedUnits(
                  bytes,
                  count: sequenceParameterSetCount,
                  offset: &offset
              ), sequenceParameterSets.allSatisfy({
                  guard let proof = try? VideoSequenceParameterSetInspector.inspectH264($0) else {
                      return false
                  }
                  return proof.profileIDC == bytes[1]
                      && proof.compatibilityFlags == UInt32(bytes[2])
                      && proof.levelIDC == bytes[3]
                      && proof.chromaFormatIDC == 1
                      && proof.bitDepthLuma == 8
                      && proof.bitDepthChroma == 8
                      && proof.width == expectedWidth
                      && proof.height == expectedHeight
              }), offset < bytes.count else {
            return false
        }
        let pictureParameterSetCount = Int(bytes[offset])
        offset += 1
        guard pictureParameterSetCount > 0,
              let pictureParameterSets = readLengthPrefixedUnits(
                  bytes,
                  count: pictureParameterSetCount,
                  offset: &offset
              ), pictureParameterSets.allSatisfy({
                  !$0.isEmpty && $0[0] & 0x1F == 8
              }), offset + 4 <= bytes.count else {
            return false
        }
        let chromaFormat = bytes[offset] & 0x03
        let lumaBitDepthMinus8 = bytes[offset + 1] & 0x07
        let chromaBitDepthMinus8 = bytes[offset + 2] & 0x07
        let sequenceParameterSetExtensionCount = Int(bytes[offset + 3])
        guard bytes[offset] & 0xFC == 0xFC,
              bytes[offset + 1] & 0xF8 == 0xF8,
              bytes[offset + 2] & 0xF8 == 0xF8,
              chromaFormat == 1,
              lumaBitDepthMinus8 == 0,
              chromaBitDepthMinus8 == 0 else {
            return false
        }
        offset += 4
        guard let extensions = readLengthPrefixedUnits(
            bytes,
            count: sequenceParameterSetExtensionCount,
            offset: &offset
        ) else {
            return false
        }
        return offset == bytes.count
            && extensions.allSatisfy { !$0.isEmpty && $0[0] & 0x1F == 13 }
    }

    private static func hevcConfigurationMatches(
        _ data: Data,
        profileIDC: UInt8,
        bitDepthMinus8: UInt8,
        expectedWidth: Int32,
        expectedHeight: Int32
    ) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 23,
              bytes[0] == 1,
              bytes[1] & 0x1F == profileIDC,
              bytes[13] & 0xF0 == 0xF0,
              bytes[15] & 0xFC == 0xFC,
              bytes[16] & 0xFC == 0xFC,
              bytes[16] & 0x03 == 1,
              bytes[17] & 0xF8 == 0xF8,
              bytes[18] & 0xF8 == 0xF8,
              bytes[17] & 0x07 == bitDepthMinus8,
              bytes[18] & 0x07 == bitDepthMinus8 else {
            return false
        }
        let arrayCount = Int(bytes[22])
        let compatibilityFlags = UInt32(bytes[2]) << 24
            | UInt32(bytes[3]) << 16
            | UInt32(bytes[4]) << 8
            | UInt32(bytes[5])
        let constraintIndicatorFlags = bytes[6...11].reduce(UInt64(0)) {
            $0 << 8 | UInt64($1)
        }
        let tier: VideoCodecTier = bytes[1] & 0x20 == 0 ? .main : .high
        var offset = 23
        var parameterSetTypes = Set<UInt8>()
        var sequenceParameterSets: [[UInt8]] = []
        for _ in 0..<arrayCount {
            guard offset + 3 <= bytes.count else { return false }
            let nalUnitType = bytes[offset] & 0x3F
            offset += 1
            guard let unitCount = unsigned16(bytes, at: offset) else { return false }
            offset += 2
            guard unitCount > 0 else { return false }
            for _ in 0..<unitCount {
                guard let length = unsigned16(bytes, at: offset) else { return false }
                offset += 2
                guard length > 0, offset + length <= bytes.count else { return false }
                let unit = Array(bytes[offset..<(offset + length)])
                guard unit.count >= 2,
                      unit[0] & 0x80 == 0,
                      unit[0] >> 1 & 0x3F == nalUnitType,
                      unit[1] & 0x07 > 0 else {
                    return false
                }
                if nalUnitType == 33 { sequenceParameterSets.append(unit) }
                offset += length
            }
            parameterSetTypes.insert(nalUnitType)
        }
        return offset == bytes.count
            && parameterSetTypes.isSuperset(of: [32, 33, 34])
            && !sequenceParameterSets.isEmpty
            && sequenceParameterSets.allSatisfy {
                guard let proof = try? VideoSequenceParameterSetInspector.inspectHEVC($0) else {
                    return false
                }
                let expectedBitDepth = 8 + bitDepthMinus8
                return proof.profileIDC == profileIDC
                    && proof.compatibilityFlags == compatibilityFlags
                    && proof.hevcConstraintIndicatorFlags == constraintIndicatorFlags
                    && proof.levelIDC == bytes[12]
                    && proof.tier == tier
                    && proof.chromaFormatIDC == 1
                    && proof.bitDepthLuma == expectedBitDepth
                    && proof.bitDepthChroma == expectedBitDepth
                    && proof.width == expectedWidth
                    && proof.height == expectedHeight
            }
    }

    private static func readLengthPrefixedUnits(
        _ bytes: [UInt8],
        count: Int,
        offset: inout Int
    ) -> [[UInt8]]? {
        var units: [[UInt8]] = []
        units.reserveCapacity(count)
        for _ in 0..<count {
            guard let length = unsigned16(bytes, at: offset) else { return nil }
            offset += 2
            guard length > 0, offset + length <= bytes.count else { return nil }
            units.append(Array(bytes[offset..<(offset + length)]))
            offset += length
        }
        return units
    }

    private static func unsigned16(_ bytes: [UInt8], at offset: Int) -> Int? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }

    private static func formatExtensions(
        _ format: CMFormatDescription
    ) -> [String: Any]? {
        guard let raw = CMFormatDescriptionGetExtensions(format) else { return nil }
        return raw as? [String: Any]
    }

    private static func strictDictionary(_ value: Any?) -> [String: Any]? {
        guard let value,
              CFGetTypeID(value as AnyObject) == CFDictionaryGetTypeID() else {
            return nil
        }
        return value as? [String: Any]
    }

    private static func strictData(_ value: Any?) -> Data? {
        guard let value,
              CFGetTypeID(value as AnyObject) == CFDataGetTypeID() else {
            return nil
        }
        return value as? Data
    }

    private static func strictString(_ value: Any?) -> String? {
        guard let value,
              CFGetTypeID(value as AnyObject) == CFStringGetTypeID() else {
            return nil
        }
        return value as? String
    }

    private static func exactString(_ value: Any?, equals expected: String) -> Bool {
        strictString(value) == expected
    }

    private static func transferMatches(
        _ value: Any?,
        expected: VideoFormatMetadata.Transfer
    ) -> Bool {
        guard let value = strictString(value) else { return false }
        switch expected {
        case .bt709:
            return value == kCVImageBufferTransferFunction_ITU_R_709_2 as String
                || value == kCVImageBufferTransferFunction_ITU_R_2020 as String
        case .pq, .hlg, .linear:
            return value == expected.vtValue
        case .unknown:
            return false
        }
    }

    private static func optionalString(_ value: Any?, equals expected: String?) -> Bool {
        guard let expected else { return value == nil }
        return exactString(value, equals: expected)
    }

    private static func exactBoolean(_ value: Any?, equals expected: Bool) -> Bool {
        guard let value,
              CFGetTypeID(value as AnyObject) == CFBooleanGetTypeID() else {
            return false
        }
        return CFEqual(value as CFTypeRef, expected ? kCFBooleanTrue : kCFBooleanFalse)
    }

    private static func optionalData(_ value: Any?, equals expected: Data?) -> Bool {
        guard let expected else { return value == nil }
        return strictData(value) == expected
    }

    private static func optionalAspectRatio(
        _ value: Any?,
        equals expected: MediaRational?
    ) -> Bool {
        guard let expected else { return value == nil }
        guard let dictionary = strictDictionary(value),
              let horizontal = strictPositiveInt32(dictionary[
                  kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String
              ]),
              let vertical = strictPositiveInt32(dictionary[
                  kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String
              ]),
              let actual = MediaRational(num: horizontal, den: vertical) else {
            return false
        }
        return actual == expected
    }

    private static func optionalCleanAperture(
        _ value: Any?,
        equals expected: HLSCleanApertureSignature?
    ) -> Bool {
        guard let expected else { return value == nil }
        guard let dictionary = strictDictionary(value),
              let width = unsignedRational(
                  dictionary[
                      kCMFormatDescriptionKey_CleanApertureWidthRational as String
                  ]
              ),
              let height = unsignedRational(
                  dictionary[
                      kCMFormatDescriptionKey_CleanApertureHeightRational as String
                  ]
              ),
              let horizontalOffset = signedRational(
                  dictionary[
                      kCMFormatDescriptionKey_CleanApertureHorizontalOffsetRational as String
                  ]
              ),
              let verticalOffset = signedRational(
                  dictionary[
                      kCMFormatDescriptionKey_CleanApertureVerticalOffsetRational as String
                  ]
              ) else {
            return false
        }
        return width == expected.width
            && height == expected.height
            && horizontalOffset == expected.horizontalOffset
            && verticalOffset == expected.verticalOffset
    }

    private static func unsignedRational(_ value: Any?) -> MediaRational? {
        guard let pair = rationalPair(value),
              pair.0 > 0,
              pair.1 > 0 else {
            return nil
        }
        return MediaRational(num: pair.0, den: pair.1)
    }

    private static func signedRational(_ value: Any?) -> SignedMediaRational? {
        guard let pair = rationalPair(value), pair.1 > 0 else { return nil }
        return SignedMediaRational(num: pair.0, den: pair.1)
    }

    private static func rationalPair(_ value: Any?) -> (Int32, Int32)? {
        guard let value,
              CFGetTypeID(value as AnyObject) == CFArrayGetTypeID(),
              let values = value as? [Any],
              values.count == 2,
              let numerator = strictInt32(values[0]),
              let denominator = strictInt32(values[1]) else {
            return nil
        }
        return (numerator, denominator)
    }

    private static func strictPositiveInt32(_ value: Any?) -> Int32? {
        guard let result = strictInt32(value), result > 0 else { return nil }
        return result
    }

    private static func strictInt32(_ value: Any?) -> Int32? {
        guard let value,
              CFGetTypeID(value as AnyObject) == CFNumberGetTypeID(),
              let number = value as? NSNumber else {
            return nil
        }
        let integer = number.int64Value
        guard number.compare(NSNumber(value: integer)) == .orderedSame else { return nil }
        return Int32(exactly: integer)
    }

    private static func validate(_ configuration: VTVideoEncoderConfiguration) throws {
        let format = configuration.inputFormat
        guard format.width > 0, format.height > 0 else {
            throw VTVideoEncoderFailure.invalidDimensions
        }
        guard format.width <= 3_840, format.height <= 2_160 else {
            throw VTVideoEncoderFailure.dimensionsExceeded
        }
        let frameRateLimit = Int64(configuration.frameRate.den)
            .multipliedReportingOverflow(by: 60)
        guard !frameRateLimit.overflow,
              Int64(configuration.frameRate.num) <= frameRateLimit.partialValue else {
            throw VTVideoEncoderFailure.frameRateExceeded
        }

        let expectedBitDepth: UInt8
        switch format.pixelFormat {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            expectedBitDepth = 8
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            expectedBitDepth = 10
        default:
            throw VTVideoEncoderFailure.unsupportedPixelFormat
        }
        guard format.bitDepth == expectedBitDepth else {
            throw VTVideoEncoderFailure.inconsistentBitDepth
        }
        guard format.range != .unknown,
              format.primaries != .unknown,
              format.transfer != .unknown,
              format.matrix != .unknown else {
            throw VTVideoEncoderFailure.unknownMetadata
        }
        if let mastering = format.masteringDisplayColorVolume,
           mastering.count != 24 {
            throw VTVideoEncoderFailure.invalidHDRMetadata
        }
        if let light = format.contentLightLevelInfo,
           light.count != 4 {
            throw VTVideoEncoderFailure.invalidHDRMetadata
        }

        switch format.dynamicRange {
        case .hlg, .pq:
            guard expectedBitDepth == 10,
                  format.primaries == .bt2020,
                  format.matrix == .bt2020 else {
                throw VTVideoEncoderFailure.inconsistentHDRMetadata
            }
        case .sdr:
            guard format.masteringDisplayColorVolume == nil,
                  format.contentLightLevelInfo == nil,
                  (format.primaries == .bt709 && format.matrix == .bt709)
                    || (format.primaries == .bt2020 && format.matrix == .bt2020) else {
                throw VTVideoEncoderFailure.inconsistentHDRMetadata
            }
        }
    }

    private static func preferredProfile(
        for format: VideoEncodingInputFormatSignature
    ) -> VTVideoCodecProfile {
        if format.bitDepth == 10 { return .hevcMain10 }
        if format.width <= 1_920, format.height <= 1_080 { return .h264High }
        return .hevcMain
    }

    private static func creationConfiguration(
        _ configuration: VTVideoEncoderConfiguration,
        profile: VTVideoCodecProfile
    ) -> VTCompressionSessionCreationConfiguration {
        let format = configuration.inputFormat
        return VTCompressionSessionCreationConfiguration(
            width: format.width,
            height: format.height,
            codecType: profile.codecType,
            encoderSpecification: [
                kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String:
                    .boolean(true),
            ],
            sourceImageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: .unsigned(UInt64(format.pixelFormat)),
                kCVPixelBufferWidthKey as String: .signed(Int64(format.width)),
                kCVPixelBufferHeightKey as String: .signed(Int64(format.height)),
                kCVPixelBufferMetalCompatibilityKey as String: .boolean(true),
                kCVPixelBufferIOSurfacePropertiesKey as String: .dictionary([:]),
            ]
        )
    }

    private static func configure(
        _ session: any VTCompressionSessionHandle,
        profile: VTVideoCodecProfile,
        configuration: VTVideoEncoderConfiguration,
        api: any VTCompressionAPI
    ) throws {
        let format = configuration.inputFormat
        let interval = try roundedUpFrameRate(configuration.frameRate)
        var properties: [(String, VTCompressionPropertyValue)] = [
            (kVTCompressionPropertyKey_RealTime as String, .boolean(true)),
            (kVTCompressionPropertyKey_ExpectedFrameRate as String, .rational(
                Int64(configuration.frameRate.num), Int64(configuration.frameRate.den)
            )),
            (kVTCompressionPropertyKey_AllowFrameReordering as String, .boolean(false)),
            (kVTCompressionPropertyKey_AllowOpenGOP as String, .boolean(false)),
            (kVTCompressionPropertyKey_MaxKeyFrameInterval as String, .signed(interval)),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration as String, .rational(1, 1)),
            (kVTCompressionPropertyKey_FieldCount as String, .signed(1)),
            (kVTCompressionPropertyKey_ProfileLevel as String, .string(profile.profileLevel)),
            (kVTCompressionPropertyKey_OutputBitDepth as String, .signed(Int64(format.bitDepth))),
            (kVTCompressionPropertyKey_AverageBitRate as String, .unsigned(
                configuration.bitrate.averageBitsPerSecond
            )),
            (kVTCompressionPropertyKey_DataRateLimits as String, .array([
                .unsigned(configuration.bitrate.dataRateLimitBytesPerSecond),
                .signed(1),
            ])),
            (kVTCompressionPropertyKey_ColorPrimaries as String, .string(format.primaries.vtValue)),
            (kVTCompressionPropertyKey_TransferFunction as String, .string(format.transfer.vtValue)),
            (kVTCompressionPropertyKey_YCbCrMatrix as String, .string(format.matrix.vtValue)),
        ]
        if let cleanAperture = format.cleanAperture {
            properties.append((kVTCompressionPropertyKey_CleanAperture as String, .dictionary([
                kCMFormatDescriptionKey_CleanApertureWidth as String:
                    .rational(Int64(cleanAperture.width.num), Int64(cleanAperture.width.den)),
                kCMFormatDescriptionKey_CleanApertureHeight as String:
                    .rational(Int64(cleanAperture.height.num), Int64(cleanAperture.height.den)),
                kCMFormatDescriptionKey_CleanApertureHorizontalOffset as String: .rational(
                    Int64(cleanAperture.horizontalOffset.num),
                    Int64(cleanAperture.horizontalOffset.den)
                ),
                kCMFormatDescriptionKey_CleanApertureVerticalOffset as String: .rational(
                    Int64(cleanAperture.verticalOffset.num),
                    Int64(cleanAperture.verticalOffset.den)
                ),
                kCMFormatDescriptionKey_CleanApertureWidthRational as String: .array([
                    .signed(Int64(cleanAperture.width.num)), .signed(Int64(cleanAperture.width.den)),
                ]),
                kCMFormatDescriptionKey_CleanApertureHeightRational as String: .array([
                    .signed(Int64(cleanAperture.height.num)), .signed(Int64(cleanAperture.height.den)),
                ]),
                kCMFormatDescriptionKey_CleanApertureHorizontalOffsetRational as String: .array([
                    .signed(Int64(cleanAperture.horizontalOffset.num)),
                    .signed(Int64(cleanAperture.horizontalOffset.den)),
                ]),
                kCMFormatDescriptionKey_CleanApertureVerticalOffsetRational as String: .array([
                    .signed(Int64(cleanAperture.verticalOffset.num)),
                    .signed(Int64(cleanAperture.verticalOffset.den)),
                ]),
            ])))
        }
        if let aspect = format.sampleAspectRatio {
            properties.append((kVTCompressionPropertyKey_PixelAspectRatio as String, .dictionary([
                kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String:
                    .signed(Int64(aspect.num)),
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String:
                    .signed(Int64(aspect.den)),
            ])))
        }
        if let mastering = format.masteringDisplayColorVolume {
            properties.append((
                kVTCompressionPropertyKey_MasteringDisplayColorVolume as String,
                .data(mastering)
            ))
        }
        if let light = format.contentLightLevelInfo {
            properties.append((
                kVTCompressionPropertyKey_ContentLightLevelInfo as String,
                .data(light)
            ))
        }
        if format.dynamicRange != .sdr {
            properties.append((
                kVTCompressionPropertyKey_HDRMetadataInsertionMode as String,
                .string(kVTHDRMetadataInsertionMode_Auto as String)
            ))
        }

        for (key, value) in properties {
            let status = api.setProperty(session, key: key, value: value)
            guard status == noErr else {
                throw VTVideoEncoderFailure.propertySet(key, status)
            }
        }
    }

    private static func roundedUpFrameRate(_ frameRate: MediaRational) throws -> Int64 {
        let numerator = Int64(frameRate.num)
        let denominator = Int64(frameRate.den)
        let added = numerator.addingReportingOverflow(denominator - 1)
        guard !added.overflow else { throw VTVideoEncoderFailure.arithmeticOverflow }
        return added.partialValue / denominator
    }

    private static func isCapabilityPropertyFailure(
        _ failure: VTVideoEncoderFailure
    ) -> Bool {
        guard case let .propertySet(_, status) = failure else { return false }
        return status == kVTPropertyNotSupportedErr || status == kVTPropertyReadOnlyErr
    }

    private static func isSync(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let rawAttachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) else { return true }
        let attachments = rawAttachments as NSArray
        guard let first = attachments.firstObject as? NSDictionary else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }
}

private extension VTVideoCodecProfile {
    var profileLevel: String {
        switch self {
        case .h264High: kVTProfileLevel_H264_High_AutoLevel as String
        case .hevcMain: kVTProfileLevel_HEVC_Main_AutoLevel as String
        case .hevcMain10: kVTProfileLevel_HEVC_Main10_AutoLevel as String
        }
    }
}

extension VideoFormatMetadata.Primaries {
    var vtValue: String {
        switch self {
        case .bt709: kCVImageBufferColorPrimaries_ITU_R_709_2 as String
        case .bt2020: kCVImageBufferColorPrimaries_ITU_R_2020 as String
        case .unknown: ""
        }
    }
}

extension VideoFormatMetadata.Transfer {
    var vtValue: String {
        switch self {
        case .bt709: kCVImageBufferTransferFunction_ITU_R_709_2 as String
        case .pq: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
        case .hlg: kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
        case .linear: kCVImageBufferTransferFunction_Linear as String
        case .unknown: ""
        }
    }
}

extension VideoFormatMetadata.Matrix {
    var vtValue: String {
        switch self {
        case .bt601: kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String
        case .bt709: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
        case .bt2020: kCVImageBufferYCbCrMatrix_ITU_R_2020 as String
        case .identity: "Identity"
        case .unknown: ""
        }
    }
}
