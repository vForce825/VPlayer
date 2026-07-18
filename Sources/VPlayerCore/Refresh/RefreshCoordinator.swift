// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public enum RefreshTrigger: Sendable {
    case manual
    case foreground
    case background
}

public struct RefreshOutcome: Equatable, Sendable {
    public let resource: RefreshResource
    public let succeeded: Bool
    public let message: String?

    public init(resource: RefreshResource, succeeded: Bool, message: String?) {
        self.resource = resource
        self.succeeded = succeeded
        self.message = message
    }
}

public actor RefreshCoordinator {
    public typealias PersistedOutcomeHandler = @Sendable (UUID, RefreshOutcome) async -> Void

    private struct RefreshKey: Hashable, Sendable {
        let profileID: UUID
        let resource: RefreshResource
    }

    private struct InFlight {
        let id: UUID
        let task: Task<RefreshOutcome, Never>
        var waiters: [UUID: CheckedContinuation<RefreshOutcome, Never>]
        var drainWaiters: [UUID: CheckedContinuation<Bool, Never>]
        var isDraining: Bool
    }

    private enum CoordinatorError: Error, Sendable {
        case unsupportedRemoteURL
    }

    private struct PerformedRefresh: Sendable {
        let outcome: RefreshOutcome
        let didPersistTerminalStatus: Bool
    }

    private let repository: any LibraryRepository & RefreshSnapshotCommitting
    private let downloader: any RemoteResourceDownloading
    private let now: @Sendable () -> Date
    private let onPersistedOutcome: PersistedOutcomeHandler?
    private var inFlight: [RefreshKey: InFlight] = [:]

    public init(
        repository: any LibraryRepository & RefreshSnapshotCommitting,
        downloader: any RemoteResourceDownloading,
        now: @escaping @Sendable () -> Date = Date.init,
        onPersistedOutcome: PersistedOutcomeHandler? = nil
    ) {
        self.repository = repository
        self.downloader = downloader
        self.now = now
        self.onPersistedOutcome = onPersistedOutcome
    }

    public func refresh(
        profileID: UUID,
        resources: Set<RefreshResource>,
        trigger: RefreshTrigger
    ) async -> [RefreshOutcome] {
        _ = trigger
        return await withTaskGroup(of: RefreshOutcome.self) { group in
            for resource in resources {
                group.addTask {
                    await self.refreshOne(profileID: profileID, resource: resource)
                }
            }
            var outcomes: [RefreshOutcome] = []
            for await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes.sorted { Self.order($0.resource) < Self.order($1.resource) }
        }
    }

    private func refreshOne(
        profileID: UUID,
        resource: RefreshResource
    ) async -> RefreshOutcome {
        if Task.isCancelled {
            return Self.cancellationOutcome(resource: resource)
        }

        let key = RefreshKey(profileID: profileID, resource: resource)
        if let existing = inFlight[key], existing.isDraining {
            let shouldRetry = await waitForDrain(key: key, flightID: existing.id)
            guard shouldRetry else {
                return Self.cancellationOutcome(resource: resource)
            }
            return await refreshOne(profileID: profileID, resource: resource)
        }

        let flightID: UUID
        if let existing = inFlight[key] {
            flightID = existing.id
        } else {
            let repository = repository
            let downloader = downloader
            let onPersistedOutcome = onPersistedOutcome
            let timestamp = now()
            let id = UUID()
            let task = Task {
                let performed = await Self.performRefresh(
                    repository: repository,
                    downloader: downloader,
                    profileID: profileID,
                    resource: resource,
                    timestamp: timestamp
                )
                if performed.didPersistTerminalStatus, let onPersistedOutcome {
                    await onPersistedOutcome(profileID, performed.outcome)
                }
                self.completeFlight(key: key, id: id, outcome: performed.outcome)
                return performed.outcome
            }
            inFlight[key] = InFlight(
                id: id,
                task: task,
                waiters: [:],
                drainWaiters: [:],
                isDraining: false
            )
            flightID = id
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard var flight = inFlight[key], flight.id == flightID else {
                    continuation.resume(returning: Self.cancellationOutcome(resource: resource))
                    return
                }
                if Task.isCancelled {
                    if flight.waiters.isEmpty {
                        flight.isDraining = true
                        flight.task.cancel()
                    }
                    inFlight[key] = flight
                    continuation.resume(returning: Self.cancellationOutcome(resource: resource))
                    return
                }
                flight.waiters[waiterID] = continuation
                inFlight[key] = flight
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(
                    key: key,
                    flightID: flightID,
                    waiterID: waiterID,
                    resource: resource
                )
            }
        }
    }

    private func cancelWaiter(
        key: RefreshKey,
        flightID: UUID,
        waiterID: UUID,
        resource: RefreshResource
    ) {
        guard var flight = inFlight[key],
              flight.id == flightID,
              let waiter = flight.waiters.removeValue(forKey: waiterID) else { return }
        if flight.waiters.isEmpty {
            flight.isDraining = true
            flight.task.cancel()
        }
        inFlight[key] = flight
        waiter.resume(returning: Self.cancellationOutcome(resource: resource))
    }

    private func waitForDrain(
        key: RefreshKey,
        flightID: UUID
    ) async -> Bool {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard var flight = inFlight[key],
                      flight.id == flightID,
                      flight.isDraining else {
                    continuation.resume(returning: true)
                    return
                }
                if Task.isCancelled {
                    continuation.resume(returning: false)
                    return
                }
                flight.drainWaiters[waiterID] = continuation
                inFlight[key] = flight
            }
        } onCancel: {
            Task {
                await self.cancelDrainWaiter(
                    key: key,
                    flightID: flightID,
                    waiterID: waiterID
                )
            }
        }
    }

    private func cancelDrainWaiter(
        key: RefreshKey,
        flightID: UUID,
        waiterID: UUID
    ) {
        guard var flight = inFlight[key],
              flight.id == flightID,
              let waiter = flight.drainWaiters.removeValue(forKey: waiterID) else { return }
        inFlight[key] = flight
        waiter.resume(returning: false)
    }

    private func completeFlight(
        key: RefreshKey,
        id: UUID,
        outcome: RefreshOutcome
    ) {
        guard let flight = inFlight[key], flight.id == id else { return }
        inFlight[key] = nil
        for waiter in flight.waiters.values {
            waiter.resume(returning: outcome)
        }
        for waiter in flight.drainWaiters.values {
            waiter.resume(returning: true)
        }
    }

    private nonisolated static func performRefresh(
        repository: any LibraryRepository & RefreshSnapshotCommitting,
        downloader: any RemoteResourceDownloading,
        profileID: UUID,
        resource: RefreshResource,
        timestamp: Date
    ) async -> PerformedRefresh {
        var resourceURL: URL?
        do {
            try Task.checkCancellation()
            guard let profile = try await repository.profiles().first(where: { $0.id == profileID }) else {
                throw LibraryRepositoryError.profileNotFound
            }
            let url = resource == .playlist ? profile.m3uURL : profile.epgURL
            resourceURL = url
            try await repository.recordAttempt(profileID: profileID, resource: resource, at: timestamp)
            try Task.checkCancellation()
            guard isRemoteHTTPURL(url) else { throw CoordinatorError.unsupportedRemoteURL }

            let downloaded = try await downloader.download(RemoteResourceRequest(
                url: url,
                resource: resource
            ))
            defer { try? FileManager.default.removeItem(at: downloaded.temporaryFileURL) }
            try Task.checkCancellation()

            switch resource {
            case .playlist:
                let data = try Data(contentsOf: downloaded.temporaryFileURL)
                let channels = try M3UParser().parse(
                    data: data,
                    sourceURL: url,
                    profileID: profileID
                )
                try Task.checkCancellation()
                try await repository.commitPlaylistRefresh(
                    profileID: profileID,
                    channels: channels,
                    fetchedAt: timestamp
                )
            case .epg:
                try Task.checkCancellation()
                _ = try await repository.commitEPGRefresh(
                    profileID: profileID,
                    fileURL: downloaded.temporaryFileURL,
                    fetchedAt: timestamp
                )
            }
            return PerformedRefresh(
                outcome: RefreshOutcome(resource: resource, succeeded: true, message: nil),
                didPersistTerminalStatus: true
            )
        } catch is CancellationError {
            let summary = "刷新已取消。"
            let persisted = await recordFailure(
                repository: repository,
                profileID: profileID,
                resource: resource,
                summary: summary,
                at: timestamp
            )
            return PerformedRefresh(
                outcome: RefreshOutcome(resource: resource, succeeded: false, message: summary),
                didPersistTerminalStatus: persisted
            )
        } catch RemoteDownloadError.cancelled {
            let summary = "刷新已取消。"
            let persisted = await recordFailure(
                repository: repository,
                profileID: profileID,
                resource: resource,
                summary: summary,
                at: timestamp
            )
            return PerformedRefresh(
                outcome: RefreshOutcome(resource: resource, succeeded: false, message: summary),
                didPersistTerminalStatus: persisted
            )
        } catch {
            let summary = sanitizedSummary(error: error, url: resourceURL)
            let persisted = await recordFailure(
                repository: repository,
                profileID: profileID,
                resource: resource,
                summary: summary,
                at: timestamp
            )
            return PerformedRefresh(
                outcome: RefreshOutcome(resource: resource, succeeded: false, message: summary),
                didPersistTerminalStatus: persisted
            )
        }
    }

    private nonisolated static func recordFailure(
        repository: any LibraryRepository,
        profileID: UUID,
        resource: RefreshResource,
        summary: String,
        at timestamp: Date
    ) async -> Bool {
        do {
            try await repository.recordFailure(
                profileID: profileID,
                resource: resource,
                summary: summary,
                at: timestamp
            )
            return true
        } catch {
            return false
        }
    }

    private nonisolated static func sanitizedSummary(error: any Error, url: URL?) -> String {
        let reason: String
        switch error {
        case RemoteDownloadError.invalidResponse:
            reason = "服务器返回了无效响应。"
        case let RemoteDownloadError.httpStatus(status):
            reason = "服务器返回 HTTP \(status)。"
        case let RemoteDownloadError.responseTooLarge(limit):
            reason = "下载内容超过大小限制（\(limit) 字节）。"
        case CoordinatorError.unsupportedRemoteURL:
            reason = "仅支持 HTTP 或 HTTPS 远程资源。"
        case LibraryRepositoryError.profileNotFound:
            reason = "找不到源配置。"
        case is M3UParserError, is PlaylistTextDecodingError:
            reason = "播放列表格式无效。"
        case is XMLTVParserError, LibraryRepositoryError.epgHasNoChannels:
            reason = "EPG 格式无效。"
        default:
            if let url, isNetworkError(error) {
                reason = NetworkFailureMapper.map(error, for: url).message
            } else {
                reason = "资源处理失败。"
            }
        }

        let summary: String
        if let url {
            summary = "刷新 \(RedactedURL.string(url)) 失败：\(reason)"
        } else {
            summary = "刷新失败：\(reason)"
        }
        return String(summary.prefix(240))
    }

    private nonisolated static func isNetworkError(_ error: any Error) -> Bool {
        let nsError = error as NSError
        if error is URLError
            || nsError.domain == NSURLErrorDomain
            || nsError.domain == NSPOSIXErrorDomain {
            return true
        }
        return nsError.userInfo[NSUnderlyingErrorKey] != nil
    }

    private nonisolated static func isRemoteHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.isEmpty else { return false }
        return scheme == "http" || scheme == "https"
    }

    private nonisolated static func order(_ resource: RefreshResource) -> Int {
        resource == .playlist ? 0 : 1
    }

    private nonisolated static func cancellationOutcome(
        resource: RefreshResource
    ) -> RefreshOutcome {
        RefreshOutcome(resource: resource, succeeded: false, message: "刷新已取消。")
    }
}
