// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Darwin
import Foundation
import Network
import XCTest
@testable import VPlayerPlayback

final class HLSProxyBackpressureTests: XCTestCase {
    func testFixedWindowAndFinalDataAliasKeepTheirPrepaidLease() throws {
        let budget = try HLSProxyBudget()
        let transfer = try budget.admitTransfer()
        try withExtendedLifetime(transfer) {
            let baseline = budget.usage.bytes
            var window: HLSProxyBudget.ReadWindow? = .init(envelope: try transfer.reserveBodyEnvelope())
            let size = try XCTUnwrap(window).capacity
            for index in 0..<size { window?.store(UInt8(truncatingIfNeeded: index), at: index) }
            var bytes: Data? = try XCTUnwrap(window).borrow(count: size).makeData()
            XCTAssertEqual(bytes?.count, size)
            XCTAssertEqual(bytes?.last, UInt8(truncatingIfNeeded: size - 1))
            var physicalAlias = bytes
            bytes = nil; window = nil
            XCTAssertEqual(budget.usage.bytes, baseline + 2 * size)
            withExtendedLifetime(physicalAlias) {}
            physicalAlias = nil
            XCTAssertEqual(budget.usage.bytes, baseline)
        }
    }

    func testTinyFinalBorrowCanReleaseBeforeWaitRegistrationAndReuse() async throws {
        let budget = try HLSProxyBudget()
        let transfer = try budget.admitTransfer()
        let window = HLSProxyBudget.ReadWindow(envelope: try transfer.reserveBodyEnvelope())
        for value in [UInt8(0x47), UInt8(0x48)] {
            window.store(value, at: 0)
            let borrow = window.borrow(count: 1)
            var bytes: Data? = borrow.makeData()
            XCTAssertEqual(bytes, Data([value]))
            bytes = nil
            await borrow.waitForRelease()
        }
    }

    func testRingPublishesShortPrefixAndProtectsBorrowedCellsUntilRelease() async throws {
        let budget = try HLSProxyBudget()
        let transfer = try budget.admitTransfer()
        let pipe = HLSProxyBudget.BytePipe(envelope: try transfer.reserveBodyEnvelope())
        let prefixCount = 188
        for index in 0..<prefixCount { try pipe.publish(UInt8(truncatingIfNeeded: index), at: UInt64(index)) }
        let firstValue = try await pipe.nextSpan(at: 0)
        let first = try XCTUnwrap(firstValue)
        XCTAssertEqual(first.offset, 0); XCTAssertEqual(first.count, prefixCount)
        let borrow = pipe.window.borrow(offset: first.offset, count: first.count)
        var bytes: Data? = borrow.makeData()
        var nativeAlias = bytes
        bytes = nil
        for index in prefixCount..<pipe.window.capacity {
            try pipe.publish(UInt8(truncatingIfNeeded: index), at: UInt64(index))
        }
        XCTAssertTrue(pipe.isFull(at: UInt64(pipe.window.capacity)))
        XCTAssertEqual(nativeAlias, Data((0..<prefixCount).map { UInt8(truncatingIfNeeded: $0) }))
        let released = Task { await borrow.waitForRelease() }
        await Task.yield()
        nativeAlias = nil
        await released.value
        pipe.releaseThrough(UInt64(prefixCount))
        XCTAssertFalse(pipe.isFull(at: UInt64(pipe.window.capacity)))
        try pipe.publish(0xAA, at: UInt64(pipe.window.capacity))
        pipe.finish(.success(()))
        let restValue = try await pipe.nextSpan(at: UInt64(prefixCount))
        let rest = try XCTUnwrap(restValue)
        XCTAssertEqual(rest.offset, prefixCount)
        XCTAssertEqual(rest.count, pipe.window.capacity - prefixCount)
        pipe.releaseThrough(UInt64(pipe.window.capacity))
        let wrappedValue = try await pipe.nextSpan(at: UInt64(pipe.window.capacity))
        let wrapped = try XCTUnwrap(wrappedValue)
        XCTAssertEqual(wrapped.offset, 0); XCTAssertEqual(wrapped.count, 1)
        pipe.releaseThrough(UInt64(pipe.window.capacity + 1))
        let end = try await pipe.nextSpan(at: UInt64(pipe.window.capacity + 1))
        XCTAssertNil(end)
    }

