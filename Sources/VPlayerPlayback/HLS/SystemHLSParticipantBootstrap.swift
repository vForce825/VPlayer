// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// 首个真实 writer initialization 的 production 验证入口。它只接受 relay 已封存的
/// callback object；不能从 Data、playlist 或测试 sample 重建 proof。
enum SystemHLSParticipantBootstrap {
    static func makeParticipant(
        initialization: SealedMediaObject,
        binding: FMP4WriterBinding,
        mediaType: FinalFMP4MediaType,
        relay: SegmentReportRelay,
        aacTerminalBinding: AACWriterTerminalBinding? = nil,
        aacRenditionBinding: AACRenditionTerminalBinding? = nil
    ) throws -> HLSInitialParticipant {
        let proof = try FinalFMP4Validator(binding: binding, mediaType: mediaType)
            .validateInitialization(initialization)
        return HLSInitialParticipant(
            initialization: initialization, proof: proof, relay: relay,
            candidateTicket: nil, aacTerminalBinding: aacTerminalBinding,
            aacRenditionBinding: aacRenditionBinding
        )
    }
}

/// 注入 `SegmentReportRelay(objectSink:)` 的生产捕获器。它保存 relay 已封存的 object
/// 身份而非 callback bytes，bootstrap 因而不能绕过 relay/validator。
final class SystemHLSSealedObjectCapture: @unchecked Sendable {
    private let lock = NSCondition()
    private var objects: [SealedMediaObject] = []

    func accept(_ object: SealedMediaObject) {
        lock.withLock {
            objects.append(object)
            lock.broadcast()
        }
    }

    func takeInitialization() -> SealedMediaObject? {
        lock.withLock {
            guard let index = objects.firstIndex(where: { $0.kind == .initialization }) else { return nil }
            return objects.remove(at: index)
        }
    }

    func takeMedia() -> SealedMediaObject? {
        lock.withLock {
            guard let index = objects.firstIndex(where: { $0.kind == .media }) else { return nil }
            return objects.remove(at: index)
        }
    }

    func waitForInitialization(until deadline: Date) -> SealedMediaObject? {
        lock.lock()
        defer { lock.unlock() }
        while !objects.contains(where: { $0.kind == .initialization }) {
            guard lock.wait(until: deadline) else { return nil }
        }
        guard let index = objects.firstIndex(where: { $0.kind == .initialization }) else {
            return nil
        }
        return objects.remove(at: index)
    }
}

struct SystemHLSPublicationBootstrap: @unchecked Sendable {
    let store: SealedMediaStore
    let publisher: HLSPublicationCoordinator

    init(token: LoopbackSessionToken, declaration: HLSItemDeclaration,
         participants: [HLSInitialParticipant]) throws {
        store = SealedMediaStore(loopbackSession: token, itemGeneration: declaration.itemGeneration)
        publisher = try HLSPublicationCoordinator(
            store: store, participants: participants, declaration: declaration,
            anchor: .init(
                mediaOrigin: ExactMediaTime(value: 0, timescale: 1),
                utcMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000))
        )
    }
}
