// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

public protocol XMLTVEventSink: AnyObject {
    func accept(channel: EPGChannel) throws
    func accept(programme: Programme) throws
    func shouldPruneHistoricalProgramme(stop: Date) -> Bool
    func accept(programme: Programme, digest: ProgrammeDigestKey) throws
    func recordExpiredProgramme(digest: ProgrammeDigestKey, stop: Date) throws
}

public extension XMLTVEventSink {
    func shouldPruneHistoricalProgramme(stop: Date) -> Bool { false }

    func accept(programme: Programme, digest: ProgrammeDigestKey) throws {
        try accept(programme: programme)
    }

    func recordExpiredProgramme(digest: ProgrammeDigestKey, stop: Date) throws {}
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
    public let coverageEnd: Date?

    public init(
        channelCount: Int,
        programmeCount: Int,
        coverageEnd: Date? = nil
    ) {
        self.channelCount = channelCount
        self.programmeCount = programmeCount
        self.coverageEnd = coverageEnd
    }
}

public enum XMLTVParserError: Error, Equatable, Sendable, LocalizedError {
    case malformed
    case parserFailure(line: Int, column: Int, diagnostic: ErrorDiagnosticSnapshot)
    case entityDeclarationForbidden
    case excessiveDepth
    case excessiveText
    case excessiveChannels
    case excessiveProgrammes
    case excessiveEvents
    case invalidProgramme

    public var errorDescription: String? {
        if case let .parserFailure(line, column, diagnostic) = self {
            return "XML 第 \(line) 行、第 \(column) 列解析失败：\(diagnostic.summary)"
        }
        return nil
    }
}

public final class XMLTVParser {
    public init() {}

    public func parse(
        fileURL: URL,
        into sink: XMLTVEventSink,
        limits: XMLTVParseLimits = .production,
        cancellationCheck: @escaping @Sendable () throws -> Void = {}
    ) throws -> XMLTVParseSummary {
        guard fileURL.isFileURL else {
            throw XMLTVParserError.malformed
        }
        let mappedData: Data
        do {
            mappedData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            throw XMLTVParserError.malformed
        }

        do {
            return try mappedData.withUnsafeBytes { rawBuffer in
                let bytes = rawBuffer.bindMemory(to: UInt8.self)
                var scanner = XMLTVUTF8Scanner(
                    bytes: bytes,
                    sink: sink,
                    limits: limits,
                    cancellationCheck: cancellationCheck
                )
                return try scanner.parse()
            }
        } catch FastPathEscalation.delegateWholeParseToFoundation {
            return try parseWithFoundation(
                fileURL: fileURL,
                into: sink,
                limits: limits,
                cancellationCheck: cancellationCheck
            )
        } catch FastPathEscalation.diagnoseSyntaxWithFoundation {
            try diagnoseMalformedWithFoundation(fileURL: fileURL, limits: limits)
        }
    }

    private func parseWithFoundation(
        fileURL: URL,
        into sink: XMLTVEventSink,
        limits: XMLTVParseLimits,
        cancellationCheck: @escaping @Sendable () throws -> Void
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
            if let error = parser.parserError {
                throw XMLTVParserError.parserFailure(
                    line: parser.lineNumber,
                    column: parser.columnNumber,
                    diagnostic: ErrorDiagnosticSnapshot(error)
                )
            }
            throw XMLTVParserError.malformed
        }
        return XMLTVParseSummary(
            channelCount: delegate.channelCount,
            programmeCount: delegate.programmeCount
        )
    }

    private func diagnoseMalformedWithFoundation(
        fileURL: URL,
        limits: XMLTVParseLimits
    ) throws -> Never {
        guard let parser = Foundation.XMLParser(contentsOf: fileURL) else {
            throw XMLTVParserError.malformed
        }
        let validator = XMLTVDiagnosticDelegate(maximumDepth: limits.maximumDepth)
        parser.delegate = validator
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        _ = parser.parse()
        if let error = validator.firstError {
            throw error
        }
        if let error = parser.parserError {
            throw XMLTVParserError.parserFailure(
                line: parser.lineNumber,
                column: parser.columnNumber,
                diagnostic: ErrorDiagnosticSnapshot(error)
            )
        }
        throw XMLTVParserError.malformed
    }
}

private enum FastPathEscalation: Error {
    case delegateWholeParseToFoundation
    case diagnoseSyntaxWithFoundation
}

private final class XMLTVDiagnosticDelegate: NSObject, XMLParserDelegate {
    private let maximumDepth: Int
    private var depth = 0
    private(set) var firstError: Error?

    init(maximumDepth: Int) {
        self.maximumDepth = maximumDepth
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        depth += 1
        if depth > maximumDepth {
            firstError = XMLTVParserError.excessiveDepth
            parser.abortParsing()
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        depth -= 1
    }

    func parser(
        _ parser: XMLParser,
        foundInternalEntityDeclarationWithName name: String,
        value: String?
    ) {
        failEntity(parser)
    }

    func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        failEntity(parser)
    }

    func parser(
        _ parser: XMLParser,
        foundUnparsedEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?,
        notationName: String?
    ) {
        failEntity(parser)
    }

    func parser(
        _ parser: XMLParser,
        resolveExternalEntityName name: String,
        systemID: String?
    ) -> Data? {
        failEntity(parser)
        return nil
    }

    func parser(_ parser: XMLParser, foundSkippedEntityName name: String) {
        failEntity(parser)
    }

    private func failEntity(_ parser: XMLParser) {
        guard firstError == nil else { return }
        firstError = XMLTVParserError.entityDeclarationForbidden
        parser.abortParsing()
    }
}

private struct XMLTVUTF8Scanner {
    private enum CapturedTextKind {
        case displayName
        case title
        case subtitle
        case desc
        case category
    }

    private struct FastChannelState {
        let id: String
        var displayNames: [String] = []
        var iconURL: URL?
    }

