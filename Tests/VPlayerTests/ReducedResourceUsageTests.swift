// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Observation
import SwiftUI
import UIKit
import XCTest
@testable import VPlayer

@MainActor
final class ReducedResourceUsageTests: XCTestCase {
    func testLogoPreferenceRecoveryWaitsForANormalVisibilityLoadOpportunity() async throws {
        let state = LogoViewTestState(prefersReducedResourceUsage: true)
        let loader = LogoViewLoaderProbe()
        let window = try mountLogo(state: state, loader: loader)
        defer { window.isHidden = true }
        await waitForLogoRendering { loader.observedPreferences == [true] }
        XCTAssertEqual(loader.loadAdmissions, [])

        state.prefersReducedResourceUsage = false
        await waitForLogoRendering { loader.observedPreferences == [true, false] }
        XCTAssertEqual(loader.loadAdmissions, [], "The signal itself must not start disk/network/decode work")

        state.isVisible = false
        await waitForLogoRendering { loader.observedVisibility.last == false }
        state.isVisible = true
        await waitForLogoRendering { loader.loadAdmissions == [state.url] }
        XCTAssertEqual(loader.physicalLoadCount, 1)
    }

    func testLogoResourceReductionDoesNotRestartOrCancelAnAdmittedSharedLoad() async throws {
        let state = LogoViewTestState(prefersReducedResourceUsage: false)
        let loader = LogoViewLoaderProbe()
        loader.holdsSharedLoad = true
        let window = try mountLogo(state: state, loader: loader)
        defer { window.isHidden = true; loader.completeSharedLoad() }
        await waitForLogoRendering { loader.physicalLoadCount == 1 }

        state.prefersReducedResourceUsage = true
        await waitForLogoRendering { loader.observedPreferences == [false, true] }
        XCTAssertEqual(loader.loadAdmissions, [state.url])
        XCTAssertEqual(loader.completedSharedLoadCount, 0)
        loader.completeSharedLoad()
        await waitForLogoRendering { loader.completedConsumerCancellationStates.count == 1 }

        XCTAssertEqual(loader.completedSharedLoadCount, 1)
        XCTAssertEqual(loader.completedConsumerCancellationStates, [false])
        XCTAssertTrue(loader.memoryImages[state.url] === loader.decodedImage)
        state.prefersReducedResourceUsage = false
        await waitForLogoRendering { loader.observedPreferences == [false, true, false] }
        XCTAssertEqual(loader.loadAdmissions, [state.url])
        XCTAssertEqual(loader.physicalLoadCount, 1)
    }

    func testMemoryCachedLogoNeedsNoOptionalLoadAcrossPreferenceChangesOrRemount() async throws {
        let state = LogoViewTestState(prefersReducedResourceUsage: true)
        let loader = LogoViewLoaderProbe()
        loader.memoryImages[state.url] = loader.decodedImage
        let window = try mountLogo(state: state, loader: loader)
        defer { window.isHidden = true }
        await waitForLogoRendering { loader.observedPreferences == [true] }
        XCTAssertGreaterThan(loader.memoryCacheHitCount, 0)

        state.prefersReducedResourceUsage = false
        await waitForLogoRendering { loader.observedPreferences == [true, false] }
        state.isVisible = false
        await waitForLogoRendering { loader.observedVisibility.last == false }
        state.isVisible = true
        await waitForLogoRendering { loader.observedVisibility.last == true }

        XCTAssertEqual(loader.loadAdmissions, [])
        XCTAssertEqual(loader.physicalLoadCount, 0)
        XCTAssertTrue(loader.memoryImages[state.url] === loader.decodedImage)
    }