    func testRingAbortWakesBothDirectionsWithoutTreatingBufferedBytesAsSuccess() async throws {
        let budget = try HLSProxyBudget()
        let transfer = try budget.admitTransfer()
        let empty = HLSProxyBudget.BytePipe(envelope: try transfer.reserveBodyEnvelope())
        let waitingReader = Task { try await empty.nextSpan(at: 0) }
        await Task.yield()
        empty.abort(CancellationError())
        do { _ = try await waitingReader.value; XCTFail("Abort must not look like EOF") }
        catch { XCTAssertTrue(error is CancellationError) }
        let full = HLSProxyBudget.BytePipe(envelope: try transfer.reserveBodyEnvelope())
        for index in 0..<full.window.capacity { try full.publish(0x47, at: UInt64(index)) }
        let waitingWriter = Task { try await full.waitForSpace(at: UInt64(full.window.capacity)) }
        await Task.yield()
        full.abort(CancellationError())
        do { try await waitingWriter.value; XCTFail("Abort wake must not manufacture write credit") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await full.nextSpan(at: 0); XCTFail("Abort must not drain a successful body") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testUnknownAndLargeResponseWindowsShareExistingDomainAndTransferCaps() throws {
        let budget = try HLSProxyBudget()
        let baseline = budget.usage.bytes
        var transfers: [HLSProxyBudget.Lease] = []
        var envelopes: [HLSProxyBudget.BodyEnvelope] = []
        for _ in 0..<8 {
            let transfer = try budget.admitTransfer()
            transfers.append(transfer)
            let envelope = try transfer.reserveBodyEnvelope()
            envelopes.append(envelope)
            XCTAssertEqual(envelope.maximumWindowBytes, 32 * 1_024)
        }
        XCTAssertEqual(HLSProxyBudget.domainBytes, 32 * 1_024 * 1_024)
        XCTAssertEqual(HLSProxyBudget.maximumTransfers, 8)
        XCTAssertEqual(HLSProxyBudget.maximumConnections, 16)
        XCTAssertEqual(budget.usage.bytes, baseline + 8 * (512 * 1_024 + 2 * HLSProxyBudget.transferBufferBytes))
        XCTAssertLessThanOrEqual(budget.usage.bytes, HLSProxyBudget.domainBytes)
        XCTAssertThrowsError(try budget.admitTransfer())
        envelopes.removeAll(); transfers.removeAll()
        XCTAssertEqual(budget.usage.bytes, baseline)
        XCTAssertEqual(budget.usage.transfers, 0)
    }

    func testBodyWindowFailsBeforeAdmissionWhenSharedDomainCannotPay() throws {
        let budget = try HLSProxyBudget()
        let transfer = try budget.admitTransfer()
        let remaining = HLSProxyBudget.domainBytes - budget.usage.bytes
        let occupied = try budget.reserve(bytes: remaining - 2 * HLSProxyBudget.transferBufferBytes + 1)
        try withExtendedLifetime((transfer, occupied)) {
            let before = budget.usage.bytes
            XCTAssertThrowsError(try transfer.reserveBodyEnvelope())
            XCTAssertEqual(budget.usage.bytes, before)
            XCTAssertEqual(budget.usage.transfers, 1)
        }
    }

    func testCancellationBeforeRunCannotCreateAReadWindowOrUpstreamTask() async throws {
        let context = try sourceContext()
        let source = ResolvedPlaybackSource(context: context, responseURL: context.entryURL,
            generation: 1, topology: .media(Data([0x47])))
        let budget = try HLSProxyBudget()
        let registry = try HLSProxyResourceRegistry(source: source, budget: budget)
        let path = try registry.register(url: context.entryURL, kind: .segment, mediaType: .transportStream)
        let io = HLSProxyIOCounters()
        let connection = HLSProxyConnection(connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            lease: try budget.admitConnection(), io: io)
        let upstream = HLSProxyUpstream(resource: try registry.lease(path: path), method: .get,
            range: nil, connection: connection, transfer: try budget.admitTransfer())
        upstream.cancel()
        let baseline = budget.usage.bytes
        do { try await upstream.run(); XCTFail("Cancelled operation must not begin") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(io.snapshot.readWindows, 0)
        XCTAssertEqual(io.snapshot.peakReadWindows, 0)
        XCTAssertEqual(io.snapshot.pendingSendAliases, 0)
        XCTAssertEqual(budget.usage.bytes, baseline)
    }

    func testCancellationWhileWaitingForHeadersAndNextByteJoinsRealTasks() async throws {
        for withholdHeaders in [true, false] {
            let block = Data(repeating: 0x47, count: 188)
            try await withOrdinaryProxy(resource: .init(data: block, contentType: "video/mp2t",
                withholdResponse: withholdHeaders, withholdBody: !withholdHeaders)) { proxy, origin in
                let reader = SlowProxySocket()
                try await reader.start(proxy.itemURL)
                let deadline = ContinuousClock.now + .seconds(5)
                while (withholdHeaders ? origin.requestCount == 0 : proxy.observedIO.awaitingFirstByteReaders == 0),
                      ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
                XCTAssertGreaterThan(origin.requestCount, 0)
                if !withholdHeaders {
                    XCTAssertGreaterThan(origin.completedHeaders, 0)
                    XCTAssertEqual(proxy.observedIO.awaitingFirstByteReaders, 1,
                        "The real reader must enter its first-next scope while the origin withholds every body byte")
                }
                XCTAssertEqual(proxy.observedIO.readWindows, 1)
                let joined = await proxy.retire()
                await reader.close()
                XCTAssertTrue(joined, "Cancel must unwind bytes(for:) or pending iterator.next(), then physically join")
                XCTAssertEqual(proxy.observedIO.readWindows, 0)
                XCTAssertEqual(proxy.observedIO.awaitingFirstByteReaders, 0)
                XCTAssertEqual(proxy.observedIO.pendingSendAliases, 0)
            }
        }
    }

    func testUnknownLengthShortChunksDeliverProgressBeforeOriginEOF() async throws {
        let block = Data(repeating: 0x47, count: 512 * 1_024)
        try await withOrdinaryProxy(resource: .init(data: block, contentType: "video/mp2t",
            omitContentLength: true, chunkBytes: 64, chunkDelay: 0.125)) { proxy, _ in
            // Ordinary 512 B/s progress. Filling the whole app window would take
            // 64 seconds and hit the existing 30-second connection deadline.
            let client = URLSession(configuration: .ephemeral)
            let observation = ProxyFirstByteObservation()
            let read = Task {
                let (bytes, response) = try await client.bytes(from: proxy.itemURL)
                let http = try XCTUnwrap(response as? HTTPURLResponse)
                XCTAssertEqual(http.statusCode, 200)
                XCTAssertEqual(http.value(forHTTPHeaderField: "Transfer-Encoding"), "chunked")
                var iterator = bytes.makeAsyncIterator()
                if let byte = try await iterator.next() { observation.record(byte) }
                bytes.task.cancel()
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while observation.first == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            let first = observation.first
            read.cancel(); client.invalidateAndCancel()
            _ = await read.result
            XCTAssertEqual(first, 0x47, "A live response must make progress without EOF or a full read window")
            XCTAssertLessThan(proxy.observedIO.deliveredBodyBytes, Int64(block.count))
        }
    }

    func testShortUnknownLengthPrefixArrivesBeforeHeldOriginIsReleased() async throws {
        let media = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "progressive-h264-aac", withExtension: "ts")))
        let prefixCount = 7
        try await withOrdinaryProxy(resource: .init(data: media, contentType: "video/mp2t",
            omitContentLength: true, pauseAfterBodyBytes: prefixCount)) { proxy, origin in
            let client = URLSession(configuration: .ephemeral)
            defer { client.invalidateAndCancel() }
            let prefix = ProxyFirstByteObservation()
            let read = Task { () async throws -> (Int, Bool) in
                let (bytes, _) = try await client.bytes(from: proxy.itemURL)
                var index = 0, matches = true
                for try await byte in bytes {
                    if index >= media.count || byte != media[index] { matches = false }
                    index += 1
                    if index == prefixCount { prefix.record(1) }
                }
                return (index, matches)
            }
            let deadline = ContinuousClock.now + .seconds(5)
            while prefix.first == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            let arrivedWhileHeld = prefix.first != nil
            XCTAssertEqual(origin.pausedBodyCount, 1)
            XCTAssertTrue(arrivedWhileHeld, "The entire short prefix must arrive with no next byte or EOF")
            origin.resumePausedBodies()
            let result = await read.result
            read.cancel()
            switch result {
            case let .success(value): XCTAssertEqual(value.0, media.count); XCTAssertTrue(value.1)
            case let .failure(error): throw error
            }
        }
    }

    func testMultiMegabyteBodyRemainsByteExactWithOneFixedRing() async throws {
        let media = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "progressive-h264-aac", withExtension: "ts")))
        var expected = Data(capacity: media.count * 4)
        for _ in 0..<4 { expected.append(media) }
        XCTAssertGreaterThan(expected.count, 2 * 1_024 * 1_024)
        try await withOrdinaryProxy(resource: .init(data: media, contentType: "video/mp2t", repetitions: 4)) { proxy, _ in
            let client = URLSession(configuration: .ephemeral)
            defer { client.invalidateAndCancel() }
            let before = try ProxyTransferMeasurement.sample()
            let result = try await client.data(from: proxy.itemURL)
            let after = try ProxyTransferMeasurement.sample()
            XCTAssertEqual((result.1 as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(result.0, expected)
            XCTAssertEqual(proxy.observedIO.peakReadWindowBytes, HLSProxyBudget.transferBufferBytes)
            XCTAssertEqual(proxy.observedIO.peakReadWindows, 1)
            print("PROXY_ASYNC_BYTES stage=complete response-bytes=\(expected.count) " +
                "process-cpu-seconds=\(after.cpu - before.cpu) footprint-before=\(before.footprint) " +
                "footprint-after=\(after.footprint) upstream-received=\(proxy.observedIO.upstreamReceivedBytes) " +
                "app-delivered=\(proxy.observedIO.deliveredBodyBytes) body-spans=\(proxy.observedIO.bodySpans) " +
                "span-min=\(proxy.observedIO.smallestBodySpanBytes) span-max=\(proxy.observedIO.largestBodySpanBytes) " +
                "includes-origin-and-client=true")
        }
    }

    func testUnknownLengthBodyAndHEADAndRangeErrorRemainByteExact() async throws {
        let media = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "progressive-h264-aac", withExtension: "ts")))
        let errorBody = Data("Range unavailable.".utf8)
        try await withOrdinaryProxy(resource: .init(data: media, contentType: "video/mp2t",
            rangeErrorBody: errorBody, omitContentLength: true)) { proxy, _ in
            let client = URLSession(configuration: .ephemeral)
            defer { client.invalidateAndCancel() }
            let result = try await client.data(from: proxy.itemURL)
            XCTAssertEqual((result.1 as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual((result.1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Transfer-Encoding"), "chunked")
            XCTAssertEqual(result.0, media)
            var head = URLRequest(url: proxy.itemURL); head.httpMethod = "HEAD"
            let headed = try await client.data(for: head)
            XCTAssertEqual((headed.1 as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertTrue(headed.0.isEmpty)
            var range = URLRequest(url: proxy.itemURL)
            range.setValue("bytes=\(media.count)-", forHTTPHeaderField: "Range")
            let unsatisfied = try await client.data(for: range)
            XCTAssertEqual((unsatisfied.1 as? HTTPURLResponse)?.statusCode, 416)
            XCTAssertEqual((unsatisfied.1 as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"), "bytes */\(media.count)")
            XCTAssertEqual(unsatisfied.0, errorBody)
        }
    }

    private func withOrdinaryProxy(resource: NativeHLSHTTPFixture.Resource,
        operation: (HLSProxySession, NativeHLSHTTPFixture) async throws -> Void) async throws {
        let origin = try NativeHLSHTTPFixture(resources: ["/media.ts": resource])
        let context = try sourceContext(url: origin.url("media.ts"))
        let transport = SourceTestTransport(responses: [context.entryURL: .init(responseURL: context.entryURL,
            data: Data(resource.data.prefix(188)), completeness: .prefix)])
        let resolver = URLSessionPlaybackSourceResolver(transport: transport)
        let source = try await resolver.resolve(context, reason: .initial)
        let owner = try XCTUnwrap(context.owner)
        let proxy = try await HLSByteProxy.start(source: source,
            lifecycle: .init(backendIdentity: owner.backendIdentity, outputNonce: owner.outputLifecycleNonce), resolver: resolver)
        var failure: (any Error)?
        do { try await operation(proxy, origin) } catch { failure = error }
        await resolver.invalidate()
        let joined = await proxy.retire()
        await origin.close()
        XCTAssertTrue(joined)
        XCTAssertEqual(proxy.admissionUsage.bytes, 128 * 1_024)
        XCTAssertEqual(proxy.admissionUsage.transfers, 0)
        XCTAssertEqual(proxy.admissionUsage.connections, 0)
        XCTAssertEqual(proxy.observedIO.readWindows, 0)
        XCTAssertEqual(proxy.observedIO.pendingSendAliases, 0)
        if let failure { throw failure }
    }

    func testOrdinaryLargeRangedResponseRemainsByteExactAndReleasesBodyEnvelope() async throws {
        let media = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "progressive-h264-aac", withExtension: "ts")))
        XCTAssertGreaterThan(media.count, 393_216)
        let origin = try NativeHLSHTTPFixture(resources: [
            "/media.ts": .init(data: media, contentType: "video/mp2t")], credential: "ordinary proxy fixture")
        let context = try sourceContext(url: origin.url("media.ts"), attributes: ["Authorization": "ordinary proxy fixture"])
        let transport = SourceTestTransport(responses: [context.entryURL: .init(responseURL: context.entryURL,
            data: Data(media.prefix(188)), completeness: .prefix)])
        let resolver = URLSessionPlaybackSourceResolver(transport: transport)
        let source = try await resolver.resolve(context, reason: .initial)
        let owner = try XCTUnwrap(context.owner)
        let proxy = try await HLSByteProxy.start(source: source,
            lifecycle: .init(backendIdentity: owner.backendIdentity, outputNonce: owner.outputLifecycleNonce), resolver: resolver)
        let client = URLSession(configuration: .ephemeral)
        var failure: (any Error)?
        do {
            var request = URLRequest(url: proxy.itemURL)
            request.setValue("bytes=0-", forHTTPHeaderField: "Range")
            let result = try await client.data(for: request)
            let response = try XCTUnwrap(result.1 as? HTTPURLResponse)
            XCTAssertEqual(response.statusCode, 206)
            XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Range"), "bytes 0-\(media.count - 1)/\(media.count)")
            XCTAssertEqual(result.0, media)
            XCTAssertEqual(proxy.observedIO.peakReadWindows, 1)
            XCTAssertLessThanOrEqual(proxy.observedIO.peakReadWindowBytes, media.count)
            XCTAssertEqual(origin.deniedCount, 0)
        } catch { failure = error }
        client.invalidateAndCancel()
        await resolver.invalidate()
        let joined = await proxy.retire()
        await origin.close()
        XCTAssertTrue(joined)
        XCTAssertEqual(proxy.admissionUsage.bytes, 128 * 1_024)
        XCTAssertEqual(proxy.admissionUsage.transfers, 0)
        XCTAssertEqual(proxy.admissionUsage.connections, 0)
        XCTAssertEqual(proxy.observedIO.readWindows, 0)
        XCTAssertEqual(proxy.observedIO.pendingSendAliases, 0)
        if let failure { throw failure }
    }

    func testInterruptedKnownLengthOriginReleasesBodyEnvelopeAfterFailedRead() async throws {
        let media = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "progressive-h264-aac", withExtension: "ts")))
        let origin = try NativeHLSHTTPFixture(resources: ["/media.ts": .init(data: media,
            contentType: "video/mp2t", disconnectAfterBodyBytes: 64 * 1_024)])
        let context = try sourceContext(url: origin.url("media.ts"))
        let transport = SourceTestTransport(responses: [context.entryURL: .init(responseURL: context.entryURL,
            data: Data(media.prefix(188)), completeness: .prefix)])
        let resolver = URLSessionPlaybackSourceResolver(transport: transport)
        let source = try await resolver.resolve(context, reason: .initial)
        let owner = try XCTUnwrap(context.owner)
        let proxy = try await HLSByteProxy.start(source: source,
            lifecycle: .init(backendIdentity: owner.backendIdentity, outputNonce: owner.outputLifecycleNonce), resolver: resolver)
        let client = URLSession(configuration: .ephemeral)
        var rejected = false
        do { _ = try await client.data(from: proxy.itemURL) } catch { rejected = true }
        client.invalidateAndCancel()
        await resolver.invalidate()
        let joined = await proxy.retire()
        await origin.close()
        XCTAssertTrue(rejected, "A truncated known-length upstream response must not appear complete")
        XCTAssertGreaterThan(origin.requestCount, 0)
        XCTAssertTrue(joined)
        XCTAssertEqual(proxy.admissionUsage.bytes, 128 * 1_024)
        XCTAssertEqual(proxy.admissionUsage.transfers, 0)
        XCTAssertEqual(proxy.admissionUsage.connections, 0)
        XCTAssertEqual(proxy.observedIO.readWindows, 0)
        XCTAssertEqual(proxy.observedIO.readWindowBytes, 0)
        XCTAssertEqual(proxy.observedIO.pendingSendAliases, 0)
    }

    func testSlowNativeSocketReaderBackpressuresOneUpstreamCallbackAndCancellationJoins() async throws {
        // Virtual 32 MiB ordinary source from one 512 KiB block. The fixture sends
        // only one 32 KiB chunk at a time; it does not allocate a 32 MiB copy.
        let block = Data(repeating: 0x47, count: 512 * 1_024)
        let origin = try NativeHLSHTTPFixture(resources: ["/stream.ts": .init(data: block, contentType: "video/mp2t", repetitions: 64)])
        let context = try sourceContext(url: origin.url("stream.ts"))
        let transport = SourceTestTransport(responses: [context.entryURL: .init(responseURL: context.entryURL,
            data: Data(block.prefix(188)), completeness: .prefix)])
        let resolver = URLSessionPlaybackSourceResolver(transport: transport)
        let source = try await resolver.resolve(context, reason: .initial)
        let owner = try XCTUnwrap(context.owner)
        let proxy = try await HLSByteProxy.start(source: source,
            lifecycle: .init(backendIdentity: owner.backendIdentity, outputNonce: owner.outputLifecycleNonce), resolver: resolver)
        let reader = SlowProxySocket()
        let initialMeasurement = try ProxyTransferMeasurement.sample()
        var heldMeasurement: ProxyTransferMeasurement?
        var failure: (any Error)?
        do {
            try await reader.start(proxy.itemURL)
            let deadline = ContinuousClock.now + .seconds(5)
            var held: HLSProxyIOCounters.Snapshot?
            while ContinuousClock.now < deadline {
                let before = proxy.observedIO
                if before.suspendedReaders == 1, before.pendingSendAliases > 0 {
                    try await Task.sleep(for: .milliseconds(50))
                    let after = proxy.observedIO
                    if after.suspendedReaders == 1, after.pendingSendAliases > 0,
                       after.completedSends == before.completedSends { held = after; break }
                } else { try await Task.sleep(for: .milliseconds(10)) }
            }
            guard let observed = held else {
                let observed = proxy.observedIO
                XCTFail("No held proxy app window: peak=\(observed.peakReadWindowBytes) " +
                    "pending-send=\(observed.pendingSendAliases) suspended=\(observed.suspendedReaders) " +
                    "transfers=\(proxy.admissionUsage.transfers) origin-requests=\(origin.requestCount)")
                throw HLSSourceError.deadline
            }
            heldMeasurement = try ProxyTransferMeasurement.sample()
            print("PROXY_ASYNC_BYTES stage=held response-bytes=\(block.count * 64) " +
                "app-window=\(observed.readWindowBytes) native-send=\(observed.pendingSendAliases) " +
                "upstream-received=\(observed.upstreamReceivedBytes) app-delivered=\(observed.deliveredBodyBytes) " +
                "body-spans=\(observed.bodySpans) span-min=\(observed.smallestBodySpanBytes) span-max=\(observed.largestBodySpanBytes)")
            XCTAssertEqual(observed.readWindowBytes, HLSProxyBudget.transferBufferBytes)
            XCTAssertEqual(observed.readWindows, 1)
            XCTAssertEqual(observed.peakReadWindows, 1)
            XCTAssertGreaterThanOrEqual(proxy.admissionUsage.bytes, 2 * HLSProxyBudget.transferBufferBytes)
            XCTAssertEqual(observed.peakReadWindowBytes, HLSProxyBudget.transferBufferBytes)
            XCTAssertLessThanOrEqual(observed.peakPendingSendAliases, HLSProxyBudget.transferBufferBytes + 16 * 1_024)
            XCTAssertEqual(proxy.admissionUsage.transfers, 1)
            XCTAssertLessThanOrEqual(proxy.admissionUsage.bytes, HLSProxyBudget.domainBytes)
        } catch { failure = error }
        await reader.close()
        await resolver.invalidate()
        let joined = await proxy.retire()
        await origin.close()
        XCTAssertTrue(joined)
        XCTAssertEqual(proxy.admissionUsage.bytes, 128 * 1_024)
        XCTAssertEqual(proxy.admissionUsage.transfers, 0)
        XCTAssertEqual(proxy.admissionUsage.connections, 0)
        XCTAssertEqual(proxy.observedIO.readWindowBytes, 0)
        XCTAssertEqual(proxy.observedIO.readWindows, 0)
        XCTAssertEqual(proxy.observedIO.pendingSendAliases, 0)
        let finalMeasurement = try ProxyTransferMeasurement.sample()
        print("PROXY_ASYNC_BYTES stage=joined cpu-seconds=\(finalMeasurement.cpu - initialMeasurement.cpu) " +
            "footprint-before=\(initialMeasurement.footprint) footprint-held=\(heldMeasurement?.footprint ?? 0) " +
            "footprint-after=\(finalMeasurement.footprint) sdk-buffer-bound=unproven")
        // App window/lease assertions are strict; sampled process observations are not a hard SDK buffer bound.
        if let failure { throw failure }
    }
}

