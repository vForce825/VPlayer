// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation
import XCTest
@testable import VPlayerPlayback

final class HLSManifestGraphTests: XCTestCase {
    func testMasterPreservesAlternatesAndExactURIByteSpans() throws {
        let url = URL(string: "https://example.test/cdn/master?sig=parent")!
        let text = "#EXTM3U\r\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"English, main\",URI=\"../audio?sig=child\"\r\n#EXT-X-STREAM-INF:BANDWIDTH=1000,AUDIO=\"a\",CODECS=\"avc1.640029,mp4a.40.2\"\r\nvideo\r\n"
        let graph = try HLSManifestGraph.parse(data: Data(text.utf8), responseURL: url)
        let document = try XCTUnwrap(graph.document(for: url))
        XCTAssertEqual(document.kind, .master)
        XCTAssertEqual(document.rawData, Data(text.utf8))
        XCTAssertEqual(document.renditions.first?.attributes["NAME"], "English, main")
        XCTAssertEqual(document.renditions.first?.url?.absoluteString, "https://example.test/audio?sig=child")
        XCTAssertEqual(document.variants.first?.url.absoluteString, "https://example.test/cdn/video")
        for ref in document.references { XCTAssertEqual(String(data: document.rawData[ref.byteRange], encoding: .utf8), ref.originalURI) }
    }
    func testMapRangesAndAESProtectionRemainDistinct() throws {
        let url = URL(string: "https://example.test/media")!
        let text = "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:7\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\",IV=0x1\n#EXT-X-MAP:URI=\"init\"\n#EXT-X-KEY:METHOD=NONE\n#EXTINF:1,\npart\n#EXT-X-DISCONTINUITY\n#EXTINF:1,\npart2\n"
        let graph = try HLSManifestGraph.parse(data: Data(text.utf8), responseURL: url)
        let segments = try XCTUnwrap(graph.document(for: url)?.segments)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].mediaSequence, 7)
        XCTAssertEqual(segments[1].discontinuity, 1)
        XCTAssertEqual(segments[0].encryption, .none)
        guard case let .aes128(key, iv) = segments[0].initializationEncryption else { return XCTFail("lost MAP protection") }
        XCTAssertEqual(key.path, "/key"); XCTAssertEqual(iv, Data(repeating: 0, count: 15) + Data([1]))
        XCTAssertTrue(graph.unsupportedFeatures.isEmpty)
    }
    func testUnmanagedURIExtensionsAndEncryptionAreNotAdmitted() throws {
        for tag in ["#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key\"", "#EXT-X-PART:DURATION=0.1,URI=\"part\"", "#EXT-X-SESSION-DATA:DATA-ID=\"x\",URI=\"metadata\""] {
            let graph = try HLSManifestGraph.parse(data: Data("#EXTM3U\n\(tag)\n#EXTINF:1,\npart\n".utf8), responseURL: URL(string: "https://example.test/media")!)
            XCTAssertFalse(graph.unsupportedFeatures.isEmpty)
        }
    }
    func testSessionDataValuePreservesLiteralResourceMarkersWithoutReferences() throws {
        let url = URL(string: "https://example.test/master")!
        for value in ["Programme title", "URI=label", "URL=label", "URI=first, URL=second", ""] {
            let text = "#EXTM3U\n#EXT-X-SESSION-DATA:DATA-ID=\"com.example.title\",LANGUAGE=\"en\",VALUE=\"\(value)\"\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nvideo\n"
            let graph = try HLSManifestGraph.parse(data: Data(text.utf8), responseURL: url)
            let document = try XCTUnwrap(graph.document(for: url))
            XCTAssertTrue(graph.unsupportedFeatures.isEmpty, value)
            XCTAssertEqual(document.kind, .master)
            XCTAssertEqual(document.rawData, Data(text.utf8))
            XCTAssertEqual(document.references.count, 1)
            XCTAssertEqual(document.references.first?.kind, .variant)
            XCTAssertEqual(document.references.first?.url, URL(string: "https://example.test/video"))
        }
    }
    func testSessionDataResourcesAndVariablesRemainUnsupportedWithoutReferences() throws {
        let url = URL(string: "https://example.test/master")!
        for attributes in [
            "DATA-ID=\"x\",URI=\"metadata.json\"",
            "DATA-ID=\"x\",VALUE=\"title\",URL=\"metadata.json\"",
            "DATA-ID=\"x\",VALUE=\"title\",X-URI=\"metadata.json\"",
            "DATA-ID=\"x\",VALUE=\"title\",X-METADATA=\"URI=metadata\"",
            "DATA-ID=\"URI=label\",VALUE=\"title\"",
            "DATA-ID=\"x\",VALUE=\"{$title}\"",
            "DATA-ID=\"x\",URI=\"{$metadata}\""
        ] {
            let text = "#EXTM3U\n#EXT-X-SESSION-DATA:\(attributes)\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nvideo\n"
            let graph = try HLSManifestGraph.parse(data: Data(text.utf8), responseURL: url)
            let document = try XCTUnwrap(graph.document(for: url))
            XCTAssertEqual(graph.unsupportedFeatures, ["unmanaged-uri-extension"], attributes)
            XCTAssertEqual(document.references.count, 1)
            XCTAssertEqual(document.references.first?.kind, .variant)
        }
    }
    func testSessionDataRejectsMalformedAttributeShapes() {
        let url = URL(string: "https://example.test/master")!
        for attributes in [
            "VALUE=\"title\"",
            "DATA-ID=\"x\"",
            "DATA-ID=\"x\",VALUE=\"title\",URI=\"metadata.json\"",
            "DATA-ID=\"x\",VALUE=\"first\",VALUE=\"second\"",
            "DATA-ID=x,VALUE=\"title\"",
            "DATA-ID=\"x\",VALUE=title",
            "DATA-ID=\"x\",URI=metadata.json",
            "DATA-ID=\"x\",VALUE=\"title\",LANGUAGE=en",
            "DATA-ID=\"x\",VALUE=\"unterminated",
            "DATA-ID=\"x\",VALUE=\"title\","
        ] {
            let text = "#EXTM3U\n#EXT-X-SESSION-DATA:\(attributes)\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nvideo\n"
            XCTAssertThrowsError(try HLSManifestGraph.parse(data: Data(text.utf8), responseURL: url), attributes) { error in
                XCTAssertEqual(error as? HLSSourceError, .malformedManifest, attributes)
            }
        }
    }
    func testSessionDataValueDoesNotRelaxOtherExtensionRestrictions() throws {
        let url = URL(string: "https://example.test/master")!
        for tag in [
            "#EXT-X-OTHER:URI=\"metadata.json\"",
            "#EXT-X-OTHER:VALUE=\"URL=metadata\"",
            "#EXT-X-DEFINE:NAME=\"title\",VALUE=\"example\"",
            "#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES",
            "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key\""
        ] {
            let text = "#EXTM3U\n#EXT-X-SESSION-DATA:DATA-ID=\"x\",VALUE=\"URI=first, URL=second\"\n\(tag)\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nvideo\n"
            let graph = try HLSManifestGraph.parse(data: Data(text.utf8), responseURL: url)
            XCTAssertFalse(graph.unsupportedFeatures.isEmpty, tag)
        }
    }
}
