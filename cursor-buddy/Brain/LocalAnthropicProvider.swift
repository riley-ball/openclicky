//
//  LocalAnthropicProvider.swift
//  cursor-buddy
//
//  Phase 1c Task 3 of the clank-voice → openclicky integration: brain
//  provider wrapping the existing `ClaudeAPI` (Anthropic direct). Lower
//  fidelity than RemoteClankSessionProvider — Anthropic's HTTP API has no
//  `[question]` / `[open-url]` marker layer — but works without Tailscale.
//
//  Architecture:
//    - `submit(...)` synchronously registers an AsyncStream continuation
//      keyed by `requestId`, then kicks off a background Task that calls
//      `ClaudeAPI.analyzeImageStreaming(...)` and translates each text
//      chunk into a `BrainStreamEvent.response(text:)` event.
//    - `streamEvents(requestId:)` returns the pre-created AsyncStream so
//      no events are lost between submit-returns and stream-subscribe.
//    - `streamPush()` returns an immediately-finished stream — Anthropic
//      has no equivalent of clank-voice's `/v1/push` long-lived channel.
//    - `submitAnswer(...)` is a no-op with a print warning — there's no
//      `/v1/answer` to call when the brain isn't a Claude Code session.
//    - `openURL(...)` re-checks the `{http, https}` scheme allowlist per
//      the operational rule (defense in depth — never trust upstream).
//
//  Fidelity caveats (vs RemoteClankSessionProvider):
//    - No channel markers — Anthropic's text stream is raw prose; the
//      consumer sees only `.response(text:)` + `.done`.
//    - No audio events — the existing openclicky TTS pipeline (Phase 3
//      candidate to replace) handles synthesis from the response text.
//    - No status / progress / log events — Anthropic doesn't emit any
//      structured progress signal.
//    - No question / open-url cards — see above.
//

import Foundation
import AppKit

final class LocalAnthropicProvider: BrainProvider {
    private let claudeAPI: ClaudeAPI

    /// Per-requestId continuations, populated by `submit(...)` and consumed
    /// (handed off) by `streamEvents(requestId:)`. Accessed under `queueLock`.
    private var continuationsByRid: [String: AsyncStream<BrainStreamEvent>.Continuation] = [:]
    private var streamsByRid: [String: AsyncStream<BrainStreamEvent>] = [:]
    private let queueLock = NSLock()

    init(claudeAPI: ClaudeAPI) {
        self.claudeAPI = claudeAPI
    }

    // MARK: - BrainProvider conformance (display + isConfigured)

    var displayName: String { "Anthropic Cloud" }

    /// `ClaudeAPI` does not expose its API-key presence as a public bool.
    /// We assume the provider is configured if the caller bothered to
    /// construct it; `submit(...)` will throw if the key turns out to be
    /// missing (ClaudeAPI's `makeAPIRequest()` throws -1000 in that case).
    var isConfigured: Bool { true }

    // MARK: - BrainProvider.submit

    func submit(
        requestId: String,
        text: String,
        audio: Data?,
        context: BrainScreenContext?,
        attachments: [BrainAttachment]
    ) async throws -> BrainSubmitResult {
        // Synchronously create the stream + continuation BEFORE returning,
        // so a subsequent streamEvents(requestId:) finds the queue ready.
        // This closes the race between submit-returns and stream-subscribe.
        var capturedContinuation: AsyncStream<BrainStreamEvent>.Continuation!
        let stream = AsyncStream<BrainStreamEvent> { cont in
            capturedContinuation = cont
        }
        queueLock.lock()
        streamsByRid[requestId] = stream
        continuationsByRid[requestId] = capturedContinuation
        queueLock.unlock()

        // Background-launch the Anthropic streaming call. Each text chunk
        // becomes a `.response(text:)` event; settle with `.done` per the
        // BrainProvider contract.
        Task { [weak self] in
            await self?.runStream(
                requestId: requestId,
                text: text,
                audio: audio,
                context: context,
                attachments: attachments
            )
        }

        // The protocol expects a synchronous return value with the rid +
        // transcript. Anthropic doesn't do STT, so we echo the user's text
        // back as the transcript (matches clank-voice's text_endpoint
        // behaviour where the typed text IS the transcript).
        return BrainSubmitResult(requestId: requestId, transcript: text)
    }

