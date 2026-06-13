import Foundation

/// One turn in a conversation, in the shape every chat API expects: a `role`
/// (`"user"` or `"assistant"`) and its `content`. `NotchModel` builds the running
/// list and hands the whole thing to the service on each submit, so a follow-up
/// carries the full context instead of starting over.
struct ChatMessage: Sendable, Equatable {
    let role: String   // "user" | "assistant"
    let content: String
}

/// The seam where the notch talks to an AI. In the web prototype this was
/// `window.claude.complete()`; here it's an async protocol so a real Claude API
/// client can be dropped in later without touching any UI code.
///
/// Per the current scope the app ships with `StubAIService` — no network, no API
/// key. To go live, implement this protocol against the Anthropic API (ideally
/// through a small backend so the key never ships in the app) and swap the
/// instance handed to `NotchModel`.
protocol AIService: Sendable {
    /// Continue a conversation, streaming the reply as it arrives. `system` is the
    /// persona/instruction; `messages` is the full alternating user/assistant
    /// history ending on the latest user turn — so the model answers *with the
    /// prior turns in context* (real follow-ups, not fresh single-shot queries).
    /// Each yielded value is an incremental chunk of text to append (not the full
    /// answer). The stream finishes when the model is done; it should respect
    /// cancellation (stop producing once the surrounding `Task` is cancelled).
    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error>
}

extension AIService {
    /// Convenience for callers that just want the whole answer to a single
    /// question: wraps it as a one-message conversation, drains the stream, and
    /// concatenates it. Kept so non-streaming, single-shot use sites stay simple.
    func complete(prompt: String) async throws -> String {
        var out = ""
        let messages = [ChatMessage(role: "user", content: prompt)]
        for try await chunk in stream(system: notchSystemPrompt, messages: messages) { out += chunk }
        return out
    }
}

/// The system prompt the prototype used for its in-notch assistant. Kept here so
/// a real implementation can reuse the exact persona.
let notchSystemPrompt = """
You are a helpful assistant living in the notch of a Mac. Answer the user's \
question concisely and warmly in the user's language. Keep it under 90 words, \
no markdown headers.
"""

// MARK: - Providers

/// The AI backends the app knows how to talk to. Every supported provider here
/// exposes an **OpenAI-compatible** `/v1/chat/completions` endpoint, so they all
/// share one client (`OpenAICompatAIService`) and differ only in this metadata.
///
/// Adding another OpenAI-compatible vendor is a one-line case here — no new
/// networking code.
enum Provider: String, CaseIterable, Identifiable, Sendable {
    /// First in the menu deliberately: the only backend that works without
    /// pasting a key (one-click OAuth connect, free models) — the default for
    /// fresh installs.
    case openrouter
    case mimo
    case deepseek
    case openai
    case gemini
    case anthropic
    case minimax
    case glm
    case qwen
    case kimi

    var id: String { rawValue }

    /// Whether this provider speaks the OpenAI-compatible `/v1/chat/completions`
    /// contract (true for everyone) or a vendor-native protocol (Anthropic's
    /// `/v1/messages`). `AppDelegate` uses this to pick the client implementation.
    var isOpenAICompatible: Bool {
        switch self {
        case .anthropic: return false
        default:         return true
        }
    }

    /// Human-readable name shown in Settings.
    var displayName: String {
        switch self {
        case .openrouter: return "OpenRouter"
        case .mimo:      return "MiMo"
        case .deepseek:  return "DeepSeek"
        case .openai:    return "OpenAI"
        case .gemini:    return "Google Gemini"
        case .anthropic: return "Anthropic"
        case .minimax:   return "MiniMax"
        case .glm:       return "GLM"
        case .qwen:      return "Qwen"
        case .kimi:      return "Kimi"
        }
    }

