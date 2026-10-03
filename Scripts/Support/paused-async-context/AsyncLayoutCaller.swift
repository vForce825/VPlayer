// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import AsyncLayoutControls

// A separate module with no @inlinable definitions prevents Release from
// replacing the imported descriptor loads with locally known frame constants.
@inline(never)
public func callSmall(_ operation: @Sendable (inout SmallState) async -> Void) async -> UInt64 {
    let result = await controlSmall(operation)
    return result &+ 1
}

@inline(never)
public func callWide(_ operation: @Sendable (inout WideState) async -> Void) async -> UInt64 {
    let result = await controlWide(operation)
    return result &+ 1
}

@inline(never)
public func callContinuation(
    _ register: @Sendable (CheckedContinuation<Void, any Error>) -> Void,
    onCancel: @escaping @Sendable () -> Void
) async throws -> UInt64 {
    try await controlContinuation(register, onCancel: onCancel)
    return 1
}
