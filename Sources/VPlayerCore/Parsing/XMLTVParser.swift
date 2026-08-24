// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public protocol XMLTVEventSink: AnyObject {
    func accept(channel: EPGChannel) throws
    func accept(programme: Programme) throws
}

public struct XMLTVParseLimits: Equatable, Sendable {
    public let maximumChannels: Int
    public let maximumProgrammes: Int
    public let maximumEvents: Int
    public let maximumDepth: Int
    public let maximumTextBytes: Int

    public init(
        maximumChannels: Int,
        maximumProgrammes: Int,
        maximumEvents: Int,
        maximumDepth: Int,
        maximumTextBytes: Int
    ) {
        self.maximumChannels = maximumChannels
        self.maximumProgrammes = maximumProgrammes
        self.maximumEvents = maximumEvents
        self.maximumDepth = maximumDepth
        self.maximumTextBytes = maximumTextBytes
    }

    public static let production = Self(
        maximumChannels: 50_000,
        maximumProgrammes: 500_000,
        maximumEvents: 550_000,
        maximumDepth: 32,
        maximumTextBytes: 1_048_576
    )
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
    case excessiveChannels
    case excessiveProgrammes
    case excessiveEvents
    case invalidProgramme
}

public final class XMLTVParser {
    public init() {}

    public func parse(
        fileURL: URL,
        into sink: XMLTVEventSink,
        limits: XMLTVParseLimits = .production,
        cancellationCheck: @escaping @Sendable () throws -> Void = {}
    ) throws -> XMLTVParseSummary {
        guard let parser = Foundation.XMLParser(contentsOf: fileURL) else {
            throw XMLTVParserError.malformed
        }
        let delegate = XMLTVDelegate(
            sink: sink,
            limits: limits,
            cancellationCheck: cancellationCheck
        )
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
    private let limits: XMLTVParseLimits
    private let cancellationCheck: @Sendable () throws -> Void
    private let timeParser = XMLTVTimeParser()
    private var depth = 0
    private var rawChannelCount = 0
    private var rawProgrammeCount = 0
    private var rawEventCount = 0
    private var channel: ChannelState?
    private var programme: ProgrammeState?
    private var textElement: (name: String, depth: Int)?
    private var text = ""
    private var textByteCount = 0

    private(set) var channelCount = 0
    private(set) var programmeCount = 0
    private(set) var firstError: Error?

    init(
        sink: XMLTVEventSink,
        limits: XMLTVParseLimits,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) {
        self.sink = sink
        self.limits = limits
        self.cancellationCheck = cancellationCheck
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard firstError == nil else { return }
        guard checkCancellation(parser: parser) else { return }
        depth += 1
        guard depth <= limits.maximumDepth else {
            fail(XMLTVParserError.excessiveDepth, parser: parser)
            return
        }

        switch elementName {
        case "channel":
            rawChannelCount += 1
            rawEventCount += 1
            guard rawChannelCount <= limits.maximumChannels else {
                fail(XMLTVParserError.excessiveChannels, parser: parser)
                return
            }
            guard rawEventCount <= limits.maximumEvents else {
                fail(XMLTVParserError.excessiveEvents, parser: parser)
                return
            }
            channel = ChannelState(
                id: attributeDict["id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        case "programme":
            rawProgrammeCount += 1
            rawEventCount += 1
            guard rawProgrammeCount <= limits.maximumProgrammes else {
                fail(XMLTVParserError.excessiveProgrammes, parser: parser)
                return
            }
            guard rawEventCount <= limits.maximumEvents else {
                fail(XMLTVParserError.excessiveEvents, parser: parser)
                return
            }
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
        guard checkCancellation(parser: parser) else { return }
        appendText(string, parser: parser)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard checkCancellation(parser: parser) else { return }
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
        guard addedBytes <= limits.maximumTextBytes - textByteCount else {
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
        guard checkCancellation(parser: parser) else { return }
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
            let id = ProgrammeStableID.make(
                channelID: channelID,
                startEpochSeconds: Int64(start.timeIntervalSince1970),
                stopEpochSeconds: Int64(stop.timeIntervalSince1970),
                title: title
            )
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
        } catch is XMLTVParserError, is XMLTVTimeError {
            return
        } catch {
            fail(error, parser: parser)
            return
        }

        guard checkCancellation(parser: parser) else { return }
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

    private func checkCancellation(parser: XMLParser) -> Bool {
        guard firstError == nil else { return false }
        do {
            try cancellationCheck()
            return true
        } catch {
            fail(error, parser: parser)
            return false
        }
    }

    private func fail(_ error: Error, parser: XMLParser) {
        guard firstError == nil else { return }
        firstError = error
        parser.abortParsing()
    }
}