    /// The request endpoint. OpenAI-compatible vendors share the
    /// `/v1/chat/completions` shape; Anthropic uses its native `/v1/messages`.
    var endpoint: URL {
        switch self {
        case .openrouter: return URL(string: "https://openrouter.ai/api/v1/chat/completions")!
        case .mimo:      return URL(string: "https://api.xiaomimimo.com/v1/chat/completions")!
        case .deepseek:  return URL(string: "https://api.deepseek.com/v1/chat/completions")!
        case .openai:    return URL(string: "https://api.openai.com/v1/chat/completions")!
        case .gemini:    return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
        case .anthropic: return URL(string: "https://api.anthropic.com/v1/messages")!
        case .minimax:   return URL(string: "https://api.minimaxi.com/v1/chat/completions")!
        case .glm:       return URL(string: "https://open.bigmodel.cn/api/paas/v4/chat/completions")!
        case .qwen:      return URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")!
        case .kimi:      return URL(string: "https://api.moonshot.cn/v1/chat/completions")!
        }
    }

    /// Default model used when the user hasn't picked one explicitly.
    var defaultModel: String {
        switch self {
        // The free auto-router: OpenRouter picks a currently-available free
        // model per request, so this keeps working as the free lineup rotates.
        case .openrouter: return "openrouter/free"
        case .mimo:      return "mimo-v2.5-pro"
        case .deepseek:  return "deepseek-v4-flash"
        case .openai:    return "gpt-5.5"
        case .gemini:    return "gemini-3.5-flash"
        case .anthropic: return "claude-sonnet-4-6"
        case .minimax:   return "MiniMax-M3"
        case .glm:       return "glm-5"
        case .qwen:      return "qwen3-max"
        case .kimi:      return "kimi-k2.6"
        }
    }

    /// The models offered in the Settings model picker for this provider. The
    /// first entry is always `defaultModel`. These are the current, commonly-used
    /// model ids per vendor — a curated shortlist, not an exhaustive catalog;
    /// vendors add/retire models over time, so treat this as a sensible default
    /// set rather than the source of truth.
    var availableModels: [String] {
        switch self {
        case .openrouter:
            // Just the router — the live `/models` fetch fills in the current
            // `:free` lineup (see `ModelCatalog`), which rotates too often to bundle.
            return ["openrouter/free"]
        case .mimo:
            return ["mimo-v2.5-pro", "mimo-v2.5"]
        case .deepseek:
            return ["deepseek-v4-flash", "deepseek-v4-pro"]
        case .openai:
            return ["gpt-5.5", "gpt-5.5-pro", "gpt-5.4", "gpt-5.2", "gpt-5", "gpt-5-mini"]
        case .gemini:
            return ["gemini-3.5-flash", "gemini-3-flash", "gemini-3.1-pro", "gemini-3.1-flash-lite", "gemini-2.5-pro", "gemini-2.5-flash"]
        case .anthropic:
            return ["claude-sonnet-4-6", "claude-opus-4-8", "claude-haiku-4-5"]
        case .minimax:
            return ["MiniMax-M3", "MiniMax-M3-highspeed", "MiniMax-M2.7", "MiniMax-M2.5"]
        case .glm:
            return ["glm-5", "glm-5.1", "glm-5-turbo", "glm-4.6"]
        case .qwen:
            return ["qwen3-max", "qwen3.5-plus", "qwen3.5-flash", "qwen-plus", "qwen-flash"]
        case .kimi:
            return ["kimi-k2.6", "kimi-k2.5", "moonshot-v1-128k", "moonshot-v1-32k"]
        }
    }

    /// Where the user signs up / gets an API key (shown in the Settings footer).
    var signupHost: String {
        switch self {
        case .openrouter: return "openrouter.ai"
        case .mimo:      return "platform.xiaomimimo.com"
        case .deepseek:  return "platform.deepseek.com"
        case .openai:    return "platform.openai.com"
        case .gemini:    return "aistudio.google.com"
        case .anthropic: return "console.anthropic.com"
        case .minimax:   return "platform.minimaxi.com"
        case .glm:       return "open.bigmodel.cn"
        case .qwen:      return "bailian.console.aliyun.com"
        case .kimi:      return "platform.moonshot.cn"
        }
    }

