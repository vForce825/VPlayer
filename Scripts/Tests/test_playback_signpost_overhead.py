#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 VPlayer contributors
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileComment: Apple App Store distribution is additionally permitted by LICENSE.APPSTORE-EXCEPTION.
"""Guard inactive signpost cost in Apple-only playback hot paths."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
PLAYBACK = ROOT / "Sources/VPlayerPlayback"


class PlaybackSignpostOverheadTests(unittest.TestCase):
    def test_inactive_begin_returns_before_correlation_hash_or_signpost_id(self):
        source = (PLAYBACK / "Diagnostics/PlaybackSignposts.swift").read_text()
        begin = source.split("    func begin(", 1)[1].split("    func end(", 1)[0]
        guard = "guard signposter.isEnabled else { return nil }"
        self.assertIn(guard, begin)
        self.assertLess(begin.index(guard), begin.index("signposter.makeSignpostID()"))
        self.assertLess(begin.index(guard), begin.index("PlaybackDiagnosticsCorrelationID("))

    def test_async_hotpaths_do_not_allocate_an_inactive_lifetime(self):
        paths = (
            "Video/VideoToolboxDecoder.swift",
            "Deinterlace/YADIF/YADIFProcessor.swift",
            "Deinterlace/VideoPipelineCoordinator.swift",
        )
        for path in paths:
            with self.subTest(path=path):
                source = (PLAYBACK / path).read_text()
                self.assertNotIn("PlaybackSignpostLifetime(", source)
                self.assertIn("signposts?.beginLifetime(", source)
        source = (PLAYBACK / "Diagnostics/PlaybackSignposts.swift").read_text()
        self.assertIn("    func beginLifetime(", source)
        lifetime = source.split("    func beginLifetime(", 1)[1].split("    func end(", 1)[0]
        self.assertLess(
            lifetime.index("guard let token = begin(span, correlation: correlation) else { return nil }"),
            lifetime.index("PlaybackSignpostLifetime {"),
        )

    def test_production_factory_omits_signposts_without_diagnostic_build_flag(self):
        source = (PLAYBACK / "Diagnostics/PlaybackSignposts.swift").read_text()
        self.assertIn("    static func makeForCurrentBuild(", source)
        factory = source.split("    static func makeForCurrentBuild(", 1)[1].split("    func begin(", 1)[0]
        self.assertIn("#if DEBUG || VPLAYER_PERFORMANCE_DIAGNOSTICS", factory)
        enabled, disabled = factory.split("#else", 1)
        self.assertIn("PlaybackSignposts(channelIdentifier: channelIdentifier)", enabled)
        self.assertIn("return nil", disabled.split("#endif", 1)[0])
        pipeline = (PLAYBACK / "Pipeline/PlaybackPipeline.swift").read_text()
        self.assertIn("PlaybackSignposts.makeForCurrentBuild(channelIdentifier: metrics.channelIdentifier)", pipeline)

    def test_metrics_remain_independent_of_optional_signposts(self):
        for path in ("Video/VideoToolboxDecoder.swift", "Deinterlace/YADIF/YADIFProcessor.swift"):
            with self.subTest(path=path):
                source = (PLAYBACK / path).read_text()
                self.assertIn("diagnostics: (metrics: PlaybackMetrics, signposts: PlaybackSignposts?)", source)
                self.assertIn("metrics: diagnostics.metrics", source)
        hls = (PLAYBACK / "HLS/HLSVideoTranscodeBranch.swift").read_text()
        factory = hls.split("    static func makeRoutingDecoderFactory(", 1)[1].split("    init(", 1)[0]
        self.assertNotIn("if let metrics, let signposts", factory)
        self.assertIn("if let metrics {", factory)


if __name__ == "__main__":
    unittest.main()
