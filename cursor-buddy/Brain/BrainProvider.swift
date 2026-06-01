//
//  BrainProvider.swift
//  cursor-buddy
//
//  Phase 1c of the clank-voice → openclicky integration: the cross-provider
//  contract for "the thing that thinks for Clank." Ported verbatim from
//  ~/Documents/coding/clank-voice/app/Sources/ClankVoice/Brain/BrainProvider.swift
//  with the only adaptation being the swap of `ScreenContextData?` for
//  `BrainScreenContext?` (spine TODO §5.2: stop the protocol leaking the
//  concrete clank-voice type).
//
//  Implementations (each lives in its own file under cursor-buddy/Brain/):
//    - RemoteClankSessionProvider — talks to clank-voice's FastAPI server on
//      your Tailscale-routed Mac Mini server, surfacing the full SSE event
//      vocabulary including `[question]` and `[open-url]` cards.
//    - LocalAnthropicProvider — wraps the existing ClaudeAPI (Anthropic
//      direct). Lower fidelity (no question / open-url markers — Anthropic's
//      API has no marker layer) but works without Tailscale; synthesises
//      `.response` events from streamed text deltas.
//
//  Contract notes mirrored from the spine:
//    - `streamEvents(requestId:)` MUST emit a final `.done` event when the
//      server's `event: done` arrives (consumers rely on this for the
//      "settled" state transition).
//    - `streamPush()` is long-lived — one connection per app session,
//      reconnect on disconnect handled by the consumer. NOT per-request.
//    - `openURL(_:)` is a LOCAL action — the protocol's default impl calls
//      `NSWorkspace.shared.open(_:)`. The defensive allowlist re-check still
//      lives in the view layer (Phase 2 OpenURLCard) per the operational
//      rule "Scheme validation MUST be an allowlist."
//

import Foundation
import AppKit

protocol BrainProvider: AnyObject {
    /// Human-readable name shown in Settings → Brain Provider.
    var displayName: String { get }

    /// Whether the provider has the configuration it needs to be usable
    /// (e.g. API key present, Tailscale reachable, etc.). The UI greys out
    /// unusable providers in the picker.
    var isConfigured: Bool { get }

    /// Submit a request to the brain. `audio` is the WAV payload from the
    /// PTT recorder; `text` is the typed/transcribed prose; if both are
    /// non-nil the implementation should prefer audio. `requestId` MUST be
    /// unique per call (8 hex chars by clank-voice convention) and is the
    /// key the SSE stream is opened against.
    func submit(
        requestId: String,
        text: String,
        audio: Data?,
        context: BrainScreenContext?,
        attachments: [BrainAttachment]
    ) async throws -> BrainSubmitResult

    /// SSE stream of typed events for one request. Per the
    /// streamEvents/streamPush operational rule the typed events on this
    /// channel MUST mirror those on `streamPush()` for any schema shared
    /// between the two transports (question / open-url today).
    func streamEvents(requestId: String) -> AsyncStream<BrainStreamEvent>

    /// Long-lived SSE stream for unsolicited brain pushes. One connection
    /// per app session; reconnect on disconnect handled by the consumer.
    func streamPush() -> AsyncStream<BrainPushEvent>

    /// Submit an answer to a `[question]` card. The server's
    /// `POST /v1/answer` semantics: either `answerKey` (option tap) or
    /// `answerText` (free-text reply) must be present.
    func submitAnswer(
        questionId: String,
        answerKey: String?,
        answerText: String?
    ) async throws

    /// Open a URL on the user's machine. Default implementation calls
    /// `NSWorkspace.shared.open(_:)`. Providers MAY override (e.g. to log
    /// analytics or sandbox the open through a security helper). View layer
    /// MUST still re-check the scheme allowlist before calling this — see
    /// the Phase 2 OpenURLCard slot.
    func openURL(_ data: BrainOpenURLData)
}

// Default `openURL` — provider implementations rarely need to override.
extension BrainProvider {
    func openURL(_ data: BrainOpenURLData) {
        guard let url = URL(string: data.url) else { return }
        NSWorkspace.shared.open(url)
    }
}
