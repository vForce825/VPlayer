// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

final class RouteServiceTestHarness: @unchecked Sendable {
    var initialPorts: PlaybackRoutePorts {
        didSet {
            sdk.initialPorts = initialPorts
        }
    }
    var committedBackend: PlaybackBackendKind?
    var routeGetterCallCount: Int = 0
    var routeGetterMaximumConcurrency: Int = 0
    var categoryCallCount: Int = 0
    var registration: PlaybackAudioSessionRegistration?
    
    let allocator: PlaybackIdentityAllocator
    let clock: ManualPlaybackClock
    let registry: ControlTaskRegistry
    let sdk: FakeAudioSessionSDK
    let owner: PlaybackAudioSessionOwner
    let service: PlaybackAudioRouteService
    
    init(initialPorts: PlaybackRoutePorts) {
        self.initialPorts = initialPorts
        self.allocator = PlaybackIdentityAllocator()
        self.clock = ManualPlaybackClock(100)
        self.registry = ControlTaskRegistry(allocator: allocator, clock: clock)
        self.sdk = FakeAudioSessionSDK(initialPorts: initialPorts)
        self.owner = try! PlaybackAudioSessionOwner(registry: registry, sdk: sdk)
        self.service = PlaybackAudioRouteService(registry: registry, owner: owner)
        self.sdk.harness = self
    }

    var currentAcquisitionTicket: ControlTaskTicket?

    func acquireWithoutNotification() async throws {
        if let current = currentAcquisitionTicket {
            _ = registry.requestCancel(current)
            _ = registry.cancelAcquisitionSession()
            currentAcquisitionTicket = nil
            try? await Task.sleep(nanoseconds: 10_000_000)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                registry.executor.submit { continuation.resume() }
            }
        }

        service.addSubscriber { [weak self] snap in
            if let ports = snap.ports {
                if ports.contains(.airPlay) {
                    self?.committedBackend = .hlsAVPlayer
                } else {
                    self?.committedBackend = .sampleBuffer
                }
            } else {
                self?.committedBackend = nil
            }
        }
        
        let session = PlaybackSessionIdentity(sessionID: try allocator.next(in: .session), requestID: UUID())
        let parent = CurrentPlaybackOperationDeadlineTicket.coldStart(.init(
            identity: .init(sessionIdentity: session, nonce: try allocator.next(in: .deadline)),
            kind: .coldStart,
            originInstant: clock.nowNanoseconds,
            cap: 40_000_000_000,
            accumulatedEffectiveTime: 0,
            runningSince: nil,
            freezeGeneration: 0
        ))
        let acquisition = try registry.beginOutputAcquisition(session: session, parent: parent, resetRecoveryMandatorySuffix: 3_000_000_000)!
        self.currentAcquisitionTicket = acquisition
        
        let _ = owner.startAcquisition(acquisition, receiver: service)
        
        do {
            try await flushCommits()
        } catch {
            print("Ignoring flushCommits error: \(error)")
        }
    }


    func flushCommits() async throws {
        var token: OutputAcquisitionCommitToken? = nil
        for _ in 0..<500 {
            token = registry.outputAcquisitionCommitSnapshot()
            if token != nil { break }
            if registry.executor.safetyIngress.snapshot.interruptionVeto { break }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        guard let validToken = token else {
            if registry.executor.safetyIngress.snapshot.interruptionVeto {
                return
            }
            throw NSError(domain: "Token never generated", code: 1, userInfo: nil)
        }
        
        var handoff: OutputAcquisitionHandoff? = nil
        var currentToken = validToken
        for _ in 0..<50 {
            let result = try registry.commitAcquisitionRelayAndContext(currentToken)
            switch result {
            case .committed(let h):
                handoff = h
            case .retry(let next):
                currentToken = next
            case .rejected:
                throw NSError(domain: "Commit rejected", code: 1, userInfo: nil)
            }
            if handoff != nil { break }
        }
        guard let finalHandoff = handoff else { throw NSError(domain: "Failed to commit after retries", code: 1) }
        guard let registration = owner.registration(for: finalHandoff.committed.relayIdentity.acquisitionTicket) else { throw NSError(domain: "Missing registration", code: 1, userInfo: nil) }
        self.registration = registration
        service.bindSession(registration: registration, initialSampler: finalHandoff.sampler)
        
        // getter进入不等于真实completion/arm完成；虚拟时钟只在实际排期后推进。
        for _ in 0..<500 {
            if clock.hasScheduledDeadlineTimer { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw NSError(domain: "Route stability was not scheduled", code: 3)
    }

    func flushRouteSampler() async throws {
        var token: ControlTaskTicket? = nil
        for _ in 0..<500 {
            if case .pending(let pending) = registry.outputRouteObservationSnapshot(), let sampler = pending.sampler {
                token = sampler
                break
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                registry.executor.submit { continuation.resume() }
            }
        }
        guard let validToken = token else {
            throw NSError(domain: "Sampler never generated", code: 2, userInfo: nil)
        }
        _ = owner.sample(validToken, receiver: service)
        for _ in 0..<500 {
            if case .terminal(.completed) = registry.phase(of: validToken) { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            registry.executor.submit { continuation.resume() }
        }
    }

    func advanceThroughStabilityWindow() async {
        clock.advance(nanoseconds: 125_000_000)
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 2_000_000)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                registry.executor.submit { continuation.resume() }
            }
        }
    }
}

