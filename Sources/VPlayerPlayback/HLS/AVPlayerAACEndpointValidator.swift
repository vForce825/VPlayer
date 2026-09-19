// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

enum AVPlayerAACEndpointValidationFailure: Error, Equatable {
    case authorityAlreadyConsumed
    case identityMismatch
    case incompleteHTTPBody
    case invalidTrim
    case effectiveEndMismatch
}

/// Task21 只消费 Task17 writer terminal 与 Task20 completed-response authority。
/// 调用方不能填写 expected UUID、buffer index、trim 或 endpoint。
enum AVPlayerAACEndpointValidator {
    @discardableResult
    static func validate(
        authority: AACEffectiveEndpointAuthority,
        completedPublication: LoopbackCompletedPublicationEvidence
    ) throws -> AACEffectiveEndpointReceipt {
        let receipt = try preflight(
            authority: authority,
            completedPublication: completedPublication
        )
        return try consume(authority: authority, verifiedReceipt: receipt)
    }

    /// server 需要先把 publication horizon、selection 与时间轴映射一并复验，再提交
    /// endpoint 的单次消费。预检只读取 writer 私有冻结值，不签发新能力。
    static func preflight(
        authority: AACEffectiveEndpointAuthority,
        completedPublication: some LoopbackPublicationFacts
    ) throws -> AACEffectiveEndpointReceipt {
        if let rendition = authority.renditionBinding {
            return try preflightRendition(
                authority: authority,
                rendition: rendition,
                completedPublication: completedPublication)
        }
        let receipt = authority.receipt
        let terminal = authority.terminal
        guard terminal.terminalReason == .finished,
              terminal.identity == receipt.writerReceiptIdentity,
              terminal.binding == receipt.binding,
              terminal.inputCount == receipt.inputEvidenceCount,
              terminal.callbackEvidenceCount == receipt.callbackEvidenceCount,
              terminal.callbackEvidenceDigest == receipt.callbackEvidenceDigest,
              terminal.lastLogicalSequence == receipt.terminalLogicalSequence,
              terminal.lastCallbackReportIdentity == receipt.terminalMedia.reportIdentity,
              receipt.mappingReportIdentity == receipt.firstMedia.reportIdentity,
              completedPublication.itemGeneration == receipt.binding.itemGeneration.rawValue,
              authority.initialization.key.itemGeneration
                == receipt.binding.itemGeneration.rawValue,
              authority.initialization.key.mediaEpoch
                == receipt.binding.mediaEpoch.rawValue,
              authority.initialization.key.participantID
                == receipt.binding.publicationParticipantID.rawValue,
              authority.initialization.backingIdentity
                == receipt.initializationBackingIdentity,
              authority.initialization.key.kind == .initialization,
              !authority.media.isEmpty, authority.media.count <= 128,
              authority.media.first == receipt.firstMedia,
              authority.media.last == receipt.terminalMedia,
              authority.media.allSatisfy({
                  $0.key.itemGeneration == receipt.binding.itemGeneration.rawValue
                    && $0.key.mediaEpoch == receipt.binding.mediaEpoch.rawValue
                    && $0.key.participantID
                        == receipt.binding.publicationParticipantID.rawValue
                    && $0.key.kind == .media
              }),
              let participant = completedPublication.participants.first(where: {
                  $0.participantID == receipt.binding.publicationParticipantID.rawValue
                    && $0.renditionIdentity == receipt.binding.renditionIdentity
                    && $0.mediaType == .audio
              }) else {
            throw AVPlayerAACEndpointValidationFailure.identityMismatch
        }
        guard participant.containsInitializationBacking(
                  authority.initialization.backingIdentity
              ), !participant.completedMedia.isEmpty,
              participant.completedMedia.allSatisfy({
                  completed in authority.media.contains {
                      $0.key == completed.key && $0.backingIdentity == completed.backingIdentity
                  }
              }), let terminalMedia = authority.media.last,
              participant.completedMedia.contains(where: {
                  $0.key == terminalMedia.key
                    && $0.backingIdentity == terminalMedia.backingIdentity
              }) else {
            throw AVPlayerAACEndpointValidationFailure.incompleteHTTPBody
        }
        guard receipt.sampleRate > 0,
              receipt.leadingFrames >= 0, receipt.trailingFrames >= 0,
              receipt.totalDecodedFrames >= receipt.leadingFrames,
              receipt.totalDecodedFrames - receipt.leadingFrames >= receipt.trailingFrames,
              receipt.realSampleCount
                == receipt.totalDecodedFrames - receipt.leadingFrames - receipt.trailingFrames else {
            throw AVPlayerAACEndpointValidationFailure.invalidTrim
        }
        let inputEffectiveBase = try receipt.inputPhysicalBase.adding(
            ExactMediaTime(value: receipt.leadingFrames,
                           timescale: receipt.sampleRate))
        let offset = try receipt.writtenPhysicalBase.subtracting(
            receipt.inputPhysicalBase)
        let writtenEffectiveBase = try receipt.inputEffectiveBase.adding(offset)
        let calculatedEffectiveEnd = try receipt.writtenEffectiveBase.adding(
            ExactMediaTime(value: receipt.realSampleCount,
                           timescale: receipt.sampleRate))
        let calculatedPhysicalEnd = try receipt.writtenPhysicalBase.adding(
            ExactMediaTime(value: receipt.totalDecodedFrames,
                           timescale: receipt.sampleRate))
        let physicalEndFromTrim = try receipt.lastEffectiveEnd.adding(
            ExactMediaTime(value: receipt.trailingFrames,
                           timescale: receipt.sampleRate))
        guard receipt.inputEffectiveBase == inputEffectiveBase,
              receipt.timelineOffset == offset,
              receipt.writtenEffectiveBase == writtenEffectiveBase,
              receipt.lastEffectiveEnd == calculatedEffectiveEnd,
              receipt.terminalPhysicalEnd == calculatedPhysicalEnd,
              receipt.terminalPhysicalEnd == physicalEndFromTrim else {
            throw AVPlayerAACEndpointValidationFailure.effectiveEndMismatch
        }
        return receipt
    }

