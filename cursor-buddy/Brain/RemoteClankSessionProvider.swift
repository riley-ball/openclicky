//
//  RemoteClankSessionProvider.swift
//  cursor-buddy
//
//  Phase 1c of the clank-voice → openclicky integration: brain provider
//  routing through clank-voice's FastAPI server at
//  `http://localhost:8420`. Backed by the file-inbox relay at
//  `~/.claude/voice-inbox/` (request-{id}.json → response-{id}.json) which
//  the long-running Claude Code session on the Mac Mini brokers.
//
//  **Phase 1c Task 1 scaffold — REPLACED by Task 2's verbatim port** of
//  `clank-voice/app/Sources/ClankVoice/ClankClient.swift`. This file ships in
//  Task 1 only so BrainProviderFactory parses; the real multipart + SSE
//  decode logic arrives in Task 2.
//

import Foundation

final class RemoteClankSessionProvider: BrainProvider {
    let baseURL: String

    init(baseURL: String = "http://localhost:8420") {
        self.baseURL = baseURL
    }

    var displayName: String { "Remote Clank Session" }
    var isConfigured: Bool { URL(string: baseURL) != nil }

    func submit(
        requestId: String,
        text: String,
        audio: Data?,
        context: BrainScreenContext?,
        attachments: [BrainAttachment]
    ) async throws -> BrainSubmitResult {
        // Task 2 will port the multipart body + POST against /v1/text or
        // /v1/talk from ClankClient.swift::sendText / sendAudio.
        throw NSError(
            domain: "RemoteClankSessionProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Phase 1c Task 2 stub: submit() not yet implemented"]
        )
    }

    func streamEvents(requestId: String) -> AsyncStream<BrainStreamEvent> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

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
        throw NSError(
            domain: "RemoteClankSessionProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Phase 1c Task 2 stub: submitAnswer() not yet implemented"]
        )
    }
}
