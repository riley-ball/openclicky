//
//  RemoteClankSessionProvider.swift
//  cursor-buddy
//
//  Phase 1c Task 2 of the clank-voice → openclicky integration: brain
//  provider routing through clank-voice's FastAPI server at
//  `http://localhost:8420`, backed by the file-inbox relay at
//  `~/.claude/voice-inbox/` (request-{id}.json → response-{id}.json) which
//  the long-running Claude Code session on the Mac Mini brokers.
//
//  Ported verbatim from
//  `~/Documents/coding/clank-voice/app/Sources/ClankVoice/ClankClient.swift`
//  with the minimal adaptations required by the spine:
//    - Class renamed: `ClankClient` → `RemoteClankSessionProvider`.
//    - The BrainProvider conformance extension from
//      `clank-voice/.../Brain/BrainProviderConformance.swift` is merged
//      inline (no external `extension ClankClient: BrainProvider` needed).
//    - `ScreenContextData?` parameters become `BrainScreenContext?` per
//      the spine §5.2 TODO.
//    - `AsyncStream<StreamEvent>` / `<PushEvent>` use the Brain* names
//      directly (no underlying StreamEvent/PushEvent type in openclicky).
//    - Removed clank-voice's `fetchConversations` / `fetchConversation` /
//      `deleteConversation` methods — those depend on
//      `ConversationSummary` / `ConversationDetail` types not yet ported
//      to the fork (Phase 4 Threads tab work will bring them across).
//    - SSE schema (response/audio/question/open-url/notch/status/log/
//      suggest/artifact/progress/error/done) preserved byte-for-byte per
//      the streamEvents/streamPush sync operational rule.
//

import Foundation
import AVFoundation

final class RemoteClankSessionProvider: BrainProvider {
    let baseURL: String
    private var audioPlayer: AVAudioPlayer?
    private var interruptedSession: Bool = false
    /// Generation counter: incremented by resetInterrupt() at the start of
    /// each new request. Each playAudio() captures the generation when it
    /// starts — if a newer request has since called resetInterrupt(), the
    /// old generation won't match and the stale audio silently skips. This
    /// prevents the race where resetInterrupt() clears interruptedSession
    /// but the OLD request's SSE loop still has queued audio events.
    private var playbackGeneration: Int = 0

    /// UserDefaults key the Settings UI writes the base URL to. If unset,
    /// the Phase 1c default (Tailscale-routed Mac Mini) is used.
    static let userBaseURLDefaultsKey = "ClankBrainProviderRemoteURL"
    static let defaultBaseURL = "http://localhost:8420"

    init(baseURL: String? = nil) {
        if let explicit = baseURL, !explicit.isEmpty {
            self.baseURL = explicit
        } else if let stored = UserDefaults.standard.string(forKey: Self.userBaseURLDefaultsKey),
                  !stored.trimmingCharacters(in: .whitespaces).isEmpty {
            self.baseURL = stored
        } else {
            self.baseURL = Self.defaultBaseURL
        }
    }

    // MARK: - BrainProvider conformance (display + isConfigured)

    var displayName: String { "Remote Clank Session" }
    /// Considered configured if the base URL is well-formed. Network reach
    /// (Tailscale up, server alive) is verified asynchronously via
    /// `checkHealth()`.
    var isConfigured: Bool { URL(string: baseURL) != nil }

    var volume: Float = UserDefaults.standard.object(forKey: "ttsVolume") as? Float ?? 1.0

    // MARK: - Audio playback control

    func stopAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    func cancelRemainingAudio() {
        playbackGeneration += 1
        audioPlayer?.stop()
        audioPlayer = nil
    }

    func stopAndInterruptSession() {
        interruptedSession = true
        audioPlayer?.stop()
        audioPlayer = nil
    }

    func resetInterrupt() {
        interruptedSession = false
        playbackGeneration += 1
    }

    var isPlayingAudio: Bool {
        audioPlayer?.isPlaying == true
    }

    // MARK: - Health check

