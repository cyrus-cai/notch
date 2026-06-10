import Foundation

/// Decides, from the text in the input box alone, whether the user is more likely
/// **asking the AI** or **jotting a note** — so the panel routes the line to the
/// right surface on its own, without the user having to remember which mode they're
/// in and switch to it by hand.
///
/// This is the deliberate design choice behind the whole feature: it's a **pure,
/// local, zero-latency function**, not a model call. Two reasons drove that:
///
///   1. The interaction is "live, correct-before-send" — the send button's label
///      ("Ask" / "Note") updates on every keystroke and the Enter that follows it
///      routes to match. Per-keystroke inference (device-side or remote) can't be
///      that cheap, so only a plain function fits.
///   2. A big slice of the user base is in mainland China (half the shipped
///      providers are Chinese models). Apple's on-device model needs Apple
///      Intelligence, which isn't available there — so a model-based classifier
///      would silently leave those users with no signal at all.
///
/// The mis-fire cost is already absorbed by the UI around it: the destination is
/// spelled out on the button while typing, so an occasional wrong guess costs a
/// glance and an edit before Enter, never a misrouted message. That makes a rules
/// engine's ~70-85% accuracy plenty here.
///
/// `classify` is intentionally the only entry point and returns a `Result` (intent
/// + confidence + why), so a future enhancement — e.g. layering Apple's
/// `FoundationModels` on top *only* on capable, eligible devices — can slot in as
/// a fallback for the `.ambiguous` case without the UI layer changing at all.
enum IntentClassifier {
    /// What the text reads as. `ambiguous` means the signals conflicted or none
    /// fired — the caller decides the default (here: treat it as ask).
    enum Intent: Equatable {
        case ask
        case note
        case ambiguous
    }

    /// The verdict for one piece of text. `confidence` is a rough 0…1 strength of
    /// the winning signal (for the UI to decide how loudly to hint); `reason` is a
    /// short tag, handy for debugging/tuning and never shown to the user.
    struct Result: Equatable {
        var intent: Intent
        var confidence: Double
        var reason: String

        static let empty = Result(intent: .ambiguous, confidence: 0, reason: "empty")
    }

    /// Classify a raw input string. Trims first; empty text is `.ambiguous` so the
    /// resting box hints nothing.
    static func classify(_ raw: String) -> Result {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }

        let lower = text.lowercased()
        // Score each side; the larger margin wins, ties fall to ambiguous.
        var askScore = 0.0
        var noteScore = 0.0
        var reasons: [String] = []

        // ---- Strong ASK: a trailing question mark (CJK or ASCII). ----
        // The single most reliable signal in both languages — a question mark at
        // the end is almost always a question.
        if let last = text.unicodeScalars.last,
           last == "?" || last == "？" {
            askScore += 2.0
            reasons.append("qmark")
        }

        // ---- ASK: interrogative / request openers. ----
        // Chinese question words and English wh-/auxiliary openers, plus polite
        // request verbs ("帮我…", "translate…") that signal a task for the AI. CJK
        // openers match the original text (case doesn't apply); English ones match
        // the lowercased copy with a word-boundary guard.
        if matchesAny(text, prefixes: Self.askOpenersCJK)
            || matchesAny(lower, prefixes: Self.askOpenersLower) {
            askScore += 1.5
            reasons.append("ask-opener")
        }
        // Imperative help/▸do verbs anywhere near the start ("帮我写", "解释一下",
        // "summarize this") — a command aimed at the assistant.
        if containsAny(lower, Self.askVerbsLower) {
            askScore += 1.0
            reasons.append("ask-verb")
        }
        // A bare interrogative word sitting *inside* the line ("…是谁", "…对不对")
        // even without a question mark.
        if containsAny(text, Self.askMarkersCJK) {
            askScore += 1.0
            reasons.append("ask-marker")
        }

