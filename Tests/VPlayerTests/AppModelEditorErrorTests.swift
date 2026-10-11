// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayer
@testable import VPlayerCore

@MainActor
final class AppModelEditorErrorTests: XCTestCase {
    func testPersistedSaveSucceedsWhenAnotherReloadAppliesTheSameWriteFirst() async {
        for operation in Operation.allCases {
            let fixture = Fixture()
            await fixture.model.reload()
            await fixture.repository.gateNextChannelRead()
            var failures: [String] = []
            let save = Task { await fixture.save(operation) { failures.append($0) } }
            await fixture.repository.waitUntilChannelReadIsBlocked()
            let latestReload = await fixture.model.reload()
            XCTAssertTrue(latestReload)
            await fixture.repository.releaseChannelRead()
            let saved = await save.value
            XCTAssertTrue(saved, "通知触发的重读已应用同一次写入，不能误报保存失败")
            XCTAssertTrue(failures.isEmpty)
            XCTAssertNil(fixture.model.alertMessage)
        }
    }

    func testSupersedingReadFailureDoesNotTurnAnOlderSnapshotIntoSaveSuccess() async {
        let fixture = Fixture()
        await fixture.model.reload()
        await fixture.repository.gateNextChannelRead()
        var failures: [String] = []
        let save = Task { await fixture.save(.update) { failures.append($0) } }
        await fixture.repository.waitUntilChannelReadIsBlocked()
        await fixture.repository.setReadFailure(true)
        let latestReload = await fixture.model.reload(onError: { _ in })
        XCTAssertFalse(latestReload)
        await fixture.repository.releaseChannelRead()
        let saved = await save.value
        XCTAssertFalse(saved)
        XCTAssertTrue(failures.last?.contains("已保存") == true)
    }

    func testEditorWritesReportLocallyWithoutOverwritingAnUnrelatedAlert() async {
        for operation in Operation.allCases {
            let fixture = Fixture()
            await fixture.model.reload()
            await fixture.repository.setEditorWriteFailure(true)
            fixture.model.alertMessage = "其他操作的提示"
            var failures: [String] = []
            let succeeded = await fixture.save(operation) { failures.append($0) }
            XCTAssertFalse(succeeded)
            XCTAssertTrue(failures.last?.contains("editorWrite") == true)
            XCTAssertEqual(fixture.model.alertMessage, "其他操作的提示")

            await fixture.repository.setEditorWriteFailure(false)
            failures = []
            let retried = await fixture.save(operation) { failures.append($0) }
            XCTAssertTrue(retried)
            XCTAssertTrue(failures.isEmpty)
        }
    }

    func testCommittedEditorWritesAndNestedReloadFailuresStayLocalAndCanRetry() async {
        for operation in Operation.allCases {
            let fixture = Fixture()
            await fixture.model.reload()
            await fixture.repository.setReadFailure(true)
            var failures: [String] = []
            let succeeded = await fixture.save(operation) { failures.append($0) }
            XCTAssertFalse(succeeded)
            XCTAssertTrue(failures.first?.contains("读取资料库失败") == true)
            XCTAssertTrue(failures.last?.contains("已保存") == true)
            XCTAssertNil(fixture.model.alertMessage, "重读产生的中间错误也不能交给根视图弹窗")

            await fixture.repository.setReadFailure(false)
            failures = []
            let retried = await fixture.save(operation) { failures.append($0) }
            XCTAssertTrue(retried)
            XCTAssertTrue(failures.isEmpty)
            let snapshot = await fixture.repository.snapshot()
            XCTAssertEqual(snapshot.profileCreateCount, operation == .create ? 1 : 0,
                           "重试不能重复创建已持久化的播放列表")
        }
    }

    func testStaleMappingRejectionAndRecoveryReadFailureStayInTheEditor() async {
        let fixture = Fixture()
        await fixture.model.reload()
        fixture.model.channels = []
        await fixture.repository.setReadFailure(true)
        var failures: [String] = []
        let succeeded = await fixture.save(.mapping) { failures.append($0) }
        XCTAssertFalse(succeeded)
        XCTAssertTrue(failures.last?.contains("频道列表已更改") == true)
        XCTAssertNil(fixture.model.alertMessage)
    }

    func testEditorHandlerDoesNotCaptureIndependentOperationsOrLaterErrors() async {
        let fixture = Fixture()
        await fixture.model.reload()
        await fixture.repository.gateNextCreate()
        var localFailures: [String] = []
        let pending = Task { await fixture.save(.create) { localFailures.append($0) } }
        await fixture.repository.waitUntilCreateIsBlocked()
        await fixture.repository.setReadFailure(true)
        await fixture.model.reload()
        XCTAssertTrue(fixture.model.alertMessage?.contains("读取资料库失败") == true)
        XCTAssertTrue(localFailures.isEmpty)
        fixture.model.dismissAlert()
        await fixture.repository.releaseCreate()
        let succeeded = await pending.value
        XCTAssertFalse(succeeded)
        XCTAssertTrue(localFailures.last?.contains("已保存") == true)
        XCTAssertNil(fixture.model.alertMessage)
        await fixture.model.reload()
        XCTAssertNotNil(fixture.model.alertMessage, "局部回调不能改变后续操作的默认错误呈现")
    }

    private enum Operation: CaseIterable { case create, update, mapping }

    @MainActor
    private struct Fixture {
        let repository: RepositorySpy
        let model: AppModel
        let profile: SourceProfile
        let channel: Channel
        let attemptID = UUID()
        let input = SourceProfileInput(name: "保存测试",
            m3uURLString: "https://example.test/list.m3u",
            epgURLString: "https://example.test/guide.xml",
            m3uRefreshInterval: .manual, epgRefreshInterval: .manual)

        init() {
            let date = Date(timeIntervalSince1970: 2_000_000_000)
            profile = SourceProfile(id: UUID(), name: "原始名称",
                m3uURL: URL(string: "https://example.test/list.m3u")!,
                epgURL: URL(string: "https://example.test/guide.xml")!,
                m3uRefreshInterval: .manual, epgRefreshInterval: .manual,
                m3uStatus: ResourceRefreshStatus(), epgStatus: ResourceRefreshStatus(),
                createdAt: date, updatedAt: date)
            channel = Channel(sourceProfileID: profile.id, displayName: "新闻",
                streamURL: URL(string: "https://example.test/live")!, tvgID: "news",
                tvgName: nil, logoURL: nil, groupTitle: nil, attributes: [:], order: 0)
            repository = RepositorySpy(profiles: [profile], activeProfileID: profile.id,
                channels: [profile.id: [channel]],
                epgChannels: [profile.id: [EPGChannel(id: "news", displayNames: ["新闻"], iconURL: nil)]])
            model = AppModel(repository: repository, refresh: { _, _, _ in [] }, now: { date })
        }

        func save(_ operation: Operation, onError: @escaping AppModel.OperationErrorHandler) async -> Bool {
            switch operation {
            case .create: await model.create(input: input, attemptID: attemptID, onError: onError)
            case .update: await model.update(profileID: profile.id, input: input, onError: onError)
            case .mapping: await model.saveMapping(channel: channel, xmltvChannelID: "news", onError: onError)
            }
        }
    }
}
