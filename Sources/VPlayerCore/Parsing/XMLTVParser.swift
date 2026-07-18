// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import CryptoKit
import Foundation

public protocol XMLTVEventSink: AnyObject {
    func accept(channel: EPGChannel) throws
    func accept(programme: Programme) throws
}

public struct XMLTVParseSummary: Equatable, Sendable {
    public let channelCount: Int
    public let programmeCount: Int
}

public enum XMLTVParserError: Error, Equatable, Sendable {
    case malformed
    case entityDeclarationForbidden
    case excessiveDepth
    case excessiveText
    case invalidProgramme
}

public final class XMLTVParser {
    public init() {}

    public func parse(fileURL: URL, into sink: XMLTVEventSink) throws -> XMLTVParseSummary {
        guard let parser = Foundation.XMLParser(contentsOf: fileURL) else {
            throw XMLTVParserError.malformed
        }
        let delegate = XMLTVDelegate(sink: sink)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never

        let succeeded = parser.parse()
        if let error = delegate.firstError {
            throw error
        }
        guard succeeded, parser.parserError == nil else {
            throw XMLTVParserError.malformed
        }
        return XMLTVParseSummary(
            channelCount: delegate.channelCount,
            programmeCount: delegate.programmeCount
        )
    }
}

private final class XMLTVDelegate: NSObject, XMLParserDelegate {
    private static let maximumDepth = 32
    private static let maximumTextBytes = 1_048_576

    private struct ChannelState {
        let id: String
        var displayNames: [String] = []
        var iconURL: URL?
    }

    private struct ProgrammeState {
        let channelID: String?
        let rawStart: String?
        let rawStop: String?
        var title: String?
        var subtitle: String?
        var summary: String?
        var categories: [String] = []
        var iconURL: URL?
    }

    private let sink: XMLTVEventSink
    private let timeParser = XMLTVTimeParser()
    private var depth = 0
    private var channel: ChannelState?
    private var programme: ProgrammeState?
    private var textElement: (name: String, depth: Int)?
    private var text = ""
    private var textByteCount = 0

    private(set) var channelCount = 0
    private(set) var programmeCount = 0
    private(set) var firstError: Error?

