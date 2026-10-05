// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CommonCrypto
import Foundation
import XCTest
@testable import VPlayerPlayback

final class HLSProxyProtectionBindingTests: XCTestCase {
    func testRealPaidMAPReceiptBindsActuallyServedInitialAndRenewedBytesIncludingSameURLKeys() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "progressive-h264-aac", withExtension: "ts"))
        let original = try Data(contentsOf: file)
        let plaintext = Data(original.prefix(188 * 3)), segment = Data(original.dropFirst(188 * 3))
        for encrypted in [false, true] {
            var key = Data(repeating: 0x11, count: 16)
            let iv = Data(repeating: 0, count: 16)
            var transported = encrypted ? try encrypt(plaintext, key: key, iv: iv) : plaintext
            let keyLine = encrypted ? "#EXT-X-KEY:METHOD=AES-128,URI=\"key\",IV=0x00000000000000000000000000000000\n" : ""
            let mapRange = encrypted ? "" : ",BYTERANGE=\"\(plaintext.count)@0\""
            let segmentClear = encrypted ? "#EXT-X-KEY:METHOD=NONE\n" : ""
            let manifest = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n\(keyLine)#EXT-X-MAP:URI=\"map\"\(mapRange)\n\(segmentClear)#EXTINF:4,\nsegment\n#EXT-X-ENDLIST\n"
            let origin = try NativeHLSHTTPFixture(resources: [
                "/media": .init(data: Data(manifest.utf8), contentType: "application/vnd.apple.mpegurl"),
                "/map": .init(data: transported, contentType: "application/octet-stream"),
                "/key": .init(data: key, contentType: "application/octet-stream"),
                "/segment": .init(data: segment, contentType: "video/mp2t")], credential: "map fixture")
            let context = try sourceContext(url: origin.url("media"), attributes: ["Authorization": "map fixture"])
            let resolver = URLSessionPlaybackSourceResolver()
            var proxy: HLSProxySession?
            let client = URLSession(configuration: .ephemeral)
            var failure: (any Error)?
            do {
                let sourceCharge = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.sourceRetention)
                let source = try await resolver.resolve(context, reason: .initial)
                let factsCharge = try HLSApplicationLifetimeCharge(bytes: HLSPreflightMemoryLimits.factsRetention)
                let facts = try await HLSCompatibilityProbe().inspect(source, retainingFacts: factsCharge)
                XCTAssertEqual(facts.initializationReceipts.count, 1, "Must use authentic concrete inspected MAP proof")
                XCTAssertEqual(facts.media.first?.container, .mpegTS, "MAP does not imply ISO BMFF")
                let owner = try XCTUnwrap(context.owner)
                let plan = HLSPlaybackPlan(owner: owner, resolutionGeneration: source.generation, transport: .proxy,
                    video: .source, audio: .source, selectedServiceURL: nil, formatFingerprint: facts.formatFingerprint)
                let owned = HLSOwnedSourcePlan(source: source, facts: facts, plan: plan, resolver: resolver,
                    sourceCharge: sourceCharge, factsCharge: factsCharge)
                let live = try await HLSByteProxy.start(source: source,
                    lifecycle: .init(backendIdentity: owner.backendIdentity, outputNonce: owner.outputLifecycleNonce),
                    resolver: resolver, sourceRetention: sourceCharge, manifestAuthority: owned.makeProxyManifestAuthority())
                proxy = live
                let initial = try await playlist(client, url: live.itemURL)
                let oldMap = try XCTUnwrap(initial.segments.first?.initialization)
                XCTAssertEqual(oldMap.url.pathExtension, "ts")
                var oldLease: HLSProxyResourceRegistry.Resource? = try live.resourceLeaseForTesting(path: oldMap.url.path)
                let originalTransported = transported
                // Mutate the origin AFTER validation, before the actual proxy GET.
                origin.replace("/map", resource: .init(data: Data(repeating: 0xEE, count: transported.count), contentType: "application/octet-stream"))
                origin.replace("/key", resource: .init(data: Data(repeating: 0xEF, count: 16), contentType: "application/octet-stream"))
                let firstRead = try await read(client, resource: oldMap)
                XCTAssertEqual(firstRead.0, originalTransported, "Validated MAP bytes, not later origin bytes, must be served")
                if encrypted {
                    let oldKey = try XCTUnwrap(initial.references.first { $0.kind == .key }?.url)
                    let oldKeyData = try await client.data(from: oldKey).0
                    XCTAssertEqual(oldKeyData, key)
                    XCTAssertEqual(try HLSAES128Preflight.decrypt(firstRead.0, key: oldKeyData, iv: iv), plaintext)
                } else {
                    XCTAssertEqual(firstRead.1.statusCode, 206)
                    XCTAssertEqual(firstRead.1.value(forHTTPHeaderField: "Content-Range"), "bytes 0-\(plaintext.count - 1)/\(plaintext.count)")
                    var head = URLRequest(url: oldMap.url); head.httpMethod = "HEAD"
                    let result = try await client.data(for: head)
                    XCTAssertTrue(result.0.isEmpty)
                    XCTAssertEqual((result.1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), String(plaintext.count))
                }
                for index in 0..<5 {
                    key = Data(repeating: UInt8(0x30 + index), count: 16)
                    transported = encrypted ? try encrypt(plaintext, key: key, iv: iv) : plaintext
                    origin.replace("/key", resource: .init(data: key, contentType: "application/octet-stream"))
                    origin.replace("/map", resource: .init(data: transported, contentType: "application/octet-stream"))
                    let renewed = try await playlist(client, url: live.itemURL)
                    let map = try XCTUnwrap(renewed.segments.first?.initialization)
                    XCTAssertNotEqual(map.url, oldMap.url, "Every renewal binds a new response even when original URLs are identical")
                    origin.replace("/map", resource: .init(data: Data(repeating: 0xAA, count: transported.count), contentType: "application/octet-stream"))
                    origin.replace("/key", resource: .init(data: Data(repeating: 0xBB, count: 16), contentType: "application/octet-stream"))
                    let served = try await read(client, resource: map)
                    XCTAssertEqual(served.0, transported)
                    if encrypted {
                        let keyURL = try XCTUnwrap(renewed.references.first { $0.kind == .key }?.url)
                        let servedKey = try await client.data(from: keyURL).0
                        XCTAssertEqual(servedKey, key)
                        XCTAssertEqual(try HLSAES128Preflight.decrypt(served.0, key: servedKey, iv: iv), plaintext)
                    }
                    XCTAssertLessThanOrEqual(live.admissionUsage.bytes, HLSProxyBudget.domainBytes)
                }
                XCTAssertEqual(oldLease?.protectedBody?.data, originalTransported)
                let beforeRelease = live.admissionUsage.bytes
                oldLease = nil
                XCTAssertLessThan(live.admissionUsage.bytes, beforeRelease)
                XCTAssertEqual(origin.deniedCount, 0, "Scoped original-origin credentials must survive all validated resource reads")
                // The next changed plaintext fails; URI continuity is not new proof.
                let rejected = try await client.data(from: live.itemURL)
                XCTAssertEqual((rejected.1 as? HTTPURLResponse)?.statusCode, 502)
            } catch { failure = error }
            await resolver.invalidate()
            if let proxy { let joined = await proxy.retire(); XCTAssertTrue(joined) }
            client.invalidateAndCancel(); await origin.close()
            if let failure { throw failure }
        }
    }
    private func playlist(_ client: URLSession, url: URL) async throws -> HLSManifestGraph.Document {
        let response = try await client.data(from: url)
        guard (response.1 as? HTTPURLResponse)?.statusCode == 200 else { throw HLSSourceError.network }
        return try XCTUnwrap(HLSManifestGraph.parse(data: response.0, responseURL: url).document(for: url))
    }
    private func read(_ client: URLSession, resource: HLSManifestGraph.Resource) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: resource.url)
        if let range = resource.range { request.setValue("bytes=\(range.offset)-\(range.offset + range.length - 1)", forHTTPHeaderField: "Range") }
        let response = try await client.data(for: request)
        return (response.0, try XCTUnwrap(response.1 as? HTTPURLResponse))
    }
    private func encrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        var result = Data(count: data.count + kCCBlockSizeAES128), count = 0
        let status = result.withUnsafeMutableBytes { output in data.withUnsafeBytes { input in key.withUnsafeBytes { key in iv.withUnsafeBytes { iv in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                key.baseAddress, key.count, iv.baseAddress, input.baseAddress, input.count, output.baseAddress, output.count, &count)
        } } } }
        guard status == kCCSuccess else { throw HLSSourceError.unsupportedMedia }
        result.removeSubrange(count..<result.count); return result
    }
}
