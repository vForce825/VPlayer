// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

// Compile-only controls. Never linked into the app or used as runtime evidence.
// Inout escape across an opaque await prevents replacing wide state with a
// precomputed checksum. The validator still requires a larger observed frame.
@frozen public struct SmallState: Sendable {
    public var word: UInt64 = 0
    public init() {}
}

@frozen public struct WideState: Sendable {
    public var a: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) = (0,0,0,0,0,0,0,0)
    public var b: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) = (0,0,0,0,0,0,0,0)
    public var c: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) = (0,0,0,0,0,0,0,0)
    public var d: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64) = (0,0,0,0,0,0,0,0)
    public init() {}
}

@inline(never)
public func controlSmall(_ operation: @Sendable (inout SmallState) async -> Void) async -> UInt64 {
    var state = SmallState()
    await operation(&state)
    return state.word
}

@inline(never)
public func controlWide(_ operation: @Sendable (inout WideState) async -> Void) async -> UInt64 {
    var state = WideState()
    await operation(&state)
    // Every byte was accessible to operation; the full mutable aggregate must
    // survive suspension even if only these selected results are returned.
    return state.a.0 &+ state.b.7 &+ state.c.0 &+ state.d.7
}

@inline(never)
public func controlContinuation(
    _ register: @Sendable (CheckedContinuation<Void, any Error>) -> Void,
    onCancel: @escaping @Sendable () -> Void
) async throws {
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            register(continuation)
        }
    } onCancel: {
        onCancel()
    }
}
