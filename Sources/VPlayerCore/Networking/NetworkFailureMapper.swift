// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Darwin
import Foundation
import Network
import ObjectiveC

/// 只保存固定容量的诊断文本，不延长原始错误及其 userInfo 的生命周期。
public struct ErrorDiagnosticSnapshot: Error, Equatable, Sendable, CustomStringConvertible {
    private let storage: Storage

    public var typeName: String { storage.bytes.text(in: 0..<128) }
    public var summary: String { "\(typeName)：\(storage.bytes.text(in: 128..<384))" }
    public var description: String { summary }
    public static var maximumStorageAllocationBytes: Int {
        malloc_good_size(class_getInstanceSize(Storage.self))
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.storage === rhs.storage || lhs.storage.bytes == rhs.storage.bytes
    }

    public init(typeName: String, code: String? = nil, message: String) {
        var bytes = InlineBytes()
        bytes.store(Self.sanitized(typeName), in: 0..<128)
        let boundedMessage = String(message.prefix(512))
        let detail = code.map { "\(String($0.prefix(64)))：\(boundedMessage)" } ?? boundedMessage
        bytes.store(Self.sanitized(detail), in: 128..<384)
        storage = Storage(bytes: bytes)
    }

    public init(_ error: any Error) {
        if let snapshot = error as? Self {
            self = snapshot
            return
        }
        let name = String(reflecting: type(of: error))
        var current: any Error = error
        var visited = Set<ObjectIdentifier>()
        var details = ""
        // 原始错误加最多三层底层错误；循环引用也不能延长遍历。
        for depth in 0..<4 {
            let system = current as NSError
            guard visited.insert(ObjectIdentifier(system)).inserted else { break }
            let reason: String
            if let localized = current as? any LocalizedError,
               let message = localized.errorDescription {
                reason = String(message.prefix(512))
            } else if let message = system.userInfo[NSLocalizedDescriptionKey] as? String {
                reason = String(message.prefix(512))
            } else if type(of: current) is NSError.Type {
                reason = "系统未提供原始错误说明"
            } else {
                reason = String(String(describing: current).prefix(512))
            }
            let prefix = depth == 0 ? "" : "；底层 \(String(String(reflecting: type(of: current)).prefix(64)))："
            details += Self.sanitized("\(prefix)\(Self.boundedDomain(system))(\(system.code))：\(reason)")
            if details.utf8.count >= 256 { break }
            if let underlying = system.userInfo[NSUnderlyingErrorKey] as? any Error {
                current = underlying
            } else if let underlying = (system.userInfo[NSMultipleUnderlyingErrorsKey] as? [any Error])?.first {
                current = underlying
            } else {
                break
            }
        }
        self.init(typeName: name, message: details)
    }

    private static func boundedDomain(_ error: NSError) -> String {
        // 借用公开 Objective-C getter 的 NSString，先截取再桥接，避免复制巨型 domain。
        let selector = #selector(getter: NSError.domain)
        guard error.responds(to: selector),
              let domain = error.perform(selector)?.takeUnretainedValue() as? NSString else { return "unknown" }
        let source = domain.substring(to: min(domain.length, 96))
        var result = ""
        var byteCount = 0
        for scalar in source.unicodeScalars {
            let character = String(scalar)
            guard byteCount + character.utf8.count <= 96 else { break }
            result += character
            byteCount += character.utf8.count
        }
        return result
    }