    /// Clickable URL to the provider's API-key console, opened from the Settings
    /// footer. The footer shows the short `signupHost`, but the link points at the
    /// exact page where the user creates a key.
    var signupURL: URL {
        switch self {
        case .openrouter: return URL(string: "https://openrouter.ai/settings/keys")!
        case .mimo:      return URL(string: "https://platform.xiaomimimo.com/console/api-keys/api_key")!
        case .deepseek:  return URL(string: "https://platform.deepseek.com/api_keys/api_key")!
        case .openai:    return URL(string: "https://platform.openai.com/api-keys/api_key")!
        case .gemini:    return URL(string: "https://aistudio.google.com/app/apikey/api_key")!
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys/api_key")!
        case .minimax:   return URL(string: "https://platform.minimaxi.com/api_key")!
        case .glm:       return URL(string: "https://open.bigmodel.cn/usercenter/apikeys/api_key")!
        case .qwen:      return URL(string: "https://bailian.console.aliyun.com/api_key")!
        case .kimi:      return URL(string: "https://platform.moonshot.cn/console/api-keys/api_key")!
        }
    }

    /// Environment variable that force-overrides the stored key (handy for dev).
    var envVarName: String {
        switch self {
        case .openrouter: return "OPENROUTER_API_KEY"
        case .mimo:      return "MIMO_API_KEY"
        case .deepseek:  return "DEEPSEEK_API_KEY"
        case .openai:    return "OPENAI_API_KEY"
        case .gemini:    return "GEMINI_API_KEY"
        case .anthropic: return "ANTHROPIC_API_KEY"
        case .minimax:   return "MINIMAX_API_KEY"
        case .glm:       return "GLM_API_KEY"
        case .qwen:      return "QWEN_API_KEY"
        case .kimi:      return "KIMI_API_KEY"
        }
    }

    /// JSON key for the output-token cap. MiMo follows OpenAI's newer
    /// `max_completion_tokens`; everyone else uses the classic `max_tokens`.
    /// (Unused by the Anthropic client, which always sends `max_tokens`.)
    var maxTokensField: String {
        switch self {
        case .mimo:     return "max_completion_tokens"
        default:        return "max_tokens"
        }
    }

    /// Vendor-specific extras sent with every chat request. OpenRouter's two
    /// optional attribution headers identify the app (its docs ask nicely);
    /// everyone else needs nothing beyond auth.
    var extraHeaders: [String: String] {
        switch self {
        case .openrouter:
            return ["HTTP-Referer": "https://github.com/\(UpdaterService.repo)",
                    "X-Title": "NotchGlass"]
        default:
            return [:]
        }
    }
}