    private struct FastProgrammeState {
        let channelRange: Range<Int>?
        let channelDecoded: String?
        let startEpoch: Int64?
        let stopEpoch: Int64?
        let isPrunableExpired: Bool
        var hasTitle = false
        var subtitle: String?
        var summary: String?
        var categories: [String] = []
        var iconURL: URL?
    }

    private let bytes: UnsafeBufferPointer<UInt8>
    private let base: UnsafePointer<UInt8>?
    private let byteCount: Int
    private let sink: XMLTVEventSink
    private let limits: XMLTVParseLimits
    private let cancellationCheck: @Sendable () throws -> Void
    private let timeParser = XMLTVTimeParser()

    private var pos = 0
    private var depth = 0
    private var rawChannelCount = 0
    private var rawProgrammeCount = 0
    private var rawEventCount = 0
    private var channelCount = 0
    private var programmeCount = 0

    private var openTagStack: [Range<Int>] = []
    private var channel: FastChannelState?
    private var programme: FastProgrammeState?
    private var activeTextElement: (kind: CapturedTextKind, depth: Int)?
    private var textBuffer: [UInt8] = []
    private var titleBuffer: [UInt8] = []
    private var textByteCount = 0
    private var scratchAttrBytes: [UInt8] = []

    init(
        bytes: UnsafeBufferPointer<UInt8>,
        sink: XMLTVEventSink,
        limits: XMLTVParseLimits,
        cancellationCheck: @escaping @Sendable () throws -> Void
    ) {
        self.bytes = bytes
        base = bytes.baseAddress
        byteCount = bytes.count
        self.sink = sink
        self.limits = limits
        self.cancellationCheck = cancellationCheck
        openTagStack.reserveCapacity(min(limits.maximumDepth + 1, 64))
        textBuffer.reserveCapacity(2_048)
        titleBuffer.reserveCapacity(256)
        scratchAttrBytes.reserveCapacity(256)
    }

    mutating func parse() throws -> XMLTVParseSummary {
        let end = bytes.count
        guard end > 0 else {
            throw FastPathEscalation.diagnoseSyntaxWithFoundation
        }

        // Check BOM: delegate UTF-16 BOMs to Foundation, skip UTF-8 BOM.
        if end >= 2, (bytes[0] == 0xFE && bytes[1] == 0xFF) || (bytes[0] == 0xFF && bytes[1] == 0xFE) {
            throw FastPathEscalation.delegateWholeParseToFoundation
        }
        if end >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            pos = 3
        }

        try skipPrologBeforeRootElement()
        try parseElementTree()
        try skipTrailingMiscAfterRootElement()