        // ---- NOTE: todo / reminder phrasing. ----
        if matchesAny(lower, prefixes: Self.noteOpenersLower)
            || containsAny(text, Self.noteMarkersCJK) {
            noteScore += 1.7
            reasons.append("note-cue")
        }
        // A leading time/date word with no question signal reads as a memo entry
        // ("明天交房租", "下午3点开会", "周五 deadline"). Only counts when nothing
        // ask-ish has fired, so "明天会下雨吗" stays a question.
        if askScore == 0, startsWithTimeCue(text, lower) {
            noteScore += 1.2
            reasons.append("note-time")
        }
        // Short, punctuation-free fragment: a *weak* corroborator, never a note
        // signal on its own. A bare noun phrase with no other cue ("天气", "小米")
        // is genuinely ambiguous — and ambiguous must fall to ask, not get quietly
        // filed as a note. So this only adds weight when some other note signal has
        // already fired (a time cue / todo phrasing), nudging e.g. "明天 团建" over
        // the line; alone it contributes nothing.
        if askScore == 0, noteScore > 0, looksLikeFragment(text) {
            noteScore += 0.6
            reasons.append("note-fragment")
        }

        // ---- Decide. ----
        let margin = abs(askScore - noteScore)
        let reason = reasons.isEmpty ? "no-signal" : reasons.joined(separator: "+")

        // No signal at all, or a genuine tie → ambiguous (caller defaults to ask).
        guard margin > 0.001 else {
            return Result(intent: .ambiguous, confidence: 0, reason: reason)
        }

