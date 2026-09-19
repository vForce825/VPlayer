// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import Security

enum LoopbackAuthorizationError: Error, Equatable {
    case invalidEntropy
    case randomGenerationFailed
    case invalidAuthority
    case invalidTarget
    case notFound
    case gone
}

/// 只有系统 CSPRNG 能签发的进程内能力；字符串只是 URI 表示，不能反向构造能力。
final class LoopbackSessionToken: @unchecked Sendable, Hashable {
    let identity = UUID()
    let value: String

    private init(entropy: Data) throws {
        guard entropy.count == 16 else { throw LoopbackAuthorizationError.invalidEntropy }
        value = entropy.map { String(format: "%02x", $0) }.joined()
        guard value.utf8.count == 32 else { throw LoopbackAuthorizationError.invalidEntropy }
    }

    static func generateSystemCapability(
        testing: LoopbackHTTPTestingConfiguration? = nil
    ) throws -> LoopbackSessionToken {
        try LoopbackSessionToken(entropy: LoopbackSystemEntropyReader.read16(testing: testing))
    }

    static func == (lhs: LoopbackSessionToken, rhs: LoopbackSessionToken) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(identity) }

    static func matches(candidate: String, expected: String) -> Bool {
        let candidateBytes = Array(candidate.utf8)
        let expectedBytes = Array(expected.utf8)
        guard candidateBytes.count == 32, expectedBytes.count == 32,
              candidateBytes.allSatisfy(Self.isLowercaseHex),
              expectedBytes.allSatisfy(Self.isLowercaseHex) else { return false }
        return zip(candidateBytes, expectedBytes).reduce(UInt8(0)) { partial, pair in
            partial | (pair.0 ^ pair.1)
        } == 0
    }

    private static func isLowercaseHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }
}

/// 系统随机读取保持私有；测试故障只能发生在这条真实 reader 路径内，不能绕过 reader 直接造 token。
private enum LoopbackSystemEntropyReader {
    static func read16(testing: LoopbackHTTPTestingConfiguration?) throws -> Data {
        let requested = 16
        let producedCapacity: Int
        if case .shortRead? = testing?.entropyFault { producedCapacity = requested - 1 }
        else { producedCapacity = requested }
        var entropy = Data(count: producedCapacity)
        let status = entropy.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        if case .failure? = testing?.entropyFault {
            testing?.entropyReadTrace?.record(requested: requested, produced: 0)
            throw LoopbackAuthorizationError.randomGenerationFailed
        }
        guard status == errSecSuccess else {
            testing?.entropyReadTrace?.record(requested: requested, produced: 0)
            throw LoopbackAuthorizationError.randomGenerationFailed
        }
        testing?.entropyReadTrace?.record(requested: requested, produced: entropy.count)
        guard entropy.count == requested else { throw LoopbackAuthorizationError.invalidEntropy }
        return entropy
    }
}

/// 测试构造链只接受这一不可自行构造的进程内能力，生产没有 provider 或裸随机数入口。
final class LoopbackHTTPTestingCapability: @unchecked Sendable {
    private init() {}

    #if DEBUG
    static func withCapability<T>(_ operation: (LoopbackHTTPTestingCapability) async throws -> T)
        async rethrows -> T {
        try await operation(LoopbackHTTPTestingCapability())
    }
    #endif
}

final class LoopbackEntropyReadTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    private var requested = 0
    private var produced = 0
    var attemptCount: Int { lock.withLock { attempts } }
    var lastRequestedByteCount: Int { lock.withLock { requested } }
    var lastProducedByteCount: Int { lock.withLock { produced } }
    fileprivate func record(requested: Int, produced: Int) { lock.withLock {
        attempts += 1
        self.requested = requested
        self.produced = produced
    } }
}

struct LoopbackHTTPTestingConfiguration: @unchecked Sendable {
    enum EntropyFault: Sendable { case failure, shortRead }
    fileprivate let capability: LoopbackHTTPTestingCapability
    let entropyFault: EntropyFault?
    let entropyReadTrace: LoopbackEntropyReadTrace?
    let nonLoopbackIPv4AddressesOverride: [String]?
    let permitsSoftCapacitySaturation: Bool
    let cancelAfterStartupProbeAccepted: Bool
    let pauseBeforeBodySend: Bool
    let bodyChunkBytes: Int?
    let failAfterSuccessfulBodyChunks: Int?
    let holdAcceptedConnectionsUntilRuntimeFailure: Bool

    init(capability: LoopbackHTTPTestingCapability,
         entropyFault: EntropyFault? = nil,
         entropyReadTrace: LoopbackEntropyReadTrace? = nil,
         nonLoopbackIPv4AddressesOverride: [String]? = nil,
         permitsSoftCapacitySaturation: Bool = false,
         cancelAfterStartupProbeAccepted: Bool = false,
         pauseBeforeBodySend: Bool = false,
         bodyChunkBytes: Int? = nil,
         failAfterSuccessfulBodyChunks: Int? = nil,
         holdAcceptedConnectionsUntilRuntimeFailure: Bool = false) {
        self.capability = capability
        self.entropyFault = entropyFault
        self.entropyReadTrace = entropyReadTrace
        self.nonLoopbackIPv4AddressesOverride = nonLoopbackIPv4AddressesOverride
        self.permitsSoftCapacitySaturation = permitsSoftCapacitySaturation
        self.cancelAfterStartupProbeAccepted = cancelAfterStartupProbeAccepted
        self.pauseBeforeBodySend = pauseBeforeBodySend
        self.bodyChunkBytes = bodyChunkBytes
        self.failAfterSuccessfulBodyChunks = failAfterSuccessfulBodyChunks
        self.holdAcceptedConnectionsUntilRuntimeFailure = holdAcceptedConnectionsUntilRuntimeFailure
    }
}