        return XMLTVParseSummary(
            channelCount: channelCount,
            programmeCount: programmeCount
        )
    }

    private mutating func skipPrologBeforeRootElement() throws {
        let end = bytes.count
        while pos < end {
            skipASCIIWhitespace()
            guard pos < end else {
                throw FastPathEscalation.diagnoseSyntaxWithFoundation
            }
            guard bytes[pos] == 0x3C else { // '<'
                throw FastPathEscalation.diagnoseSyntaxWithFoundation
            }
            guard pos + 1 < end else {
                throw FastPathEscalation.diagnoseSyntaxWithFoundation
            }
            let next = bytes[pos + 1]
            if next == 0x3F { // '<?'
                let piStart = pos + 2
                try advancePastProcessingInstruction()
                let piEnd = pos - 2
                if !isUTF8CompatibleXMLDeclaration(range: piStart..<piEnd) {
                    throw FastPathEscalation.delegateWholeParseToFoundation
                }
            } else if next == 0x21 { // '<!'
                if pos + 3 < end, bytes[pos + 2] == 0x2D, bytes[pos + 3] == 0x2D {
                    try advancePastComment()
                } else {
                    // <!DOCTYPE or <!ENTITY before any events are emitted: let Foundation handle it.
                    throw FastPathEscalation.delegateWholeParseToFoundation
                }
            } else {
                return
            }
        }
        throw FastPathEscalation.diagnoseSyntaxWithFoundation
    }

    private mutating func skipTrailingMiscAfterRootElement() throws {
        let end = bytes.count
        while pos < end {
            skipASCIIWhitespace()
            if pos >= end { return }
            guard bytes[pos] == 0x3C, pos + 1 < end else {
                throw FastPathEscalation.diagnoseSyntaxWithFoundation
            }
            let next = bytes[pos + 1]
            if next == 0x3F {
                try advancePastProcessingInstruction()
            } else if next == 0x21, pos + 3 < end, bytes[pos + 2] == 0x2D, bytes[pos + 3] == 0x2D {
                try advancePastComment()
            } else {
                throw FastPathEscalation.diagnoseSyntaxWithFoundation
            }
        }
    }

    private mutating func parseElementTree() throws {
        let end = bytes.count
        var attrNames: [Range<Int>] = []
        attrNames.reserveCapacity(8)

        while pos < end {
            if bytes[pos] == 0x3C { // '<'
                guard pos + 1 < end else {
                    throw FastPathEscalation.diagnoseSyntaxWithFoundation
                }
                let second = bytes[pos + 1]
                if second == 0x2F { // '</' end tag
                    pos += 2
                    let nameRange = try scanXMLName()
                    skipASCIIWhitespace()
                    guard pos < end, bytes[pos] == 0x3E else { // '>'
                        throw FastPathEscalation.diagnoseSyntaxWithFoundation
                    }
                    pos += 1
                    guard let expected = openTagStack.popLast(),
                          slicesEqual(expected, nameRange) else {
                        throw FastPathEscalation.diagnoseSyntaxWithFoundation
                    }
                    try handleEndElement(nameRange: nameRange)
                    if depth == 0 {
                        return
                    }
                } else if second == 0x21 { // '<!'
                    if pos + 3 < end, bytes[pos + 2] == 0x2D, bytes[pos + 3] == 0x2D {
                        try advancePastComment()
                    } else if pos + 8 < end,
                              bytes[pos + 2] == 0x5B, // '['
                              bytes[pos + 3] == 0x43, // 'C'
                              bytes[pos + 4] == 0x44, // 'D'
                              bytes[pos + 5] == 0x41, // 'A'
                              bytes[pos + 6] == 0x54, // 'T'
                              bytes[pos + 7] == 0x41, // 'A'
                              bytes[pos + 8] == 0x5B  // '['
                    {
                        guard depth >= 1 else {
                            throw FastPathEscalation.diagnoseSyntaxWithFoundation
                        }
                        pos += 9
                        let cdataStart = pos
                        let cdataEnd = try findCDATAClose()
                        try cancellationCheck()
                        try validateUTF8Slice(cdataStart..<cdataEnd)
                        if activeTextElement != nil {
                            try appendRawBytesToActiveText(cdataStart..<cdataEnd)
                        }
                    } else {
                        throw FastPathEscalation.diagnoseSyntaxWithFoundation
                    }
                } else if second == 0x3F { // '<?'
                    try advancePastProcessingInstruction()
                } else {
                    // Start tag '<name ...>' or '<name .../>'
                    pos += 1
                    let nameRange = try scanXMLName()
                    attrNames.removeAll(keepingCapacity: true)

                    var channelIDAttr: Range<Int>?
                    var progChannelAttr: Range<Int>?
                    var progStartAttr: Range<Int>?
                    var progStopAttr: Range<Int>?
                    var iconSrcAttr: Range<Int>?

                    let tagKind = classifyTag(nameRange)

                    var selfClosing = false
                    let ptr = base!
                    while true {
                        let wsStart = pos
                        while pos < end, Self.isASCIIWhitespace(ptr[pos]) { pos += 1 }
                        guard pos < end else {
                            throw FastPathEscalation.diagnoseSyntaxWithFoundation
                        }
                        let ch = ptr[pos]
                        if ch == 0x3E { // '>'
                            pos += 1
                            break
                        } else if ch == 0x2F { // '/>'
                            guard pos + 1 < end, ptr[pos + 1] == 0x3E else {
                                throw FastPathEscalation.diagnoseSyntaxWithFoundation
                            }
                            pos += 2
                            selfClosing = true
                            break
                        }
                        guard pos > wsStart else {
                            throw FastPathEscalation.diagnoseSyntaxWithFoundation
                        }
                        let attrName = try scanXMLName()
                        var dupIdx = 0
                        while dupIdx < attrNames.count {
                            if slicesEqual(attrNames[dupIdx], attrName) {
                                throw FastPathEscalation.diagnoseSyntaxWithFoundation
                            }
                            dupIdx += 1
                        }
                        attrNames.append(attrName)

                        while pos < end, Self.isASCIIWhitespace(ptr[pos]) { pos += 1 }
                        guard pos < end, ptr[pos] == 0x3D else { // '='
                            throw FastPathEscalation.diagnoseSyntaxWithFoundation
                        }
                        pos += 1
                        while pos < end, Self.isASCIIWhitespace(ptr[pos]) { pos += 1 }
                        guard pos < end else {
                            throw FastPathEscalation.diagnoseSyntaxWithFoundation
                        }
                        let quote = ptr[pos]
                        guard quote == 0x22 || quote == 0x27 else { // '"' or '\''
                            throw FastPathEscalation.diagnoseSyntaxWithFoundation
                        }
                        pos += 1
                        let valStart = pos
                        var valHasAmp = false
                        var valHasNonASCII = false
                        while pos < end {
                            let vb = ptr[pos]
                            if vb == quote { break }
                            if vb == 0x3C {
                                throw FastPathEscalation.diagnoseSyntaxWithFoundation
                            }
                            if vb == 0x26 {
                                valHasAmp = true
                            } else if vb >= 0x80 {
                                valHasNonASCII = true
                            } else if vb < 0x20, vb != 0x09, vb != 0x0A, vb != 0x0D {
                                throw FastPathEscalation.diagnoseSyntaxWithFoundation
                            }
                            pos += 1
                        }
                        guard pos < end else {
                            throw FastPathEscalation.diagnoseSyntaxWithFoundation
                        }
                        let valRange = valStart..<pos
                        pos += 1

                        if valHasAmp {
                            try validateEntitiesOnly(valRange)
                        }
                        if valHasNonASCII {
                            try validateUTF8Slice(valRange)
                        }

                        switch tagKind {
                        case .channel:
                            if sliceEqualsASCII(attrName, "id") { channelIDAttr = valRange }
                        case .programme:
                            if sliceEqualsASCII(attrName, "channel") { progChannelAttr = valRange }
                            else if sliceEqualsASCII(attrName, "start") { progStartAttr = valRange }
                            else if sliceEqualsASCII(attrName, "stop") { progStopAttr = valRange }
                        case .icon:
                            if sliceEqualsASCII(attrName, "src") { iconSrcAttr = valRange }
                        default:
                            break
                        }
                    }

                    // Check cancellation BEFORE mutating parser state, matching XMLTVDelegate.
                    try cancellationCheck()
                    depth += 1
                    guard depth <= limits.maximumDepth else {
                        throw XMLTVParserError.excessiveDepth
                    }

                    try handleStartElement(
                        tagKind: tagKind,
                        channelIDAttr: channelIDAttr,
                        progChannelAttr: progChannelAttr,
                        progStartAttr: progStartAttr,
                        progStopAttr: progStopAttr,
                        iconSrcAttr: iconSrcAttr
                    )

                    if selfClosing {
                        try handleEndElement(nameRange: nameRange)
                        if depth == 0 {
                            return
                        }
                    } else {
                        openTagStack.append(nameRange)
                    }
                }
            } else {
                // Character data between '>' and next '<'
                guard depth >= 1 else {
                    throw FastPathEscalation.diagnoseSyntaxWithFoundation
                }
                let textStart = pos
                let ptr = base!
                var hasAmpOrCR = false
                var hasNonASCII = false
                while pos < end, ptr[pos] != 0x3C {
                    let b = ptr[pos]
                    if b == 0x26 || b == 0x0D {
                        hasAmpOrCR = true
                    } else if b >= 0x80 {
                        hasNonASCII = true
                    } else if b == 0x5D, pos + 2 < end, ptr[pos + 1] == 0x5D, ptr[pos + 2] == 0x3E {
                        // Literal ']]>' is forbidden in XML character data
                        throw FastPathEscalation.diagnoseSyntaxWithFoundation
                    } else if b < 0x20, b != 0x09, b != 0x0A {
                        throw FastPathEscalation.diagnoseSyntaxWithFoundation
                    }
                    pos += 1
                }
                guard pos < end else {
                    throw FastPathEscalation.diagnoseSyntaxWithFoundation
                }
                let textRange = textStart..<pos
                if !textRange.isEmpty {
                    try cancellationCheck()
                    if hasNonASCII {
                        try validateUTF8Slice(textRange)
                    }
                    if activeTextElement != nil {
                        let skipDecode = (programme?.isPrunableExpired == true)
                            && (activeTextElement?.kind != .title)
                        if !hasAmpOrCR {
                            if skipDecode {
                                try recordSkippedTextBytes(textRange.count)
                            } else {
                                try appendRawBytesToActiveText(textRange)
                            }
                        } else {
                            try appendDecodedXMLText(textRange, normalizeWhitespaceToSpace: false, countOnly: skipDecode)
                        }
                    } else if hasAmpOrCR {
                        try validateEntitiesOnly(textRange)
                    }
                }
            }
        }
        throw FastPathEscalation.diagnoseSyntaxWithFoundation
    }

    private enum TagKind {
        case channel
        case programme
        case icon
        case displayName
        case title
        case subtitle
        case desc
        case category
        case other
    }

    @inline(__always)
    private func classifyTag(_ range: Range<Int>) -> TagKind {
        switch range.count {
        case 4:
            if sliceEqualsASCII(range, "desc") { return .desc }
            if sliceEqualsASCII(range, "icon") { return .icon }
            return .other
        case 5:
            if sliceEqualsASCII(range, "title") { return .title }
            return .other
        case 7:
            if sliceEqualsASCII(range, "channel") { return .channel }
            return .other
        case 8:
            if sliceEqualsASCII(range, "category") { return .category }
            return .other
        case 9:
            if sliceEqualsASCII(range, "programme") { return .programme }
            if sliceEqualsASCII(range, "sub-title") { return .subtitle }
            return .other
        case 12:
            if sliceEqualsASCII(range, "display-name") { return .displayName }
            return .other
        default:
            return .other
        }
    }

    private mutating func handleStartElement(
        tagKind: TagKind,
        channelIDAttr: Range<Int>?,
        progChannelAttr: Range<Int>?,
        progStartAttr: Range<Int>?,
        progStopAttr: Range<Int>?,
        iconSrcAttr: Range<Int>?
    ) throws {
        switch tagKind {
        case .channel:
            rawChannelCount += 1
            rawEventCount += 1
            guard rawChannelCount <= limits.maximumChannels else {
                throw XMLTVParserError.excessiveChannels
            }
            guard rawEventCount <= limits.maximumEvents else {
                throw XMLTVParserError.excessiveEvents
            }
            let id: String
            if let channelIDAttr {
                id = try decodeTrimmedString(attributeRange: channelIDAttr)
            } else {
                id = ""
            }
            channel = FastChannelState(id: id)

        case .programme:
            rawProgrammeCount += 1
            rawEventCount += 1
            guard rawProgrammeCount <= limits.maximumProgrammes else {
                throw XMLTVParserError.excessiveProgrammes
            }
            guard rawEventCount <= limits.maximumEvents else {
                throw XMLTVParserError.excessiveEvents
            }
            let startEpoch = try parseAttributeTimestamp(progStartAttr)
            let stopEpoch = try parseAttributeTimestamp(progStopAttr)
            let isPrunableExpired: Bool
            if let startEpoch, let stopEpoch, stopEpoch > startEpoch {
                isPrunableExpired = sink.shouldPruneHistoricalProgramme(
                    stop: Date(timeIntervalSince1970: TimeInterval(stopEpoch))
                )
            } else {
                isPrunableExpired = false
            }

            var cleanChannelSlice: Range<Int>?
            var decodedChannel: String?
            if let progChannelAttr {
                if let trimmed = cleanAttributeASCIITrimmedRange(progChannelAttr) {
                    if !trimmed.isEmpty {
                        cleanChannelSlice = trimmed
                    }
                } else {
                    let s = try decodeTrimmedString(attributeRange: progChannelAttr)
                    if !s.isEmpty {
                        decodedChannel = s
                    }
                }
            }

            titleBuffer.removeAll(keepingCapacity: true)
            programme = FastProgrammeState(
                channelRange: cleanChannelSlice,
                channelDecoded: decodedChannel,
                startEpoch: startEpoch,
                stopEpoch: stopEpoch,
                isPrunableExpired: isPrunableExpired
            )

        case .icon:
            guard let iconSrcAttr else { break }
            if channel != nil {
                let src = try decodeAttributeString(iconSrcAttr)
                channel?.iconURL = URL(string: src)
            } else if programme != nil, programme?.isPrunableExpired == false {
                let src = try decodeAttributeString(iconSrcAttr)
                programme?.iconURL = URL(string: src)
            }

        case .displayName where channel != nil:
            activeTextElement = (.displayName, depth)
            textBuffer.removeAll(keepingCapacity: true)
            textByteCount = 0

        case .title where programme != nil:
            activeTextElement = (.title, depth)
            textBuffer.removeAll(keepingCapacity: true)
            textByteCount = 0

        case .subtitle where programme != nil:
            activeTextElement = (.subtitle, depth)
            textBuffer.removeAll(keepingCapacity: true)
            textByteCount = 0

        case .desc where programme != nil:
            activeTextElement = (.desc, depth)
            textBuffer.removeAll(keepingCapacity: true)
            textByteCount = 0

        case .category where programme != nil:
            activeTextElement = (.category, depth)
            textBuffer.removeAll(keepingCapacity: true)
            textByteCount = 0

        default:
            break
        }
    }

    private mutating func handleEndElement(nameRange: Range<Int>) throws {
        let tagKind = classifyTag(nameRange)
        if let active = activeTextElement, active.depth == depth {
            switch active.kind {
            case .displayName:
                let value = trimmedStringFromTextBuffer()
                if !value.isEmpty {
                    channel?.displayNames.append(value)
                }
            case .title:
                populateTrimmedTitleBuffer()
                programme?.hasTitle = true
            case .subtitle:
                if programme?.isPrunableExpired == false {
                    let value = trimmedStringFromTextBuffer()
                    let normalized = value.isEmpty ? nil : value
                    programme?.subtitle = normalized
                }
            case .desc:
                if programme?.isPrunableExpired == false {
                    let value = trimmedStringFromTextBuffer()
                    let normalized = value.isEmpty ? nil : value
                    programme?.summary = normalized
                }
            case .category:
                if programme?.isPrunableExpired == false {
                    let value = trimmedStringFromTextBuffer()
                    if !value.isEmpty {
                        programme?.categories.append(value)
                    }
                }
            }
            activeTextElement = nil
            textBuffer.removeAll(keepingCapacity: true)
            textByteCount = 0
        }

        switch tagKind {
        case .channel:
            try emitChannel()
        case .programme:
            try emitProgramme()
        default:
            break
        }
        depth -= 1
    }

    private mutating func emitChannel() throws {
        guard let ch = channel else {
            throw XMLTVParserError.malformed
        }
        channel = nil
        guard !ch.id.isEmpty, !ch.displayNames.isEmpty else {
            throw XMLTVParserError.malformed
        }
        try cancellationCheck()
        try sink.accept(channel: EPGChannel(
            id: ch.id,
            displayNames: ch.displayNames,
            iconURL: ch.iconURL
        ))
        channelCount += 1
    }

    private mutating func emitProgramme() throws {
        guard let prog = programme else {
            throw XMLTVParserError.invalidProgramme
        }
        programme = nil

        guard prog.hasTitle, !titleBuffer.isEmpty,
              let startEpoch = prog.startEpoch,
              let stopEpoch = prog.stopEpoch,
              stopEpoch > startEpoch,
              (prog.channelRange != nil || prog.channelDecoded != nil) else {
            return
        }

        let startDate = Date(timeIntervalSince1970: TimeInterval(startEpoch))
        let stopDate = Date(timeIntervalSince1970: TimeInterval(stopEpoch))

        let ptr = base!
        let digest = titleBuffer.withUnsafeBufferPointer { titleBuf -> ProgrammeDigestKey in
            if let range = prog.channelRange {
                let channelBuf = UnsafeBufferPointer(start: ptr + range.lowerBound, count: range.count)
                return ProgrammeDigestKey(digest: ProgrammeStableID.makeDigest(
                    channelIDUTF8: channelBuf,
                    startEpochSeconds: startEpoch,
                    stopEpochSeconds: stopEpoch,
                    titleUTF8: titleBuf
                ))
            } else {
                var channelStr = prog.channelDecoded!
                return channelStr.withUTF8 { channelBuf in
                    ProgrammeDigestKey(digest: ProgrammeStableID.makeDigest(
                        channelIDUTF8: channelBuf,
                        startEpochSeconds: startEpoch,
                        stopEpochSeconds: stopEpoch,
                        titleUTF8: titleBuf
                    ))
                }
            }
        }

        try cancellationCheck()

        if prog.isPrunableExpired {
            try sink.recordExpiredProgramme(digest: digest, stop: stopDate)
            programmeCount += 1
            return
        }

        let channelID: String
        if let range = prog.channelRange {
            channelID = String(decoding: UnsafeBufferPointer(start: ptr + range.lowerBound, count: range.count), as: UTF8.self)
        } else {
            channelID = prog.channelDecoded!
        }
        let title = String(decoding: titleBuffer, as: UTF8.self)
        let id = Self.hexString(from: digest)

        let emitted = Programme(
            id: id,
            xmltvChannelID: channelID,
            start: startDate,
            stop: stopDate,
            title: title,
            subtitle: prog.subtitle,
            summary: prog.summary,
            categories: prog.categories
        )
        try sink.accept(programme: emitted, digest: digest)
        programmeCount += 1
    }

    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    private static func hexString(from key: ProgrammeDigestKey) -> String {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 64) { buffer in
            writeHexUInt64(key.a, to: buffer, offset: 0)
            writeHexUInt64(key.b, to: buffer, offset: 16)
            writeHexUInt64(key.c, to: buffer, offset: 32)
            writeHexUInt64(key.d, to: buffer, offset: 48)
            return String(decoding: UnsafeBufferPointer(buffer), as: UTF8.self)
        }
    }

    @inline(__always)
    private static func writeHexUInt64(
        _ value: UInt64,
        to buffer: UnsafeMutableBufferPointer<UInt8>,
        offset: Int
    ) {
        for i in 0..<8 {
            let byte = Int((value >> (56 - i * 8)) & 0xFF)
            buffer[offset + i * 2] = hexDigits[byte >> 4]
            buffer[offset + i * 2 + 1] = hexDigits[byte & 0x0F]
        }
    }

    private mutating func parseAttributeTimestamp(_ attrRange: Range<Int>?) throws -> Int64? {
        guard let attrRange else { return nil }
        if let cleanRange = cleanAttributeRawRange(attrRange) {
            let slice = UnsafeBufferPointer(rebasing: bytes[cleanRange])
            if let fast = XMLTVTimeParser.parseModernEpochSeconds(utf8: slice) {
                return fast
            }
            return try? timeParser.parseEpochSeconds(utf8: slice)
        }
        let decoded = try decodeAttributeString(attrRange)
        guard let date = try? timeParser.parse(decoded) else { return nil }
        return Int64(date.timeIntervalSince1970)
    }

    @inline(__always)
    private func cleanAttributeRawRange(_ range: Range<Int>) -> Range<Int>? {
        let ptr = base!
        var i = range.lowerBound
        let u = range.upperBound
        while i < u {
            let b = ptr[i]
            if b == 0x26 || b < 0x20 || b >= 0x80 { return nil }
            i += 1
        }
        return range
    }

    @inline(__always)
    private func cleanAttributeASCIITrimmedRange(_ range: Range<Int>) -> Range<Int>? {
        let ptr = base!
        var i = range.lowerBound
        let u = range.upperBound
        while i < u {
            let b = ptr[i]
            if b == 0x26 || b < 0x20 || b >= 0x80 { return nil }
            i += 1
        }
        var s = range.lowerBound
        var e = u
        while s < e, ptr[s] == 0x20 { s += 1 }
        while e > s, ptr[e - 1] == 0x20 { e -= 1 }
        return s..<e
    }

    private mutating func recordSkippedTextBytes(_ addedBytes: Int) throws {
        guard addedBytes <= limits.maximumTextBytes - textByteCount else {
            throw XMLTVParserError.excessiveText
        }
        textByteCount += addedBytes
    }

    private mutating func appendRawBytesToActiveText(_ range: Range<Int>) throws {
        let addedBytes = range.count
        guard addedBytes <= limits.maximumTextBytes - textByteCount else {
            throw XMLTVParserError.excessiveText
        }
        textBuffer.append(contentsOf: bytes[range])
        textByteCount += addedBytes
    }

    private mutating func appendDecodedXMLText(
        _ range: Range<Int>,
        normalizeWhitespaceToSpace: Bool,
        countOnly: Bool
    ) throws {
        var i = range.lowerBound
        let upper = range.upperBound
        while i < upper {
            let b = bytes[i]
            if b == 0x0D { // '\r' or '\r\n'
                if i + 1 < upper, bytes[i + 1] == 0x0A {
                    i += 2
                } else {
                    i += 1
                }
                let outByte: UInt8 = normalizeWhitespaceToSpace ? 0x20 : 0x0A
                try appendSingleDecodedByte(outByte, countOnly: countOnly)
            } else if normalizeWhitespaceToSpace, (b == 0x09 || b == 0x0A) {
                i += 1
                try appendSingleDecodedByte(0x20, countOnly: countOnly)
            } else if b == 0x26 { // '&'
                let scalar = try decodeEntity(at: &i, upper: upper)
                var utf8Tuple: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
                var scalarLen = 0
                for uByte in scalar.utf8 {
                    switch scalarLen {
                    case 0: utf8Tuple.0 = uByte
                    case 1: utf8Tuple.1 = uByte
                    case 2: utf8Tuple.2 = uByte
                    default: utf8Tuple.3 = uByte
                    }
                    scalarLen += 1
                }
                guard scalarLen <= limits.maximumTextBytes - textByteCount else {
                    throw XMLTVParserError.excessiveText
                }
                textByteCount += scalarLen
                if !countOnly {
                    if scalarLen >= 1 { textBuffer.append(utf8Tuple.0) }
                    if scalarLen >= 2 { textBuffer.append(utf8Tuple.1) }
                    if scalarLen >= 3 { textBuffer.append(utf8Tuple.2) }
                    if scalarLen == 4 { textBuffer.append(utf8Tuple.3) }
                }
            } else {
                let runStart = i
                i += 1
                while i < upper {
                    let nb = bytes[i]
                    if nb == 0x26 || nb == 0x0D || (normalizeWhitespaceToSpace && (nb == 0x09 || nb == 0x0A)) {
                        break
                    }
                    i += 1
                }
                let count = i - runStart
                guard count <= limits.maximumTextBytes - textByteCount else {
                    throw XMLTVParserError.excessiveText
                }
                textByteCount += count
                if !countOnly {
                    textBuffer.append(contentsOf: bytes[runStart..<i])
                }
            }
        }
    }

    @inline(__always)
    private mutating func appendSingleDecodedByte(_ byte: UInt8, countOnly: Bool) throws {
        guard 1 <= limits.maximumTextBytes - textByteCount else {
            throw XMLTVParserError.excessiveText
        }
        textByteCount += 1
        if !countOnly {
            textBuffer.append(byte)
        }
    }

    private func decodeEntity(at index: inout Int, upper: Int) throws -> UnicodeScalar {
        // index points at '&'
        let start = index + 1
        var semi = start
        while semi < upper, bytes[semi] != 0x3B { // ';'
            if semi - start > 12 {
                throw FastPathEscalation.diagnoseSyntaxWithFoundation
            }
            semi += 1
        }
        guard semi < upper, semi > start else {
            throw FastPathEscalation.diagnoseSyntaxWithFoundation
        }
        index = semi + 1
        let entityRange = start..<semi
        if sliceEqualsASCII(entityRange, "amp") { return UnicodeScalar(0x26)! }
        if sliceEqualsASCII(entityRange, "lt") { return UnicodeScalar(0x3C)! }
        if sliceEqualsASCII(entityRange, "gt") { return UnicodeScalar(0x3E)! }
        if sliceEqualsASCII(entityRange, "quot") { return UnicodeScalar(0x22)! }
        if sliceEqualsASCII(entityRange, "apos") { return UnicodeScalar(0x27)! }

        if bytes[start] == 0x23 { // '#'
            var codePoint: UInt32 = 0
            if start + 1 < semi, (bytes[start + 1] == 0x78 || bytes[start + 1] == 0x58) {
                let hexStart = start + 2
                guard hexStart < semi else {
                    throw FastPathEscalation.diagnoseSyntaxWithFoundation
                }
                for p in hexStart..<semi {
                    let b = bytes[p]
                    let digit: UInt32
                    if b >= 0x30, b <= 0x39 { digit = UInt32(b - 0x30) }
                    else if b >= 0x61, b <= 0x66 { digit = UInt32(b - 0x61 + 10) }
                    else if b >= 0x41, b <= 0x46 { digit = UInt32(b - 0x41 + 10) }
                    else { throw FastPathEscalation.diagnoseSyntaxWithFoundation }
                    let (mul, o1) = codePoint.multipliedReportingOverflow(by: 16)
                    let (add, o2) = mul.addingReportingOverflow(digit)
                    guard !o1, !o2, add <= 0x10FFFF else {
                        throw FastPathEscalation.diagnoseSyntaxWithFoundation
                    }
                    codePoint = add
                }
            } else {
                let decStart = start + 1
                guard decStart < semi else {
                    throw FastPathEscalation.diagnoseSyntaxWithFoundation
                }
                for p in decStart..<semi {
                    let b = bytes[p]
                    guard b >= 0x30, b <= 0x39 else {
                        throw FastPathEscalation.diagnoseSyntaxWithFoundation
                    }
                    let (mul, o1) = codePoint.multipliedReportingOverflow(by: 10)
                    let (add, o2) = mul.addingReportingOverflow(UInt32(b - 0x30))
                    guard !o1, !o2, add <= 0x10FFFF else {
                        throw FastPathEscalation.diagnoseSyntaxWithFoundation
                    }
                    codePoint = add
                }
            }
            guard isValidXMLCodePoint(codePoint), let scalar = UnicodeScalar(codePoint) else {
                throw FastPathEscalation.diagnoseSyntaxWithFoundation
            }
            return scalar
        }

        throw FastPathEscalation.diagnoseSyntaxWithFoundation
    }

    @inline(__always)
    private func isValidXMLCodePoint(_ cp: UInt32) -> Bool {
        cp == 0x9 || cp == 0xA || cp == 0xD
            || (0x20...0xD7FF).contains(cp)
            || (0xE000...0xFFFD).contains(cp)
            || (0x10000...0x10FFFF).contains(cp)
    }

    private func validateEntitiesOnly(_ range: Range<Int>) throws {
        let ptr = base!
        var i = range.lowerBound
        let upper = range.upperBound
        while i < upper {
            if ptr[i] == 0x26 {
                _ = try decodeEntity(at: &i, upper: upper)
            } else {
                i += 1
            }
        }
    }

    private mutating func decodeAttributeString(_ range: Range<Int>) throws -> String {
        var needsNormalize = false
        for i in range {
            let b = bytes[i]
            if b == 0x26 || b == 0x09 || b == 0x0A || b == 0x0D {
                needsNormalize = true
                break
            }
        }
        if !needsNormalize {
            return String(decoding: bytes[range], as: UTF8.self)
        }
        scratchAttrBytes.removeAll(keepingCapacity: true)
        var i = range.lowerBound
        let upper = range.upperBound
        while i < upper {
            let b = bytes[i]
            if b == 0x0D {
                if i + 1 < upper, bytes[i + 1] == 0x0A { i += 2 } else { i += 1 }
                scratchAttrBytes.append(0x20)
            } else if b == 0x09 || b == 0x0A {
                i += 1
                scratchAttrBytes.append(0x20)
            } else if b == 0x26 {
                let scalar = try decodeEntity(at: &i, upper: upper)
                scratchAttrBytes.append(contentsOf: scalar.utf8)
            } else {
                scratchAttrBytes.append(b)
                i += 1
            }
        }
        return String(decoding: scratchAttrBytes, as: UTF8.self)
    }

    private mutating func decodeTrimmedString(attributeRange: Range<Int>) throws -> String {
        if let clean = cleanAttributeASCIITrimmedRange(attributeRange) {
            return String(decoding: bytes[clean], as: UTF8.self)
        }
        let decoded = try decodeAttributeString(attributeRange)
        return Self.trimWhitespaceAndNewlines(decoded)
    }

    private mutating func populateTrimmedTitleBuffer() {
        titleBuffer.removeAll(keepingCapacity: true)
        var s = 0
        var e = textBuffer.count
        while s < e, Self.isASCIIWhitespace(textBuffer[s]) { s += 1 }
        while e > s, Self.isASCIIWhitespace(textBuffer[e - 1]) { e -= 1 }
        guard s < e else { return }
        if textBuffer[s] < 0x80, textBuffer[e - 1] < 0x80 {
            titleBuffer.append(contentsOf: textBuffer[s..<e])
            return
        }
        let trimmed = String(decoding: textBuffer[s..<e], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        titleBuffer.append(contentsOf: trimmed.utf8)
    }

    private func trimmedStringFromTextBuffer() -> String {
        var s = 0
        var e = textBuffer.count
        while s < e, Self.isASCIIWhitespace(textBuffer[s]) { s += 1 }
        while e > s, Self.isASCIIWhitespace(textBuffer[e - 1]) { e -= 1 }
        guard s < e else { return "" }
        let decoded = String(decoding: textBuffer[s..<e], as: UTF8.self)
        if textBuffer[s] < 0x80, textBuffer[e - 1] < 0x80 {
            return decoded
        }
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimWhitespaceAndNewlines(_ value: String) -> String {
        let utf8 = value.utf8
        guard let first = utf8.first, let last = utf8.last else { return value }
        if (0x21...0x7E).contains(first), (0x21...0x7E).contains(last) {
            return value
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validateUTF8Slice(_ range: Range<Int>) throws {
        guard !range.isEmpty else { return }
        let slice = UnsafeBufferPointer(rebasing: bytes[range])
        guard String(validating: slice, as: UTF8.self) != nil else {
            throw FastPathEscalation.diagnoseSyntaxWithFoundation
        }
    }

    private func isUTF8CompatibleXMLDeclaration(range: Range<Int>) -> Bool {
        let slice = String(decoding: bytes[range], as: UTF8.self).lowercased()
        guard let encRange = slice.range(of: "encoding") else { return true }
        var rest = slice[encRange.upperBound...].drop(while: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" })
        guard rest.first == "=" else { return true }
        rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" })
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return false }
        rest = rest.dropFirst()
        guard let endQuote = rest.firstIndex(of: quote) else { return false }
        let encoding = rest[..<endQuote]
        return encoding == "utf-8" || encoding == "utf8" || encoding == "us-ascii" || encoding == "ascii"
    }

    private mutating func advancePastComment() throws {
        // Assumes bytes[pos..<pos+4] == "<!--"
        let end = bytes.count
        pos += 4
        while pos + 2 < end {
            if bytes[pos] == 0x2D, bytes[pos + 1] == 0x2D {
                guard bytes[pos + 2] == 0x3E else {
                    // '--' is forbidden inside XML comments unless immediately followed by '>'
                    throw FastPathEscalation.diagnoseSyntaxWithFoundation
                }
                pos += 3
                return
            }
            pos += 1
        }
        throw FastPathEscalation.diagnoseSyntaxWithFoundation
    }

    private mutating func advancePastProcessingInstruction() throws {
        // Assumes bytes[pos..<pos+2] == "<?"
        let end = bytes.count
        pos += 2
        guard pos < end, Self.isNameStartByte(bytes[pos]) else {
            throw FastPathEscalation.diagnoseSyntaxWithFoundation
        }
        while pos + 1 < end {
            if bytes[pos] == 0x3F, bytes[pos + 1] == 0x3E { // '?>'
                pos += 2
                return
            }
            pos += 1
        }
        throw FastPathEscalation.diagnoseSyntaxWithFoundation
    }

    private mutating func findCDATAClose() throws -> Int {
        let end = bytes.count
        while pos + 2 < end {
            if bytes[pos] == 0x5D, bytes[pos + 1] == 0x5D, bytes[pos + 2] == 0x3E {
                let contentEnd = pos
                pos += 3
                return contentEnd
            }
            pos += 1
        }
        throw FastPathEscalation.diagnoseSyntaxWithFoundation
    }

    private mutating func scanXMLName() throws -> Range<Int> {
        let end = byteCount
        let ptr = base!
        guard pos < end, Self.isNameStartByte(ptr[pos]) else {
            throw FastPathEscalation.diagnoseSyntaxWithFoundation
        }
        let start = pos
        var hasNonASCII = ptr[pos] >= 0x80
        pos += 1
        while pos < end, Self.isNameContinueByte(ptr[pos]) {
            if ptr[pos] >= 0x80 { hasNonASCII = true }
            pos += 1
        }
        if hasNonASCII {
            try validateUTF8Slice(start..<pos)
        }
        return start..<pos
    }

    @inline(__always)
    private mutating func skipASCIIWhitespace() {
        let end = byteCount
        guard let ptr = base else { return }
        while pos < end, Self.isASCIIWhitespace(ptr[pos]) {
            pos += 1
        }
    }

    @inline(__always)
    private static func isASCIIWhitespace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
    }

    @inline(__always)
    private static func isNameStartByte(_ b: UInt8) -> Bool {
        (b >= 0x61 && b <= 0x7A) // a-z
            || (b >= 0x41 && b <= 0x5A) // A-Z
            || b == 0x5F || b == 0x3A // '_' or ':'
            || b >= 0x80
    }

    @inline(__always)
    private static func isNameContinueByte(_ b: UInt8) -> Bool {
        isNameStartByte(b)
            || (b >= 0x30 && b <= 0x39) // 0-9
            || b == 0x2D || b == 0x2E // '-' or '.'
    }

    @inline(__always)
    private func slicesEqual(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Bool {
        let count = lhs.count
        guard count == rhs.count else { return false }
        let ptr = base!
        return memcmp(ptr + lhs.lowerBound, ptr + rhs.lowerBound, count) == 0
    }

    @inline(__always)
    private func sliceEqualsASCII(_ range: Range<Int>, _ ascii: StaticString) -> Bool {
        let count = range.count
        guard count == ascii.utf8CodeUnitCount else { return false }
        let ptr = base!
        return memcmp(ptr + range.lowerBound, ascii.utf8Start, count) == 0
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
            acceptText(Self.trimmedWhitespaceAndNewlines(text), for: elementName)
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
        let digestKey: ProgrammeDigestKey
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
            let digest = ProgrammeStableID.makeDigest(
                channelID: channelID,
                startEpochSeconds: Int64(start.timeIntervalSince1970),
                stopEpochSeconds: Int64(stop.timeIntervalSince1970),
                title: title
            )
            digestKey = ProgrammeDigestKey(digest: digest)
            let id = ProgrammeStableID.hexString(for: digest)
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
            if sink.shouldPruneHistoricalProgramme(stop: emittedProgramme.stop) {
                try sink.recordExpiredProgramme(digest: digestKey, stop: emittedProgramme.stop)
            } else {
                try sink.accept(programme: emittedProgramme, digest: digestKey)
            }
            programmeCount += 1
        } catch {
            fail(error, parser: parser)
        }
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = Self.trimmedWhitespaceAndNewlines(value)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func trimmedWhitespaceAndNewlines(_ value: String) -> String {
        let utf8 = value.utf8
        guard let first = utf8.first, let last = utf8.last else { return value }
        if (0x21...0x7E).contains(first), (0x21...0x7E).contains(last) {
            return value
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
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
