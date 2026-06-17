import SwiftUI
import Combine
import AppKit   // NSWorkspace — opening Notes/Reminders for a Recent capture

/// The notch's interaction state. Mirrors the prototype's `mode` plus the
/// open/closed state, and owns the history list + AI calls.
@MainActor
final class NotchModel: ObservableObject {
    enum Mode: Equatable {
        case idle      // resting input, may show "Recent"
        case load      // waiting on the AI
        case result    // showing an answer
    }

    /// Where pressing Enter on the current line will *send* it — decided live by the
    /// intent classifier as you type. This is a routing destination, NOT a rendered
    /// surface: there's only ever one input on screen ("Type anything…"). It just
    /// determines whether Enter asks the AI or files the line somewhere.
    ///   · `chat`     — ask the AI a question (idle/load/result)
    ///   · `note`     — file the line as a new note in Apple Notes
    ///   · `reminder` — file the line in Apple Reminders with the time it names
    enum Panel: String, Equatable {
        case chat
        case note
        case reminder
    }

    /// One bubble in the on-screen conversation. `role` is `"user"` or
    /// `"assistant"`; the assistant turn is created empty and filled as the stream
    /// arrives (`streaming` is true until it finishes), which is what lets the text
    /// appear to grow in place.
    struct Turn: Identifiable, Codable, Equatable {
        var id = UUID()
        var role: String     // "user" | "assistant"
        var text: String
        var streaming: Bool = false
        /// True on the *user* turn whose message was enriched with the clipboard, so
        /// the result view can show a permanent "based on what you copied" trace above
        /// it — not a flag that flashes during load and vanishes. Always false on
        /// assistant turns.
        var usedClipboard: Bool = false

        init(id: UUID = UUID(), role: String, text: String,
             streaming: Bool = false, usedClipboard: Bool = false) {
            self.id = id; self.role = role; self.text = text
            self.streaming = streaming; self.usedClipboard = usedClipboard
        }

