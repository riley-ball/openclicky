//
//  BrainProviderID.swift
//  cursor-buddy
//
//  Phase 1c of the clank-voice → openclicky integration: identifier enum for
//  the BrainProvider seam. Shape mirrors
//  `cursor-buddy/BuddyTranscriptionProvider.swift::BuddyTranscriptionProviderID`
//  (the existing fork pattern). Persisted under
//  `UserDefaults` key `ClankBrainProvider` (see BrainProviderFactory).
//

import Foundation

enum BrainProviderID: String, CaseIterable, Identifiable {
    /// The clank-voice remote brain: long-running Claude Code session on
    /// the Mac Mini, talking through the FastAPI server at
    /// `http://localhost:8420`. Surfaces the full SSE event vocabulary
    /// including `[question]` and `[open-url]` cards. Default in Phase 1c.
    case remoteClankSession = "remote-clank"

    /// Direct Anthropic API call via the existing `ClaudeAPI`. Lower
    /// fidelity (no question / open-url markers — Anthropic has no marker
    /// layer) but works offline (no Tailscale required). Kept alive as a
    /// fallback / sanity check.
    case localAnthropic = "local-anthropic"

    var id: String { rawValue }

    /// User-visible label for the Settings picker.
    var label: String {
        switch self {
        case .remoteClankSession: return "Remote Clank Session"
        case .localAnthropic:     return "Anthropic Cloud"
        }
    }

    /// User-visible subtitle / hint for the Settings picker.
    var subtitle: String {
        switch self {
        case .remoteClankSession: return "Mac Mini file-inbox relay (full SSE)"
        case .localAnthropic:     return "Direct Anthropic API (no markers)"
        }
    }
}
