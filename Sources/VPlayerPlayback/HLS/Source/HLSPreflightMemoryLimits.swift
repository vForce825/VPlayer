// SPDX-FileCopyrightText: 2026 VPlayer contributors
// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.

import Foundation

/// Conservative application-ledger admission charges, separate from serialized
/// byte limits. These are not measurements of process RSS or SDK allocator sizes.
/// Context construction owns contextRetention. The admitted prepare owner reserves
/// the other charges BEFORE calling resolve/inspect; it must not charge context twice.
public enum HLSPreflightMemoryLimits {
    public static let contextRetention = 256 * 1_024
    public static let sourceRetention = 64 * 1_024 * 1_024
    public static let resolverTemporary = 16 * 1_024 * 1_024
    public static let probeTemporary = 64 * 1_024 * 1_024
    public static let factsRetention = 4 * 1_024 * 1_024
    public static let maximumRetainedAudioConfigurationBytes = 1_024 * 1_024

    // contextRetention: reserved by SourceContextCharge before backing construction;
    // released at final request/context/header alias, independently of backend life.
    // sourceRetention: raw graph (4 MiB), bounded parsed attributes/references,
    // URL representations/aliases and metadata; until source/graph/proxy retire.
    // resolverTemporary: only after resolve returns/throws AND cancelled I/O joins.
    // probeTemporary: unique I/O/plaintext/assembly (8 MiB admission), Swift parsing
    // copies, <=8 admitted native tracks, <=1 fixed-table AVC parser (no HEVC
    // native parser/CTB maps), 4 MiB aggregate metadata expansion and bounded
    // packets/BSF storage: BMFF coded AU <=1 MiB, converted AU <=1 MiB+64 KiB;
    // TS emitted chunks remain <=256 KiB and all parser input <=8 MiB. Only SPS
    // header bytes (<=256 KiB) are copied for video facts, never a large AU.
    // No stream-info or video decoding. After demux cleanup,
    // one ADTS-only AAC format decoder uses <=48 MiB audited fixed workspace,
    // <=8 AUs/64 KiB and <=1 MiB cumulative gated output. No decoder overlap;
    // all other explicit formats remain parser-only. Retires after all cleanup.
    // factsRetention: up to 128 media fact sets, 32 tracks each, <=1 MiB of copied
    // audio configurations, video digests and plan fingerprints; final reference.
    // An externally retained preflight/proxy cache has its OWN reservation for its
    // admitted bytes; returning from inspect does not retire that external owner.
}
