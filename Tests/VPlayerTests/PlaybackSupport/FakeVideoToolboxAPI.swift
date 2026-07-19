// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreMedia
import Foundation
import VideoToolbox
@testable import VPlayerPlayback

final class FakeVideoToolboxSession: VideoToolboxSession, @unchecked Sendable {
    let id: VTSessionID

    init(id: VTSessionID) {
        self.id = id
    }
}

final class FakeVideoToolboxAPI: VideoToolboxAPI, @unchecked Sendable {
    struct CreateRecord: Sendable, Equatable {
        let mediaSubtype: FourCharCode
        let decoderSpecification: [String: VTPropertyValue]
        let imageBufferAttributes: [String: VTPropertyValue]
    }

    struct PropertyRecord: Sendable, Equatable {
        let sessionID: VTSessionID
        let key: String
        let value: VTPropertyValue
    }

    struct CopyRecord: Sendable, Equatable {
        let sessionID: VTSessionID
        let key: String
    }

    struct DecodeRecord: Sendable, Equatable {
        let sessionID: VTSessionID
        let flagsRawValue: UInt32
        let frameOptions: [String: VTPropertyValue]?
    }

    struct Snapshot: Sendable {
        let operations: [String]
        let creates: [CreateRecord]
        let sets: [PropertyRecord]
        let copies: [CopyRecord]
        let decodes: [DecodeRecord]
        let finishedSessionIDs: [VTSessionID]
        let waitedSessionIDs: [VTSessionID]
        let invalidatedSessionIDs: [VTSessionID]
        let pendingDecodeCount: Int
    }

    struct CreateScript: Sendable {
        let status: OSStatus
        let returnsSession: Bool

        init(status: OSStatus, returnsSession: Bool = true) {
            self.status = status
            self.returnsSession = returnsSession
        }
    }

    private struct PendingDecode: @unchecked Sendable {
        let sessionID: VTSessionID
        let output: @Sendable (VTDecodeOutput) -> Void
    }

    private let lock = NSLock()
    private var nextSessionRawValue: UInt64 = 1
    private var createScripts: [CreateScript] = []
    private var setStatuses: [OSStatus] = []
    private var copyResults: [VTPropertyCopyResult] = []
    private var decodeStatuses: [OSStatus] = []
    private var finishStatuses: [OSStatus] = []
    private var waitStatuses: [OSStatus] = []
    private var operations: [String] = []
    private var creates: [CreateRecord] = []
    private var sets: [PropertyRecord] = []
    private var copies: [CopyRecord] = []
    private var decodes: [DecodeRecord] = []
    private var finishedSessionIDs: [VTSessionID] = []
    private var waitedSessionIDs: [VTSessionID] = []
    private var invalidatedSessionIDs: [VTSessionID] = []
    private var pendingDecodes: [PendingDecode] = []

    func enqueueCreate(_ script: CreateScript) {
        withLock { createScripts.append(script) }
    }

    func enqueueSetStatus(_ status: OSStatus) {
        withLock { setStatuses.append(status) }
    }

    func enqueueCopyResult(_ result: VTPropertyCopyResult) {
        withLock { copyResults.append(result) }
    }

    func enqueueDecodeStatus(_ status: OSStatus) {
        withLock { decodeStatuses.append(status) }
    }

    func enqueueFinishStatus(_ status: OSStatus) {
        withLock { finishStatuses.append(status) }
    }

    func enqueueWaitStatus(_ status: OSStatus) {
        withLock { waitStatuses.append(status) }
    }

    var snapshot: Snapshot {
        withLock {
            Snapshot(
                operations: operations,
                creates: creates,
                sets: sets,
                copies: copies,
                decodes: decodes,
                finishedSessionIDs: finishedSessionIDs,
                waitedSessionIDs: waitedSessionIDs,
                invalidatedSessionIDs: invalidatedSessionIDs,
                pendingDecodeCount: pendingDecodes.count
            )
        }
    }

    func deliver(
        index: Int,
        output: VTDecodeOutput,
        on queue: DispatchQueue? = nil
    ) {
        let callback: (@Sendable (VTDecodeOutput) -> Void)? = withLock {
            guard pendingDecodes.indices.contains(index) else { return nil }
            return pendingDecodes[index].output
        }
        guard let callback else { return }
        if let queue {
            queue.async { callback(output) }
        } else {
            callback(output)
        }
    }

    func createSession(
        format: CMVideoFormatDescription,
        decoderSpecification: [String: VTPropertyValue],
        imageBufferAttributes: [String: VTPropertyValue]
    ) -> (status: OSStatus, session: (any VideoToolboxSession)?) {
        withLock {
            operations.append("create")
            creates.append(CreateRecord(
                mediaSubtype: CMFormatDescriptionGetMediaSubType(format),
                decoderSpecification: decoderSpecification,
                imageBufferAttributes: imageBufferAttributes
            ))
            let script = createScripts.isEmpty
                ? CreateScript(status: noErr)
                : createScripts.removeFirst()
            guard script.returnsSession else { return (script.status, nil) }
            let session = FakeVideoToolboxSession(
                id: VTSessionID(rawValue: nextSessionRawValue)
            )
            nextSessionRawValue &+= 1
            return (script.status, session)
        }
    }

    func setProperty(
        _ session: any VideoToolboxSession,
        key: String,
        value: VTPropertyValue
    ) -> OSStatus {
        withLock {
            operations.append("set")
            sets.append(PropertyRecord(sessionID: session.id, key: key, value: value))
            return setStatuses.isEmpty ? noErr : setStatuses.removeFirst()
        }
    }

    func copyProperty(
        _ session: any VideoToolboxSession,
        key: String
    ) -> VTPropertyCopyResult {
        withLock {
            operations.append("copy")
            copies.append(CopyRecord(sessionID: session.id, key: key))
            return copyResults.isEmpty
                ? VTPropertyCopyResult(status: noErr, value: .boolean(true))
                : copyResults.removeFirst()
        }
    }

    func decode(
        _ session: any VideoToolboxSession,
        sampleBuffer: CMSampleBuffer,
        flags: VTDecodeFrameFlags,
        frameOptions: [String: VTPropertyValue]?,
        output: @escaping @Sendable (VTDecodeOutput) -> Void
    ) -> OSStatus {
        withLock {
            operations.append("decode")
            decodes.append(DecodeRecord(
                sessionID: session.id,
                flagsRawValue: flags.rawValue,
                frameOptions: frameOptions
            ))
            let status = decodeStatuses.isEmpty ? noErr : decodeStatuses.removeFirst()
            if status == noErr {
                pendingDecodes.append(PendingDecode(sessionID: session.id, output: output))
            }
            return status
        }
    }

    func finishDelayedFrames(_ session: any VideoToolboxSession) -> OSStatus {
        withLock {
            operations.append("finish")
            finishedSessionIDs.append(session.id)
            return finishStatuses.isEmpty ? noErr : finishStatuses.removeFirst()
        }
    }

    func waitForAsynchronousFrames(_ session: any VideoToolboxSession) -> OSStatus {
        withLock {
            operations.append("wait")
            waitedSessionIDs.append(session.id)
            return waitStatuses.isEmpty ? noErr : waitStatuses.removeFirst()
        }
    }

    func invalidate(_ session: any VideoToolboxSession) {
        withLock {
            operations.append("invalidate")
            invalidatedSessionIDs.append(session.id)
        }
    }

    @discardableResult
    private func withLock<Result>(_ body: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
