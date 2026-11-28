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
        let resource: RefreshResource
        let source: SourceURLIdentity
    }

    private struct Waiter {
        let profileID: UUID
        let continuation: CheckedContinuation<RefreshOutcome, Never>
    }

    private struct InFlight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: Waiter]
        var drainWaiters: [UUID: CheckedContinuation<Bool, Never>]
        var isDraining: Bool
    }

    private enum CoordinatorError: Error, Sendable {
        case unsupportedRemoteURL
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
        let profiles: [SourceProfile]
        do {
            try Task.checkCancellation()
            profiles = try await repository.profiles()
            guard let profile = profiles.first(where: {
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
        let key = RefreshKey(resource: resource, source: source)
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
        let joinedExistingFlight = inFlight[key] != nil
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
                let outcomes = await Self.performRefresh(
                    repository: repository,
                    downloader: downloader,
                    profiles: profiles,
                    initiatingProfileID: profileID,
                    resource: resource,
                    sourceURL: sourceURL,
                    context: context,
                    timestamp: timestamp,
                    trigger: trigger,
                    onRefreshStarted: onRefreshStarted,
                    onPersistedOutcome: onPersistedOutcome
                )
                self.completeFlight(key: key, id: id, outcomes: outcomes)
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
        let outcome = await withTaskCancellationHandler {
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
                flight.waiters[waiterID] = Waiter(profileID: profileID, continuation: continuation)
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
        // URL 改回原值并不恢复旧 attempt 的提交资格。加入者需核对持久化
        // attempt；配置已换代时等旧下载退场，再登记一次独立的刷新。
        if joinedExistingFlight, !Task.isCancelled,
           let current = try? await repository.profiles().first(where: { $0.id == profileID }),
           SourceURLIdentity(url: current.sourceURL(for: resource)) == source {
            let status = resource == .playlist ? current.m3uStatus : current.epgStatus
            if status.attemptID != flightID {
                return await refreshOne(profileID: profileID, resource: resource, trigger: trigger)
            }
        }
        return outcome
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
        waiter.continuation.resume(returning: Self.cancellationOutcome(
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
        outcomes: [UUID: RefreshOutcome]
    ) {
        guard let flight = inFlight[key], flight.id == id else { return }
        inFlight[key] = nil
        for waiter in flight.waiters.values {
            waiter.continuation.resume(returning: outcomes[waiter.profileID] ?? Self.failureOutcome(
                error: LibraryRepositoryError.sourceConfigurationChanged,
                resource: key.resource,
                sourceURL: nil,
                attemptID: id
            ))
        }
        for waiter in flight.drainWaiters.values {
            waiter.resume(returning: true)
        }
    }

    private nonisolated static func performRefresh(
        repository: any LibraryRepository & RefreshSnapshotCommitting
            & ConditionalRefreshStatusWriting,
        downloader: any RemoteResourceDownloading,
        profiles: [SourceProfile],
        initiatingProfileID: UUID,
        resource: RefreshResource,
        sourceURL: URL,
        context: RefreshSourceContext,
        timestamp: Date,
        trigger: RefreshTrigger,
        onRefreshStarted: RefreshStartedHandler?,
        onPersistedOutcome: PersistedOutcomeHandler?
    ) async -> [UUID: RefreshOutcome] {
        var begun: [UUID] = []
        var outcomes: [UUID: RefreshOutcome] = [:]
        do {
            // 同一 URL 的资料共用下载；快照、频道身份和事务仍归各自的源配置。
            for profile in profiles where SourceURLIdentity(url: profile.sourceURL(for: resource)) == context.source {
                try Task.checkCancellation()
                do {
                    guard try await repository.beginRefresh(
                        profileID: profile.id, resource: resource, context: context, at: timestamp
                    ) else { throw LibraryRepositoryError.sourceConfigurationChanged }
                    begun.append(profile.id)
                    // 手动调用者已即时更新界面；其他关联配置也需要收到开始通知。
                    if profile.id != initiatingProfileID || trigger != .manual {
                        await onRefreshStarted?(profile.id, resource)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    outcomes[profile.id] = failureOutcome(
                        error: error, resource: resource, sourceURL: sourceURL, attemptID: context.attemptID
                    )
                }
            }
            guard !begun.isEmpty else { return outcomes }
            try Task.checkCancellation()
            guard isRemoteHTTPURL(sourceURL) else { throw CoordinatorError.unsupportedRemoteURL }
            let downloaded = try await downloader.download(RemoteResourceRequest(url: sourceURL, resource: resource))
            defer { try? FileManager.default.removeItem(at: downloaded.temporaryFileURL) }
            try Task.checkCancellation()

            let parsedChannels: [Channel]?
            switch resource {
            case .playlist:
                guard isRemoteHTTPURL(downloaded.responseURL) else { throw CoordinatorError.unsupportedRemoteURL }
                parsedChannels = try M3UParser().parse(
                    data: Data(contentsOf: downloaded.temporaryFileURL),
                    sourceURL: downloaded.responseURL,
                    profileID: initiatingProfileID
                )
            case .epg:
                parsedChannels = nil
            }

            var pending = begun
            while !pending.isEmpty {
                for profileID in pending {
                    try Task.checkCancellation()
                    do {
                        switch resource {
                        case .playlist:
                            let baseChannels = parsedChannels ?? []
                            let channels: [Channel]
                            if profileID == initiatingProfileID {
                                channels = baseChannels
                            } else {
                                channels = baseChannels.map { channel in
                                    Channel(
                                        sourceProfileID: profileID, displayName: channel.displayName,
                                        streamURL: channel.streamURL, tvgID: channel.tvgID, tvgName: channel.tvgName,
                                        logoURL: channel.logoURL, groupTitle: channel.groupTitle,
                                        attributes: channel.attributes, order: channel.order
                                    )
                                }
                            }
                            try await repository.commitPlaylistRefresh(
                                profileID: profileID, channels: channels, fetchedAt: timestamp, context: context
                            )
                        case .epg:
                            _ = try await repository.commitEPGRefresh(
                                profileID: profileID, fileURL: downloaded.temporaryFileURL,
                                fetchedAt: timestamp, context: context
                            )
                        }
                        let outcome = RefreshOutcome(
                            resource: resource, succeeded: true, message: nil, attemptID: context.attemptID
                        )
                        outcomes[profileID] = outcome
                        await onPersistedOutcome?(profileID, outcome)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        let outcome = failureOutcome(
                            error: error, resource: resource, sourceURL: sourceURL, attemptID: context.attemptID
                        )
                        outcomes[profileID] = outcome
                        if await recordFailure(repository: repository, profileID: profileID, resource: resource,
                            summary: outcome.message ?? "刷新失败。", at: timestamp, context: context) {
                            await onPersistedOutcome?(profileID, outcome)
                        }
                    }
                }
                pending = []
                // 下载或写回期间新增的同 URL 配置也获得结果。提交时仍校验 URL 和
                // attemptID，旧响应不能覆盖已更改的配置。
                let currentProfiles = try await repository.profiles()
                let knownIDs = Set(begun).union(outcomes.keys)
                for profile in currentProfiles where !knownIDs.contains(profile.id)
                    && SourceURLIdentity(url: profile.sourceURL(for: resource)) == context.source {
                    try Task.checkCancellation()
                    do {
                        guard try await repository.beginRefresh(
                            profileID: profile.id, resource: resource, context: context, at: timestamp
                        ) else { throw LibraryRepositoryError.sourceConfigurationChanged }
                        begun.append(profile.id)
                        pending.append(profile.id)
                        await onRefreshStarted?(profile.id, resource)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        outcomes[profile.id] = failureOutcome(
                            error: error, resource: resource, sourceURL: sourceURL, attemptID: context.attemptID
                        )
                    }
                }
            }
        } catch {
            let outcome = failureOutcome(
                error: error, resource: resource, sourceURL: sourceURL, attemptID: context.attemptID
            )
            // 已提交的配置保留其成功状态；其余配置共享下载/解析失败或取消结果。
            for profileID in begun where outcomes[profileID] == nil {
                outcomes[profileID] = outcome
                if await recordFailure(repository: repository, profileID: profileID, resource: resource,
                    summary: outcome.message ?? "刷新失败。", at: timestamp, context: context) {
                    await onPersistedOutcome?(profileID, outcome)
                }
            }
            if outcomes[initiatingProfileID] == nil { outcomes[initiatingProfileID] = outcome }
        }
        return outcomes
    }

    private nonisolated static func failureOutcome(
        error: any Error,
        resource: RefreshResource,
        sourceURL: URL?,
        attemptID: UUID
    ) -> RefreshOutcome {
        if error is CancellationError || (error as? RemoteDownloadError) == .cancelled {
            return cancellationOutcome(resource: resource, attemptID: attemptID)
        }
        return RefreshOutcome(
            resource: resource, succeeded: false,
            message: sanitizedSummary(error: error, resource: resource, url: sourceURL), attemptID: attemptID
        )
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
        let resourceName = resource == .playlist ? "频道列表" : "EPG"
        let reason: String
        switch error {
        case RemoteDownloadError.invalidResponse:
            reason = "服务器返回了无法识别的响应，请检查地址是否正确。"
        case let RemoteDownloadError.httpStatus(status):
            switch status {
            case 401, 403:
                reason = "服务器拒绝访问（HTTP \(status)），链接可能已失效或需要鉴权。"
            case 404, 410:
                reason = "找不到目标文件（HTTP \(status)），请检查地址是否正确。"
            case 429:
                reason = "请求过于频繁（HTTP 429），请稍后再试。"
            case 500...599:
                reason = "服务器暂时异常（HTTP \(status)），请稍后重试。"
            default:
                reason = "服务器返回异常状态（HTTP \(status)）。"
            }
        case let RemoteDownloadError.responseTooLarge(limit):
            let megabytes = String(format: "%.0f MB", Double(limit) / 1_048_576.0)
            reason = "下载文件体积超过上限（\(megabytes)）。"
        case CoordinatorError.unsupportedRemoteURL:
            reason = "仅支持 HTTP 或 HTTPS 地址。"
        case LibraryRepositoryError.profileNotFound:
            reason = "未找到对应的播放列表配置。"
        case LibraryRepositoryError.sourceConfigurationChanged:
            reason = "播放列表配置刚刚已修改，本次刷新已中止。"
        case M3UParserError.missingHeader:
            reason = "返回的内容不是有效的 M3U 播放列表（缺少 #EXTM3U 标头）。"
        case M3UParserError.noChannels:
            reason = "播放列表中没有解析到任何可用频道。"
        case PlaylistTextDecodingError.unsupportedEncoding:
            reason = "播放列表文件编码不受支持，请确认使用 UTF-8 编码。"
        case XMLTVParserError.malformed:
            reason = "EPG 文件的 XML 格式损坏，无法解析。"
        case let XMLTVParserError.parserFailure(line, column, diagnostic):
            return String("刷新 EPG 失败：XML 第 \(line) 行第 \(column) 列语法错误。\(NetworkFailure.diagnosticSeparator)\(diagnostic.summary)".prefix(240))
        case XMLTVParserError.entityDeclarationForbidden:
            reason = "EPG 文件包含不安全的 XML 实体声明，已拒绝导入。"
        case XMLTVParserError.excessiveDepth:
            reason = "EPG 文件的 XML 嵌套层级过深，超出安全限制。"
        case XMLTVParserError.excessiveText:
            reason = "EPG 文件单段文本过长，超出安全限制。"
        case XMLTVParserError.excessiveChannels:
            reason = "EPG 包含的频道数量超出上限。"
        case XMLTVParserError.excessiveProgrammes:
            reason = "EPG 包含的节目数量超出上限。"
        case XMLTVParserError.excessiveEvents:
            reason = "EPG 文件内容过于庞大，超出解析上限。"
        case XMLTVParserError.invalidProgramme:
            reason = "EPG 中包含格式异常的节目条目。"
        case LibraryRepositoryError.epgHasNoChannels:
            reason = "EPG 文件中未包含任何频道信息。"
        case LibraryRepositoryError.invalidChannelProfile:
            reason = "频道归属与当前播放列表不一致。"
        case LibraryRepositoryError.duplicatePlaylistChannel:
            reason = "频道列表中存在重复频道。"
        case LibraryRepositoryError.corruptPersistedValue:
            reason = "本地资料库数据异常，请重试或重新添加源。"
        case let LibraryRepositoryError.corruptPersistedField(field):
            reason = "本地资料库字段异常（\(field)）。"
        case let LibraryRepositoryError.persistedValueDecodingFailed(field, diagnostic):
            return String("刷新\(resourceName)失败：本地资料库数据读取异常（\(field)）。\(NetworkFailure.diagnosticSeparator)\(diagnostic.summary)".prefix(240))
        case EPGPersistenceSinkError.duplicateChannelID:
            reason = "EPG 文件中存在重复的频道 ID，无法导入。"
        default:
            if let url, NetworkFailureMapper.isNetworkError(error) {
                return String("刷新\(resourceName)失败：\(NetworkFailureMapper.map(error, for: url).message)".prefix(240))
            } else {
                reason = "处理内容时发生未识别错误，请重试。"
            }
        }

        let summary = "刷新\(resourceName)失败：\(reason)\(NetworkFailure.diagnosticSeparator)\(ErrorDiagnosticSnapshot(error).summary)"
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
