// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Darwin
import Foundation
import Network

public struct NetworkFailure: Error, Equatable, Sendable {
    public let code: String
    public let message: String

    public var userMessage: String { message }

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public enum NetworkFailureMapper {
    public static func map(_ error: any Error, for url: URL) -> NetworkFailure {
        if isLocalHost(url.host), containsPermissionDenial(error) {
            return NetworkFailure(
                code: "network.localPermissionDenied",
                message: "请在“设置”中允许 VPlayer 访问本地网络后重试。"
            )
        }
        return NetworkFailure(
            code: "network.connectionFailed",
            message: "无法连接到服务器，请检查网络后重试。"
        )
    }

    public static func map(_ error: any Error, url: URL) -> NetworkFailure {
        map(error, for: url)
    }

    private static func containsPermissionDenial(_ error: any Error) -> Bool {
        var pending: [any Error] = [error]
        var visited = Set<ObjectIdentifier>()

        while let current = pending.popLast() {
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
                pending.append(contentsOf: multiple)
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