import AVFAudio

final class FakeSDKRouteSnapshot: AudioSessionRouteSnapshot, @unchecked Sendable {
    let ports: PlaybackRoutePorts
    init(ports: PlaybackRoutePorts) { self.ports = ports }
    var endpointCount: Int { ports.isEmpty ? 0 : 1 }
    func endpoint(at index: Int) -> AudioSessionRouteEndpoint {
        if ports.contains(.airPlay) {
            return .init(uid: "airplay-1", portType: AVAudioSession.Port.airPlay.rawValue as NSString, dataSource: .missing)
        } else if ports.contains(.hdmi) {
            return .init(uid: "hdmi-1", portType: AVAudioSession.Port.HDMI.rawValue as NSString, dataSource: .missing)
        } else if ports.contains(.bluetooth) {
            return .init(uid: "bluetooth-1", portType: AVAudioSession.Port.bluetoothA2DP.rawValue as NSString, dataSource: .missing)
        } else {
            return .init(uid: "speaker-1", portType: AVAudioSession.Port.builtInSpeaker.rawValue as NSString, dataSource: .missing)
        }
    }
}

final class FakeAudioSessionSDK: PlaybackAudioSessionSDK, @unchecked Sendable {
    enum Call: Equatable {
        case category(AudioSessionActualPolicy)
        case multichannel
        case activate
        case deactivate
        case currentRoute
    }
    var initialPorts: PlaybackRoutePorts
    weak var harness: RouteServiceTestHarness?
    var failLongFormCategory = false
    var categoryCallCount = 0
    var currentConcurrency = 0
    var maxConcurrency = 0
    var routeCallCount = 0
    var activateCallCount = 0
    var deactivateCallCount = 0
    var shouldFailActivate = false
    var activateError: (any Error)?
    var onActivate: (@Sendable () -> Void)?
    var onDeactivate: (@Sendable () -> Void)?
    var calls: [Call] = []
    let lock = NSLock()
    
    init(initialPorts: PlaybackRoutePorts) {
        self.initialPorts = initialPorts
    }
    
    func setPlaybackCategory(policy: AudioSessionActualPolicy) throws {
        lock.withLock {
            categoryCallCount += 1
            calls.append(.category(policy))
            harness?.categoryCallCount = categoryCallCount
        }
        if failLongFormCategory && policy == .longFormAudio {
            throw NSError(domain: "AVAudioSession", code: -1)
        }
    }
    
    func setSupportsMultichannelContent() throws {
        lock.withLock { calls.append(.multichannel) }
    }
    
    func activate() throws {
        let (cb, err) = lock.withLock { () -> ((@Sendable () -> Void)?, (any Error)?) in
            activateCallCount += 1
            calls.append(.activate)
            let err = shouldFailActivate ? (activateError ?? NSError(domain: "AVAudioSession", code: -1)) : activateError
            return (onActivate, err)
        }
        cb?()
        if let err { throw err }
    }
    func deactivate() throws {
        let cb = lock.withLock { () -> (@Sendable () -> Void)? in
            deactivateCallCount += 1
            calls.append(.deactivate)
            return onDeactivate
        }
        cb?()
    }
    
    func currentRoute() -> any AudioSessionRouteSnapshot {
        lock.withLock {
            currentConcurrency += 1
            routeCallCount += 1
            calls.append(.currentRoute)
            maxConcurrency = max(maxConcurrency, currentConcurrency)
            harness?.routeGetterMaximumConcurrency = maxConcurrency
            harness?.routeGetterCallCount = routeCallCount
        }
        defer { lock.withLock { currentConcurrency -= 1 } }
        return FakeSDKRouteSnapshot(ports: initialPorts)
    }
}

extension FakeAudioSessionSDK {
    func fillRandomBytes(_ bytes: UnsafeMutableRawBufferPointer) -> Bool { return true }
}