    private func mountLogo(state: LogoViewTestState, loader: LogoViewLoaderProbe) throws -> UIWindow {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: LogoViewHarness(state: state, loader: loader))
        window.makeKeyAndVisible()
        window.rootViewController?.view.layoutIfNeeded()
        return window
    }

    private func waitForLogoRendering(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if condition() {
                // Allow SwiftUI's lifecycle task queued by this render to run as well.
                try? await Task.sleep(for: .milliseconds(50))
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Logo render condition was not met", file: file, line: line)
    }

    func testReducedResourcePreferenceDefersAutomaticProfileLoads() async {
        let probe = ReducedResourceRefreshProbe()
        let driver = ForegroundRefreshDriver(
            loadProfiles: { await probe.loaded(); return [] },
            refresh: { _, _, _ in [] },
            sleep: { await probe.slept(); try await Task.sleep(for: .seconds(3_600)) },
            reportStatus: { _ in }
        )
        driver.setPrefersReducedResourceUsage(true)
        driver.initialLibraryLoadDidComplete()
        driver.activate()
        for _ in 0..<1_000 {
            if await probe.sleepCount > 0 { break }
            await Task.yield()
        }
        let loads = await probe.loadCount
        let sleeps = await probe.sleepCount
        XCTAssertEqual(loads, 0)
        XCTAssertEqual(sleeps, 1)
        driver.deactivate()
    }

    func testPreferenceChangeDoesNotStartAnImmediateRefresh() async {
        let probe = ReducedResourceRefreshProbe()
        let driver = ForegroundRefreshDriver(
            loadProfiles: { await probe.loaded(); return [] },
            refresh: { _, _, _ in [] },
            sleep: { await probe.slept(); try await Task.sleep(for: .seconds(3_600)) },
            reportStatus: { _ in }
        )
        driver.setPrefersReducedResourceUsage(true)
        driver.initialLibraryLoadDidComplete()
        driver.activate()
        for _ in 0..<1_000 {
            if await probe.sleepCount > 0 { break }
            await Task.yield()
        }
        driver.setPrefersReducedResourceUsage(false)
        for _ in 0..<100 { await Task.yield() }
        let loads = await probe.loadCount
        XCTAssertEqual(loads, 0, "Preference changes must not trigger expensive work")
        driver.deactivate()
    }
}

private actor ReducedResourceRefreshProbe {
    private(set) var loadCount = 0
    private(set) var sleepCount = 0
    func loaded() { loadCount += 1 }
    func slept() { sleepCount += 1 }
}

@MainActor
@Observable
private final class LogoViewTestState {
    let url = URL(string: "https://example.com/logo.png")!
    var prefersReducedResourceUsage: Bool
    var isVisible = true

    init(prefersReducedResourceUsage: Bool) {
        self.prefersReducedResourceUsage = prefersReducedResourceUsage
    }
}

@MainActor
private struct LogoViewHarness: View {
    let state: LogoViewTestState
    let loader: LogoViewLoaderProbe

    var body: some View {
        ZStack {
            if state.isVisible {
                CachedChannelLogo(
                    url: state.url,
                    prefersReducedResourceUsage: state.prefersReducedResourceUsage,
                    imagePadding: 20,
                    placeholderVerticalPadding: 34,
                    memoryCachedImage: { loader.memoryCachedImage(for: $0) },
                    loadImage: { await loader.loadImage(for: $0) }
                )
            }
        }
        .onChange(of: state.prefersReducedResourceUsage, initial: true) { _, value in
            loader.observedPreferences.append(value)
        }
        .onChange(of: state.isVisible, initial: true) { _, value in
            loader.observedVisibility.append(value)
        }
    }
}

@MainActor
private final class LogoViewLoaderProbe {
    let decodedImage = UIImage(systemName: "tv")!
    var memoryImages: [URL: UIImage] = [:]
    var observedPreferences: [Bool] = []
    var observedVisibility: [Bool] = []
    var holdsSharedLoad = false
    private(set) var memoryCacheHitCount = 0
    private(set) var loadAdmissions: [URL] = []
    private(set) var physicalLoadCount = 0
    private(set) var completedSharedLoadCount = 0
    private(set) var completedConsumerCancellationStates: [Bool] = []
    private var sharedLoad: Task<UIImage, Never>?
    private var sharedContinuation: CheckedContinuation<Void, Never>?

    func memoryCachedImage(for url: URL) -> UIImage? {
        if memoryImages[url] != nil { memoryCacheHitCount += 1 }
        return memoryImages[url]
    }

    func loadImage(for url: URL) async -> UIImage? {
        loadAdmissions.append(url)
        // Model the cache's independent shared task: cancelling a view consumer
        // is not evidence that its disk/network/decode task stopped.
        let shared = sharedLoad ?? Task { @MainActor in
            self.physicalLoadCount += 1
            if self.holdsSharedLoad {
                await withCheckedContinuation { self.sharedContinuation = $0 }
            }
            self.completedSharedLoadCount += 1
            return self.decodedImage
        }
        sharedLoad = shared
        let image = await shared.value
        memoryImages[url] = image
        completedConsumerCancellationStates.append(Task.isCancelled)
        return image
    }

    func completeSharedLoad() {
        sharedContinuation?.resume()
        sharedContinuation = nil
    }
}