        // Same defensive decode as `HistoryItem` (see the long note there): turns
        // are persisted inside a saved thread, and the whole history list is
        // decoded in one `try?` — so a turn saved before `usedClipboard`/`streaming`
        // existed must NOT throw `keyNotFound` and take the entire list down with
        // it. `decodeIfPresent` + defaults is what keeps old saved conversations
        // loadable. `role`/`text` are required — every saved turn has them.
        enum CodingKeys: String, CodingKey { case id, role, text, streaming, usedClipboard }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id           = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            role         = try c.decode(String.self, forKey: .role)
            text         = try c.decode(String.self, forKey: .text)
            streaming    = try c.decodeIfPresent(Bool.self, forKey: .streaming) ?? false
            usedClipboard = try c.decodeIfPresent(Bool.self, forKey: .usedClipboard) ?? false
        }
    }

    struct HistoryItem: Identifiable, Codable, Equatable {
        var id = UUID()
        var q: String
        var a: String
        var t: Date
        /// The full conversation, so reopening a recent item restores every turn
        /// (not just the first Q/A). Optional for backward-compatible decoding of
        /// items saved before multi-turn — those fall back to `[q, a]`.
        var turns: [Turn]? = nil
        /// A short title summarizing the actual conversation content. Generated
        /// asynchronously after the first answer so the recent list can show the
        /// topic (e.g. "小米高管") instead of a generic first prompt (e.g.
        /// "总结一下"). `nil` for legacy items and for unconfigured/offline sessions.
        var title: String? = nil
        /// What the recent list should display: the generated title when available,
        /// otherwise the first user message for backward compatibility.
        var displayTitle: String { title ?? q }

        /// Where this captured line actually went. `.ask` is an AI Q&A (reopens the
        /// conversation); `.note`/`.reminder` are captures filed into Apple
        /// Notes/Reminders — they keep a trace in Recent but have no answer to
        /// reopen, so tapping one jumps to that note/reminder in its app instead.
        /// Defaults to `.ask`; decoded with `decodeIfPresent` (see `init(from:)`)
        /// so items saved before this field decode as `.ask`, not a hard failure.
        enum Source: String, Codable { case ask, note, reminder }
        var source: Source = .ask

        /// Deep link back to the exact note/reminder this capture created, so
        /// tapping the row jumps straight to it in Apple Notes/Reminders instead
        /// of re-filling the input. The note's `x-coredata://` id (opened via
        /// AppleScript `show`) for notes, an `x-apple-reminderkit://` URL for
        /// reminders. `nil` for `.ask` items, and for captures saved before this
        /// field existed — those fall back to opening the destination app's main
        /// window (see `openCapture`). The service layer captures the identifier at
        /// creation time; if that capture fails the link stays nil and the row
        /// still opens the app, never dead-ends.
        var link: String? = nil

        /// The turns to restore on reopen: the saved thread when present, else a
        /// two-turn thread rebuilt from the legacy `q`/`a` fields. A note/reminder
        /// capture has no conversation at all — never synthesize a ghost assistant
        /// bubble for it.
        var conversation: [Turn] {
            guard source == .ask else { return [] }
            return turns ?? [
                Turn(role: "user", text: q),
                Turn(role: "assistant", text: a),
            ]
        }

        init(id: UUID = UUID(), q: String, a: String, t: Date,
             turns: [Turn]? = nil, title: String? = nil,
             source: Source = .ask, link: String? = nil) {
            self.id = id; self.q = q; self.a = a; self.t = t
            self.turns = turns; self.title = title
            self.source = source; self.link = link
        }

        // Custom decoder — the load-bearing reason this exists: history is decoded
        // as one `try? JSONDecoder().decode([HistoryItem].self …)` (see
        // `loadHistory`), so if ONE item fails to decode the WHOLE list is dropped
        // and every Recent row vanishes. Swift's *synthesized* `Decodable` calls
        // `decode` (not `decodeIfPresent`) for non-optional stored properties even
        // when they carry a Swift default — the `= .ask` / `= nil` defaults apply
        // only to the memberwise init, NOT to decoding. So an item saved before
        // `source`/`link`/`turns`/`title` existed would throw `keyNotFound` and
        // wipe the list. Decoding the newer fields with `decodeIfPresent` (and
        // falling back to their defaults) is what actually makes old items decode
        // cleanly with no migration. `id`/`q`/`a`/`t` are required — every saved
        // item has always had them.
        enum CodingKeys: String, CodingKey { case id, q, a, t, turns, title, source, link }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id     = try c.decode(UUID.self,   forKey: .id)
            q      = try c.decode(String.self, forKey: .q)
            a      = try c.decode(String.self, forKey: .a)
            t      = try c.decode(Date.self,   forKey: .t)
            turns  = try c.decodeIfPresent([Turn].self,  forKey: .turns)
            title  = try c.decodeIfPresent(String.self,  forKey: .title)
            source = try c.decodeIfPresent(Source.self,  forKey: .source) ?? .ask
            link   = try c.decodeIfPresent(String.self,  forKey: .link)
        }
    }

    // Open / closed drives the grow-out-of-the-notch animation.
    @Published var open = false
    /// Which screen's island is unfurled. With one panel per display sharing this
    /// model, `open` alone would unfurl every screen at once — views gate on
    /// `isOpen(on:)` so only the hovered screen expands while the others keep
    /// their resting notch. `nil` while closed (and in single-screen debug paths,
    /// where it means "any screen").
    @Published var activeDisplay: CGDirectDisplayID? = nil
    @Published var mode: Mode = .idle

    /// The cursor's velocity at the instant the island opened — SwiftUI
    /// orientation (+x right, +y down), points/second. Hover-opens pass the
    /// tracker's reading; every other path (⌘, / debug launches) leaves it
    /// zero, which renders as the standard calm unfurl. `NotchIsland` consumes
    /// it to seed the entry kick and ease the open spring — set *before* `open`
    /// flips so the view computes its animation from a fresh reading.
    /// Deliberately not `@Published`: it is only ever written immediately before
    /// `open` flips (which already invalidates the tree), so publishing it would
    /// just add a second whole-tree invalidation on the open edge.
    var entryVelocity: CGVector = .zero

    @Published var text = "" {      // current input (idle prompt or follow-up)
        didSet {
            // A Tab override is scoped to the line it was pressed on. The field
            // emptying — submit cleared it, or the user deleted everything — ends
            // that line, so the next one starts back on auto-classification.
            if manualPanelOverride != nil,
               text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                manualPanelOverride = nil
            }
            detectedDue = RemindersService.futureDate(in: text)
                ?? RemindersService.recurrenceDate(in: text)
            scheduleClassification()
        }
    }

    /// Destination forced by pressing Tab — the manual escape hatch for when the
    /// classifier reads the line wrong. `nil` means no override: route by the
    /// classifier as usual. Wins over `suggestedPanel` while set, and is scoped to
    /// the current line: cleared the moment the field empties (submit, delete-all,
    /// close), so the next line is auto-classified again. See `toggleSubmitPanel`.
    @Published var manualPanelOverride: Panel? = nil

    /// Confidence the classifier must clear before we'll act on it — both to route
    /// Enter to the other surface AND to label the send button with that destination.
    /// One shared floor on purpose: we never switch surfaces *more* eagerly than the
    /// button is willing to say we will. Below it, the read is treated as unsure and
    /// the current surface (→ ask, by the resting default) handles the line. Tuned
    /// against the embedding engine's calibration (confidence = |2p−1|): on held-out
    /// data 0.4 keeps ~3% confident-and-wrong while still routing ~70% of clear
    /// lines; everything below falls to the ask default (or the LLM second opinion
    /// on Apple Intelligence machines — see `scheduleClassification`).
    static let intentActionFloor = 0.4

    /// The engine's latest read of `text` — published asynchronously by
    /// `scheduleClassification()` after a short debounce, since classification runs
    /// off the main actor (embedding lookup ~10ms on the engine's actor). `.empty`
    /// while the field is empty or a read is still in flight, which resolves to the
    /// ask default everywhere it's consumed.
    @Published private(set) var liveIntent: IntentEngine.Reading = .empty

    /// The first *future* moment the current text names (NSDataDetector, sub-ms,
    /// recomputed synchronously in `text.didSet`). This is what splits the note
    /// branch: the engine only reads ask-vs-note semantically; a note that names a
    /// future time is a **reminder** — a structural fact, not a semantic one. The
    /// same date routes the hint and becomes the due date `submitReminder()` files,
    /// so the "Remind" label and the alarm can never disagree.
    @Published private(set) var detectedDue: Date? = nil

    /// In-flight classification for the current text — superseded (cancelled) by
    /// every keystroke, so only the read of what's actually in the box lands.
    private var classifyTask: Task<Void, Never>?

    /// Debounced re-classification of `text`, called from its `didSet`. Two stages:
    ///   1. ~140ms after the last keystroke: embedding classify (fast, every Mac).
    ///   2. If that read is *unsure* (< 0.5): wait for a real pause (~350ms more),
    ///      then ask the on-device LLM for a second opinion — only exists on Apple
    ///      Intelligence machines; `refine` returns nil everywhere else.
    /// Each publish re-checks that `text` is still the snapshot it classified, so a
    /// stale read can never label (or route) a line it wasn't computed from.
    private func scheduleClassification() {
        classifyTask?.cancel()
        let snapshot = text
        guard !snapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            liveIntent = .empty
            return
        }
        classifyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled, let self, self.text == snapshot else { return }
            let reading = await IntentEngine.shared.classify(snapshot)
            guard !Task.isCancelled, self.text == snapshot else { return }
            self.liveIntent = reading

            guard reading.confidence < 0.5 else { return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, self.text == snapshot else { return }
            guard let refined = await IntentEngine.shared.refine(snapshot),
                  !Task.isCancelled, self.text == snapshot else { return }
            self.liveIntent = refined
        }
    }

    /// Which destination the text *confidently* wants, or `nil` when there's no
    /// clear, confident lean (ambiguous, weak, or empty). Routing and the inline hint
    /// both read this, so they can never disagree — if it's not sure enough to name a
    /// destination, it's not sure enough to route there either. There is only ever one
    /// rendered surface (the chat input); this just decides where Enter *sends* the
    /// line, not what the panel looks like. The "ambiguous → ask" default is applied
    /// at submit time by falling back to `.chat`, not here.
    var suggestedPanel: Panel? {
        guard liveIntent.confidence >= Self.intentActionFloor else { return nil }
        switch liveIntent.intent {
        case .ask:       return .chat
        // Within the note branch, naming a future time upgrades the line to a
        // reminder (a date on an *ask* changes nothing — "明天天气怎么样" still asks).
        case .note:      return detectedDue != nil ? .reminder : .note
        case .ambiguous: return nil
        }
    }

    /// Where pressing Enter on the *current* text will actually land. Resolution
    /// order: a Tab override (the user said so explicitly) beats the classifier's
    /// confident read, which beats `.chat` (the resting "ambiguous → ask" default).
    /// This is exactly the resolution `submitCurrent()` uses, so the inline hint can
    /// show its destination and never lie about it.
    var effectiveSubmitPanel: Panel { manualPanelOverride ?? suggestedPanel ?? .chat }

    /// Tab in the idle prompt: step where Enter will send the current line
    /// (Ask → Note → Remind → Ask…), overriding the classifier. Steps from whatever
    /// the *effective* destination is right now — including a prior override — so
    /// each press reads as "the next one", exactly what the cycled inline hint shows.
    func toggleSubmitPanel() {
        switch effectiveSubmitPanel {
        case .chat:     manualPanelOverride = .note
        case .note:     manualPanelOverride = .reminder
        case .reminder: manualPanelOverride = .chat
        }
    }

    /// The word in the inline hint — the destination spelled out: "Note" when this
    /// line will be saved to Apple Notes, "Remind" when it'll be filed in Apple
    /// Reminders, "Ask" when it'll go to the AI. Flips live with the classifier as
    /// the text crosses intents, so the hint beside the caret literally says where
    /// Enter sends the line.
    var submitLabel: String {
        switch effectiveSubmitPanel {
        case .chat:     return L("hint.ask")
        case .note:     return L("hint.note")
        case .reminder: return L("hint.remind") + submitHintSuffix
        }
    }

    /// The recurrence suffix shown live in the Remind hint *before* Enter (" \u{00B7} Daily"
    /// / " \u{00B7} Weekly \u{00B7} Mon" / " \u{00B7} Monthly"), so the user sees the recurrence
    /// was parsed while they can still correct it — anticipatory, not retrospective. Reads
    /// the same `recurrenceKind(in:)` the post-submit toast uses, off the live `text`.
    ///
    /// Gated on `effectiveSubmitPanel == .reminder` (so a Tab-override to Note/Ask drops
    /// it immediately) — and therefore only meaningful once the classifier has fired
    /// (~140ms after the keystroke). Empty for one-shot lines and non-reminders.
    ///
    /// NOTE: bare "weekly" (no named day) intentionally shows just " \u{00B7} Weekly" here —
    /// the repeat day is only resolved from the due date at file time, which the pre-Enter
    /// text alone can't know. The toast (which *has* the resolved `due`) shows the concrete
    /// day; the two diverge by design only in that one case.
    var submitHintSuffix: String {
        guard effectiveSubmitPanel == .reminder else { return "" }
        switch RemindersService.recurrenceKind(in: text) {
        case .daily:
            return L("recur.daily")
        case .weekly(let ekDay):
            if let ekDay {
                let dayIdx = ekDay.rawValue - 1   // EKWeekday 1-Sun…7-Sat \u{2192} 0-based
                return L("recur.weeklyOn", Calendar.current.shortWeekdaySymbols[dayIdx % 7])
            }
            return L("recur.weekly")
        case .monthly:
            return L("recur.monthly")
        case nil:
            return ""
        }
    }

    /// One past line written to Notes/Reminders this session, kept only to flash a
    /// brief confirmation under the record input. `nil` clears the cue.
    /// Not persisted — Notes/Reminders are the store of record; this is feedback.
    @Published var lastSavedNote: String? = nil
    /// Which app the flashed cue's line landed in, so the cue can say "Added to
    /// Reminders" vs "Added to Notes". Only meaningful while `lastSavedNote` is set.
    @Published var lastSavedToReminders = false
    /// Set when a note write fails (e.g. Automation permission not granted), so the
    /// record view can surface the recovery hint instead of silently dropping the
    /// line. Cleared on the next successful write or when the user edits the field.
    @Published var noteError: String? = nil
    /// True while a note write is in flight (the AppleScript runs off-thread and
    /// the first one waits on the TCC prompt), so the record view can show a quiet
    /// "Saving…" cue instead of looking like nothing happened on Enter.
    @Published var noteSaving = false

    /// The pasteboard's `changeCount` as of the last moment the notch was *resting*
    /// (closed, or a fresh chat) — i.e. the value from *before* the current open. An
    /// Ask injects the clipboard when the live count has moved past this baseline,
    /// which is the signal that the user copied something for *this* session and a
    /// referential query ("summarize this") is about the thing they just copied.
    ///
    /// Crucially this is the *pre-open* value, NOT the count at the instant the panel
    /// opened: the user's intended flow is copy-THEN-open, so by open time the copy
    /// has already bumped the count. Baselining at open would swallow exactly the copy
    /// we want to catch. Instead we carry forward the resting count (see
    /// `pasteboardChangeCountAtRest`), so a copy made while the notch was closed still
    /// reads as "new" once it opens. A count that hasn't moved since rest means the
    /// clipboard is stale relative to this session, so we leave it alone. Re-baselined
    /// on a new chat so our own handoff write can't leak back in.
    private var pasteboardChangeCountAtOpen = NSPasteboard.general.changeCount

    /// The pasteboard's `changeCount` while the notch is *resting* — refreshed every
    /// time it fully closes, so the next open can baseline against the count from
    /// before the user's copy-then-open. Seeded at construction so the very first
    /// open (copy → open, no prior close) still has a sane pre-copy reference: the
    /// count as of app launch. `openPanel` copies this into `pasteboardChangeCountAtOpen`
    /// on the closed→open edge.
    private var pasteboardChangeCountAtRest = NSPasteboard.general.changeCount

    /// The clipboard content that's currently available to be folded into an Ask
    /// if the user's question refers to it ("summarize this", "翻译这段", etc.).
    /// Surfaced in the idle UI so the user sees what a referential query would
    /// actually point at. `nil` when the clipboard is stale, empty, oversized, or
    /// an unsupported type.
    @Published var pendingClipboard: String? = nil

    /// What the *copied text itself* reads as, when it leans note/reminder rather than
    /// something to ask about — `.note` or `.reminder`, never `.chat`, and `nil` while
    /// it reads as an Ask, is ambiguous, or the classifier hasn't landed yet. Computed
    /// off the same engine the input box uses, but on the clipboard's text instead of
    /// the prompt's, and published asynchronously by `classifyPendingClipboard()` when
    /// a new clip becomes pending. Drives a leading "Note"/"Remind" capture chip in the
    /// preset row so a copied jot can be filed in one tap, ahead of the Ask presets.
    @Published private(set) var pendingClipboardCapture: Panel? = nil

    /// In-flight clipboard classification — superseded (cancelled) when a new clip
    /// becomes pending, so only the read of what's actually copied lands.
    private var clipboardClassifyTask: Task<Void, Never>?

    /// Set for exactly one `submit()` when a clipboard preset chip is fired, so that
    /// turn folds in the copied text *unconditionally* — skipping the `isReferentialQuery`
    /// re-classification a typed query is gated on. A chip is only ever rendered when
    /// clipboard content exists and its whole purpose is to act on that content, so the
    /// intent isn't in doubt; routing it through the lexical gate just risked a preset
    /// whose phrase happens not to read as referential (e.g. "List the key points of
    /// this") silently running with no copied text. `submit()` reads this once and
    /// clears it, so it never leaks into a follow-up.
    private var forceClipboardInjection = false

    /// The live conversation rendered in the result view — alternating user and
    /// assistant `Turn`s. A follow-up appends to this rather than replacing it, so
    /// the whole thread stays on screen and (via `submit`) in the model's context.
    /// Empty while idle; the first submit seeds the first user + assistant turns.
    @Published var turns: [Turn] = []

    /// The question shown in the result header — the *first* question of the
    /// thread, so the header labels the conversation as a whole. Empty when there's
    /// no conversation yet.
    var question: String { turns.first(where: { $0.role == "user" })?.text ?? "" }

    /// Whether a live backend is wired up (an API key is available for the
    /// selected provider). `false` means we're on the offline stub, in which case
    /// a follow-up can only ever return another placeholder — so the result view
    /// swaps the follow-up field for a "set up your model" call to action instead.
    /// Kept in sync by `AppDelegate` alongside `setService`.
    @Published var isConfigured = false

    @Published var showHistory = false {
        // Closing the recent list (from ANY of its 11+ callsites — fullClose,
        // newChat, collapseHistory, openHistory, settings, submit/submitNote/
        // submitReminder, …) drops any active filter, so reopening always starts on
        // the full unfiltered list. One didSet covers every path atomically.
        didSet {
            if !showHistory {
                historySearchQuery = ""
                showHistoryFilter = false
            }
        }
    }
    /// Whether the compact filter field is expanded below the RECENT header.
    /// Hidden by default so the list stays minimal; toggled from the filter icon.
    /// Cleared automatically when the list closes (see `showHistory`).
    @Published var showHistoryFilter = false
    /// Live substring filter for the recent list. Empty = show everything. Set by the
    /// `HistorySearchField` that appears above the rows once the list is long enough
    /// to need it; cleared automatically when the list closes (see `showHistory`).
    @Published var historySearchQuery = "" {
        // Filtering reshuffles which rows exist, so a stale keyboard highlight could
        // point at a now-hidden (or shifted) row. Release it on every query change;
        // the next ↓ re-selects row 0 of the freshly filtered slice.
        didSet { if historySearchQuery != oldValue { highlightedHistoryIndex = nil } }
    }
    /// Whether the inline settings panel is showing in place of the recent list.
    /// Replaces the old native Settings window — the gear (and ⌘,) flip this, and
    /// the idle view swaps the RECENT block for the settings form when it's true.
    @Published var showSettings = false
    /// Arms the destructive "Clear recent history?" confirmation. Lives on the
    /// model (not the view) so the Clear pill can raise it while the centered
    /// confirmation card is mounted on the *island* — so it sits in the middle of
    /// the whole glass panel rather than anchored under the pill near the bottom.
    @Published var confirmingClear = false
    /// The open settings category (raw value of `InlineSettingsView.Section`),
    /// held here rather than as view-local `@State` so it survives the panel
    /// subtree rebuild an App Language switch triggers (root `.id(loc.language)`).
    /// Without this, switching language while in General would snap back to Model.
    @Published var settingsSection: String = "Model"
    /// Which recent row the keyboard has highlighted while navigating the list
    /// with ↑/↓. `nil` means nothing is highlighted yet — the list may be open
    /// (revealed by mouse) but the caret is still in the input. The first ↓
    /// promotes this to `0`. Indexes into the *visible* slice (`recentVisible`).
    @Published var highlightedHistoryIndex: Int? = nil
    @Published private(set) var history: [HistoryItem] = []

    /// The recent items rendered in the list — now the FULL stored history (up to
    /// the 50-item persistence cap), not a clipped top-8. The list scrolls, and
    /// keyboard nav auto-scrolls the highlight into view, so every captured item
    /// is reachable. Keyboard navigation indexes into THIS, so highlight bounds and
    /// the rendered rows can never drift apart.
    var recentVisible: [HistoryItem] {
        guard !historySearchQuery.isEmpty else { return history }
        return history.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(historySearchQuery)
        }
    }

    private var ai: AIService
    private var task: Task<Void, Never>?
    /// Holds the auto-dismiss timer for the "Saved to Notes" cue so a rapid second
    /// save cancels the first one's fade rather than letting them overlap.
    private var noteCueTask: Task<Void, Never>?
    private let historyKey = "notch_history"

    /// Stable id for the conversation currently on screen, so a follow-up updates
    /// the *same* recent-list row instead of inserting a new one each turn. Reset
    /// whenever a fresh thread begins (first question, new chat, reopened item).
    private var threadHistoryID = UUID()

    init(ai: AIService = StubAIService()) {
        self.ai = ai
        history = loadHistory()
    }

    /// Swap the backend at runtime — used when the user saves an API key in
    /// Settings, so the next question goes live without an app restart.
    func setService(_ service: AIService) {
        ai = service
    }

    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: - Handoff

    /// Compress the on-screen conversation into a single portable block the user can
    /// paste into a full chat (ChatGPT, Claude, …) to pick up exactly where the
    /// notch left off — copied to the clipboard so the handoff is one click. Plain
    /// Q/A transcript with a short framing line; no app-specific markup so it drops
    /// cleanly into any assistant.
    @discardableResult
    func copyHandoffContext() -> String {
        var lines = ["Here's a conversation I'd like to continue. Please pick up from the last answer.\n"]
        var round = 0
        for turn in turns {
            let body = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            if turn.role == "user" {
                round += 1
                lines.append("Q\(round): \(body)")
            } else {
                lines.append("A\(round): \(body)\n")
            }
        }
        let text = lines.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        return text
    }

    /// Re-sync the clipboard baseline after Notch itself wrote to the pasteboard
    /// from *within* an open panel — e.g. the per-code-block copy button. Without
    /// this, that in-app write bumps `changeCount` past `pasteboardChangeCountAtOpen`,
    /// and `clipboardContextIfEligible()` would then mistake the user's own just-copied
    /// code for "something they copied to ask about" and silently inject it into the
    /// next Ask. Same one-line re-baseline `newChat()` uses after a handoff copy.
    func rebaselineClipboardAfterInAppWrite() {
        pasteboardChangeCountAtOpen = NSPasteboard.general.changeCount
        refreshPendingClipboard()
    }

    /// Read the current pasteboard and update `pendingClipboard` for the idle UI.
    /// Called on the closed→open edge and after any in-app pasteboard write, so the
    /// preview stays in sync with what's actually available. Respects the same
    /// eligibility rules as injection (fresh, non-empty, ≤1500 chars, supported type).
    func refreshPendingClipboard() {
        let next = clipboardContextIfEligible()
        // A new (or cleared) clipboard always reopens the preset row collapsed, so the
        // panel never inherits a previous clip's expanded state.
        if next != pendingClipboard {
            clipboardPresetsExpanded = false
            // Drop the prior clip's verdict *synchronously* so its chip can't linger
            // over the new clip while the async re-classification is still in flight —
            // otherwise a "Note" chip from the old copy could briefly sit (and act) on
            // the new one. classifyPendingClipboard republishes once the read lands.
            pendingClipboardCapture = nil
            classifyPendingClipboard(next)
        }
        pendingClipboard = next
    }

    /// Read whether the *copied text* is itself a note/reminder, and publish the verdict
    /// to `pendingClipboardCapture`. Mirrors the input box's `scheduleClassification`,
    /// but on the clipboard string and with no debounce — a clipboard changes far less
    /// often than a keystroke, so we classify the one snapshot directly. Clears the
    /// capture immediately for an empty/stale clip so a leftover verdict can't linger.
    ///
    /// The note→reminder split is the same structural rule the prompt uses: a note that
    /// names a future time is a reminder. We compute that date here from the *clip*
    /// (not `detectedDue`, which tracks the input box) so the chip and the eventual
    /// write agree on what got copied.
    private func classifyPendingClipboard(_ clip: String?) {
        clipboardClassifyTask?.cancel()
        guard let clip, !clip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pendingClipboardCapture = nil
            return
        }
        clipboardClassifyTask = Task { [weak self] in
            let reading = await IntentEngine.shared.classify(clip)
            guard !Task.isCancelled, let self, self.pendingClipboard == clip else { return }
            // Only a confident *note* read earns a capture chip; an Ask (or anything
            // unsure) leaves the row as the existing preset-only Ask shortcuts.
            let verdict: Panel?
            if reading.confidence >= Self.intentActionFloor, reading.intent == .note {
                let due = RemindersService.futureDate(in: clip)
                    ?? RemindersService.recurrenceDate(in: clip)
                verdict = due != nil ? .reminder : .note
            } else {
                verdict = nil
            }
            // The read lands ~10-20ms after the preset row is already on screen. The
            // chip's appearance is animated by an `.animation(value:)` on the row itself
            // (see clipboardPresetChips) — keying the spring there, not here, keeps the
            // FlowLayout reflow and the chip's own transition on one transaction.
            self.pendingClipboardCapture = verdict
        }
    }

    /// File the *current answer* (the last settled assistant turn) into Apple Notes
    /// from the result view — the one-tap archive path for AI output, so a good
    /// answer doesn't dead-end at "select the text and switch apps yourself".
    ///
    /// Reuses the exact `NotesService.writeNote` off-thread path `submitNote` uses,
    /// and the same `noteSaving`/`noteError` state, but deliberately does NOT call
    /// `persistCapture` or `flashSavedCue`: this isn't a one-line jot. Stamping a
    /// "→ Notes" Recent row would pre-fill the input with hundreds of words of LLM
    /// prose on reopen (`openHistory` pre-fills capture rows), and the idle-only
    /// "Added to Notes" cue never shows from the result view anyway. The caller
    /// drives all confirmation animation from `success`, so the model stays clean.
    ///
    /// Guards: no-op while a write is already in flight (`noteSaving`) so a double
    /// tap can't fire two AppleScripts, and no-op when the target turn has no text.
    ///
    /// `turnID` names *which* assistant answer to file: each answer in the thread now
    /// carries its own save button beneath it (see `turnView`), so a save targets that
    /// specific segment rather than always the latest. A nil id falls back to the last
    /// finished assistant turn (the historical behaviour).
    func saveAnswerToNotes(turnID: Turn.ID? = nil,
                           completion: @escaping @MainActor (Bool) -> Void) {
        guard !noteSaving else { return }
        let target = turnID.flatMap { id in turns.first { $0.id == id } }
            ?? turns.last { $0.role == "assistant" && !$0.streaming }
        let answer = target.flatMap { $0.role == "assistant" && !$0.streaming ? $0 : nil }?
            .text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let content = answer, !content.isEmpty else { return }

        noteError = nil
        noteSaving = true
        NotesService.writeNote(content) { [weak self] result in
            guard let self else { return }
            self.noteSaving = false
            switch result {
            case .success:
                self.lastSavedToReminders = false
                completion(true)
            case .failure(let err):
                self.noteError = err.errorDescription ?? L("feedback.notesFailed")
                completion(false)
            }
        }
    }

    // MARK: - Open / collapse

    /// Whether the island on `display` should render expanded. A `nil` active
    /// display means "no specific screen claimed the panel" (debug launch paths
    /// set `open` directly) and unfurls everywhere; otherwise only the claiming
    /// screen expands.
    func isOpen(on display: CGDirectDisplayID?) -> Bool {
        open && (activeDisplay == nil || display == nil || activeDisplay == display)
    }

    /// Open (or migrate) the panel on the given screen. Hovering another screen's
    /// resting notch while the panel is open elsewhere moves the whole island —
    /// conversation and all — to where the user actually is. `activeDisplay` is
    /// set BEFORE `open` so AppDelegate's combined observer keys the right panel.
    /// `velocity` is the cursor's approach vector (zero for non-hover opens);
    /// it must land before `open` so the island's animation reads it fresh.
    func openPanel(on display: CGDirectDisplayID?, velocity: CGVector = .zero) {
        entryVelocity = velocity
        if let display { activeDisplay = display }
        // Only the *closed→open* edge sets the clipboard baseline. Hover fires
        // `openPanel` again on every re-enter and on display migration while already
        // open — re-baselining there would clobber a copy the user made mid-session.
        // The baseline is the count from when the notch was last *resting* (before
        // this open), NOT the count right now: the user copies first and opens
        // second, so by now the copy has already bumped the live count. Carrying the
        // pre-open resting value forward is what lets that copy-then-open read as
        // fresh in `clipboardContextIfEligible`.
        if !open {
            pasteboardChangeCountAtOpen = pasteboardChangeCountAtRest
        }
        open = true
        refreshPendingClipboard()
    }

    /// Toggle the inline settings panel. Opening it folds the recent list away
    /// (they share the same slot below the prompt) and drops any keyboard
    /// highlight; closing returns to the bare idle prompt.
    func toggleSettings() {
        showSettings.toggle()
        if showSettings {
            showHistory = false
            highlightedHistoryIndex = nil
        }
    }

    /// Open the panel straight into settings — the path the gear and ⌘, take.
    /// Works whether the panel was resting or already open on some other view.
    /// `display` says which screen should host it (AppDelegate passes the screen
    /// under the mouse when ⌘, fires from anywhere); nil keeps the current one.
    func openSettings(on display: CGDirectDisplayID? = nil) {
        // Summoned by keyboard, not approached by mouse — a stale entry vector
        // from an earlier hover must not kick the settings unfurl sideways.
        entryVelocity = .zero
        if let display { activeDisplay = display }
        // Same closed→open-edge rule as openPanel: adopt the pre-open resting
        // baseline so a copy-then-⌘, still leaves the clipboard eligible for the
        // first Ask, and a re-open while already open doesn't clobber it.
        if !open {
            pasteboardChangeCountAtOpen = pasteboardChangeCountAtRest
        }
        open = true
        refreshPendingClipboard()
        mode = .idle
        showSettings = true
        showHistory = false
        highlightedHistoryIndex = nil
    }

    /// Leave settings and return to the idle prompt (panel stays open).
    func closeSettings() {
        showSettings = false
    }

    /// Auto-retract once the pointer leaves — but ONLY when nothing has been
    /// asked and nothing is on screen (the rule the user settled on):
    ///   · keep open while an answer is showing (`.result`)
    ///   · keep open while the AI is working (`.load`)
    ///   · keep open while the user is mid-way through typing
    ///   · keep open while the Recent list is expanded — moving the mouse away
    ///     must never fold a notch that has recent content on screen
    func collapseOnLeave(from display: CGDirectDisplayID? = nil) {
        // The pointer leaving a *resting* notch on a screen that isn't hosting
        // the open panel has nothing to fold — and must never close the island
        // that's actually in use on another display.
        if let display, let active = activeDisplay, display != active { return }
        if mode == .load || mode == .result { return }
        if hasText { return }
        // Mid-confirmation of a destructive clear — don't fold the panel out from
        // under the dialog if the cursor slips off the island.
        if confirmingClear { return }
        if showHistory { return }
        // Never fold while settings are open — the user may be mid-way through
        // pasting a key or picking a model.
        if showSettings { return }
        fullClose()
    }

    /// Hard close from Esc / click-outside — always collapses regardless of mode,
    /// including mid-request: an answer still in flight is detached, not cancelled.
    /// The task keeps streaming on its own snapshot (see `submit`) and files the
    /// finished round into Recent, so closing never loses a conversation.
    func fullClose() {
        // Detach, don't cancel: dropping the reference leaves the Task running
        // (deinit doesn't cancel it) and frees the slot so the next submit's
        // supersede-cancel can't reach the detached round.
        task = nil
        open = false
        activeDisplay = nil
        mode = .idle
        text = ""; turns = []
        showHistory = false
        showSettings = false
        confirmingClear = false
        highlightedHistoryIndex = nil
        // Drop any lingering note-save feedback so a fresh open starts clean.
        noteCueTask?.cancel()
        lastSavedNote = nil
        noteError = nil
        noteSaving = false
        // Snapshot the resting clipboard count: the next open baselines against this
        // (the count from *before* the user's next copy-then-open), so a copy made
        // while the notch is closed still reads as fresh context on the next Ask.
        pasteboardChangeCountAtRest = NSPasteboard.general.changeCount
        // Drop the preview so the resting panel stays minimal; the next open will
        // re-evaluate and surface anything fresh.
        pendingClipboard = nil
        clipboardClassifyTask?.cancel()
        pendingClipboardCapture = nil
    }

    /// "Back" / start a new conversation: drop the current Q&A from the screen and
    /// return to the idle input — but stay OPEN, so the user lands straight on a
    /// fresh prompt instead of the panel collapsing. Triggered by the back button
    /// in a result view and by the ← arrow key. Like `fullClose`, an answer still
    /// in flight is detached rather than cancelled — it finishes in the background
    /// and lands in Recent, so backing out while waiting never loses the round.
    func newChat() {
        task = nil
        mode = .idle
        text = ""; turns = []
        showHistory = false
        showSettings = false
        highlightedHistoryIndex = nil
        // Re-baseline the clipboard against NOW. The handoff-copy button writes the
        // transcript to the pasteboard (bumping changeCount past the open baseline);
        // without this reset, the next first-turn Ask would mistake our own handoff
        // text for "something the user copied to ask about" and inject it.
        pasteboardChangeCountAtOpen = NSPasteboard.general.changeCount
    }

    // MARK: - Submit

    /// The single Enter entry point the input field calls. There's only one surface
    /// — the chat input — so this never changes what the panel looks like; it just
    /// routes the line by **intent**:
    ///   · note naming a future time → file it in Apple Reminders (alarm at that time)
    ///   · note                      → write it to Apple Notes (feedback shows inline)
    ///   · ask, or ambiguous         → send it to the AI
    /// Ambiguity falls to ask (`effectiveSubmitPanel` resolves `nil` → `.chat`), so an
    /// unsure line on a fresh prompt asks the AI — the agreed "ambiguous → ask" rule.
    /// This matches `submitLabel` exactly, so the inline "Ask"/"Note"/"Remind" hint
    /// always names where the line actually went.
    func submitCurrent() {
        switch effectiveSubmitPanel {
        case .chat:     submit()
        case .note:     submitNote()
        case .reminder: submitReminder()
        }
    }

    /// The clipboard string that's *available* to fold into an Ask, or `nil` when
    /// the clipboard itself isn't a candidate. This is only the clipboard-state half
    /// of the gate — whether the *query* actually refers to it is `isReferentialQuery`,
    /// tested separately in `submit`. Available means: the user copied for *this*
    /// session — the `changeCount` has moved past its pre-open resting baseline, which
    /// covers the intended copy-THEN-open flow (the baseline is the count from before
    /// the open; see `pasteboardChangeCountAtOpen`) as well as a copy made while the
    /// panel is open; the clipboard holds a non-empty string, URL, or file URL; and
    /// it's short enough (≤ 1500 chars) to inject without blowing up the prompt.
    /// Anything longer than 1500 chars, an image, or a stale clipboard returns nil.
    /// Read once per submit; never mutates the pasteboard.
    private func clipboardContextIfEligible() -> String? {
        let pb = NSPasteboard.general
        guard pb.changeCount != pasteboardChangeCountAtOpen else { return nil }
        // Read priority: plain string (the common case) → "Copy Link" URL → Finder
        // file path. Safari/Chrome's right-click "Copy Link" writes `.URL` with no
        // `.string` companion, so a copied link would otherwise read as nil and inject
        // nothing on "summarize this link"; a Cmd-C from the address bar DOES write
        // `.string`, so it resolves in the first arm. Finder file copies write
        // `.fileURL` (a file:// URI) with no `.string`. First non-nil arm wins, so
        // plain-text copies are completely unaffected.
        let raw = pb.string(forType: .string)
               ?? pb.string(forType: .URL)
               ?? pb.string(forType: .fileURL)
        guard let s = raw else { return nil }
        let clip = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clip.isEmpty, clip.count <= 1500 else { return nil }
        return clip
    }

    /// Does this query *refer to* something the user has on hand — i.e. is it the
    /// kind of line where folding in the clipboard actually helps? This is the
    /// automatic gate that replaced the manual "attach" pill: a fresh copy alone
    /// isn't enough to inject (people copy things incidentally), so we only pull the
    /// clipboard in when the question reads as being *about* it. Two signals, either
    /// one is enough:
    ///   1. A deictic — a pointing word with no antecedent in the query itself
    ///      ("summarize **this**", "翻译**这段**", "what does **it** mean"). On a
    ///      first turn there's nothing on screen to point at, so the referent is
    ///      almost always what they just copied.
    ///   2. A bare content operation — a transform verb whose object is missing
    ///      ("summarize", "translate", "解释一下", "润色"). "Summarize the French
    ///      revolution" names its own object and is NOT referential; "Summarize" /
    ///      "Summarize this" leaves the object open, so the clipboard fills it.
    /// Deliberately conservative: a self-contained question ("what's the capital of
    /// France") matches neither and gets no clipboard, which is the safe default —
    /// a false negative just means the old no-context behaviour, a false positive
    /// silently pollutes an unrelated answer. Lexical only; no model call.
    private func isReferentialQuery(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return false }

        // --- Colon guard (ASCII + fullwidth): "translate: bonjour", "解释：光合作用",
        // "rewrite this sentence: the cat sat …". When a colon is followed by ≥2
        // non-blank chars the object is supplied inline — NOT referential, whatever
        // verb or deictic precedes it.
        if let colon = q.range(of: ":") ?? q.range(of: "：") {
            let after = q[colon.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if after.count >= 2 { return false }
        }

        // ── Chinese ───────────────────────────────────────────────────────────
        // Verbs first — a couple of CJK gates below key off whether one is present.
        // Bare transform verbs that imply "…this text". Length gate ≤15 (up from 8)
        // lets polite forms like "帮我总结一下重要内容" through; the named-object guard
        // keeps "总结法国史"/"翻译猫" out.
        let cjkContentOps = ["总结", "概括", "归纳", "摘要", "翻译", "翻", "解释",
                             "润色", "改写", "修改", "修正", "改", "扩写", "缩写",
                             "提炼", "分析", "点评", "校对", "整理", "检查", "查"]
        let hasCjkVerb = cjkContentOps.contains { q.contains($0) }

        // Specific content-deictics (point at a text object, not a place/time).
        // Excludes bare "这" (fires on "这里" = a location) and bare "其" (fires
        // inside discourse markers 其实/其次) — those were the worst false-positives.
        let cjkDeictics = ["这个", "这段", "这些", "这条", "这句", "这篇", "这里面",
                           "上面", "上述", "里面", "它"]
        if cjkDeictics.contains(where: { q.contains($0) }) {
            // CJK has no clean copula signal, so a deictic inside a plain *statement*
            // ("其实这个问题很简单", "Python很流行，它好学吗") still slips through the
            // deictic list. Cheap guard: if there's no content-op verb AND a degree/
            // copula cue is present (很/真/非常/就是…), read it as a statement, not a
            // request, and don't inject. Drops the worst remaining false-positives.
            let statementCues = ["很", "真", "挺", "非常", "特别", "太", "就是",
                                 "好用", "简单", "流行", "厉害"]
            let looksLikeStatement = !hasCjkVerb && statementCues.contains { q.contains($0) }
            if !looksLikeStatement { return true }
        }

        // "以上" points at copied text only in a *request* — not in a declarative
        // ("以上就是我的看法" = "that's my view", a statement).
        if q.contains("以上") {
            let after = q.components(separatedBy: "以上").dropFirst().joined()
            let declarative = ["是", "就是", "为", "就为"].contains { after.hasPrefix($0) }
            if !declarative { return true }
        }

        // "刚才"/"刚刚" point at the clipboard only when the referent is *content*;
        // when they refer to the ongoing chat ("总结一下刚才的对话") the query names
        // its own source and is self-contained.
        let chatReferents = ["对话", "聊", "说", "讲", "谈", "讨论", "交流", "的话"]
        for deictic in ["刚才", "刚刚"] where q.contains(deictic) {
            if !chatReferents.contains(where: { q.contains($0) }) { return true }
        }

        // Bare-verb path (verb list + flag hoisted above): referential only when the
        // line is essentially the verb plus filler — no self-supplied named object.
        if q.count <= 15, let verb = cjkContentOps.first(where: { q.contains($0) }) {
            if !cjkHasNamedObject(q, verb: verb) { return true }
        }

        // ── English ───────────────────────────────────────────────────────────
        // A deictic alone isn't enough — "this is great"/"it works" are statements.
        // Require an action signal (content-op verb or question word) alongside it,
        // and exclude fixed discourse markers that merely *contain* a deictic word.
        let enDeictics = ["this", "that", "these", "those", "it", "above", "the following", "the text"]
        if enDeictics.contains(where: { containsWord($0, in: q) }) {
            let discourseMarkers = ["that said", "that is to say", "that being said",
                                    "it depends", "it takes", "it is what it is",
                                    "above average", "above all"]
            if !discourseMarkers.contains(where: { q.contains($0) }) {
                let verbs = enContentOpVerbs
                let questionWords = ["what", "how", "why", "when", "where", "who",
                                     "which", "does", "do", "mean", "means", "meant"]
                let hasVerb = verbs.contains { containsWord($0, in: q) }
                let hasQuestion = questionWords.contains { containsWord($0, in: q) }
                // "the following"/"the text" are task-oriented even without a verb.
                let contentDeictic = containsWord("the following", in: q) || containsWord("the text", in: q)
                // "explain yourself" addresses the assistant, not copied text.
                let selfDirected = containsWord("yourself", in: q) && containsWord("explain", in: q)
                if (hasVerb || hasQuestion || contentDeictic) && !selfDirected { return true }
            }
        }

        // Bare content-op verb (no deictic): referential when the line is the verb
        // plus filler only. Word gate ≤7 (up from 3) admits "can you summarize for
        // me"; the named-object guard keeps "explain recursion"/"tldr on stoicism" out.
        let words = q.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
        if words <= 7, enContentOpVerbs.contains(where: { containsWord($0, in: q) }) {
            if !enHasNamedObject(q) { return true }
        }

        return false
    }

    /// English transform verbs whose object can dangle onto the clipboard. Shared by
    /// the deictic-pairing check and the bare-verb path so the two never drift.
    private var enContentOpVerbs: [String] {
        ["summarize", "summarise", "translate", "explain", "paraphrase",
         "rephrase", "rewrite", "proofread", "tldr", "tl;dr", "simplify",
         "fix", "edit", "reword", "condense", "check", "improve",
         "clean", "correct", "tighten", "convert", "format", "compress",
         "shorten", "expand", "review", "analyze", "analyse"]
    }

    /// Filler *nouns* that name a generic facet of the copied text rather than a
    /// self-supplied subject — "总结一下主要**内容**" still dangles onto the clipboard,
    /// and grammar/spelling style nouns ("帮我改一下**语法**") are properties of the
    /// copied text, not new objects. Stripped alongside particles so they don't read
    /// as a named object and suppress injection.
    private let cjkFillerNouns = ["内容", "信息", "文字", "文本", "部分", "东西",
                                  "语法", "拼写", "标点", "措辞", "格式", "错误",
                                  "错别字", "病句", "用词"]

    /// True when a CJK query supplies its *own* named object (so the clipboard isn't
    /// needed). Strips the matched verb, polite prefixes, and filler particles; if any
    /// CJK char survives, it's a self-supplied subject ("翻译**猫**", "总结**法国史**").
    /// "翻译一下" / "帮我总结一下" / "总结一下主要内容" leave nothing → object is dangling.
    private func cjkHasNamedObject(_ q: String, verb: String) -> Bool {
        let fillers = ["一下", "一遍", "一次", "一番", "帮我", "帮忙", "请你", "你帮",
                       "给我", "给你", "我需要", "麻烦", "请", "帮",
                       "吧", "呢", "啊", "嘛", "吗", "哦", "哈", "好",
                       "主要", "重要", "关键", "重点"] + cjkFillerNouns
        var residual = q
        // Remove the longest matching verb first ("改写" before "改") so a short verb
        // doesn't leave its longer sibling's tail behind.
        let allVerbs = ["总结", "概括", "归纳", "摘要", "翻译", "解释", "润色", "改写",
                        "修改", "修正", "扩写", "缩写", "提炼", "分析", "点评", "校对",
                        "整理", "检查", "翻", "改", "查"].sorted { $0.count > $1.count }
        for v in allVerbs {
            if let r = residual.range(of: v) { residual.removeSubrange(r); break }
        }
        // Longest filler first ("错别字" before "错误"/"字") so a short noun doesn't
        // strand its longer sibling's tail.
        for filler in fillers.sorted(by: { $0.count > $1.count }) {
            residual = residual.replacingOccurrences(of: filler, with: "")
        }
        var maxRun = 0, run = 0
        for c in residual {
            let isHan = c.unicodeScalars.first.map { $0.value >= 0x4E00 && $0.value <= 0x9FFF } ?? false
            if isHan { run += 1; maxRun = max(maxRun, run) } else { run = 0 }
        }
        // Even one leftover Han char ("翻译猫" → "猫") is a self-supplied object.
        return maxRun >= 1
    }

    /// Attribute words that name a *property* of the copied text rather than a fresh
    /// subject — "fix the grammar", "check spelling", "any typos?" all operate on
    /// whatever was copied. Treated as fillers so they don't read as a named object
    /// and suppress injection.
    private let enAttributeWords: Set<String> = [
        "grammar", "spelling", "typo", "typos", "punctuation", "wording", "phrasing",
        "tone", "clarity", "writing", "text", "wordings", "mistakes", "errors",
        "mistake", "error", "sentence", "sentences", "paragraph", "wordiness",
    ]

    /// True when an English query supplies its own named object beyond language /
    /// direction words (so the clipboard isn't needed). Strips verbs, fillers, and
    /// target-language/style words; a substantive token left over is a named subject
    /// ("explain **recursion**", "tldr on **stoicism**"). "translate to french
    /// please" leaves only direction/filler → object dangles → referential.
    private func enHasNamedObject(_ q: String) -> Bool {
        let baseFillers: Set<String> = [
            "please", "pls", "plz", "can", "you", "me", "for", "a", "the", "i", "just",
            "quickly", "could", "would", "should", "will", "may", "might", "help",
            "to", "into", "from", "in", "on", "at", "of", "and", "or", "up",
            "my", "this", "that", "these", "those", "it", "all", "any", "some", "more",
            // target-language / style indicators name a TARGET, not the source object
            "english", "french", "spanish", "german", "italian", "portuguese",
            "chinese", "japanese", "korean", "arabic", "russian", "hindi",
            "formal", "informal", "simple", "simpler", "clearer", "shorter",
            "better", "bullet", "points", "tone", "style", "format",
        ]
        // Attribute words (grammar/spelling/…) operate on the copied text, not a new
        // object, so they count as fillers too.
        let fillers = baseFillers.union(enAttributeWords)
        let verbs = Set(enContentOpVerbs + ["give", "get", "make"])
        let substantive = q
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty && !fillers.contains($0) && !verbs.contains($0) }
        return substantive.contains { $0.count >= 2 && ($0.first?.isLetter ?? false) }
    }

    /// Whole-word containment for the Latin-script gates above — avoids "it" firing
    /// inside "edit" or "this" inside "thistle". Loops over every occurrence so a
    /// non-boundary first hit doesn't mask a later word-boundary one. Builds a manual
    /// boundary test rather than dragging in NSRegularExpression for a few literals.
    private func containsWord(_ word: String, in haystack: String) -> Bool {
        var start = haystack.startIndex
        while start < haystack.endIndex,
              let r = haystack.range(of: word, range: start..<haystack.endIndex) {
            let isBoundary: (Character?) -> Bool = { c in
                guard let c else { return true }            // string edge is a boundary
                return !(c.isLetter || c.isNumber)
            }
            let before = r.lowerBound > haystack.startIndex
                ? haystack[haystack.index(before: r.lowerBound)] : nil
            let after = r.upperBound < haystack.endIndex
                ? haystack[r.upperBound] : nil
            if isBoundary(before) && isBoundary(after) { return true }
            start = haystack.index(after: r.lowerBound)
        }
        return false
    }

    // MARK: - Clipboard presets

    /// A one-tap action offered above the prompt when there's eligible clipboard
    /// content — the equivalent of Apple Writing Tools' Proofread / Rewrite / tone /
    /// Summarize / Key-Points chips, but routed through this app's existing pipeline.
    ///
    /// Each preset is just a *referential query* the chip authors into the prompt:
    /// the phrase ("Summarize this", "润色", …) is deliberately object-less so
    /// `isReferentialQuery` reads it as pointing at the copied text and `submit()`
    /// folds the clipboard in — no separate prompt plumbing, the same path a typed
    /// "summarize this" already takes. The cases mirror Apple's set; `phrase(cjk:)`
    /// returns the wording in the language of the copied text (we present the action
    /// in the script the user actually copied, matching the bilingual gates above).
    enum ClipboardPreset: String, CaseIterable, Identifiable {
        case summarize          // Apple: Summary
        case keyPoints          // Apple: Key Points
        case proofread          // Apple: Proofread
        case rewrite            // Apple: Rewrite
        case friendly           // Apple: Friendly tone
        case professional       // Apple: Professional tone
        case concise            // Apple: Concise tone
        case translate          // (Notch addition — common on copied text)

        var id: String { rawValue }

        /// The short chip label, in the app's interface language. (The *phrase*
        /// sent to the model still follows the copied text's script — see
        /// `phrase(cjk:)` — but the chip the user reads tracks the UI language.)
        var label: String {
            switch self {
            case .summarize:    return L("preset.summarize")
            case .keyPoints:    return L("preset.keyPoints")
            case .proofread:    return L("preset.proofread")
            case .rewrite:      return L("preset.rewrite")
            case .friendly:     return L("preset.friendly")
            case .professional: return L("preset.professional")
            case .concise:      return L("preset.concise")
            case .translate:    return L("preset.translate")
            }
        }

        /// The referential query the chip drops into the prompt. Object-less by
        /// design so `isReferentialQuery` pairs it with the clipboard.
        func phrase(cjk: Bool) -> String {
            switch self {
            case .summarize:    return cjk ? "总结一下这段"           : "Summarize this"
            case .keyPoints:    return cjk ? "用要点列出这段的重点"     : "List the key points of this"
            case .proofread:    return cjk ? "校对这段，修正语法和拼写" : "Proofread this for grammar and spelling"
            case .rewrite:      return cjk ? "改写这段"               : "Rewrite this"
            case .friendly:     return cjk ? "把这段改得更友好一些"     : "Rewrite this to sound more friendly"
            case .professional: return cjk ? "把这段改得更正式一些"     : "Rewrite this to sound more professional"
            case .concise:      return cjk ? "把这段改得更精炼"         : "Rewrite this to be more concise"
            case .translate:
                // Honor the user's preferred target language: `.auto` keeps the
                // original object-less phrase (model infers the target); any
                // explicit pick names it so the tap always lands in that
                // language. The named form stays object-less ("把这段…"/"this")
                // so `isReferentialQuery` still pairs it with the clipboard.
                let lang = TranslationLanguage.current
                if cjk {
                    guard let name = lang.cjkName else { return "翻译这段" }
                    return "把这段翻译成\(name)"
                } else {
                    guard let name = lang.englishName else { return "Translate this" }
                    return "Translate this to \(name)"
                }
            }
        }

        /// The handful of presets shown by default — the rest stay tucked behind the
        /// "⋯" chip. This block is auxiliary to the prompt, so only the most common
        /// reaches on copied text get a chip up front; everything else is one tap away.
        static let primary: [ClipboardPreset] = [.summarize, .proofread, .translate]
    }

    /// The presets to offer for the currently-pending clipboard, or `[]` when there's
    /// nothing eligible. The set is the same regardless of content; only the *script*
    /// of the labels/phrases follows the copied text (so a Chinese clipboard gets
    /// Chinese chips). Returns Apple's core actions plus Translate, ordered most-used
    /// first so the row reads left-to-right by likelihood.
    var clipboardPresets: [ClipboardPreset] {
        guard pendingClipboard != nil else { return [] }
        return ClipboardPreset.allCases
    }

    /// The presets visible right now: just the primary few when the row is collapsed
    /// (the default), the full set once the user taps "⋯" to expand. Empty when
    /// there's nothing eligible. Keeps the default panel to one short row so the
    /// prompt stays the focus.
    var visibleClipboardPresets: [ClipboardPreset] {
        let all = clipboardPresets
        guard !all.isEmpty else { return [] }
        if clipboardPresetsExpanded { return all }
        return all.filter { ClipboardPreset.primary.contains($0) }
    }

    /// Whether the clipboard preset row is showing every action (true) or just the
    /// primary few behind a "⋯" chip (false, the default). Resets to collapsed each
    /// time a new clipboard becomes pending so the panel always opens compact.
    @Published var clipboardPresetsExpanded = false

    /// True when the pending clipboard is predominantly CJK text, so the preset chips
    /// speak the language the user copied. Counts Han characters against total letters;
    /// a short majority is enough (mixed clips lean to whichever script dominates).
    var pendingClipboardIsCJK: Bool {
        guard let clip = pendingClipboard else { return false }
        var han = 0, letters = 0
        for scalar in clip.unicodeScalars {
            if scalar.value >= 0x4E00 && scalar.value <= 0x9FFF { han += 1; letters += 1 }
            else if CharacterSet.letters.contains(scalar) { letters += 1 }
        }
        guard letters > 0 else { return false }
        return Double(han) / Double(letters) >= 0.3
    }

    /// Fire a clipboard preset: author its referential phrase into the prompt and
    /// submit it. Going through `text` + `submitCurrent()` (rather than a bespoke
    /// path) means the existing clipboard-injection gate in `submit()` does the real
    /// work — the phrase is object-less, so `isReferentialQuery` pairs it with the
    /// copied text and folds it into the wire message exactly as a typed "summarize
    /// this" would. No-op if the clipboard went stale between render and tap.
    ///
    /// Goes straight to `submit()` (the AI path), NOT `submitCurrent()`: a preset is
    /// always an Ask, and `submitCurrent()` would route off the *stale* `liveIntent`
    /// — classification is debounced ~140ms, so right after we set `text` the read is
    /// still whatever the field held before, which could misfile a preset to
    /// Note/Reminder. Calling `submit()` directly sidesteps the classifier entirely;
    /// the referential phrase still drives clipboard injection inside `submit()`.
    func runClipboardPreset(_ preset: ClipboardPreset) {
        guard pendingClipboard != nil else { return }
        manualPanelOverride = nil
        text = preset.phrase(cjk: pendingClipboardIsCJK)
        // The chip *is* the clipboard intent — fold the copied text in directly rather
        // than re-deriving it from the phrase's wording (which `isReferentialQuery`
        // can misjudge). `submit()` reads and clears the flag this turn.
        forceClipboardInjection = true
        submit()
    }

    /// Fire the leading capture chip: file the *copied text itself* straight into
    /// Apple Notes or Reminders, the one-tap path for when you copied a jot rather
    /// than something to ask about. Drops the clip into `text` and routes through the
    /// existing `submitNote()`/`submitReminder()` so the write, the "Added to…" cue,
    /// the Recent row, and (for reminders) `detectedDue` + the recurrence suffix all
    /// come for free — `text.didSet` recomputes the due date from the clip we just
    /// assigned, so the reminder lands at the time the copied line names. No-op if the
    /// clipboard went stale between render and tap.
    func runClipboardCapture(_ panel: Panel) {
        // No-op if the clipboard went stale, or a save is already in flight — the chip
        // vanishes the instant we fire (we clear the verdict below), but the Enter path
        // could re-enter before the async write lands, which would file a duplicate.
        guard let clip = pendingClipboard, !noteSaving else { return }
        // Consume the verdict up front: the chip's whole purpose is this one tap, so it
        // disappears immediately rather than lingering over already-filed text (where a
        // second tap would file a duplicate). The clipboard preview itself stays — the
        // copied text is still a valid Ask referent for the presets beside it.
        manualPanelOverride = nil
        pendingClipboardCapture = nil
        text = clip
        switch panel {
        case .reminder: submitReminder()
        case .note, .chat: submitNote()
        }
    }

    func submit() {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        // One-shot: a preset chip set this so its turn injects the clipboard without
        // having to read as referential. Consume it here regardless of the early
        // returns below, so it can never carry over to a later typed submit.
        let forceClip = forceClipboardInjection
        forceClipboardInjection = false
        text = ""
        showHistory = false
        highlightedHistoryIndex = nil

        // A first question starts a fresh thread: give it a new history id so it
        // becomes its own recent row. A follow-up keeps the existing id, so the
        // whole conversation stays one row, updated in place. Captured before the
        // append below empties this out — clipboard injection keys off it too
        // (only a first turn pulls in the clipboard).
        let firstTurn = turns.isEmpty
        if firstTurn { threadHistoryID = UUID() }

        // A follow-up sent while the previous answer is still streaming supersedes
        // it: settle any stale streaming flag now, because the superseded task is
        // cancelled below and will never settle it itself.
        for i in turns.indices where turns[i].streaming { turns[i].streaming = false }

        // Append this question and an empty assistant turn it'll stream into. On a
        // first question `turns` is empty (fresh thread); on a follow-up the prior
        // turns are already here, so the new pair just extends the conversation.
        turns.append(Turn(role: "user", text: q))
        let answerID = UUID()
        turns.append(Turn(id: answerID, role: "assistant", text: "", streaming: true))

        // The history sent to the model: every completed turn, plus the new
        // question — but NOT the empty assistant placeholder we just appended.
        var context: [ChatMessage] = turns
            .filter { $0.id != answerID }
            .map { ChatMessage(role: $0.role, content: $0.text) }

        // Clipboard-context injection — first turn only. If the user copied text
        // before invoking Notch and then typed a referential query ("summarize
        // this", "translate this"), fold the copied text into THIS user message so
        // the model has the referent. We rewrite the existing user turn's content
        // rather than prepend a fake assistant ack — that keeps the user/assistant
        // alternation valid (Anthropic rejects a leading non-alternating turn) and
        // never persists a ghost turn to the on-screen thread or Recent (the
        // visible `turns` and the saved snapshot still hold the raw `q`). Only the
        // wire copy in `context` carries the clipboard. Skipped on follow-ups: a
        // mid-conversation clipboard change is almost never "about" the new turn.
        var system = notchSystemPrompt
        // A forced (chip-driven) turn falls back to `pendingClipboard` — the exact text
        // the chip previewed — if a re-read comes back stale (e.g. an in-app copy bumped
        // the baseline between render and tap), so the chip always acts on what it showed.
        let clipForTurn = forceClip ? (clipboardContextIfEligible() ?? pendingClipboard)
                                    : (isReferentialQuery(q) ? clipboardContextIfEligible() : nil)
        if firstTurn, let clip = clipForTurn {
            context[context.count - 1] = ChatMessage(
                role: "user",
                content: "For context, here is what I have copied:\n\n\(clip)\n\nWith that in mind: \(q)")
            // Stamp the on-screen user turn so the result view can show a *permanent*
            // "based on what you copied" trace above it — not a load-only flash. The
            // user turn is the second-to-last entry (the empty assistant placeholder
            // is last). Set before `seedThread = turns` is captured below, so the flag
            // rides into the saved snapshot and survives reopen from Recent.
            if turns.count >= 2 { turns[turns.count - 2].usedClipboard = true }
            // The injected text needs room the 90-word cap can't give. Raise the
            // ceiling just for this enriched turn so summaries/translations aren't
            // truncated mid-thought; the base persona/no-headers rules still hold.
            system = notchSystemPrompt + "\nFor this turn you may use up to 200 words."
        }

        mode = .load

        // The task owns a value-type snapshot of the thread it's answering, plus
        // the thread id captured here. Backing out (`newChat`) or closing the panel
        // (`fullClose`) only detaches the screen — the task keeps streaming into
        // its snapshot and persists the finished round to Recent, so an in-flight
        // round is never lost. The snapshot is also what gets saved, so whatever
        // `turns` shows by completion time (a new chat, a reopened history item,
        // nothing at all) can never leak into this thread's history row.
        let threadID = threadHistoryID
        let seedThread = turns

        // Cancelling here only ever supersedes within the SAME on-screen round (a
        // follow-up sent while the previous answer streams): detached tasks have
        // already cleared this slot, so they're out of reach.
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            var thread = seedThread
            do {
                var acc = ""
                for try await chunk in self.ai.stream(system: system, messages: context) {
                    if Task.isCancelled { return }
                    acc += chunk
                    if let i = thread.firstIndex(where: { $0.id == answerID }) {
                        thread[i].text = acc
                    }
                    if self.isOnScreen(answerID: answerID) {
                        // First chunk: flip to the result view, so the answer
                        // appears to grow in place out of the thinking state. The
                        // permanent clipboard trace rides on the user turn, so there's
                        // no transient flag to clear here.
                        if self.mode == .load { self.mode = .result }
                        self.updateAnswer(id: answerID, text: acc)
                    }
                }
                if Task.isCancelled { return }
                if let i = thread.firstIndex(where: { $0.id == answerID }) {
                    thread[i].streaming = false
                }
                self.markFinished(id: answerID)   // no-op when detached
                self.persistThread(thread, threadID: threadID, answer: acc)
            } catch is CancellationError {
                // superseded by a newer round on the same screen; nothing to persist
            } catch {
                if Task.isCancelled { return }
                // The error placeholder is only worth showing on screen — a
                // detached round that failed is dropped, not filed into Recent.
                if self.isOnScreen(answerID: answerID) {
                    self.updateAnswer(id: answerID, text: L("error.generic"))
                    self.markFinished(id: answerID)
                    self.mode = .result
                }
            }
        }
    }

    /// Does this *note* line point at something on the clipboard rather than carry
    /// its own content? Sibling to `isReferentialQuery` (which is tuned for ASK
    /// content-ops like summarize/translate) but calibrated for **note-filing**: the
    /// verbs are save/keep/bookmark/file, and the useful payload is the copied
    /// URL/snippet, not the directive phrase. "Add this to my reading list" should
    /// file the link, not the literal sentence. Two signals, either is enough:
    ///   1. A note-filing verb paired with a deictic ("save **this**", "收藏**这个**").
    ///   2. A very short line that is essentially a bare deictic ("this", "这个") —
    ///      <=5 words / a lone CJK deictic, with nothing else to file.
    /// Conservative by design: a self-contained jot ("buy milk", "dentist tue 3pm")
    /// matches neither and is filed verbatim as today. Lexical only; no model call.
    private func isDeicticNoteCapture(_ line: String) -> Bool {
        let q = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return false }

        // Discourse markers that merely *contain* a deictic word — never captures.
        let discourseMarkers = ["that said", "that is to say", "that being said",
                                "it depends", "it is what it is"]
        if discourseMarkers.contains(where: { q.contains($0) }) { return false }

        let enDeictics = ["this", "that", "these", "those", "it"]
        let cjkDeictics = ["这个", "这段", "这些", "这条", "这句", "这篇", "它"]
        let hasEnDeictic = enDeictics.contains { containsWord($0, in: q) }
        let hasCjkDeictic = cjkDeictics.contains { q.contains($0) }
        let hasDeictic = hasEnDeictic || hasCjkDeictic
        guard hasDeictic else { return false }

        // 1. Note-filing verb + deictic → capture (the verb's object is the clip).
        let enFileVerbs = ["save", "add", "bookmark", "keep", "file", "store",
                           "note", "jot", "log", "put", "record", "capture"]
        let cjkFileVerbs = ["保存", "收藏", "记下", "记录", "存", "加到", "添加", "留着"]
        let hasFileVerb = enFileVerbs.contains { containsWord($0, in: q) }
            || cjkFileVerbs.contains { q.contains($0) }
        if hasFileVerb { return true }

        // 2. Essentially a bare deictic — nothing else of substance to file.
        let words = q.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
        if hasEnDeictic && words <= 5 { return true }
        if hasCjkDeictic && q.count <= 6 { return true }

        return false
    }

    // MARK: - Note submit

    /// Route a note-classified line into Apple Notes as a new note. The surface never
    /// changes — the user stays on the same "Type anything…" input and can keep
    /// jotting (or asking) right after; the only sign it went to Notes is the quiet
    /// "Added to Notes" line that flashes below the input.
    ///
    /// The write runs **off the main thread** (see `NotesService`) so the first-run
    /// TCC permission prompt doesn't deadlock the UI. We optimistically clear the
    /// field right away and show a quiet "Saving…" cue; the main-thread callback
    /// then either confirms "Saved" or — on failure (most often permission not yet
    /// granted, or the user clicking "Don't Allow") — **restores the exact line** so
    /// nothing typed is lost, and surfaces the recovery hint.
    func submitNote() {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }

        // A deictic note ("save this", "收藏这个") points at the clipboard, not at
        // itself — fold the copied URL/snippet into the note body so what gets filed
        // is the *referent*, not a useless directive phrase. The raw `line` is still
        // what we persist to Recent and restore on failure; only the Notes payload
        // is the compound. Self-contained jots take the plain path unchanged.
        let clip = isDeicticNoteCapture(line) ? clipboardContextIfEligible() : nil
        let noteBody = clip.map { "\(line)\n\n\($0)" } ?? line
        let usedClip = clip != nil

        // Optimistic: free the field for the next jot immediately, show progress.
        // Collapse the recent list too — clearing the text would otherwise let a
        // still-true `showHistory` pop it right back open under the saved cue.
        text = ""
        showHistory = false
        highlightedHistoryIndex = nil
        noteError = nil
        noteCueTask?.cancel()
        lastSavedNote = nil
        noteSaving = true

        NotesService.writeNote(noteBody) { [weak self] result in
            guard let self else { return }
            self.noteSaving = false
            switch result {
            case .success(let noteID):
                self.lastSavedToReminders = false
                self.persistCapture(line, source: .note, link: noteID)
                self.flashSavedCue(usedClip ? L("feedback.addedNotesClip") : L("feedback.addedNotes"))
            case .failure(let err):
                // Put the line back so the user can retry / copy it, but only if
                // they haven't already started typing the next one — clobbering a
                // fresh draft would be worse than losing the failed line to the cue.
                if self.text.isEmpty { self.text = line }
                self.noteError = err.errorDescription ?? L("feedback.notesFailed")
            }
        }
    }

    // MARK: - Reminder submit

    /// Route a time-bound line into Apple Reminders, due (and ringing) at the
    /// moment the text names. Same optimistic shape as `submitNote`: clear the
    /// field immediately, show "Saving…", and on failure (usually the Reminders
    /// permission not yet granted) restore the exact line so nothing is lost.
    ///
    /// The due date is captured **before** clearing the field — `text.didSet`
    /// recomputes `detectedDue` to nil on the clear, so reading it after would
    /// file a dateless reminder.
    func submitReminder() {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        let due = detectedDue

        text = ""
        showHistory = false
        highlightedHistoryIndex = nil
        noteError = nil
        noteCueTask?.cancel()
        lastSavedNote = nil
        noteSaving = true

        RemindersService.createReminder(line, due: due) { [weak self] result in
            guard let self else { return }
            self.noteSaving = false
            switch result {
            case .success(let link):
                self.lastSavedToReminders = true
                self.persistCapture(line, source: .reminder, link: link)
                // Echo the recurrence kind write() applied, resolving a bare
                // "weekly" line's day from `due` exactly as write() does so the
                // displayed weekday matches what EventKit actually filed.
                let suffix: String
                switch RemindersService.recurrenceKind(in: line) {
                case .daily:
                    suffix = L("recur.daily")
                case .weekly(let ekDay):
                    let dayIdx: Int
                    if let ekDay {
                        dayIdx = ekDay.rawValue - 1   // EKWeekday 1-Sun…7-Sat \u{2192} 0-based
                    } else if let due {
                        dayIdx = Calendar.current.component(.weekday, from: due) - 1
                    } else {
                        dayIdx = -1
                    }
                    if dayIdx >= 0 {
                        let abbr = Calendar.current.shortWeekdaySymbols[dayIdx % 7]
                        suffix = L("recur.weeklyOn", abbr)
                    } else {
                        suffix = L("recur.weekly")
                    }
                case .monthly:
                    suffix = L("recur.monthly")
                case nil:
                    suffix = ""
                }
                self.flashSavedCue(L("feedback.addedReminders", suffix))
            case .failure(let err):
                if self.text.isEmpty { self.text = line }
                self.noteError = err.errorDescription ?? L("feedback.remindersFailed")
            }
        }
    }

    /// File a successful Note/Reminder capture into the same Recent history the AI
    /// Q&A uses, so a jotted line leaves a visible trace instead of vanishing with
    /// the 1.7s toast. Stored with its `source` (→ Notes / → Reminders tag), the
    /// `link` back to the exact note/reminder so the row jumps there, and an
    /// explicit empty `turns`, so reopening it can never synthesize a ghost answer
    /// bubble — `openHistory` opens the capture in its app instead.
    private func persistCapture(_ line: String, source: HistoryItem.Source, link: String?) {
        var item = HistoryItem(q: line, a: "", t: Date(), turns: [])
        item.source = source
        item.link = link
        history.insert(item, at: 0)
        history = Array(history.prefix(50))
        saveHistory()
    }

    /// Briefly show "Saved to Notes" under the record input, then fade it. A new
    /// save resets the timer so back-to-back jots don't flicker.
    private func flashSavedCue(_ line: String) {
        noteCueTask?.cancel()
        lastSavedNote = line
        noteCueTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_700_000_000)
            guard !Task.isCancelled else { return }
            // Clear the cue on the SAME spring the record view and the island both
            // use for this state (response 0.42, damping 0.82). Driving it explicitly
            // — rather than leaning on the implicit `.animation(value:)` modifiers —
            // puts the inner line's fade and the outer island's height collapse on
            // one shared transaction, so they can't be scheduled apart and the panel
            // draws up as a single smooth motion instead of a two-step settle.
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                self?.lastSavedNote = nil
            }
        }
    }

    /// Whether the round identified by its answer placeholder is still the one on
    /// screen. Once `newChat`/`fullClose` (or opening another thread) detaches it,
    /// the screen is no longer the task's to touch — only its snapshot (and, at
    /// the end, history) hears about the stream.
    private func isOnScreen(answerID: UUID) -> Bool {
        turns.contains { $0.id == answerID }
    }

    /// Replace the streaming assistant turn's text as chunks arrive. Looked up by
    /// id so an out-of-order or post-`newChat` chunk can't write into the wrong row.
    private func updateAnswer(id: UUID, text: String) {
        guard let i = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[i].text = text
    }

    /// Clear the `streaming` flag on the assistant turn (its caret/typing cue can
    /// stop) without otherwise touching it.
    private func markFinished(id: UUID) {
        guard let i = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[i].streaming = false
    }

    /// Called once a stream completes: persist the task's snapshot of the thread
    /// to history (one recent item per thread, updated in place as it grows).
    /// Runs whether or not the thread is still on screen — a round detached by
    /// `newChat`/`fullClose` lands here all the same, which is what makes backing
    /// out mid-answer safe. Built from the snapshot rather than the live `turns`,
    /// so whatever the screen shows by completion time can't cross into this
    /// thread's row. Skips empty results (e.g. a stream that errored before any
    /// text). The recent row shows the first question + latest answer; reopening
    /// it restores every turn.
    private func persistThread(_ thread: [Turn], threadID: UUID, answer ans: String) {
        let trimmed = ans.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let firstQ = thread.first(where: { $0.role == "user" })?.text ?? ""
        // One history entry per conversation: if this thread already has a row
        // (a follow-up), update it in place instead of inserting a duplicate, so
        // a long chat is a single recent row, not one per turn. Carry over any
        // previously generated title so follow-ups don't wipe it.
        let existingTitle = history.first(where: { $0.id == threadID })?.title
        var item = HistoryItem(id: threadID, q: firstQ, a: trimmed, t: Date(), turns: thread)
        item.title = existingTitle
        if let existing = history.firstIndex(where: { $0.id == threadID }) {
            history.remove(at: existing)
        }
        history.insert(item, at: 0)
        history = Array(history.prefix(50))
        saveHistory()

        // Derive a title from the actual conversation content so the recent list
        // doesn't just display the first user message — prompts like "总结一下"
        // would make many rows look identical. Runs detached so the UI is never
        // blocked; if it fails (offline, no key, timeout) the row falls back to
        // the first question.
        //
        // Regenerate on follow-ups too: the first title is made from the opening
        // exchange, but a thread that drifts to a new topic would otherwise stay
        // frozen on the original subject. Once the conversation has grown past the
        // first round (>2 turns), re-title from the full transcript so the row
        // reflects where the chat actually went, not just how it started.
        let isFollowUp = thread.count > 2
        if existingTitle == nil || isFollowUp {
            Task { [weak self] in
                guard let self, let title = await self.generateTitle(for: thread) else { return }
                await MainActor.run {
                    guard let index = self.history.firstIndex(where: { $0.id == threadID }) else { return }
                    self.history[index].title = title
                    self.saveHistory()
                }
            }
        }
    }

    /// Ask the configured model to summarize the conversation into a short title.
    /// Returns `nil` when offline (stub), unconfigured, or the request fails, so
    /// the UI can always fall back to the first user message.
    private func generateTitle(for thread: [Turn]) async -> String? {
        guard !(ai is StubAIService) else { return nil }

        var transcript = ""
        for turn in thread {
            let label = turn.role == "user" ? "User" : "Assistant"
            transcript += "\(label): \(turn.text)\n"
        }
        let prompt = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }

        do {
            var title = ""
            for try await chunk in ai.stream(
                system: titleSystemPrompt,
                messages: [ChatMessage(role: "user", content: prompt)]
            ) {
                title += chunk
            }
            let cleaned = title
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "^[\"']+|[\"']+$", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\n", with: " ")
            guard !cleaned.isEmpty else { return nil }
            return cleaned
        } catch {
            return nil
        }
    }

    /// Debug-only: drop a finished Q/A onto the screen as a one-exchange thread,
    /// so the result view (and its markdown renderer) can be inspected at launch
    /// without a live backend. Used by the `NOTCH_DEMO` env path in `AppDelegate`.
    func seedDemo(question: String, answer: String) {
        turns = [
            Turn(role: "user", text: question),
            Turn(role: "assistant", text: answer),
        ]
        mode = .result
    }

    /// Debug-only: seed a pending clipboard (bypassing the freshness/changeCount gate)
    /// so the preset row — and the note/reminder capture chip — can be inspected at
    /// launch without a real copy-then-hover. Runs the same async classification the
    /// live path does. Used by the `NOTCH_DEMO_CLIP` env path in `AppDelegate`.
    func seedDemoClipboard(_ text: String) {
        pendingClipboard = text
        classifyPendingClipboard(text)
    }

    /// Debug-only: seed a long multi-turn thread so the result view's scrolling and
    /// edge fades can be inspected at launch without clicking. Used by the
    /// `NOTCH_DEMO_THREAD` env path in `AppDelegate`.
    func seedDemoThread() {
        turns = [
            Turn(role: "user", text: "小米 ceo 是谁"),
            Turn(role: "assistant", text: "小米公司的创始人兼首席执行官（CEO）是**雷军**。他自 2010 年公司创立起便担任这一职务，并持续领导小米的发展。"),
            Turn(role: "user", text: "cfo 呢"),
            Turn(role: "assistant", text: "小米集团首席财务官（CFO）是**林世伟**。他于 2020 年加入小米，此前曾在金融机构有丰富的工作经验。"),
            Turn(role: "user", text: "其他高管呢"),
            Turn(role: "assistant", text: "小米其他主要高管包括：\n\n- **卢伟冰**：集团总裁，兼任国际业务部总裁、分管手机部、生态链部等多个关键部门。\n- **曾学忠**：集团高级副总裁，兼任手机部总裁。\n- **王翔**：高级顾问，前集团总裁。\n- **颜克胜**：集团副总裁，负责质量委员会和采购委员会。\n\n这些高管共同组成了小米的管理层核心。"),
            Turn(role: "user", text: "雷军是哪里人"),
            Turn(role: "assistant", text: "雷军出生于**湖北省仙桃市**，1969 年出生。他毕业于武汉大学计算机系。"),
            Turn(role: "user", text: "他还创办过别的公司吗"),
            Turn(role: "assistant", text: "是的。雷军在创办小米之前，曾长期担任**金山软件**的高管乃至 CEO，并参与创办了**卓越网**（后被亚马逊收购）。他也是知名的天使投资人，通过**顺为资本**投资了大量科技公司。"),
        ]
        mode = .result
    }

    // MARK: - History

    func openHistory(_ item: HistoryItem) {
        showHistory = false
        highlightedHistoryIndex = nil

        // A Note/Reminder capture has no AI answer to reopen — it lives in Apple
        // Notes/Reminders, so tapping the row jumps straight *there*, to the exact
        // note/reminder it created. This is the single choke point for BOTH the
        // click path and the keyboard-Enter path (`historyConfirmHighlighted`
        // calls straight through here), so handling it once here covers both.
        guard item.source == .ask else {
            openCapture(item)
            // Close the panel after launching — the user's attention is moving to
            // Notes/Reminders, so leaving the notch unfurled behind it is noise.
            // Same hard-close Esc/click-outside use.
            fullClose()
            return
        }

        text = ""
        // Restore the whole thread, and adopt this item's id so a follow-up on the
        // reopened conversation updates the same recent row rather than forking a
        // new one. (Legacy single-Q/A items rebuild a two-turn thread.)
        turns = item.conversation
        threadHistoryID = item.id
        mode = .result
    }

    /// Jump from a Recent row straight to the note/reminder it created.
    ///
    /// Two tiers, so a jump never dead-ends:
    ///   1. With a stored `link`, open that exact item — Notes via AppleScript
    ///      `show` (the `link` is the note's `x-coredata://` id), Reminders via
    ///      the `x-apple-reminderkit://` URL. A stale link (item deleted in the
    ///      app, or the undocumented Reminders scheme stops resolving) fails
    ///      quietly *inside* the app and lands the user on its current view.
    ///   2. Without a link — captures saved before this feature shipped, or a
    ///      save that returned no identifier — just bring the destination app
    ///      forward by its bundle id, so an old row still goes *somewhere* useful
    ///      rather than doing nothing.
    private func openCapture(_ item: HistoryItem) {
        switch item.source {
        case .note:
            if let id = item.link, !id.isEmpty {
                // `show` can fail on a stale id (note deleted, or a Core Data id
                // synced from another device) or revoked Automation access — when
                // it does, don't dead-end: fall back to Notes' main window so the
                // tap still lands the user *somewhere*.
                NotesService.showNote(id: id) { [weak self] ok in
                    if !ok { self?.openApp(bundleID: "com.apple.Notes") }
                }
            } else {
                openApp(bundleID: "com.apple.Notes")
            }
        case .reminder:
            if let link = item.link, let url = URL(string: link) {
                NSWorkspace.shared.open(url)
            } else {
                openApp(bundleID: "com.apple.reminders")
            }
        case .ask:
            break   // handled by openHistory; never reached here
        }
    }

    /// Bring an app forward by bundle id — the no-deep-link fallback. Uses the
    /// modern `openApplication(at:configuration:)` since `launchApplication` is
    /// deprecated; resolving the URL first keeps it a no-op if the app is missing.
    private func openApp(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - History keyboard navigation

    /// ↓ in the empty idle prompt: open the recent list (if any) and highlight
    /// the next row. The first press both reveals the list and lands on row 0;
    /// each subsequent press steps down, clamping at the last row. Returns
    /// `false` when there's nothing to navigate (no history), so the caller can
    /// let the keystroke fall through to its default behaviour.
    @discardableResult
    func historyNavigateDown() -> Bool {
        let items = recentVisible
        guard !items.isEmpty else { return false }
        if !showHistory { showHistory = true }
        let next = (highlightedHistoryIndex ?? -1) + 1
        highlightedHistoryIndex = min(next, items.count - 1)
        return true
    }

    /// ↑ while navigating the recent list: step the highlight up. Moving up past
    /// the first row collapses the list and returns the caret to the input — the
    /// inverse of the ↓ that opened it. Returns `false` when the list isn't open
    /// / nothing is highlighted, so ↑ behaves normally in the field otherwise.
    @discardableResult
    func historyNavigateUp() -> Bool {
        guard showHistory, let current = highlightedHistoryIndex else { return false }
        if current <= 0 {
            // Past the top — fold the list back up and release the highlight.
            highlightedHistoryIndex = nil
            showHistory = false
        } else {
            highlightedHistoryIndex = current - 1
        }
        return true
    }

    /// Enter while a recent row is highlighted: open it. Returns `false` when
    /// nothing is highlighted, so a normal Enter still submits the prompt.
    @discardableResult
    func historyConfirmHighlighted() -> Bool {
        guard showHistory, let i = highlightedHistoryIndex else { return false }
        let items = recentVisible
        guard items.indices.contains(i) else { return false }
        openHistory(items[i])
        return true
    }

    /// Enter on an *empty* idle prompt while a capture chip is showing: file the copied
    /// jot straight to Notes/Reminders, the keyboard twin of tapping the leading chip.
    /// Only fires with nothing typed — once there's text, Enter belongs to that line
    /// (routed by intent), so this never steals a real submit. Returns `true` when it
    /// handled the key so the caller stops before the empty `submitCurrent()` no-op.
    func confirmClipboardCaptureIfIdle() -> Bool {
        guard !hasText, let capture = pendingClipboardCapture else { return false }
        runClipboardCapture(capture)
        return true
    }

    /// Esc / outside-collapse for the list alone: fold it back to the input
    /// without closing the whole panel. Returns `false` when the list isn't
    /// open, letting Esc fall through to its usual full-close.
    @discardableResult
    func collapseHistory() -> Bool {
        guard showHistory else { return false }
        showHistory = false
        highlightedHistoryIndex = nil
        return true
    }

    func clearHistory() {
        history = []
        saveHistory()
    }

    /// Drop a single recent item by id (right-click → Delete on its row). Keeps the
    /// keyboard highlight valid: removing a row at/above the highlighted index would
    /// otherwise leave the caret pointing past the end or at the wrong row, so we
    /// recompute it against the shortened visible slice — clamping to the last row,
    /// or releasing the highlight (and folding the list) once it's empty.
    func deleteHistory(id: UUID) {
        guard let removedVisibleIndex = recentVisible.firstIndex(where: { $0.id == id }) else { return }
        history.removeAll { $0.id == id }
        saveHistory()

        guard let current = highlightedHistoryIndex else { return }
        let remaining = recentVisible.count
        if remaining == 0 {
            highlightedHistoryIndex = nil
            showHistory = false
        } else if removedVisibleIndex <= current {
            highlightedHistoryIndex = min(current, remaining - 1)
        }
    }

    private func loadHistory() -> [HistoryItem] {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let items = try? JSONDecoder().decode([HistoryItem].self, from: data)
        else { return [] }
        return items
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    // MARK: - Open width per state (matches the prototype's s-* widths)

    var openWidth: CGFloat {
        // Settings needs a touch more room for the provider/model rows; it only
        // ever shows over the idle view, so it wins regardless of `mode`.
        if showSettings { return Tokens.openWidthSettings }
        switch mode {
        case .result: return Tokens.openWidthResult
        // A follow-up loads with the thread already on screen (shown via the result
        // view), so it must keep the result width — only the first question, with
        // nothing on screen yet, uses the narrower load width.
        case .load:   return turns.isEmpty ? Tokens.openWidthLoad : Tokens.openWidthResult
        case .idle:   return hasText ? Tokens.openWidthIdle : Tokens.openWidthIdle
        }
    }
}

/// Relative time strings ("just now", "12m ago"…) matching the prototype.
func relativeTime(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return L("time.justNow") }
    if s < 3600 { return L("time.minutesAgo", s / 60) }
    if s < 86400 { return L("time.hoursAgo", s / 3600) }
    return L("time.daysAgo", s / 86400)
}
