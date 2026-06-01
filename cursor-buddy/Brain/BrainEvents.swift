//
//  BrainEvents.swift
//  cursor-buddy
//
//  Phase 1c of the clank-voice → openclicky integration: cross-provider event
//  surface for the BrainProvider seam. Ported verbatim (then namespaced) from
//  ~/Documents/coding/clank-voice/app/Sources/ClankVoice/Brain/BrainEvents.swift
//  + the underlying type declarations in ClankClient.swift (which the spine
//  typealiases). See wiki/projects/clank-spine.md §4 (SSE event schema
//  catalogue) and §5 (BrainProvider protocol shape).
//
//  In clank-voice these types live at top-level (StreamEvent/PushEvent +
//  ProgressEvent/QuestionData/...). In openclicky they live under Brain/ to
//  avoid colliding with the fork's existing types and to make the brain-
//  agnostic surface explicit. The Brain* names are the Phase 1c source of
//  truth; the spine's typealias indirection (BrainStreamEvent = StreamEvent)
//  is dropped because there is no underlying StreamEvent here.
//

import Foundation

// MARK: - Wire-level supporting types

/// Decoded shape of the server's `POST /v1/text` and `/v1/talk` 200 response.
/// Server contract: wiki/projects/clank-spine.md §6 (multipart fields) +
/// clank-voice/server/main.py text_endpoint()/talk_endpoint().
struct TalkStartResponse: Decodable {
    let requestId: String
    let transcript: String

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case transcript
    }
}

/// One entry in a `event: progress` SSE payload. `kind` is `"tool"` |
/// `"text"` | `"thinking"` per the server's transcript-tail emitter.
struct ProgressEvent: Decodable, Identifiable, Equatable {
    let ts: Double
    let kind: String
    let tool: String?
    let summary: String
    let detail: String

    var id: String { "\(ts)-\(summary)" }
}

/// One option on a `[question]` card. `key` is `"a"`/`"b"`/... by convention;
/// `label` is the human-readable button text.
struct QuestionOption: Equatable {
    let key: String
    let label: String
}

/// Payload of a `[question]` card. Mirrors the server's `_emit_question_segment`
/// JSON. `voiceReply`/`textReply` toggle which input modes the card surfaces.
struct QuestionData: Equatable {
    let id: String
    let text: String
    let options: [QuestionOption]
    let voiceReply: Bool
    let textReply: Bool
}

/// Payload of an `[open-url]` card. Carries the URL + a display title from
/// the server's `parse_open_url_text` (wiki/systems/clank-voice-open-url.md).
/// The OpenURLCard view (Phase 2) defensively re-checks the URL scheme before
/// calling NSWorkspace.shared.open per the allowlist operational rule.
struct OpenURLData: Equatable {
    let id: String
    let url: String
    let title: String
}


// MARK: - Brain stream event vocabulary

/// One event on the per-request SSE channel (`/v1/stream/{rid}`). Mirrors
/// `clank-voice/.../ClankClient.swift::StreamEvent` 1:1.
///
/// Phase 1c consumers should drive the panel state machine off this enum
/// rather than provider-specific transports — adding a new case here means
/// updating BOTH `RemoteClankSessionProvider.streamEvents(requestId:)` and
/// `LocalAnthropicProvider.streamEvents(requestId:)` decoders in the same
/// commit (the streamEvents/streamPush sync operational rule).
enum BrainStreamEvent {
    case progress(ProgressEvent)
    case response(text: String)
    case audio(url: String, index: Int, text: String, isFinal: Bool)
    case status(text: String, ts: Double)
    case log(text: String, ts: Double)
    case question(QuestionData)
    case openURL(OpenURLData)
    case notch(label: String, background: Bool)
    case suggest(text: String)
    case artifact(path: String, title: String)
    case error(String)
    case done
}

/// One event on the long-lived push SSE channel (`/v1/push`). Mirrors
/// `clank-voice/.../ClankClient.swift::PushEvent` 1:1. Smaller surface than
/// `BrainStreamEvent` — push is for unsolicited brain messages + the orphan
/// promoter (wiki/projects/clank-spine.md §8).
enum BrainPushEvent {
    case push(text: String, audioURL: String, source: String)
    case openURL(OpenURLData)
    case question(QuestionData)
}


// MARK: - Submit input + result + screen context

/// Cross-provider representation of an attachment a user can drop on a
/// request. Maps to the multipart fields `attachment_image` (repeated) and
/// `attachment_file` (repeated) per wiki/projects/clank-spine.md §6.
enum BrainAttachment {
    /// In-memory image payload (JPEG bytes by convention).
    case image(Data)
    /// Local file reference (anything ≤ 10 MB).
    case file(URL)
}

/// Decoded shape of a successful brain-provider submit. Maps 1:1 to the
/// server's TalkStartResponse but lives in Brain/ so consumers don't have
/// to import the wire type.
struct BrainSubmitResult: Equatable {
    let requestId: String
    let transcript: String

    init(requestId: String, transcript: String) {
        self.requestId = requestId
        self.transcript = transcript
    }
}

/// Brain-level screen context. Phase 1c version of clank-voice's
/// `ScreenContextData` (the spine TODO at clank-spine.md §5.2). Defined here
/// so the protocol doesn't leak openclicky's existing `ScreenContextData`
/// shape if/when that diverges. Field set matches the server's multipart
/// receiver fields (active_app, chrome_url, chrome_title, screenshot).
struct BrainScreenContext {
    let screenshot: Data?
    let activeApp: String
    let chromeURL: String?
    let chromeTitle: String?

    init(screenshot: Data?, activeApp: String, chromeURL: String?, chromeTitle: String?) {
        self.screenshot = screenshot
        self.activeApp = activeApp
        self.chromeURL = chromeURL
        self.chromeTitle = chromeTitle
    }
}


// MARK: - Brain-namespace typealiases

// Per wiki/projects/clank-spine.md §5.2 — typealiases for cards/views that
// want to refer to the open-url / question payloads via the Brain namespace
// without coupling to the wire-level names. Cards added in Phase 2 will
// consume `BrainOpenURLData` etc; in Phase 1c they're just aliases.
typealias BrainOpenURLData = OpenURLData
typealias BrainQuestionData = QuestionData
typealias BrainQuestionOption = QuestionOption
