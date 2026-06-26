import Foundation
import AppKit

// MARK: - Built-in agent tools
//
// The first, deliberately small tool surface. Every tool here is low-risk and
// local: read what the user already copied, tell the time, open a URL the user
// can see, or run a web search. No file-system writes, no shell, no computer-use
// — those high-blast-radius surfaces are intentionally out of scope for this
// pass. The harness advertises exactly this set; growing it is a matter of adding
// a `NotchTool` and registering it (see `ToolRegistry` construction in
// `NotchModel`).

/// Current local date and time. The notch assistant has no clock of its own
/// (the model's knowledge has a cutoff), so any "what day is it / how long until
/// …" question needs this. Argument-less.
struct DateTimeTool: NotchTool {
    let name = "current_datetime"
    let description = """
    Returns the user's current local date, time, and timezone. Call this whenever \
    the answer depends on the current moment — "what day is it", "what time is \
    it", scheduling, "how long until X", or any relative-date reasoning. Do not \
    guess the date from training data; call this instead.
    """
    let schema: [String: Any] = ["type": "object", "properties": [:]]

    func execute(_ input: [String: Any]) async throws -> String {
        let now = Date()
        let fmt = DateFormatter()
        fmt.dateStyle = .full
        fmt.timeStyle = .long
        // Render in the user's chosen interface language so the model reads a date
        // string in the same language it's answering in.
        switch Localization.shared.language.resolved {
        case .en:     fmt.locale = Foundation.Locale(identifier: "en_US")
        case .zhHans: fmt.locale = Foundation.Locale(identifier: "zh_Hans")
        case .zhHant: fmt.locale = Foundation.Locale(identifier: "zh_Hant")
        }
        let tz = TimeZone.current
        return "\(fmt.string(from: now)) (timezone \(tz.identifier), UTC offset \(tz.secondsFromGMT() / 3600))"
    }
}

/// Read the system clipboard. The notch already pulls clipboard text into the
/// prompt heuristically (`clipboardContextIfEligible`); this gives the *model*
/// explicit, on-demand access for the cases that heuristic skips — a follow-up
/// turn, or a question the classifier didn't read as referential. Returns text or
/// a short "nothing usable" note; never the raw pasteboard object.
struct ReadClipboardTool: NotchTool {
    let name = "read_clipboard"
    let description = """
    Returns the current text contents of the user's clipboard. Call this when the \
    user refers to "this", "what I copied", "the text above", or otherwise points \
    at content they've put on the clipboard that isn't already in the conversation.
    """
    let schema: [String: Any] = ["type": "object", "properties": [:]]

    /// Cap the returned text so a giant clipboard can't blow up the next turn's
    /// context. Mirrors the 1500-char gate the heuristic path uses, with headroom.
    private static let maxChars = 4000

    func execute(_ input: [String: Any]) async throws -> String {
        // NSPasteboard must be read on the main thread.
        let text: String? = await MainActor.run {
            NSPasteboard.general.string(forType: .string)
        }
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return "The clipboard is empty or holds no readable text."
        }
        return raw.count > Self.maxChars
            ? String(raw.prefix(Self.maxChars)) + "\n…(clipboard truncated)"
            : raw
    }
}

/// Kimi's `$web_search` is a *builtin* server tool with an unusual contract
/// (XII-118): the model emits a tool call, and the client must echo the call's
/// arguments back **unchanged** for Moonshot to actually run the search
/// server-side. There is no local search to perform — this "tool" exists only so
/// the harness's ordinary tool loop has something to dispatch to instead of
/// failing on an unknown name, and its `execute` returns its own input re-encoded
/// as JSON, which is exactly the echo Kimi expects. Registered only for the Kimi
/// provider (see `ToolRegistry.standard(for:)`); never advertised — Kimi declares
/// the tool itself via the request's `builtin_function` entry, so this carries no
/// description/schema the model would ever read.
struct KimiWebSearchPassthrough: NotchTool {
    let name = "$web_search"
    let description = ""
    let schema: [String: Any] = ["type": "object", "properties": [:]]