    private static func sanitized(_ raw: String) -> String {
        var text = String(raw.prefix(2_048))
        // 地址及凭据可以出现在自定义错误原文中，不能只过滤 NSError 的 URL 字段。
        let replacements: [(String, String)] = [
            (#"(?i)[a-z][a-z0-9+.-]*://[^\s\"'<>，。；）]+"#, "（地址已隐藏）"),
            (#"(?i)\b(?:token|access_token|api_key|password|passwd|secret|authorization)\s*[:=]\s*[^\s,;，；]+"#, "（凭据已隐藏）"),
            (#"(?:~?/|[A-Za-z]:[\\/])[^\s\"'<>，。；）]+"#, "（路径已隐藏）"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?\b|\[[0-9A-Fa-f:]+(?:%[^\]]+)?\]"#, "（地址已隐藏）"),
            (#"[\x00-\x1F\x7F]+"#, " ")
        ]
        for (pattern, replacement) in replacements {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text
    }

    /// 同一个快照在控制票据中复制时共享固定容量文本，避免扩大每个枚举的内联尺寸。
    private final class Storage: Sendable {
        let bytes: InlineBytes
        init(bytes: InlineBytes) { self.bytes = bytes }
    }

    private struct InlineBytes: Equatable, Sendable {
        private var block0 = SIMD64<UInt8>(repeating: 0)
        private var block1 = SIMD64<UInt8>(repeating: 0)
        private var block2 = SIMD64<UInt8>(repeating: 0)
        private var block3 = SIMD64<UInt8>(repeating: 0)
        private var block4 = SIMD64<UInt8>(repeating: 0)
        private var block5 = SIMD64<UInt8>(repeating: 0)

        mutating func store(_ text: String, in range: Range<Int>) {
            var index = range.lowerBound
            // 按 Unicode 标量裁剪，避免截断 UTF-8 后生成替换字符。
            for scalar in text.unicodeScalars {
                let bytes = String(scalar).utf8
                guard index + bytes.count <= range.upperBound else { break }
                for byte in bytes {
                    self[index] = byte
                    index += 1
                }
            }
        }

        func text(in range: Range<Int>) -> String {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(range.count)
            for index in range {
                let byte = self[index]
                guard byte != 0 else { break }
                bytes.append(byte)
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        private subscript(index: Int) -> UInt8 {
            get {
                switch index / 64 {
                case 0: block0[index % 64]
                case 1: block1[index % 64]
                case 2: block2[index % 64]
                case 3: block3[index % 64]
                case 4: block4[index % 64]
                default: block5[index % 64]
                }
            }
            set {
                switch index / 64 {
                case 0: block0[index % 64] = newValue
                case 1: block1[index % 64] = newValue
                case 2: block2[index % 64] = newValue
                case 3: block3[index % 64] = newValue
                case 4: block4[index % 64] = newValue
                default: block5[index % 64] = newValue
                }
            }
        }
    }
}

public struct NetworkFailure: Error, Equatable, Sendable {
    public let code: String
    public let message: String
    public let diagnostic: ErrorDiagnosticSnapshot?

    public var userMessage: String { message }

    public init(code: String, message: String, diagnostic: ErrorDiagnosticSnapshot? = nil) {
        self.code = code
        self.diagnostic = diagnostic
        self.message = diagnostic.map { "\(message)\n\($0.summary)" } ?? message
    }
}

public enum NetworkFailureMapper {
    public static func map(_ error: any Error, for url: URL) -> NetworkFailure {
        let diagnostic = ErrorDiagnosticSnapshot(error)
        if isLocalHost(url.host), containsPermissionDenial(error) {
            return NetworkFailure(
                code: "network.localPermissionDenied",
                message: "本地网络访问被系统拒绝，请在“设置”中允许 VPlayer 访问本地网络后重试。",
                diagnostic: diagnostic
            )
        }
        var current: any Error = error
        for _ in 0..<4 {
            if current is CancellationError {
                return .init(code: "network.cancelled", message: "网络请求已取消。", diagnostic: diagnostic)
            }
            if let network = current as? NWError {
                switch network {
                case .dns:
                    return .init(code: "network.dns", message: "服务器域名解析失败。", diagnostic: diagnostic)
                case .tls:
                    return .init(code: "network.tls", message: "安全连接握手失败。", diagnostic: diagnostic)
                case .posix(let code):
                    if let cause = posixFailure(code: Int(code.rawValue)) {
                        return .init(code: cause.0, message: cause.1, diagnostic: diagnostic)
                    }
                default:
                    break
                }
            }
            let system = current as NSError
            if system.domain == NSURLErrorDomain,
               let cause = urlFailure(code: URLError.Code(rawValue: system.code)) {
                return .init(code: cause.0, message: cause.1, diagnostic: diagnostic)
            }
            if system.domain == NSPOSIXErrorDomain, let cause = posixFailure(code: system.code) {
                return .init(code: cause.0, message: cause.1, diagnostic: diagnostic)
            }
            guard let underlying = system.userInfo[NSUnderlyingErrorKey] as? any Error else { break }
            current = underlying
        }
        return NetworkFailure(
            code: "network.unknown",
            message: "网络请求发生未识别错误。",
            diagnostic: diagnostic
        )
    }

    static func isNetworkError(_ error: any Error) -> Bool {
        var current: any Error = error
        for _ in 0..<4 {
            let system = current as NSError
            if current is URLError || current is NWError || system.domain == NSURLErrorDomain {
                return true
            }
            if system.domain == NSPOSIXErrorDomain, posixFailure(code: system.code) != nil {
                return true
            }
            guard let underlying = system.userInfo[NSUnderlyingErrorKey] as? any Error else { break }
            current = underlying
        }
        return false
    }

    private static func urlFailure(code: URLError.Code) -> (String, String)? {
        switch code {
        case .timedOut: ("network.timeout", "连接服务器超时。")
        case .cannotFindHost: ("network.dns", "找不到服务器域名。")
        case .dnsLookupFailed: ("network.dns", "服务器域名解析失败。")
        case .cannotConnectToHost: ("network.connectionFailed", "无法建立服务器连接。")
        case .networkConnectionLost: ("network.connectionFailed", "服务器连接已中断。")
        case .notConnectedToInternet: ("network.offline", "设备当前未连接到网络。")
        case .dataNotAllowed: ("network.offline", "系统不允许当前网络传输数据。")
        case .secureConnectionFailed: ("network.tls", "安全连接握手失败。")
        case .serverCertificateHasBadDate: ("network.tls", "服务器证书尚未生效或已过期。")
        case .serverCertificateUntrusted: ("network.tls", "服务器证书不受信任。")
        case .serverCertificateHasUnknownRoot: ("network.tls", "服务器证书的根证书无法验证。")
        case .serverCertificateNotYetValid: ("network.tls", "服务器证书尚未生效。")
        case .clientCertificateRejected: ("network.tls", "服务器拒绝了客户端证书。")
        case .clientCertificateRequired: ("network.tls", "服务器要求提供客户端证书。")
        case .cancelled: ("network.cancelled", "网络请求已取消。")
        case .badURL: ("network.url.invalid", "请求地址无效。")
        case .unsupportedURL: ("network.url.unsupported", "请求地址使用了不支持的协议。")
        case .userAuthenticationRequired: ("network.authentication", "服务器要求身份验证。")
        case .userCancelledAuthentication: ("network.authentication.cancelled", "服务器身份验证已取消。")
        case .badServerResponse: ("network.response.invalid", "服务器响应无效。")
        case .cannotDecodeRawData: ("network.response.decode", "无法解码服务器返回的原始数据。")
        case .cannotDecodeContentData: ("network.response.decode", "无法解码服务器返回的内容。")
        case .cannotParseResponse: ("network.response.parse", "无法解析服务器响应。")
        default: nil
        }
    }

    private static func posixFailure(code: Int) -> (String, String)? {
        switch Int32(clamping: code) {
        case ETIMEDOUT: ("network.timeout", "服务器连接超时。")
        case ENETDOWN: ("network.offline", "网络接口不可用。")
        case ENETUNREACH: ("network.offline", "无法到达服务器所在网络。")
        case EHOSTUNREACH: ("network.connectionFailed", "无法到达服务器。")
        case ECONNREFUSED: ("network.connectionFailed", "服务器拒绝连接。")
        case ECONNRESET: ("network.connectionFailed", "服务器重置了连接。")
        case ECONNABORTED: ("network.connectionFailed", "服务器连接已被中止。")
        case EPERM, EACCES: ("network.connectionFailed", "系统拒绝了服务器连接。")
        default: nil
        }
    }

    public static func map(_ error: any Error, url: URL) -> NetworkFailure {
        map(error, for: url)
    }

    private static func containsPermissionDenial(_ error: any Error) -> Bool {
        var pending: [any Error] = [error]
        var visited = Set<ObjectIdentifier>()

        var examined = 0
        while examined < 16, let current = pending.popLast() {
            examined += 1
            let nsError = current as NSError
            let identity = ObjectIdentifier(nsError)
            guard visited.insert(identity).inserted else { continue }

            if nsError.domain == NSPOSIXErrorDomain,
               nsError.code == Int(EPERM) || nsError.code == Int(EACCES) {
                return true
            }
            if let networkError = current as? NWError {
                switch networkError {
                case let .posix(code) where code == .EPERM || code == .EACCES:
                    return true
                case let .dns(code) where code == -65_570:
                    return true
                default:
                    break
                }
            }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? any Error {
                pending.append(underlying)
            }
            if let multiple = nsError.userInfo[NSMultipleUnderlyingErrorsKey] as? [any Error] {
                pending.append(contentsOf: multiple.prefix(16 - examined))
            }
        }
        return false
    }

    private static func isLocalHost(_ rawHost: String?) -> Bool {
        guard var host = rawHost?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        while host.hasSuffix(".") { host.removeLast() }
        if let zoneIndex = host.firstIndex(of: "%") {
            host = String(host[..<zoneIndex])
        }

        if !host.contains(".") && !host.contains(":") {
            return true
        }
        if [".local", ".lan", ".router", ".home.arpa"].contains(where: host.hasSuffix) {
            return true
        }
        return isLocalIPv4(host) || isLocalIPv6(host)
    }

    private static func isLocalIPv4(_ host: String) -> Bool {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { return false }
        return withUnsafeBytes(of: &address) { bytes in
            let first = bytes[0]
            let second = bytes[1]
            return first == 10
                || first == 127
                || first == 169 && second == 254
                || first == 172 && (16...31).contains(second)
                || first == 192 && second == 168
        }
    }

    private static func isLocalIPv6(_ host: String) -> Bool {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return false }
        return withUnsafeBytes(of: &address) { bytes in
            let loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let linkLocal = bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80
            return loopback || linkLocal
        }
    }
}