/// Offline stand-in. Returns a short, plausible-looking answer after a brief
/// "thinking" delay so the loading state is exercised exactly as it will be with
/// a real backend. Not meant to be smart — just to make the UI fully live.
struct StubAIService: AIService {
    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        // The stub deliberately ignores `system`: the placeholder answer is built
        // only from the user's question, never from the persona/instruction text.
        // Binding it to `_` makes that explicit so the system prompt can't leak
        // into the streamed output (and thence into saved history).
        _ = system
        let q = (messages.last(where: { $0.role == "user" })?.content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Count prior user turns so a follow-up visibly knows it has context —
        // proof the whole thread reaches the service, not just the latest line.
        let priorTurns = messages.filter { $0.role == "user" }.count - 1
        let contextNote = priorTurns > 0
            ? "(Following up on \(priorTurns) earlier \(priorTurns == 1 ? "question" : "questions").) "
            : ""
        let text = """
        \(contextNote)Here's a placeholder answer to **\(q)**.

        No model connected yet — this is the offline stub. Open Settings (⌘,) and \
        connect a free OpenRouter account (or paste an API key) to get live answers.
        """
        return AsyncThrowingStream { continuation in
            let task = Task {
                // Brief lead-in so the "thinking" wave shows, then dribble the
                // text out word by word to exercise the streaming path.
                try? await Task.sleep(nanoseconds: 700_000_000)
                for word in text.split(separator: " ", omittingEmptySubsequences: false) {
                    if Task.isCancelled { break }
                    continuation.yield(String(word) + " ")
                    try? await Task.sleep(nanoseconds: 35_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - OpenAI-compatible live backend

/// One client for every OpenAI-compatible vendor (MiMo, DeepSeek, …). They all
/// expose the same `/v1/chat/completions` contract, so this is a thin POST — no
/// SDK, no framework, just `URLSession`. The only thing that varies per vendor is
/// the `Provider` (endpoint + model + key), passed in at construction.
///
/// The persona arrives as `system` and the running conversation as `messages`
/// (alternating user/assistant turns), which map straight onto the chat schema —
/// the system prompt as the first message, then the history. Cancellation is
/// honored: if the panel collapses mid-flight the `URLSession` task is torn down
/// with the surrounding `Task`.
struct OpenAICompatAIService: AIService {
    let apiKey: String
    let provider: Provider
    /// Model id; defaults to the provider's default when not overridden.
    var model: String

    init(provider: Provider, apiKey: String, model: String? = nil) {
        self.provider = provider
        self.apiKey = apiKey
        self.model = model ?? provider.defaultModel
    }

    private var endpoint: URL { provider.endpoint }

    /// Cap on how much of an error response body we'll read before giving up. A
    /// hostile/broken endpoint could stream an unbounded error body; we only need
    /// a short snippet for the message, so stop well before it can grow the
    /// process's memory. Shared by both clients via `drainErrorBody`.
    static let maxErrorBodyChars = 4096

    /// How long a streaming request may sit idle before `URLSession` aborts it, so
    /// a backend that opens the connection and then hangs can't pin the task open
    /// forever. Generous enough for slow first-token latency on real providers.
    static let streamTimeout: TimeInterval = 60

    /// Drain an error response body up to `maxErrorBodyChars`, then stop reading —
    /// the rest of the (possibly unbounded) stream is dropped. Shared so both the
    /// OpenAI-compatible and Anthropic clients cap the same way.
    static func drainErrorBody<S: AsyncSequence>(_ lines: S) async -> String
        where S.Element == String {
        var bodyText = ""
        do {
            for try await line in lines {
                bodyText += line
                if bodyText.count >= maxErrorBodyChars {
                    return String(bodyText.prefix(maxErrorBodyChars))
                }
            }
        } catch {
            // Partial body is still useful for the error message.
        }
        return bodyText
    }

    enum ServiceError: LocalizedError {
        case http(provider: String, status: Int, body: String)
        case malformedResponse(provider: String)

        var errorDescription: String? {
            switch self {
            case .http(let provider, let status, _):
                return "\(provider) request failed (HTTP \(status))."
            case .malformedResponse(let provider):
                return "\(provider) returned an unexpected response."
            }
        }
    }

    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: endpoint)
                    req.httpMethod = "POST"
                    req.timeoutInterval = Self.streamTimeout
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    for (field, value) in provider.extraHeaders {
                        req.setValue(value, forHTTPHeaderField: field)
                    }

                    // System prompt first, then the running conversation verbatim —
                    // so a follow-up is answered with every prior turn in context.
                    let chat = [Message(role: "system", content: system)]
                        + messages.map { Message(role: $0.role, content: $0.content) }
                    let body = RequestBody(
                        model: model,
                        messages: chat,
                        maxTokens: 1024,
                        tokenFieldName: provider.maxTokensField,
                        temperature: 0.7,
                        stream: true
                    )
                    req.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw ServiceError.malformedResponse(provider: provider.displayName)
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        // Drain the error body (capped) for a useful message.
                        let bodyText = await Self.drainErrorBody(bytes.lines)
                        throw ServiceError.http(provider: provider.displayName,
                                                status: http.statusCode, body: bodyText)
                    }

                    // Server-Sent Events: each event is a `data: {json}` line,
                    // terminated by `data: [DONE]`. We append only `delta.content`
                    // and deliberately skip `reasoning_content` (the model's
                    // think-aloud) so the notch shows the answer, not the
                    // scratchpad.
                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? decoder.decode(StreamChunk.self, from: data),
                              let piece = chunk.choices.first?.delta.content,
                              !piece.isEmpty
                        else { continue }
                        continuation.yield(piece)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // OpenAI-compatible request / streaming-response shapes (only fields we use).
    //
    // The output-cap field name differs across vendors: MiMo follows OpenAI's
    // newer `max_completion_tokens`, while DeepSeek uses the classic `max_tokens`.
    // We encode the same value under whichever key the provider expects, so the
    // rest of the request stays identical.
    private struct RequestBody: Encodable {
        let model: String
        let messages: [Message]
        let maxTokens: Int
        let tokenFieldName: String
        let temperature: Double
        let stream: Bool

        private struct DynamicKey: CodingKey {
            let stringValue: String
            init(_ s: String) { stringValue = s }
            init?(stringValue: String) { self.stringValue = stringValue }
            var intValue: Int? { nil }
            init?(intValue: Int) { return nil }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: DynamicKey.self)
            try c.encode(model, forKey: DynamicKey("model"))
            try c.encode(messages, forKey: DynamicKey("messages"))
            try c.encode(maxTokens, forKey: DynamicKey(tokenFieldName))
            try c.encode(temperature, forKey: DynamicKey("temperature"))
            try c.encode(stream, forKey: DynamicKey("stream"))
        }
    }
    private struct Message: Encodable {
        let role: String
        let content: String
    }
    /// One `chat.completion.chunk` event. `delta.content` is the incremental
    /// answer text; it's `null` on role-only and reasoning-only chunks, hence
    /// optional.
    private struct StreamChunk: Decodable {
        let choices: [Choice]
        struct Choice: Decodable { let delta: Delta }
        struct Delta: Decodable { let content: String? }
    }
}

// MARK: - Anthropic (Claude) native backend

/// Claude doesn't speak the OpenAI `/v1/chat/completions` contract, so it can't
/// ride `OpenAICompatAIService`. This is the same thin `URLSession` streaming
/// client shaped to Anthropic's native `/v1/messages` API instead:
///   · auth via the `x-api-key` header (not `Authorization: Bearer`)
///   · a required `anthropic-version` header
///   · the system prompt as a top-level `system` field, not a system message
///   · SSE events typed by `event.type`; the answer text arrives in
///     `content_block_delta` events as `delta.text`
///
/// It conforms to the same `AIService` protocol, so the UI and `NotchModel` are
/// none the wiser — `AppDelegate` just constructs this instead when the selected
/// provider is `.anthropic`.
struct AnthropicAIService: AIService {
    let apiKey: String
    let provider: Provider
    var model: String

    /// Pinned API version. Anthropic dates its breaking changes; `2023-06-01` is
    /// the long-stable baseline the Messages API ships against.
    private let anthropicVersion = "2023-06-01"

    init(provider: Provider = .anthropic, apiKey: String, model: String? = nil) {
        self.provider = provider
        self.apiKey = apiKey
        self.model = model ?? provider.defaultModel
    }

    func stream(system: String, messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: provider.endpoint)
                    req.httpMethod = "POST"
                    req.timeoutInterval = OpenAICompatAIService.streamTimeout
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    req.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")

                    // Anthropic takes the persona as a top-level `system` field and
                    // the conversation as `messages` (user/assistant only, no system
                    // role in the array) — both arrive ready to forward verbatim, so
                    // a follow-up carries the full prior context.
                    let body = RequestBody(
                        model: model,
                        system: system,
                        messages: messages.map { .init(role: $0.role, content: $0.content) },
                        maxTokens: 1024,
                        stream: true
                    )
                    req.httpBody = try JSONEncoder().encode(body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw OpenAICompatAIService.ServiceError.malformedResponse(provider: provider.displayName)
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        let bodyText = await OpenAICompatAIService.drainErrorBody(bytes.lines)
                        throw OpenAICompatAIService.ServiceError.http(provider: provider.displayName,
                                                                      status: http.statusCode, body: bodyText)
                    }

                    // SSE: lines come as `event: <type>` then `data: {json}`. We
                    // don't need the event line — the JSON carries its own `type`,
                    // and we only act on `content_block_delta` / `text_delta`,
                    // appending `delta.text`. Everything else (message_start,
                    // ping, content_block_stop, message_stop, …) is skipped.
                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        guard let data = payload.data(using: .utf8),
                              let event = try? decoder.decode(StreamEvent.self, from: data),
                              event.type == "content_block_delta",
                              let piece = event.delta?.text,
                              !piece.isEmpty
                        else { continue }
                        continuation.yield(piece)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // Anthropic Messages request / streaming-response shapes (only fields we use).
    private struct RequestBody: Encodable {
        let model: String
        let system: String
        let messages: [Message]
        let maxTokens: Int
        let stream: Bool

        enum CodingKeys: String, CodingKey {
            case model, system, messages, stream
            case maxTokens = "max_tokens"
        }
    }
    private struct Message: Encodable {
        let role: String
        let content: String
    }
    /// One SSE event. We only read `content_block_delta`, whose `delta.text` holds
    /// the incremental answer; on other event types `delta`/`text` are absent.
    private struct StreamEvent: Decodable {
        let type: String
        let delta: Delta?
        struct Delta: Decodable { let text: String? }
    }
}

// MARK: - Live model catalog (hot-updated, no app release needed)

/// Fetches the *live* list of models a provider currently serves, so the Settings
/// picker stays current when a vendor adds or renames a model — no new app build
/// required. This is the answer to "I can't ship a release every time a model name
/// changes": the names come from the vendor's own API at runtime.
///
/// Every OpenAI-compatible vendor exposes `GET /v1/models` (same auth as chat).
/// Anthropic exposes the same path with its `x-api-key` + `anthropic-version`
/// headers. We derive the models URL from the chat endpoint, fetch, and return the
/// ids. On any failure (no key, offline, vendor without the endpoint) the caller
/// falls back to `Provider.availableModels` — the built-in shortlist — so the
/// picker is never empty.
enum ModelCatalog {
    /// Fetch the provider's current model ids. Returns `nil` on any error so the
    /// caller can fall back to the bundled `availableModels` list.
    static func fetch(for provider: Provider, apiKey: String) async -> [String]? {
        guard let url = modelsURL(for: provider) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if provider.isOpenAICompatible {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        } else {
            // Anthropic: same key header + pinned version as the messages API.
            req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        req.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            let list = try JSONDecoder().decode(ModelList.self, from: data)
            let ids = list.data.map(\.id).filter { !$0.isEmpty }
            // OpenRouter's catalog is its FULL marketplace — hundreds of ids, most
            // of them paid, which a freshly-connected $0 account can't call. Offer
            // only what actually works free: the auto-router plus the current
            // `:free` variants.
            if provider == .openrouter {
                let free = ids.filter { $0.hasSuffix(":free") }.sorted()
                return ["openrouter/free"] + free
            }
            return ids.isEmpty ? nil : ids
        } catch {
            return nil
        }
    }

    /// Turn a chat endpoint into its `/models` sibling:
    ///   `.../v1/chat/completions`        → `.../v1/models`
    ///   `.../v1/messages` (Anthropic)    → `.../v1/models`
    ///   `.../compatible-mode/v1/chat/...`→ `.../compatible-mode/v1/models`
    /// Done by string surgery on the path so it works for every vendor's prefix.
    private static func modelsURL(for provider: Provider) -> URL? {
        let s = provider.endpoint.absoluteString
        for suffix in ["/chat/completions", "/messages"] where s.hasSuffix(suffix) {
            return URL(string: String(s.dropLast(suffix.count)) + "/models")
        }
        return nil
    }

    /// OpenAI-style `{ "data": [ { "id": "..." }, ... ] }`. Anthropic's
    /// `/v1/models` returns the same `data: [{ id }]` shape, so one decoder fits
    /// both.
    private struct ModelList: Decodable {
        let data: [Entry]
        struct Entry: Decodable { let id: String }
    }
}

// MARK: - Connectivity test

/// A one-shot "does this key actually work?" check for the Settings panel. It hits
/// the provider's `GET /v1/models` with the user's key — the same lightweight,
/// token-free request `ModelCatalog` uses — and turns the outcome into a verdict
/// the UI can show plainly. We probe `/v1/models` (not a chat completion) so the
/// test costs nothing and doesn't depend on a specific model id being valid.
enum ConnectivityTest {
    enum Result: Equatable {
        case ok                    // reachable + authenticated
        case missingKey            // nothing to test
        case unauthorized(Int)     // 401/403 — bad or revoked key
        case http(Int)             // other non-2xx from the server
        case offline               // no network / DNS / connection failure
        case timedOut
        case failed(String)        // anything else, with a short reason

        /// Short user-facing line for the Settings footer.
        var message: String {
            switch self {
            case .ok:                 return "Key verified"
            case .missingKey:         return "Enter a key"
            case .unauthorized:       return "Invalid key"
            case .http(let code):     return "Server error (\(code))"
            case .offline:            return "No connection"
            case .timedOut:           return "Timed out"
            case .failed(let why):    return why
            }
        }

        var isOK: Bool { self == .ok }
    }

    /// Probe `provider` with `apiKey`. Network call; safe to await off the main
    /// actor. Returns a verdict — never throws.
    static func run(provider: Provider, apiKey: String) async -> Result {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .missingKey }
        guard let url = probeURL(for: provider) else {
            // No /models sibling we can derive — fall back to "we can't test this".
            return .failed("Test unavailable for this provider")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        if provider.isOpenAICompatible {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        } else {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        req.timeoutInterval = 12

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failed("Unexpected response")
            }
            switch http.statusCode {
            case 200..<300:   return .ok
            case 401, 403:    return .unauthorized(http.statusCode)
            default:          return .http(http.statusCode)
            }
        } catch let error as URLError {
            switch error.code {
            case .timedOut:                   return .timedOut
            case .notConnectedToInternet,
                 .cannotConnectToHost,
                 .cannotFindHost,
                 .networkConnectionLost,
                 .dnsLookupFailed:            return .offline
            default:                          return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Same path derivation as `ModelCatalog.modelsURL`, duplicated here so the test
    /// doesn't depend on that enum's private helper. OpenRouter is the exception:
    /// its `/models` is public (answers 200 to any key, so it can't judge one) —
    /// `/api/v1/key` requires auth and describes the key, making it the honest probe.
    private static func probeURL(for provider: Provider) -> URL? {
        if provider == .openrouter {
            return URL(string: "https://openrouter.ai/api/v1/key")
        }
        let s = provider.endpoint.absoluteString
        for suffix in ["/chat/completions", "/messages"] where s.hasSuffix(suffix) {
            return URL(string: String(s.dropLast(suffix.count)) + "/models")
        }
        return nil
    }
}