    func execute(_ input: [String: Any]) async throws -> String {
        // Echo the model's arguments back verbatim as a JSON string — Moonshot
        // runs the real search on receiving this. Anything else (an error, a
        // summary, empty) means the search silently never happens.
        guard let data = try? JSONSerialization.data(withJSONObject: input),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

/// Real web search for GLM, via Zhipu's **standalone** Web Search API
/// (`/paas/v4/web_search`). XII-118 originally wired GLM as a "mode A" in-chat
/// `tools:[{web_search}]` entry, but live testing showed that path silently does
/// NOT search on the current account/models (glm-4.5-air / glm-4.6 / glm-4-air all
/// returned training-cutoff hallucinations with no `web_search` array) — exactly
/// the dishonest behavior XII-116 fought. The standalone API, by contrast, returns
/// genuine real-time results. So GLM search is a real *client-side* tool: the
/// model calls it, the harness hits the standalone endpoint with the user's GLM
/// key, and feeds the results back. This DOES drive the "🔍 searching" activity
/// line (it goes through the harness tool loop), unlike a true server-side search.
struct GLMWebSearchTool: SourcedTool {
    // NOT "web_search": that name collides with GLM's own built-in server-side
    // web_search tool, so glm-4.x mistakes this client tool for the builtin —
    // it ignores the results we feed back and re-calls the tool in a loop until
    // the iteration cap, then answers from training data (the stale/hallucinated
    // answers Cyrus saw). A distinct name makes the model treat it as an ordinary
    // function: it reads the fed-back results and answers from them. Verified live.
    let name = "lookup_web"
    let description = """
    Searches the web for current, real-time information and returns the top \
    results with sources and dates. Call this whenever the answer depends on \
    information that may have changed or is past your knowledge cutoff — news, \
    current events, today's prices or rates, the latest version of something, or \
    anything time-sensitive. Prefer a focused query. If the results don't contain \
    the answer, say so rather than guessing.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "The search query."]
        ],
        "required": ["query"],
    ]

    private static let endpoint = URL(string: "https://open.bigmodel.cn/api/paas/v4/web_search")!
    private static let timeout: TimeInterval = 15
    private static let maxResults = 6

    // Conforms to the plain protocol via the sourced path: the model gets the
    // text, the UI gets the sources, both from one search.
    func execute(_ input: [String: Any]) async throws -> String {
        try await runSourced(input).text
    }

    func runSourced(_ input: [String: Any]) async throws -> (text: String, sources: [WebSource]) {
        guard let query = (input["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return ("Error: empty search query.", [])
        }
        // The tool reads the GLM key itself (same source as the service), so the
        // NotchTool protocol stays key-agnostic.
        guard let key = APIKeyStore.current(for: .glm) else {
            return ("Error: no GLM API key configured, can't search.", [])
        }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = Self.timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "search_engine": "search_pro",
            "search_query": query,
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return ("Search failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).", [])
            }
            return Self.parse(data, query: query)
        } catch {
            return ("Search failed: \(error.localizedDescription)", [])
        }
    }

    /// Parse the standalone API's `{ search_result: [{title, content, link,
    /// publish_date, …}] }` once into BOTH the model-facing text (a compact, dated,
    /// sourced block it grounds on — with an explicit "no results" so it never
    /// invents an answer) and the structured `[WebSource]` for the UI badge. Only
    /// results carrying a usable http(s) link become badge sources; the text still
    /// includes link-less results so the model can use them.
    private static func parse(_ data: Data, query: String) -> (text: String, sources: [WebSource]) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["search_result"] as? [[String: Any]], !results.isEmpty else {
            let miss = "The search returned no results for \"\(query)\". Do not fabricate "
                     + "an answer — tell the user the search found nothing on this."
            return (miss, [])
        }
        let top = results.prefix(maxResults)
        let blocks = top.enumerated().map { (i, r) -> String in
            let title = (r["title"] as? String) ?? "(untitled)"
            let date = (r["publish_date"] as? String).map { " (\($0))" } ?? ""
            let link = (r["link"] as? String).flatMap { $0.isEmpty ? nil : "\n   \($0)" } ?? ""
            var snippet = (r["content"] as? String) ?? ""
            if snippet.count > 500 { snippet = String(snippet.prefix(500)) + "…" }
            return "[\(i + 1)] \(title)\(date)\n   \(snippet)\(link)"
        }
        let text = "Web search results for \"\(query)\":\n\n" + blocks.joined(separator: "\n\n")

        var seen = Set<String>()
        let sources: [WebSource] = top.compactMap { r in
            guard let link = r["link"] as? String,
                  let scheme = URL(string: link)?.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  !seen.contains(link) else { return nil }
            seen.insert(link)
            let title = (r["title"] as? String) ?? link
            let date = (r["publish_date"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return WebSource(title: title, url: link, date: date)
        }
        return (text, sources)
    }
}

/// Provider-agnostic web search via **Exa** (`https://api.exa.ai/search`). Unlike
/// `GLMWebSearchTool` (which reuses the GLM provider's key and only exists because
/// GLM's in-chat search silently no-ops), Exa is a standalone search backend with
/// its own key (`APIKeyStore.currentExaKey()` / `EXA_API_KEY`). When that key is
/// present this tool is registered for *every* provider and the providers' own
/// native server-side search is suppressed — Exa becomes the single searcher for
/// all backends (the point: a better, fresher, cheaper replacement than each
/// vendor's built-in search). Like the GLM tool it is a `SourcedTool`: one call
/// yields both the model-facing grounded text and the `[WebSource]` badge data.
///
/// Request shape follows Exa's coding-agent guide: `type:"auto"` (balanced
/// relevance/speed), `numResults`, and `contents:{highlights:true}` for
/// token-efficient, query-relevant excerpts. Response: `results[]` each carrying
/// `title`, `url`, `publishedDate`, and a `highlights` string array (with `text`
/// as a fallback when a result has no highlights).
struct ExaWebSearchTool: SourcedTool {
    let name = "exa_search"
    let description = """
    Searches the web for current, real-time information and returns the top \
    results with sources and dates. Call this whenever the answer depends on \
    information that may have changed or is past your knowledge cutoff — news, \
    current events, today's prices or rates, the latest version of something, or \
    anything time-sensitive. Prefer a focused query. If the results don't contain \
    the answer, say so rather than guessing.
    """
    let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "The search query."]
        ],
        "required": ["query"],
    ]

    private static let endpoint = URL(string: "https://api.exa.ai/search")!
    private static let timeout: TimeInterval = 15
    private static let maxResults = 6

    func execute(_ input: [String: Any]) async throws -> String {
        try await runSourced(input).text
    }

    func runSourced(_ input: [String: Any]) async throws -> (text: String, sources: [WebSource]) {
        guard let query = (input["query"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return ("Error: empty search query.", [])
        }
        guard let key = APIKeyStore.currentExaKey() else {
            return ("Error: no Exa API key configured, can't search.", [])
        }

        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = Self.timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Exa authenticates with an `x-api-key` header, not a Bearer token.
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "query": query,
            "type": "auto",
            "numResults": Self.maxResults,
            "contents": ["highlights": true],
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return ("Search failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).", [])
            }
            return Self.parse(data, query: query)
        } catch {
            return ("Search failed: \(error.localizedDescription)", [])
        }
    }

    /// Parse Exa's `{ results: [{title, url, publishedDate, highlights:[...],
    /// text}] }` once into BOTH the model-facing text (a compact, dated, sourced
    /// block it grounds on — with an explicit "no results" so it never invents an
    /// answer) and the structured `[WebSource]` for the UI badge. The snippet is
    /// the joined `highlights`, falling back to `text` when a result has none.
    private static func parse(_ data: Data, query: String) -> (text: String, sources: [WebSource]) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]], !results.isEmpty else {
            let miss = "The search returned no results for \"\(query)\". Do not fabricate "
                     + "an answer — tell the user the search found nothing on this."
            return (miss, [])
        }
        let top = results.prefix(maxResults)
        let blocks = top.enumerated().map { (i, r) -> String in
            let title = (r["title"] as? String) ?? "(untitled)"
            let date = (r["publishedDate"] as? String).flatMap { $0.isEmpty ? nil : " (\($0))" } ?? ""
            let link = (r["url"] as? String).flatMap { $0.isEmpty ? nil : "\n   \($0)" } ?? ""
            var snippet = snippetText(from: r)
            if snippet.count > 500 { snippet = String(snippet.prefix(500)) + "…" }
            return "[\(i + 1)] \(title)\(date)\n   \(snippet)\(link)"
        }
        let text = "Web search results for \"\(query)\":\n\n" + blocks.joined(separator: "\n\n")

        var seen = Set<String>()
        let sources: [WebSource] = top.compactMap { r in
            guard let link = r["url"] as? String,
                  let scheme = URL(string: link)?.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  !seen.contains(link) else { return nil }
            seen.insert(link)
            let title = (r["title"] as? String) ?? link
            let date = (r["publishedDate"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return WebSource(title: title, url: link, date: date)
        }
        return (text, sources)
    }

    /// The result's query-relevant excerpt: the joined `highlights` array, or the
    /// full `text` when highlights are absent (e.g. a result Exa couldn't excerpt).
    private static func snippetText(from r: [String: Any]) -> String {
        if let highlights = r["highlights"] as? [String] {
            let joined = highlights
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " … ")
            if !joined.isEmpty { return joined }
        }
        return (r["text"] as? String) ?? ""
    }
}

// MARK: - Default registry

extension ToolRegistry {
    /// The standard tool set handed to the agent for a given provider. Built once
    /// per submit; an unconfigured/offline session can be given `ToolRegistry([])`
    /// instead to force the plain non-agent path.
    ///
    /// For most providers, real web search is NOT a tool here — it's the
    /// provider's own server-side search, injected into the request by `streamTurn`
    /// off `Provider.serverSearch` (XII-118). Two providers are client-side
    /// exceptions, both added here per provider:
    ///  • **GLM** — its in-chat `tools:[{web_search}]` path silently doesn't search
    ///    on the current account/models (verified live), so GLM uses a real
    ///    client-side `GLMWebSearchTool` that hits Zhipu's standalone search API.
    ///  • **Kimi** — its builtin search needs a client-side echo, so the
    ///    `$web_search` passthrough is added so the harness can echo the call back.
    /// (The defunct DuckDuckGo `WebSearchTool` was removed — see XII-116/XII-118.)
    ///
    /// **Exa override:** when the user has configured an Exa key
    /// (`APIKeyStore.exaActive`), Exa replaces search for *every* provider — the
    /// `ExaWebSearchTool` is registered here and each provider's own native search
    /// is suppressed (the server-search gate in `streamTurn` and the GLM/Kimi
    /// client tools below all defer to Exa). One fresher/cheaper searcher for all
    /// backends, instead of each vendor's built-in.
    static func standard(for provider: Provider) -> ToolRegistry {
        var tools: [NotchTool] = [
            DateTimeTool(),
            ReadClipboardTool(),
        ]
        if APIKeyStore.exaActive {
            // Exa is the single searcher for all providers; the providers' own
            // search (GLM client tool, Kimi echo, native server search) stands down.
            tools.append(ExaWebSearchTool())
        } else {
            if provider == .glm {
                tools.append(GLMWebSearchTool())
            }
            if provider.builtinSearchName == "$web_search" {
                tools.append(KimiWebSearchPassthrough())
            }
        }
        return ToolRegistry(tools)
    }

    /// Provider-agnostic default, kept for call sites that don't yet thread a
    /// provider through (it omits any provider-specific builtin like Kimi's echo).
    static var standard: ToolRegistry { ToolRegistry([
        DateTimeTool(), ReadClipboardTool(),
    ]) }
}
