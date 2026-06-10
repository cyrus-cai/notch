import SwiftUI
import Combine

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
    /// determines whether Enter asks the AI or files the line in Apple Notes.
    ///   · `chat` — ask the AI a question (idle/load/result)
    ///   · `note` — file the line as a new note in Apple Notes
    enum Panel: String, Equatable {
        case chat
        case note
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

        /// The turns to restore on reopen: the saved thread when present, else a
        /// two-turn thread rebuilt from the legacy `q`/`a` fields.
        var conversation: [Turn] {
            turns ?? [
                Turn(role: "user", text: q),
                Turn(role: "assistant", text: a),
            ]
        }
    }

    // Open / closed drives the grow-out-of-the-notch animation.
    @Published var open = false
    @Published var mode: Mode = .idle

    @Published var text = "" {      // current input (idle prompt or follow-up)
        didSet {
            // A Tab override is scoped to the line it was pressed on. The field
            // emptying — submit cleared it, or the user deleted everything — ends
            // that line, so the next one starts back on auto-classification.
            if manualPanelOverride != nil,
               text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                manualPanelOverride = nil
            }
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
    /// against the classifier's scoring: a single weak signal lands ~0.27–0.33 and
    /// stays below; a clear cue (todo phrasing, time+fragment, a question opener, or
    /// any `?`) clears it.
    static let intentActionFloor = 0.5

    /// The classifier's read of the current `text` — recomputed on each access, so
    /// it always reflects what's in the box right now. `submitCurrent()` uses it to
    /// route Enter and the send button uses it to label its destination.
    var suggestedIntent: IntentClassifier.Result {
        IntentClassifier.classify(text)
    }

    /// Which destination the text *confidently* wants, or `nil` when there's no
    /// clear, confident lean (ambiguous, weak, or empty). Routing and the inline hint
    /// both read this, so they can never disagree — if it's not sure enough to name a
    /// destination, it's not sure enough to route there either. There is only ever one
    /// rendered surface (the chat input); this just decides where Enter *sends* the
    /// line, not what the panel looks like. The "ambiguous → ask" default is applied
    /// at submit time by falling back to `.chat`, not here.
    var suggestedPanel: Panel? {
        guard suggestedIntent.confidence >= Self.intentActionFloor else { return nil }
        switch suggestedIntent.intent {
        case .ask:       return .chat
        case .note:      return .note
        case .ambiguous: return nil
        }
    }

    /// Where pressing Enter on the *current* text will actually land. Resolution
    /// order: a Tab override (the user said so explicitly) beats the classifier's
    /// confident read, which beats `.chat` (the resting "ambiguous → ask" default).
    /// This is exactly the resolution `submitCurrent()` uses, so the inline hint can
    /// show its destination and never lie about it.
    var effectiveSubmitPanel: Panel { manualPanelOverride ?? suggestedPanel ?? .chat }

    /// Tab in the idle prompt: flip where Enter will send the current line
    /// (Ask ⇄ Note), overriding the classifier. Flips from whatever the *effective*
    /// destination is right now — including a prior override — so each press reads
    /// as "the other one", exactly what the flipped inline hint shows.
    func toggleSubmitPanel() {
        manualPanelOverride = effectiveSubmitPanel == .note ? .chat : .note
    }

    /// The word in the inline hint — the destination spelled out: "Note" when this
    /// line will be saved to Apple Notes, "Ask" when it'll go to the AI. Flips live
    /// with the classifier as the text crosses intents, so the hint beside the caret
    /// literally says where Enter sends the line.
    var submitLabel: String {
        effectiveSubmitPanel == .note ? "Note" : "Ask"
    }

    /// One past line written to Notes this session, kept only to flash a brief
    /// "Saved to Notes" confirmation under the record input. `nil` clears the cue.
    /// Not persisted — Notes itself is the store of record; this is just feedback.
    @Published var lastSavedNote: String? = nil
    /// Set when a note write fails (e.g. Automation permission not granted), so the
    /// record view can surface the recovery hint instead of silently dropping the
    /// line. Cleared on the next successful write or when the user edits the field.
    @Published var noteError: String? = nil
    /// True while a note write is in flight (the AppleScript runs off-thread and
    /// the first one waits on the TCC prompt), so the record view can show a quiet
    /// "Saving…" cue instead of looking like nothing happened on Enter.
    @Published var noteSaving = false

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

    @Published var showHistory = false
    /// Whether the inline settings panel is showing in place of the recent list.
    /// Replaces the old native Settings window — the gear (and ⌘,) flip this, and
    /// the idle view swaps the RECENT block for the settings form when it's true.
    @Published var showSettings = false
    /// Arms the destructive "Clear recent history?" confirmation. Lives on the
    /// model (not the view) so the Clear pill can raise it while the centered
    /// confirmation card is mounted on the *island* — so it sits in the middle of
    /// the whole glass panel rather than anchored under the pill near the bottom.
    @Published var confirmingClear = false
    /// Which recent row the keyboard has highlighted while navigating the list
    /// with ↑/↓. `nil` means nothing is highlighted yet — the list may be open
    /// (revealed by mouse) but the caret is still in the input. The first ↓
    /// promotes this to `0`. Indexes into the *visible* slice (`recentVisible`).
    @Published var highlightedHistoryIndex: Int? = nil
    @Published private(set) var history: [HistoryItem] = []

    /// The recent items actually rendered in the list — the same slice the view
    /// shows. Keyboard navigation indexes into THIS, so highlight bounds and the
    /// rendered rows can never drift apart.
    var recentVisible: [HistoryItem] { Array(history.prefix(8)) }

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

    // MARK: - Open / collapse

    func openPanel() {
        open = true
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
    func openSettings() {
        open = true
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
    func collapseOnLeave() {
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
    }

    // MARK: - Submit

    /// The single Enter entry point the input field calls. There's only one surface
    /// — the chat input — so this never changes what the panel looks like; it just
    /// routes the line by **intent**:
    ///   · the classifier says note → write it to Apple Notes (feedback shows inline)
    ///   · ask, or ambiguous        → send it to the AI
    /// Ambiguity falls to ask (`effectiveSubmitPanel` resolves `nil` → `.chat`), so an
    /// unsure line on a fresh prompt asks the AI — the agreed "ambiguous → ask" rule.
    /// This matches `submitLabel` exactly, so the inline "Ask"/"Note" hint always
    /// names where the line actually went.
    func submitCurrent() {
        switch effectiveSubmitPanel {
        case .chat: submit()
        case .note: submitNote()
        }
    }

    func submit() {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        text = ""
        showHistory = false
        highlightedHistoryIndex = nil

        // A first question starts a fresh thread: give it a new history id so it
        // becomes its own recent row. A follow-up keeps the existing id, so the
        // whole conversation stays one row, updated in place.
        if turns.isEmpty { threadHistoryID = UUID() }

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
        let context: [ChatMessage] = turns
            .filter { $0.id != answerID }
            .map { ChatMessage(role: $0.role, content: $0.text) }

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
                for try await chunk in self.ai.stream(system: notchSystemPrompt, messages: context) {
                    if Task.isCancelled { return }
                    acc += chunk
                    if let i = thread.firstIndex(where: { $0.id == answerID }) {
                        thread[i].text = acc
                    }
                    if self.isOnScreen(answerID: answerID) {
                        // First chunk: flip to the result view, so the answer
                        // appears to grow in place out of the thinking state.
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
                    self.updateAnswer(id: answerID, text: "Something went wrong. Try again.")
                    self.markFinished(id: answerID)
                    self.mode = .result
                }
            }
        }
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

        // Optimistic: free the field for the next jot immediately, show progress.
        text = ""
        noteError = nil
        noteCueTask?.cancel()
        lastSavedNote = nil
        noteSaving = true

        NotesService.writeNote(line) { [weak self] result in
            guard let self else { return }
            self.noteSaving = false
            switch result {
            case .success:
                self.flashSavedCue(line)
            case .failure(let err):
                // Put the line back so the user can retry / copy it, but only if
                // they haven't already started typing the next one — clobbering a
                // fresh draft would be worse than losing the failed line to the cue.
                if self.text.isEmpty { self.text = line }
                self.noteError = err.errorDescription ?? "Couldn't save to Notes. Try again."
            }
        }
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
        // a long chat is a single recent row, not one per turn.
        let item = HistoryItem(id: threadID, q: firstQ, a: trimmed, t: Date(), turns: thread)
        if let existing = history.firstIndex(where: { $0.id == threadID }) {
            history.remove(at: existing)
        }
        history.insert(item, at: 0)
        history = Array(history.prefix(50))
        saveHistory()
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
        text = ""
        // Restore the whole thread, and adopt this item's id so a follow-up on the
        // reopened conversation updates the same recent row rather than forking a
        // new one. (Legacy single-Q/A items rebuild a two-turn thread.)
        turns = item.conversation
        threadHistoryID = item.id
        mode = .result
        showHistory = false
        highlightedHistoryIndex = nil
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
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60)m ago" }
    if s < 86400 { return "\(s / 3600)h ago" }
    return "\(s / 86400)d ago"
}