private final class SlowProxySocket: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "org.vplayer.tests.slow-proxy-reader")
    private let callbacks = DispatchGroup()
    private var connection: NWConnection?
    private var ready: CheckedContinuation<Void, any Error>?
    private var stopped: CheckedContinuation<Void, Never>?
    private var done = false
    func start(_ url: URL) async throws {
        guard let port = url.port, let endpoint = NWEndpoint.Port(rawValue: UInt16(port)) else { throw HLSSourceError.invalidURL }
        let connection = NWConnection(host: "127.0.0.1", port: endpoint, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in self?.state(state) }
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { ready = continuation }
            connection.start(queue: queue)
        }
        let request = Data("GET \(url.path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n".utf8)
        callbacks.enter()
        try await withCheckedThrowingContinuation { continuation in
            connection.send(content: request, completion: .contentProcessed { [callbacks] error in
                callbacks.leave()
                if error == nil { continuation.resume() } else { continuation.resume(throwing: HLSSourceError.network) }
            })
        }
    }
    private func state(_ state: NWConnection.State) {
        switch state {
        case .ready:
            let pending = lock.withLock { defer { ready = nil }; return ready }; pending?.resume()
        case .failed: connection?.cancel()
        case .cancelled:
            let values = lock.withLock { done = true; defer { ready = nil; stopped = nil }; return (ready, stopped) }
            values.0?.resume(throwing: HLSSourceError.network); values.1?.resume()
        default: break
        }
    }
    func close() async {
        guard let connection else { return }
        connection.cancel()
        await withCheckedContinuation { continuation in
            let finished = lock.withLock { () -> Bool in if done { return true }; stopped = continuation; return false }
            if finished { continuation.resume() }
        }
        await withCheckedContinuation { continuation in callbacks.notify(queue: queue) { continuation.resume() } }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        connection.stateUpdateHandler = nil
    }
}

private struct ProxyTransferMeasurement {
    let cpu: Double
    let footprint: UInt64
    static func sample() throws -> Self {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw HLSSourceError.network }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw HLSSourceError.network }
        return .init(cpu: Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
            Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000, footprint: info.phys_footprint)
    }
}

private final class ProxyFirstByteObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt8?
    var first: UInt8? { lock.withLock { value } }
    func record(_ value: UInt8) { lock.withLock { if self.value == nil { self.value = value } } }
}