    func checkHealth() async -> Bool {
        guard let url = URL(string: "\(baseURL)/health") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - BrainProvider.submit

    func submit(
        requestId: String,
        text: String,
        audio: Data?,
        context: BrainScreenContext?,
        attachments: [BrainAttachment]
    ) async throws -> BrainSubmitResult {
        var images: [Data] = []
        var files: [URL] = []
        for a in attachments {
            switch a {
            case .image(let d): images.append(d)
            case .file(let u): files.append(u)
            }
        }
        let wire: TalkStartResponse
        if let audio = audio {
            wire = try await sendAudio(
                audio,
                requestId: requestId,
                context: context,
                extraImages: images,
                extraFiles: files
            )
        } else {
            wire = try await sendText(
                text,
                requestId: requestId,
                context: context,
                extraImages: images,
                extraFiles: files
            )
        }
        return BrainSubmitResult(
            requestId: wire.requestId,
            transcript: wire.transcript
        )
    }

    // MARK: - Multipart POST: text + audio

    func sendText(
        _ text: String,
        requestId: String,
        context: BrainScreenContext? = nil,
        extraImages: [Data] = [],
        extraFiles: [URL] = []
    ) async throws -> TalkStartResponse {
        guard let url = URL(string: "\(baseURL)/v1/text") else {
            throw URLError(.badURL)
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"request_id\"\r\n\r\n".data(using: .utf8)!)
        body.append(requestId.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"text\"\r\n\r\n".data(using: .utf8)!)
        body.append(text.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
        appendContextFields(&body, boundary: boundary, context: context)
        appendAttachments(&body, boundary: boundary, images: extraImages, files: extraFiles)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "RemoteClankSessionProvider", code: statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Server returned \(statusCode): \(bodyText)"])
        }

        return try JSONDecoder().decode(TalkStartResponse.self, from: data)
    }

    func sendAudio(
        _ wavData: Data,
        requestId: String,
        context: BrainScreenContext? = nil,
        extraImages: [Data] = [],
        extraFiles: [URL] = []
    ) async throws -> TalkStartResponse {
        guard let url = URL(string: "\(baseURL)/v1/talk") else {
            throw URLError(.badURL)
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"request_id\"\r\n\r\n".data(using: .utf8)!)
        body.append(requestId.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"recording.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)

        appendContextFields(&body, boundary: boundary, context: context)
        appendAttachments(&body, boundary: boundary, images: extraImages, files: extraFiles)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "RemoteClankSessionProvider", code: statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Server returned \(statusCode): \(bodyText)"])
        }

        return try JSONDecoder().decode(TalkStartResponse.self, from: data)
    }

    // MARK: - SSE: per-request stream

    func streamEvents(requestId: String) -> AsyncStream<BrainStreamEvent> {
        AsyncStream { continuation in
            let task = Task {
                guard let url = URL(string: "\(baseURL)/v1/stream/\(requestId)") else {
                    continuation.finish()
                    return
                }

                do {
                    let (bytes, response) = try await URLSession.shared.bytes(from: url)
                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        continuation.yield(.error("Stream connection failed"))
                        continuation.finish()
                        return
                    }

                    var eventType = ""
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }

                        if line.isEmpty {
                            eventType = ""
                            continue
                        }

                        if line.hasPrefix("event: ") {
                            eventType = String(line.dropFirst(7))
                        } else if line.hasPrefix("data: ") {
                            let dataStr = String(line.dropFirst(6))
                            guard let jsonData = dataStr.data(using: .utf8) else { continue }

                            switch eventType {
                            case "progress":
                                if let event = try? JSONDecoder().decode(ProgressEvent.self, from: jsonData) {
                                    continuation.yield(.progress(event))
                                }
                            case "response":
                                if let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                                    let text = obj["response"] as? String ?? ""
                                    continuation.yield(.response(text: text))
                                }
                            case "audio":
                                if let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                                    let url = obj["url"] as? String ?? ""
                                    let index = obj["index"] as? Int ?? 0
                                    let text = obj["text"] as? String ?? ""
                                    let isFinal = obj["final"] as? Bool ?? false
                                    continuation.yield(.audio(url: url, index: index, text: text, isFinal: isFinal))
                                }
                            case "status":
                                if let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                                    let text = obj["text"] as? String ?? ""
                                    let ts = obj["ts"] as? Double ?? 0
                                    continuation.yield(.status(text: text, ts: ts))
                                }
                            case "log":
                                if let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                                    let text = obj["text"] as? String ?? ""
                                    let ts = obj["ts"] as? Double ?? 0
                                    continuation.yield(.log(text: text, ts: ts))
                                }
                            case "question":
                                if let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                                    let qId = obj["id"] as? String ?? ""
                                    let qText = obj["text"] as? String ?? ""
                                    let voiceReply = obj["voice_reply"] as? Bool ?? true
                                    let textReply = obj["text_reply"] as? Bool ?? true
                                    var options: [QuestionOption] = []
                                    if let opts = obj["options"] as? [[String: Any]] {
                                        for opt in opts {
                                            let key = opt["key"] as? String ?? ""
                                            let label = opt["label"] as? String ?? ""
                                            options.append(QuestionOption(key: key, label: label))
                                        }
                                    }
                                    continuation.yield(.question(QuestionData(
                                        id: qId, text: qText, options: options,
                                        voiceReply: voiceReply, textReply: textReply
                                    )))
                                }
                            case "open-url":
                                // Canonical decode for the open-url card. KEEP IN SYNC with the
                                // sibling block in streamPush() — schema additions land in both
                                // call sites per the streamEvents/streamPush operational rule.
                                // See wiki/systems/clank-voice-open-url.md §4.
                                if let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                                    let uId = obj["id"] as? String ?? ""
                                    let uURL = obj["url"] as? String ?? ""
                                    let uTitle = obj["title"] as? String ?? ""
                                    if !uURL.isEmpty {
                                        continuation.yield(.openURL(OpenURLData(
                                            id: uId, url: uURL, title: uTitle
                                        )))
                                    }
                                }
                            case "notch":
                                if let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                                    let label = obj["label"] as? String ?? ""
                                    let bg = obj["background"] as? Bool ?? false
                                    continuation.yield(.notch(label: label, background: bg))
                                }
                            case "suggest":
                                if let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                                    let text = obj["text"] as? String ?? ""
                                    if !text.isEmpty { continuation.yield(.suggest(text: text)) }
                                }
                            case "artifact":
                                if let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                                    let path = obj["path"] as? String ?? ""
                                    let title = obj["title"] as? String ?? path
                                    if !path.isEmpty { continuation.yield(.artifact(path: path, title: title)) }
                                }
                            case "error":
                                if let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                                    let detail = obj["detail"] as? String ?? "Unknown error"
                                    continuation.yield(.error(detail))
                                }
                            case "done":
                                continuation.yield(.done)
                                continuation.finish()
                                return
                            default:
                                break
                            }
                            eventType = ""
                        }
                    }

                    continuation.finish()
                } catch {
                    if !Task.isCancelled {
                        print("RemoteClankSessionProvider: SSE stream error: \(error)")
                        continuation.yield(.error(error.localizedDescription))
                    }
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - SSE: long-lived push channel

    func streamPush() -> AsyncStream<BrainPushEvent> {
        AsyncStream { continuation in
            let task = Task {
                guard let url = URL(string: "\(baseURL)/v1/push") else {
                    continuation.finish()
                    return
                }

                do {
                    let (bytes, response) = try await URLSession.shared.bytes(from: url)
                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200 else {
                        continuation.finish()
                        return
                    }

                    var eventType = ""
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }

                        if line.isEmpty {
                            eventType = ""
                            continue
                        }

                        if line.hasPrefix("event: ") {
                            eventType = String(line.dropFirst(7))
                        } else if line.hasPrefix("data: ") {
                            let dataStr = String(line.dropFirst(6))
                            guard let jsonData = dataStr.data(using: .utf8) else { continue }

                            if eventType == "push",
                               let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                                let text = obj["text"] as? String ?? ""
                                let audioURL = obj["audio_url"] as? String ?? ""
                                let source = obj["source"] as? String ?? "clank"
                                continuation.yield(.push(text: text, audioURL: audioURL, source: source))
                            } else if eventType == "open-url",
                                      let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                                // Byte-for-byte mirror of the streamEvents `case "open-url"` block.
                                // KEEP IN SYNC per the streamEvents/streamPush operational rule.
                                // See wiki/systems/clank-voice-open-url.md §4.
                                let uId = obj["id"] as? String ?? ""
                                let uURL = obj["url"] as? String ?? ""
                                let uTitle = obj["title"] as? String ?? ""
                                if !uURL.isEmpty {
                                    continuation.yield(.openURL(OpenURLData(
                                        id: uId, url: uURL, title: uTitle
                                    )))
                                }
                            } else if eventType == "question",
                                      let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                                // Mirrors the streamEvents `event: question`
                                // branch. Push channel emits `event: question`
                                // BEFORE the matching `event: push` whenever a
                                // push file contains a [question] marker.
                                // KEEP IN SYNC with streamEvents per the operational rule.
                                let qId = obj["id"] as? String ?? ""
                                let qText = obj["text"] as? String ?? ""
                                let voiceReply = obj["voice_reply"] as? Bool ?? true
                                let textReply = obj["text_reply"] as? Bool ?? true
                                var options: [QuestionOption] = []
                                if let opts = obj["options"] as? [[String: Any]] {
                                    for opt in opts {
                                        let key = opt["key"] as? String ?? ""
                                        let label = opt["label"] as? String ?? ""
                                        options.append(QuestionOption(key: key, label: label))
                                    }
                                }
                                continuation.yield(.question(QuestionData(
                                    id: qId, text: qText, options: options,
                                    voiceReply: voiceReply, textReply: textReply
                                )))
                            }
                            eventType = ""
                        }
                    }

                    continuation.finish()
                } catch {
                    if !Task.isCancelled {
                        print("RemoteClankSessionProvider: push stream error: \(error)")
                    }
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - BrainProvider.submitAnswer (POST /v1/answer)

    func submitAnswer(
        questionId: String,
        answerKey: String?,
        answerText: String?
    ) async throws {
        try await sendAnswer(
            questionId: questionId,
            answerKey: answerKey,
            answerText: answerText
        )
    }

    func sendAnswer(questionId: String, answerKey: String?, answerText: String?) async throws {
        guard let url = URL(string: "\(baseURL)/v1/answer") else { throw URLError(.badURL) }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"question_id\"\r\n\r\n\(questionId)\r\n".data(using: .utf8)!)
        if let key = answerKey {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"answer_key\"\r\n\r\n\(key)\r\n".data(using: .utf8)!)
        }
        if let text = answerText, !text.isEmpty {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"answer_text\"\r\n\r\n\(text)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "RemoteClankSessionProvider", code: (response as? HTTPURLResponse)?.statusCode ?? 0,
                          userInfo: [NSLocalizedDescriptionKey: "Answer submission failed"])
        }
    }

    // MARK: - Audio playback

    func playAudio(from urlString: String) async {
        let myGeneration = playbackGeneration
        if interruptedSession { return }

        let fullURL: String
        if urlString.hasPrefix("http") {
            fullURL = urlString
        } else {
            fullURL = "\(baseURL)\(urlString)"
        }

        guard let url = URL(string: fullURL) else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if interruptedSession || myGeneration != playbackGeneration { return }
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.volume = volume
            audioPlayer?.play()

            while audioPlayer?.isPlaying == true {
                if interruptedSession || myGeneration != playbackGeneration {
                    audioPlayer?.stop()
                    audioPlayer = nil
                    return
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            print("RemoteClankSessionProvider: audio playback failed: \(error)")
        }
    }

    // MARK: - Multipart helpers

    private func appendContextFields(_ body: inout Data, boundary: String, context: BrainScreenContext?) {
        guard let ctx = context else { return }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"active_app\"\r\n\r\n".data(using: .utf8)!)
        body.append(ctx.activeApp.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
        if let chromeURL = ctx.chromeURL {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"chrome_url\"\r\n\r\n".data(using: .utf8)!)
            body.append(chromeURL.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        if let chromeTitle = ctx.chromeTitle {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"chrome_title\"\r\n\r\n".data(using: .utf8)!)
            body.append(chromeTitle.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        if let screenshot = ctx.screenshot {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"screenshot\"; filename=\"screen.jpg\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(screenshot)
            body.append("\r\n".data(using: .utf8)!)
        }
    }

    private func appendAttachments(_ body: inout Data, boundary: String, images: [Data], files: [URL]) {
        for (idx, img) in images.enumerated() {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"attachment_image\"; filename=\"pasted-\(idx).jpg\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(img)
            body.append("\r\n".data(using: .utf8)!)
        }
        for url in files {
            guard let data = try? Data(contentsOf: url) else { continue }
            // Skip files larger than 10MB to avoid huge uploads.
            if data.count > 10 * 1024 * 1024 { continue }
            let mime = mimeType(for: url)
            let name = url.lastPathComponent
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"attachment_file\"; filename=\"\(name)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n".data(using: .utf8)!)
        }
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "pdf": return "application/pdf"
        case "txt", "md", "log": return "text/plain"
        case "json": return "application/json"
        case "csv": return "text/csv"
        case "html", "htm": return "text/html"
        case "swift", "py", "js", "ts", "go", "rs", "java", "c", "cpp", "h", "sh": return "text/plain"
        default: return "application/octet-stream"
        }
    }
}
