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
    public let attemptID: UUID?

    public init(
        resource: RefreshResource,
        succeeded: Bool,
        message: String?,
        attemptID: UUID? = nil
    ) {
        self.resource = resource
        self.succeeded = succeeded
        self.message = message
        self.attemptID = attemptID
    }
}

public actor RefreshCoordinator {
    public typealias PersistedOutcomeHandler = @Sendable (UUID, RefreshOutcome) async -> Void
    public typealias RefreshStartedHandler = @Sendable (UUID, RefreshResource) async -> Void

    struct WaiterRegistration: Equatable, Sendable {
        let profileID: UUID
        let resource: RefreshResource
        let flightID: UUID
        let waiterCount: Int
    }

    typealias WaiterRegistrationObserver = @Sendable (WaiterRegistration) -> Void

    private struct RefreshKey: Hashable, Sendable {
        let profileID: UUID
        let resource: RefreshResource
        let source: SourceURLIdentity
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
        & ConditionalRefreshStatusWriting
    private let downloader: any RemoteResourceDownloading
    private let now: @Sendable () -> Date
    private let onPersistedOutcome: PersistedOutcomeHandler?
    private let onRefreshStarted: RefreshStartedHandler?
    private let waiterRegistrationObserver: WaiterRegistrationObserver?
    private var inFlight: [RefreshKey: InFlight] = [:]

    public init(
        repository: any LibraryRepository & RefreshSnapshotCommitting
            & ConditionalRefreshStatusWriting,
        downloader: any RemoteResourceDownloading,
        now: @escaping @Sendable () -> Date = Date.init,
        onPersistedOutcome: PersistedOutcomeHandler? = nil,
        onRefreshStarted: RefreshStartedHandler? = nil
    ) {
        self.repository = repository
        self.downloader = downloader
        self.now = now
        self.onPersistedOutcome = onPersistedOutcome
        self.onRefreshStarted = onRefreshStarted
        waiterRegistrationObserver = nil
    }

    init(
        repository: any LibraryRepository & RefreshSnapshotCommitting
            & ConditionalRefreshStatusWriting,
        downloader: any RemoteResourceDownloading,
        now: @escaping @Sendable () -> Date = Date.init,
        onPersistedOutcome: PersistedOutcomeHandler? = nil,
        onRefreshStarted: RefreshStartedHandler? = nil,
        waiterRegistrationObserver: @escaping WaiterRegistrationObserver
    ) {
        self.repository = repository
        self.downloader = downloader
        self.now = now
        self.onPersistedOutcome = onPersistedOutcome
        self.onRefreshStarted = onRefreshStarted
        self.waiterRegistrationObserver = waiterRegistrationObserver
    }

    public func refresh(
        profileID: UUID,
        resources: Set<RefreshResource>,
        trigger: RefreshTrigger
    ) async -> [RefreshOutcome] {
        return await withTaskGroup(of: RefreshOutcome.self) { group in
            for resource in resources {
                group.addTask {
                    await self.refreshOne(
                        profileID: profileID,
                        resource: resource,
                        trigger: trigger
                    )
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
        resource: RefreshResource,
        trigger: RefreshTrigger
    ) async -> RefreshOutcome {
        if Task.isCancelled {
            return Self.cancellationOutcome(resource: resource)
        }

        let sourceURL: URL
        do {
            try Task.checkCancellation()
            guard let profile = try await repository.profiles().first(where: {
                $0.id == profileID
            }) else {
                throw LibraryRepositoryError.profileNotFound
            }
            sourceURL = profile.sourceURL(for: resource)
        } catch is CancellationError {
            return Self.cancellationOutcome(resource: resource)
        } catch {
            return RefreshOutcome(
                resource: resource,
                succeeded: false,
                message: Self.sanitizedSummary(error: error, resource: resource, url: nil),
                attemptID: nil
            )
        }
        let source = SourceURLIdentity(url: sourceURL)
        let key = RefreshKey(profileID: profileID, resource: resource, source: source)
        if let existing = inFlight[key], existing.isDraining {
            let shouldRetry = await waitForDrain(key: key, flightID: existing.id)
            guard shouldRetry else {
                return Self.cancellationOutcome(resource: resource, attemptID: existing.id)
            }
            return await refreshOne(
                profileID: profileID,
                resource: resource,
                trigger: trigger
            )
        }

        let flightID: UUID
        if let existing = inFlight[key] {
            flightID = existing.id
        } else {
            let repository = repository
            let downloader = downloader
            let onPersistedOutcome = onPersistedOutcome
            let onRefreshStarted = onRefreshStarted
            let timestamp = now()
            let id = UUID()
            let context = RefreshSourceContext(source: source, attemptID: id)
            let task = Task {
                let performed = await Self.performRefresh(
                    repository: repository,
                    downloader: downloader,
                    profileID: profileID,
                    resource: resource,
                    sourceURL: sourceURL,
                    context: context,
                    timestamp: timestamp,
                    trigger: trigger,
                    onRefreshStarted: onRefreshStarted
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
                    continuation.resume(returning: Self.cancellationOutcome(
                        resource: resource,
                        attemptID: flightID
                    ))
                    return
                }
                if Task.isCancelled {
                    if flight.waiters.isEmpty {
                        flight.isDraining = true
                        flight.task.cancel()
                    }
                    inFlight[key] = flight
                    continuation.resume(returning: Self.cancellationOutcome(
                        resource: resource,
                        attemptID: flightID
                    ))
                    return
                }
                flight.waiters[waiterID] = continuation
                inFlight[key] = flight
                waiterRegistrationObserver?(WaiterRegistration(
                    profileID: profileID,
                    resource: resource,
                    flightID: flightID,
                    waiterCount: flight.waiters.count
                ))
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
        waiter.resume(returning: Self.cancellationOutcome(
            resource: resource,
            attemptID: flightID
        ))
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
        repository: any LibraryRepository & RefreshSnapshotCommitting
            & ConditionalRefreshStatusWriting,
        downloader: any RemoteResourceDownloading,
        profileID: UUID,
        resource: RefreshResource,
        sourceURL: URL,
        context: RefreshSourceContext,
        timestamp: Date,
        trigger: RefreshTrigger,
        onRefreshStarted: RefreshStartedHandler?
    ) async -> PerformedRefresh {
        do {
            try Task.checkCancellation()
            let began = try await repository.beginRefresh(
                profileID: profileID,
                resource: resource,
                context: context,
                at: timestamp
            )
            guard began else {
                return PerformedRefresh(
                    outcome: RefreshOutcome(
                        resource: resource,
                        succeeded: false,
                        message: sanitizedSummary(
                            error: LibraryRepositoryError.sourceConfigurationChanged,
                            resource: resource,
                            url: nil
                        ),
                        attemptID: context.attemptID
                    ),
                    didPersistTerminalStatus: false
                )
            }
            if case .manual = trigger {
                // Manual refreshes already update AppModel synchronously.
            } else if let onRefreshStarted {
                await onRefreshStarted(profileID, resource)
            }
            try Task.checkCancellation()
            guard isRemoteHTTPURL(sourceURL) else { throw CoordinatorError.unsupportedRemoteURL }

            let downloaded = try await downloader.download(RemoteResourceRequest(
                url: sourceURL,
                resource: resource
            ))
            defer { try? FileManager.default.removeItem(at: downloaded.temporaryFileURL) }
            try Task.checkCancellation()

            switch resource {
            case .playlist:
                let data = try Data(contentsOf: downloaded.temporaryFileURL)
                let channels = try M3UParser().parse(
                    data: data,
                    sourceURL: sourceURL,
                    profileID: profileID
                )
                try Task.checkCancellation()
                try await repository.commitPlaylistRefresh(
                    profileID: profileID,
                    channels: channels,
                    fetchedAt: timestamp,
                    context: context
                )
            case .epg:
                try Task.checkCancellation()
                _ = try await repository.commitEPGRefresh(
                    profileID: profileID,
                    fileURL: downloaded.temporaryFileURL,
                    fetchedAt: timestamp,
                    context: context
                )
            }
            return PerformedRefresh(
                outcome: RefreshOutcome(
                    resource: resource,
                    succeeded: true,
                    message: nil,
                    attemptID: context.attemptID
                ),
                didPersistTerminalStatus: true
            )
        } catch is CancellationError {
            let summary = "刷新已取消。"
            let persisted = await recordFailure(
                repository: repository,
                profileID: profileID,
                resource: resource,
                summary: summary,
                at: timestamp,
                context: context
            )
            return PerformedRefresh(
                outcome: RefreshOutcome(
                    resource: resource,
                    succeeded: false,
                    message: summary,
                    attemptID: context.attemptID
                ),
                didPersistTerminalStatus: persisted
            )
        } catch RemoteDownloadError.cancelled {
            let summary = "刷新已取消。"
            let persisted = await recordFailure(
                repository: repository,
                profileID: profileID,
                resource: resource,
                summary: summary,
                at: timestamp,
                context: context
            )
            return PerformedRefresh(
                outcome: RefreshOutcome(
                    resource: resource,
                    succeeded: false,
                    message: summary,
                    attemptID: context.attemptID
                ),
                didPersistTerminalStatus: persisted
            )
        } catch {
            let summary = sanitizedSummary(
                error: error,
                resource: resource,
                url: sourceURL
            )
            let persisted = await recordFailure(
                repository: repository,
                profileID: profileID,
                resource: resource,
                summary: summary,
                at: timestamp,
                context: context
            )
            return PerformedRefresh(
                outcome: RefreshOutcome(
                    resource: resource,
                    succeeded: false,
                    message: summary,
                    attemptID: context.attemptID
                ),
                didPersistTerminalStatus: persisted
            )
        }
    }

    private nonisolated static func recordFailure(
        repository: any ConditionalRefreshStatusWriting,
        profileID: UUID,
        resource: RefreshResource,
        summary: String,
        at timestamp: Date,
        context: RefreshSourceContext
    ) async -> Bool {
        do {
            return try await repository.recordRefreshFailure(
                profileID: profileID,
                resource: resource,
                context: context,
                summary: summary,
                at: timestamp
            )
        } catch {
            return false
        }
    }

    private nonisolated static func sanitizedSummary(
        error: any Error,
        resource: RefreshResource,
        url: URL?
    ) -> String {
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
        case LibraryRepositoryError.sourceConfigurationChanged:
            reason = "源配置已更改。"
        case M3UParserError.missingHeader:
            reason = "M3U 内容缺少 #EXTM3U 标头。"
        case M3UParserError.noChannels:
            reason = "M3U 内容中没有可用频道。"
        case PlaylistTextDecodingError.unsupportedEncoding:
            reason = "M3U 文本编码不受支持。"
        case XMLTVParserError.malformed:
            reason = "EPG 的 XML 结构无效。"
        case let XMLTVParserError.parserFailure(line, column, diagnostic):
            return String("刷新 EPG 失败：XML 第 \(line) 行、第 \(column) 列解析失败。\n\(diagnostic.summary)".prefix(240))
        case XMLTVParserError.entityDeclarationForbidden:
            reason = "EPG 包含禁止的 XML 实体声明。"
        case XMLTVParserError.excessiveDepth:
            reason = "EPG 的 XML 嵌套层级超过限制。"
        case XMLTVParserError.excessiveText:
            reason = "EPG 的文本长度超过限制。"
        case XMLTVParserError.excessiveChannels:
            reason = "EPG 的频道数量超过限制。"
        case XMLTVParserError.excessiveProgrammes:
            reason = "EPG 的节目数量超过限制。"
        case XMLTVParserError.excessiveEvents:
            reason = "EPG 的 XML 事件数量超过限制。"
        case XMLTVParserError.invalidProgramme:
            reason = "EPG 包含无效节目数据。"
        case LibraryRepositoryError.epgHasNoChannels:
            reason = "EPG 中没有频道数据。"
        case LibraryRepositoryError.invalidChannelProfile:
            reason = "频道所属的源配置与本次刷新不一致。"
        case LibraryRepositoryError.duplicatePlaylistChannel:
            reason = "频道列表包含重复频道。"
        case LibraryRepositoryError.corruptPersistedValue:
            reason = "资料库中的持久化数据损坏。"
        case let LibraryRepositoryError.corruptPersistedField(field):
            reason = "资料库的 \(field) 字段无效。"
        case let LibraryRepositoryError.persistedValueDecodingFailed(field, diagnostic):
            let resourceName = resource == .playlist ? "频道列表" : "EPG"
            return String("刷新\(resourceName)失败：资料库的 \(field) 数据解码失败。\n\(diagnostic.summary)".prefix(240))
        case EPGPersistenceSinkError.duplicateChannelID:
            reason = "EPG 包含重复频道标识。"
        default:
            if let url, NetworkFailureMapper.isNetworkError(error) {
                let resourceName = resource == .playlist ? "频道列表" : "EPG"
                return String("刷新\(resourceName)失败：\(NetworkFailureMapper.map(error, for: url).message)".prefix(240))
            } else {
                reason = "资源处理发生未识别错误。"
            }
        }

        let resourceName = resource == .playlist ? "频道列表" : "EPG"
        let summary = "刷新\(resourceName)失败：\(reason)\n\(ErrorDiagnosticSnapshot(error).summary)"
        return String(summary.prefix(240))
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
        resource: RefreshResource,
        attemptID: UUID? = nil
    ) -> RefreshOutcome {
        RefreshOutcome(
            resource: resource,
            succeeded: false,
            message: "刷新已取消。",
            attemptID: attemptID
        )
    }
}