    init(sink: XMLTVEventSink) {
        self.sink = sink
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard firstError == nil else { return }
        depth += 1
        guard depth <= Self.maximumDepth else {
            fail(XMLTVParserError.excessiveDepth, parser: parser)
            return
        }

        switch elementName {
        case "channel":
            channel = ChannelState(
                id: attributeDict["id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        case "programme":
            programme = ProgrammeState(
                channelID: attributeDict["channel"],
                rawStart: attributeDict["start"],
                rawStop: attributeDict["stop"]
            )
        case "icon":
            let iconURL = attributeDict["src"].flatMap(URL.init(string:))
            if channel != nil {
                channel?.iconURL = iconURL
            } else if programme != nil {
                programme?.iconURL = iconURL
            }
        case "display-name" where channel != nil,
             "title" where programme != nil,
             "sub-title" where programme != nil,
             "desc" where programme != nil,
             "category" where programme != nil:
            textElement = (elementName, depth)
            text = ""
            textByteCount = 0
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard firstError == nil else { return }

        if let textElement, textElement.name == elementName, textElement.depth == depth {
            acceptText(text.trimmingCharacters(in: .whitespacesAndNewlines), for: elementName)
            self.textElement = nil
            text = ""
            textByteCount = 0
        }

        switch elementName {
        case "channel":
            emitChannel(parser: parser)
        case "programme":
            emitProgramme(parser: parser)
        default:
            break
        }
        depth -= 1
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendText(string, parser: parser)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard let string = String(data: CDATABlock, encoding: .utf8) else {
            fail(XMLTVParserError.malformed, parser: parser)
            return
        }
        appendText(string, parser: parser)
    }

    func parser(
        _ parser: XMLParser,
        foundInternalEntityDeclarationWithName name: String,
        value: String?
    ) {
        fail(XMLTVParserError.entityDeclarationForbidden, parser: parser)
    }

    func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        fail(XMLTVParserError.entityDeclarationForbidden, parser: parser)
    }

    func parser(
        _ parser: XMLParser,
        foundUnparsedEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?,
        notationName: String?
    ) {
        fail(XMLTVParserError.entityDeclarationForbidden, parser: parser)
    }

    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        fail(XMLTVParserError.entityDeclarationForbidden, parser: parser)
        return nil
    }

    func parser(_ parser: XMLParser, foundSkippedEntityName name: String) {
        fail(XMLTVParserError.entityDeclarationForbidden, parser: parser)
    }

    private func appendText(_ addition: String, parser: XMLParser) {
        guard firstError == nil, textElement != nil else { return }
        let addedBytes = addition.utf8.count
        guard addedBytes <= Self.maximumTextBytes - textByteCount else {
            fail(XMLTVParserError.excessiveText, parser: parser)
            return
        }
        text.append(addition)
        textByteCount += addedBytes
    }

    private func acceptText(_ value: String, for elementName: String) {
        switch elementName {
        case "display-name":
            if !value.isEmpty {
                channel?.displayNames.append(value)
            }
        case "title":
            programme?.title = value
        case "sub-title":
            programme?.subtitle = value.isEmpty ? nil : value
        case "desc":
            programme?.summary = value.isEmpty ? nil : value
        case "category":
            if !value.isEmpty {
                programme?.categories.append(value)
            }
        default:
            break
        }
    }

    private func emitChannel(parser: XMLParser) {
        guard let channel else {
            fail(XMLTVParserError.malformed, parser: parser)
            return
        }
        self.channel = nil
        guard !channel.id.isEmpty, !channel.displayNames.isEmpty else {
            fail(XMLTVParserError.malformed, parser: parser)
            return
        }
        do {
            try sink.accept(channel: EPGChannel(
                id: channel.id,
                displayNames: channel.displayNames,
                iconURL: channel.iconURL
            ))
            channelCount += 1
        } catch {
            fail(error, parser: parser)
        }
    }

    private func emitProgramme(parser: XMLParser) {
        guard let programme else {
            fail(XMLTVParserError.invalidProgramme, parser: parser)
            return
        }
        self.programme = nil
        let emittedProgramme: Programme
        do {
            guard let channelID = nonEmpty(programme.channelID),
                  let rawStart = programme.rawStart,
                  let rawStop = programme.rawStop,
                  let title = nonEmpty(programme.title) else {
                throw XMLTVParserError.invalidProgramme
            }
            let start = try timeParser.parse(rawStart)
            let stop = try timeParser.parse(rawStop)
            guard stop > start else {
                throw XMLTVParserError.invalidProgramme
            }
            let identity = "\(channelID)|\(Int64(start.timeIntervalSince1970))|\(Int64(stop.timeIntervalSince1970))|\(title)"
            let digest = SHA256.hash(data: Data(identity.utf8))
            let id = digest.map { String(format: "%02x", $0) }.joined()
            _ = programme.iconURL
            emittedProgramme = Programme(
                id: id,
                xmltvChannelID: channelID,
                start: start,
                stop: stop,
                title: title,
                subtitle: programme.subtitle,
                summary: programme.summary,
                categories: programme.categories
            )
        } catch let error as XMLTVParserError {
            fail(error, parser: parser)
            return
        } catch is XMLTVTimeError {
            fail(XMLTVParserError.invalidProgramme, parser: parser)
            return
        } catch {
            fail(error, parser: parser)
            return
        }

        do {
            try sink.accept(programme: emittedProgramme)
            programmeCount += 1
        } catch {
            fail(error, parser: parser)
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func fail(_ error: Error, parser: XMLParser) {
        guard firstError == nil else { return }
        firstError = error
        parser.abortParsing()
    }
}