    /// 跨物理 writer 的终态只信稳定 rendition owner 汇合的三份私签 receipt。
    /// HTTP 可以是实际 GET 子集，因此这里只要求其真实集合包含终段，不伪造全量相等。
    private static func preflightRendition(
        authority: AACEffectiveEndpointAuthority,
        rendition: AACRenditionTerminalBinding,
        completedPublication: some LoopbackPublicationFacts
    ) throws -> AACEffectiveEndpointReceipt {
        let receipt = authority.receipt
        guard rendition.owns(authority),
              let publication = authority.publicationMembership,
              let http = authority.httpMembership,
              authority.terminal.terminalReason == .finished,
              authority.terminal.identity == receipt.writerReceiptIdentity,
              authority.terminal.binding == receipt.binding,
              receipt.callbackEvidenceCount == Int(publication.snapshot.count),
              receipt.callbackEvidenceDigest == publication.snapshot.digest,
              publication.snapshot.pendingCount == 0,
              http.snapshot.pendingCount == 0,
              http.snapshot.count <= publication.snapshot.count,
              publication.terminalLeaf == http.terminalLeaf,
              receipt.terminalLogicalSequence == publication.terminalLeaf.logicalSequence,
              receipt.firstMedia.reportIdentity == receipt.mappingReportIdentity,
              authority.initialization.key.kind == .initialization,
              authority.initialization.backingIdentity
                == receipt.initializationBackingIdentity,
              authority.media.first == receipt.firstMedia,
              authority.media.last == receipt.terminalMedia,
              completedPublication.itemGeneration == receipt.binding.itemGeneration.rawValue,
              let participant = completedPublication.participants.first(where: {
                  $0.participantID == receipt.binding.publicationParticipantID.rawValue
                    && $0.renditionIdentity == receipt.binding.renditionIdentity
                    && $0.mediaType == .audio
              }),
              participant.containsInitializationBacking(
                authority.initialization.backingIdentity),
              participant.completedMedia.contains(where: {
                  $0.key == receipt.terminalMedia.key
                    && $0.backingIdentity == receipt.terminalMedia.backingIdentity
              }) else {
            throw AVPlayerAACEndpointValidationFailure.identityMismatch
        }
        guard receipt.sampleRate > 0,
              receipt.leadingFrames >= 0, receipt.trailingFrames >= 0,
              receipt.totalDecodedFrames >= receipt.leadingFrames,
              receipt.totalDecodedFrames - receipt.leadingFrames >= receipt.trailingFrames,
              receipt.realSampleCount
                == receipt.totalDecodedFrames - receipt.leadingFrames - receipt.trailingFrames else {
            throw AVPlayerAACEndpointValidationFailure.invalidTrim
        }
        let inputEffectiveBase = try receipt.inputPhysicalBase.adding(
            ExactMediaTime(value: receipt.leadingFrames,
                           timescale: receipt.sampleRate))
        let offset = try receipt.writtenPhysicalBase.subtracting(
            receipt.inputPhysicalBase)
        let writtenEffectiveBase = try receipt.inputEffectiveBase.adding(offset)
        let calculatedEffectiveEnd = try receipt.writtenEffectiveBase.adding(
            ExactMediaTime(value: receipt.realSampleCount,
                           timescale: receipt.sampleRate))
        let calculatedPhysicalEnd = try receipt.writtenPhysicalBase.adding(
            ExactMediaTime(value: receipt.totalDecodedFrames,
                           timescale: receipt.sampleRate))
        let physicalEndFromTrim = try receipt.lastEffectiveEnd.adding(
            ExactMediaTime(value: receipt.trailingFrames,
                           timescale: receipt.sampleRate))
        guard receipt.inputEffectiveBase == inputEffectiveBase,
              receipt.timelineOffset == offset,
              receipt.writtenEffectiveBase == writtenEffectiveBase,
              receipt.lastEffectiveEnd == calculatedEffectiveEnd,
              receipt.terminalPhysicalEnd == calculatedPhysicalEnd,
              receipt.terminalPhysicalEnd == physicalEndFromTrim else {
            throw AVPlayerAACEndpointValidationFailure.effectiveEndMismatch
        }
        return receipt
    }

    /// 只有通过同一 completed-publication 预检得到的不可变 receipt 才能提交。
    /// authority 自身仍是唯一一次性门闩，重复或竞态消费继续失败闭合。
    static func consume(
        authority: AACEffectiveEndpointAuthority,
        verifiedReceipt: AACEffectiveEndpointReceipt
    ) throws -> AACEffectiveEndpointReceipt {
        guard authority.receipt == verifiedReceipt else {
            throw AVPlayerAACEndpointValidationFailure.identityMismatch
        }
        guard authority.consume() else {
            throw AVPlayerAACEndpointValidationFailure.authorityAlreadyConsumed
        }
        return verifiedReceipt
    }
}