        if askScore > noteScore {
            return Result(intent: .ask,
                          confidence: confidence(for: askScore),
                          reason: reason)
        } else {
            return Result(intent: .note,
                          confidence: confidence(for: noteScore),
                          reason: reason)
        }
    }

    // MARK: - Scoring helpers

    /// Map a raw score onto a rough 0…1 confidence. A single weak signal lands
    /// around 0.4–0.5; a question mark plus an opener saturates near 1.
    private static func confidence(for score: Double) -> Double {
        min(1.0, score / 3.0)
    }

    /// True if `text` begins with any of `prefixes` (already lowercased). For the
    /// English openers we require a word boundary so "whatever" doesn't match
    /// "what"; CJK has no spaces so prefix matching is the boundary.
    private static func matchesAny(_ text: String, prefixes: [String]) -> Bool {
        for p in prefixes where text.hasPrefix(p) {
            // ASCII opener → must be followed by a boundary (space/punct/end), so
            // "what time" matches but "whatsapp" does not. CJK openers (no ASCII)
            // skip this check.
            if let next = text.dropFirst(p.count).first,
               p.allSatisfy({ $0.isASCII }) {
                if next.isLetter || next.isNumber { continue }
            }
            return true
        }
        return false
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        for n in needles where text.contains(n) { return true }
        return false
    }

    /// A leading time/date cue: the line opens with a relative-time or clock word.
    private static func startsWithTimeCue(_ text: String, _ lower: String) -> Bool {
        if matchesAny(text, prefixes: Self.timeCuesCJK) { return true }
        if matchesAny(lower, prefixes: Self.timeCuesLower) { return true }
        return false
    }

    /// Heuristic for a "jot": short, no sentence-ending punctuation, and not
    /// obviously a question. Length is measured leniently in characters; CJK packs
    /// more meaning per char so the bar is a bit lower for it.
    private static func looksLikeFragment(_ text: String) -> Bool {
        // Sentence-ending punctuation argues against a terse jot.
        if text.contains("。") || text.contains("！") || text.contains(".")
            || text.contains("!") { return false }
        let isCJK = text.unicodeScalars.contains { $0.value >= 0x3400 && $0.value <= 0x9FFF }
        let count = text.count
        if isCJK { return count <= 12 }
        // For Latin text, gauge by word count — up to ~5 words reads as a fragment.
        let words = text.split { $0 == " " || $0 == "\t" }.count
        return words <= 5 && count <= 40
    }

    // MARK: - Lexicons
    //
    // Curated, not exhaustive — tuned to cover the common, unambiguous cases and
    // lean on `.ambiguous → ask` for the rest. Lowercased lists are matched against
    // the lowercased text; CJK lists against the original (case doesn't apply).

    /// Openers that almost always begin a question. CJK first, then English
    /// wh-/auxiliary words and polite request leads.
    private static let askOpenersLower: [String] = [
        // English wh-words
        "what", "why", "how", "who", "where", "when", "which", "whose", "whom",
        // English auxiliaries / yes-no openers
        "is ", "are ", "am ", "do ", "does ", "did ", "can ", "could ", "would ",
        "should ", "will ", "shall ", "may ", "might ", "was ", "were ", "has ",
        "have ", "had ", "is", "are", "can", "could", "would", "should",
        // Polite request leads
        "please ", "could you", "can you", "help me", "tell me", "give me",
        "explain", "translate", "summarize", "summarise", "write", "generate",
        "draft", "compare", "list", "show me", "find", "search", "recommend",
        "suggest", "calculate", "convert", "define", "describe",
    ]

    /// CJK question openers (matched as prefixes).
    private static let askOpenersCJK: [String] = [
        "什么", "为什么", "为何", "怎么", "怎样", "如何", "谁", "哪", "几时",
        "多少", "是不是", "是否", "能不能", "可不可以", "可以吗", "要不要",
        "有没有", "会不会", "该不该", "对不对", "好不好",
    ]

    /// Request/▸do verbs that signal a task handed to the assistant. CJK + English.
    private static let askVerbsLower: [String] = [
        "帮我", "帮忙", "帮", "解释", "翻译", "总结", "概括", "写一", "写个",
        "写一下", "画", "算一", "算个", "查一", "查个", "查询", "推荐", "对比",
        "比较", "分析", "介绍", "说明", "讲讲", "讲一下", "告诉我", "给我",
        "explain", "translate", "summarize", "summarise", "rewrite", "fix",
        "debug", "review", "compare", "recommend", "suggest", "calculate",
        "convert", "define", "describe", "analyze", "analyse",
    ]

    /// Interrogative markers that can sit anywhere in a CJK line (no question mark
    /// needed): question words used mid-sentence, tail particles, and A-not-A
    /// patterns. These catch questions whose interrogative isn't at the very start
    /// ("这个怎么用", "小米的市值是多少", "python 如何读文件").
    private static let askMarkersCJK: [String] = [
        // Question words used mid-string (the openers list only matches at the very
        // start; these cover the same words appearing after a subject/topic).
        "怎么", "怎样", "如何", "为什么", "为何", "是多少", "多少钱", "是谁",
        "是什么", "哪个", "哪些", "哪里", "在哪",
        // Tail particles and A-not-A patterns.
        "怎么办", "怎么回事", "对吗", "对不对", "好吗", "好不好", "是吗",
        "是不是", "可以吗", "行吗", "吗", "呢？", "了吗", "了没",
    ]

    /// Explicit note/reminder openers. CJK first.
    private static let noteOpenersLower: [String] = [
        "记一下", "记下", "记得", "记录", "提醒我", "提醒", "别忘", "别忘了",
        "备忘", "待办", "todo", "to-do", "to do", "note:", "note ", "memo",
        "remember to", "remind me", "don't forget", "dont forget",
    ]

    /// Note markers that can appear anywhere in the line.
    private static let noteMarkersCJK: [String] = [
        "记一下", "提醒我", "别忘", "待办事项", "todo",
    ]

    /// Leading relative-time / clock words that mark a memo entry. CJK.
    private static let timeCuesCJK: [String] = [
        "今天", "明天", "后天", "昨天", "下午", "上午", "中午", "晚上", "早上",
        "今晚", "今早", "周一", "周二", "周三", "周四", "周五", "周六", "周日",
        "周末", "下周", "本周", "下个月", "这个月", "月底", "月初", "今晚",
    ]

    /// Leading time words. English.
    private static let timeCuesLower: [String] = [
        "today", "tomorrow", "tonight", "yesterday", "monday", "tuesday",
        "wednesday", "thursday", "friday", "saturday", "sunday", "next week",
        "this week", "next month", "this morning", "this afternoon", "this evening",
    ]
}
