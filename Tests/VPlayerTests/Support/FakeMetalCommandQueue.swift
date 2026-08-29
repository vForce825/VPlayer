// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CoreVideo
import Foundation
@testable import VPlayerPlayback

struct FakeYADIFRecordedSubmission: @unchecked Sendable {
    let identifier: UInt64
    let job: YADIFJob
    let outputs: (first: CVPixelBuffer, second: CVPixelBuffer)
}

final class FakeYADIFSubmissionToken: @unchecked Sendable {
    let job: YADIFJob
    let outputs: (first: CVPixelBuffer, second: CVPixelBuffer)

    init(
        job: YADIFJob,
        outputs: (first: CVPixelBuffer, second: CVPixelBuffer)
    ) {
        self.job = job
        self.outputs = outputs
    }
}

final class FakeMetalCommandQueue: YADIFCommandSubmitting, @unchecked Sendable {
    private struct PendingSubmission: @unchecked Sendable {
        let identifier: UInt64
        let token: FakeYADIFSubmissionToken
        let completion: @Sendable (YADIFCommandCompletion) -> Void
    }

    private let lock = NSLock()
    private var nextIdentifier: UInt64 = 1
    private var pending: [PendingSubmission] = []
    private var queuedFailures: [YADIFFailure] = []
    private var storedCommittedCount = 0
    private var submittedIDs: [UInt64] = []
    private var submittedSourceIDs: [UInt64] = []

    var committedCount: Int { lock.withLock { storedCommittedCount } }
    var waitUntilCompletedCallCount: Int { 0 }
    var pendingSubmissionCount: Int { lock.withLock { pending.count } }
    var submissionIdentifiers: [UInt64] { lock.withLock { submittedIDs } }
    var submittedSourceAccessUnitIDs: [UInt64] {
        lock.withLock { submittedSourceIDs }
    }

    func failNextSubmission(with failure: YADIFFailure) {
        lock.withLock { queuedFailures.append(failure) }
    }

    func submit(
        job: YADIFJob,
        outputs: (first: CVPixelBuffer, second: CVPixelBuffer),
        completion: @escaping @Sendable (YADIFCommandCompletion) -> Void
    ) throws(YADIFFailure) {
        let queuedFailure = lock.withLock {
            queuedFailures.isEmpty ? nil : queuedFailures.removeFirst()
        }
        if let queuedFailure { throw queuedFailure }
        lock.withLock {
            let identifier = nextIdentifier
            nextIdentifier &+= 1
            pending.append(PendingSubmission(
                identifier: identifier,
                token: FakeYADIFSubmissionToken(job: job, outputs: outputs),
                completion: completion
            ))
            storedCommittedCount += 1
            submittedIDs.append(identifier)
            submittedSourceIDs.append(job.current.frame.accessUnitID)
        }
    }

    func submission(identifier: UInt64) -> FakeYADIFRecordedSubmission? {
        lock.withLock {
            guard let submission = pending.first(where: { $0.identifier == identifier }) else {
                return nil
            }
            return FakeYADIFRecordedSubmission(
                identifier: identifier,
                job: submission.token.job,
                outputs: submission.token.outputs
            )
        }
    }

    func submissionToken(identifier: UInt64) -> FakeYADIFSubmissionToken? {
        lock.withLock {
            pending.first(where: { $0.identifier == identifier })?.token
        }
    }

    func complete(identifier: UInt64, result: YADIFCommandResult) {
        complete(
            identifier: identifier,
            completion: YADIFCommandCompletion(result: result)
        )
    }

    func complete(identifier: UInt64, completion: YADIFCommandCompletion) {
        let callback = lock.withLock { () -> (@Sendable (YADIFCommandCompletion) -> Void)? in
            guard let index = pending.firstIndex(where: { $0.identifier == identifier }) else {
                return nil
            }
            return pending.remove(at: index).completion
        }
        callback?(completion)
    }

    func completeNext(_ result: YADIFCommandResult) {
        guard let identifier = lock.withLock({ pending.first?.identifier }) else { return }
        complete(identifier: identifier, result: result)
    }
}