    /// Background worker: invoke ClaudeAPI.analyzeImageStreaming and
    /// translate each text chunk into a BrainStreamEvent.
    private func runStream(
        requestId: String,
        text: String,
        audio: Data?,
        context: BrainScreenContext?,
        attachments: [BrainAttachment]
    ) async {
        let continuation = popContinuation(for: requestId)
        guard let continuation = continuation else { return }

        // Build labelled images: prepend the screen-context shot, then add
        // attached images. Anthropic-direct ignores audio (no STT on the
        // direct API) and file attachments (no file ingestion semantics).
        var labelledImages: [(data: Data, label: String)] = []
        if let screenshot = context?.screenshot {
            labelledImages.append((screenshot, "Current screen"))
        }
        for attachment in attachments {
            if case .image(let imageData) = attachment {
                labelledImages.append((imageData, "User attachment"))
            }
        }

        // No question/open-url marker layer is available from Anthropic
        // direct — we just synthesise .response(text:) and .done.
        do {
            let _ = try await claudeAPI.analyzeImageStreaming(
                images: labelledImages,
                systemPrompt: Self.systemPrompt,
                conversationHistory: [],
                userPrompt: text,
                assistantPrefill: nil,
                onTextChunk: { @MainActor @Sendable accumulatedText in
                    // ClaudeAPI emits the FULL accumulated text on each
                    // chunk (not deltas); pass it through as the .response
                    // payload. Consumers will replace, not append.
                    continuation.yield(.response(text: accumulatedText))
                }
            )
            continuation.yield(.done)
            continuation.finish()
        } catch {
            print("LocalAnthropicProvider: streaming error: \(error)")
            continuation.yield(.error(error.localizedDescription))
            continuation.finish()
        }
    }

    /// Default system prompt for Phase 1c. Intentionally minimal — the
    /// remote brain (Claude Code session) has its own elaborate context;
    /// this is just enough to disambiguate the persona for cloud Anthropic.
    /// Settings UI work can override this in a later phase.
    private static let systemPrompt: String = """
    You are Clank, a helpful voice assistant. Respond concisely. The user is on macOS \
    and may have included a screenshot of their current screen for context. \
    Plain prose only — no markdown headers or code fences in voice responses.
    """

    // MARK: - BrainProvider.streamEvents

    func streamEvents(requestId: String) -> AsyncStream<BrainStreamEvent> {
        queueLock.lock()
        defer { queueLock.unlock() }
        if let stream = streamsByRid.removeValue(forKey: requestId) {
            return stream
        }
        // No registered stream — return an immediately-closed AsyncStream
        // so the consumer's iterator settles cleanly.
        return AsyncStream { continuation in
            continuation.finish()
        }
    }

    /// Anthropic has no equivalent of clank-voice's `/v1/push` long-lived
    /// channel — unsolicited brain pushes don't exist on the direct API.
    /// Return an immediately-closed stream; consumers no-op.
    func streamPush() -> AsyncStream<BrainPushEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    // MARK: - BrainProvider.submitAnswer

    func submitAnswer(
        questionId: String,
        answerKey: String?,
        answerText: String?
    ) async throws {
        // Anthropic direct can't surface `[question]` cards in the first
        // place, so an answer can never legitimately reach this provider.
        // No-op with a print warning — silent drop would mask programming
        // mistakes upstream.
        print("LocalAnthropicProvider: ignoring submitAnswer for \(questionId) — Anthropic direct has no question-card channel")
    }

    // MARK: - BrainProvider.openURL (allowlist override)

    /// Allowlist override per the operational rule "Scheme validation MUST
    /// be an allowlist (not a deny-list) for any path that reaches
    /// `NSWorkspace.shared.open()`." The default protocol implementation
    /// is permissive because clank-voice's view layer (OpenURLCard) already
    /// re-checks; defence-in-depth here means a future programming mistake
    /// upstream can't smuggle a `vscode://file/...` URL through this code path.
    /// See wiki/systems/clank-voice-open-url.md §8 and wiki/index.md ops rule.
    func openURL(_ data: BrainOpenURLData) {
        let allowedSchemes: Set<String> = ["http", "https"]
        guard let url = URL(string: data.url),
              let scheme = url.scheme?.lowercased(),
              allowedSchemes.contains(scheme) else {
            print("LocalAnthropicProvider: refusing to open URL with disallowed scheme: \(data.url)")
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Internals

    private func popContinuation(for requestId: String) -> AsyncStream<BrainStreamEvent>.Continuation? {
        queueLock.lock()
        defer { queueLock.unlock() }
        return continuationsByRid.removeValue(forKey: requestId)
    }
}
