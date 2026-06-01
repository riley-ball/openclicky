//
//  LocalAnthropicProvider.swift
//  cursor-buddy
//
//  Phase 1c of the clank-voice → openclicky integration: brain provider
//  wrapping the existing `ClaudeAPI` (Anthropic direct). Lower fidelity than
//  RemoteClankSessionProvider — Anthropic's HTTP API has no `[question]` /
//  `[open-url]` marker layer — but works without Tailscale.
//
//  **Phase 1c Task 1 scaffold — REPLACED by Task 3** which fills in the
//  ClaudeAPI.analyzeImageStreaming adapter that synthesises `.response`
//  events from Anthropic's content_block_delta text chunks (and a final
//  `.done` once the stream settles).
//

import Foundation

final class LocalAnthropicProvider: BrainProvider {
    private let claudeAPI: ClaudeAPI

    init(claudeAPI: ClaudeAPI) {
        self.claudeAPI = claudeAPI
    }

    var displayName: String { "Anthropic Cloud" }
    /// Task 3 will tighten this to introspect ClaudeAPI's API-key presence.
    /// In the Task 1 scaffold, we assume the provider is configured if the
    /// caller bothered to construct it.
    var isConfigured: Bool { true }

    func submit(
        requestId: String,
        text: String,
        audio: Data?,
        context: BrainScreenContext?,
        attachments: [BrainAttachment]
    ) async throws -> BrainSubmitResult {
        // Task 3 will call into claudeAPI.analyzeImageStreaming(...) here,
        // queueing the stream chunks into an `AsyncStream<BrainStreamEvent>`
        // continuation that `streamEvents(requestId:)` returns.
        throw NSError(
            domain: "LocalAnthropicProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Phase 1c Task 3 stub: submit() not yet implemented"]
        )
    }

    func streamEvents(requestId: String) -> AsyncStream<BrainStreamEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    /// Anthropic has no equivalent of clank-voice's `/v1/push` long-lived
    /// channel — unsolicited brain pushes don't exist on the direct API.
    /// We return an immediately-closed stream and let consumers no-op.
    func streamPush() -> AsyncStream<BrainPushEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func submitAnswer(
        questionId: String,
        answerKey: String?,
        answerText: String?
    ) async throws {
        // Anthropic doesn't surface question cards, so this is a no-op
        // for the local provider. Kept as a conformance stub.
    }
}
