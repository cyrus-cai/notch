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

    /// Which input the panel is in. Two parallel surfaces that share the same
    /// glass island and toggle with Tab:
    ///   · `chat` — ask the AI a question (the original behaviour: idle/load/result)
    ///   · `note` — type a line, press Enter, it lands in Apple Notes
    /// The panel remembers which one you were last on, and the background tints to
    /// match (cold black for chat, a whisper of warm champagne for note) so the two
    /// modes read apart at a glance.
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

    /// The active surface (chat vs. note). Tab flips it. Persisted across launches
    /// so reopening returns to the surface you last used rather than snapping back
    /// to chat — `didSet` writes every change (the Tab toggle, a restore) straight
    /// through. Seeded from `loadPanel()` in `init`, which falls back to `.chat` for
    /// a first run or anyone who never touched the new mode.
    @Published var panel: Panel = .chat {
        didSet { savePanel() }
    }

    @Published var text = ""        // current input (idle prompt or follow-up)

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

    /// Briefly true right after a Tab panel switch. Flipping chat⇄note resizes the
    /// island (e.g. a wide result/history width snapping to the narrow note width),
    /// which can slide the glass out from under a stationary cursor and fire a
    /// spurious `.onHover` exit. Without this guard that exit reaches
    /// `collapseOnLeave` — and since the switch already cleared the `showHistory`
    /// safeguard, nothing stops it from `fullClose`-ing the whole panel. The window
    /// covers just the switch's layout settle; a genuine pointer-leave afterwards
    /// still folds the panel normally.
    private var suppressLeaveCollapse = false
    private var leaveSuppressTask: Task<Void, Never>?

    private var ai: AIService
    private var task: Task<Void, Never>?
    /// Holds the auto-dismiss timer for the "Saved to Notes" cue so a rapid second
    /// save cancels the first one's fade rather than letting them overlap.
    private var noteCueTask: Task<Void, Never>?
    private let historyKey = "notch_history"
    /// Persists the last-used surface (chat/note) so reopening the notch returns to
    /// the mode the user left it in rather than defaulting to chat each launch.
    private let panelKey = "notch_panel"

    /// Stable id for the conversation currently on screen, so a follow-up updates
    /// the *same* recent-list row instead of inserting a new one each turn. Reset
    /// whenever a fresh thread begins (first question, new chat, reopened item).
    private var threadHistoryID = UUID()

    init(ai: AIService = StubAIService()) {
        self.ai = ai
        history = loadHistory()
        panel = loadPanel()
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
        // A panel switch (Tab) just resized the island and may have flung the
        // cursor off it; ignore that one settling exit so the whole panel doesn't
        // fold out from under a mode change the user made by keyboard.
        if suppressLeaveCollapse { return }
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

    /// Hard close from Esc / click-outside — always collapses regardless of mode
    /// (except while loading, which the caller guards).
    func fullClose() {
        task?.cancel()
        task = nil
        open = false
        mode = .idle
        text = ""; turns = []
        showHistory = false
        showSettings = false
        confirmingClear = false
        highlightedHistoryIndex = nil
        // Drop note feedback but keep `panel` — reopening returns to the surface the
        // user last used (chat or note), which is the least surprising behaviour.
        noteCueTask?.cancel()
        lastSavedNote = nil
        noteError = nil
        noteSaving = false
    }

    /// "Back" / start a new conversation: drop the current Q&A and return to the
    /// idle input — but stay OPEN, so the user lands straight on a fresh prompt
    /// instead of the panel collapsing. Triggered by the back button in a result
    /// view and by the ← arrow key.
    func newChat() {
        task?.cancel()
        task = nil
        mode = .idle
        text = ""; turns = []
        showHistory = false
        showSettings = false
        highlightedHistoryIndex = nil
    }

    // MARK: - Submit

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

        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var acc = ""
                for try await chunk in self.ai.stream(system: notchSystemPrompt, messages: context) {
                    if Task.isCancelled { return }
                    // First chunk: flip to the result view, so the answer appears to
                    // grow in place out of the thinking state.
                    if acc.isEmpty { self.mode = .result }
                    acc += chunk
                    self.updateAnswer(id: answerID, text: acc)
                }
                if Task.isCancelled { return }
                self.finish(answerID: answerID, answer: acc)
            } catch is CancellationError {
                // panel closed mid-flight; nothing to show
            } catch {
                if Task.isCancelled { return }
                self.updateAnswer(id: answerID, text: "Something went wrong. Try again.")
                self.markFinished(id: answerID)
                self.mode = .result
            }
        }
    }

    // MARK: - Panel switch (chat ⇄ note)

    /// Tab flips between the chat and note surfaces. The input field is shared, so
    /// we drop whatever's half-typed and clear any chat-only scaffolding (an
    /// in-flight request, the recent list, settings) — switching modes is a clean
    /// context change, not something that should carry a stray draft across. The
    /// caret re-lands in the new field automatically (the body re-arms focus on a
    /// panel change, same as it does on a mode change).
    func togglePanel() {
        panel = (panel == .chat) ? .note : .chat
        // Suppress the spurious hover-exit the island's resize throws off as it
        // resizes to the new surface — see `suppressLeaveCollapse`. The window
        // spans the switch's spring settle (≈0.42s); a real pointer-leave after it
        // expires still collapses normally.
        armLeaveSuppression(for: 0.5)
        // Leaving chat mid-thought shouldn't strand a request or a draft.
        task?.cancel()
        task = nil
        text = ""
        mode = .idle
        turns = []
        showHistory = false
        showSettings = false
        highlightedHistoryIndex = nil
        // Clear note-side feedback so a stale "Saved"/error doesn't greet the
        // record view when you tab back into it later. An in-flight write keeps
        // running (it'll finish into Notes regardless); we just drop its UI cue.
        noteCueTask?.cancel()
        lastSavedNote = nil
        noteError = nil
        noteSaving = false
    }

    /// Hold the leave-collapse guard up for `seconds`, then drop it. A second call
    /// (rapid Tab-Tab) cancels the prior timer so the window always covers the most
    /// recent switch rather than expiring early mid-flurry.
    private func armLeaveSuppression(for seconds: Double) {
        suppressLeaveCollapse = true
        leaveSuppressTask?.cancel()
        leaveSuppressTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.suppressLeaveCollapse = false
        }
    }

    // MARK: - Note submit

    /// Enter in the record field: write the line into Apple Notes as a new note,
    /// then stay in record mode so the next line can go right in (the "jot one and
    /// keep going" flow the user asked for).
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
            self?.lastSavedNote = nil
        }
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

    /// Called once the stream completes: settle the assistant turn and persist the
    /// whole conversation to history (one recent item per thread, updated in place
    /// as it grows). Skips empty results (e.g. a stream that errored before any
    /// text). The recent row shows the first question + latest answer; reopening it
    /// restores every turn.
    private func finish(answerID: UUID, answer ans: String) {
        markFinished(id: answerID)
        let trimmed = ans.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let firstQ = turns.first(where: { $0.role == "user" })?.text ?? ""
        // One history entry per conversation: if this thread is already at the top
        // of the list (a follow-up), update it in place instead of inserting a
        // duplicate, so a long chat is a single recent row, not one per turn.
        let item = HistoryItem(id: threadHistoryID, q: firstQ, a: trimmed, t: Date(), turns: turns)
        if let existing = history.firstIndex(where: { $0.id == threadHistoryID }) {
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

    /// The surface to open in: the last-used one if we've stored it, else `.chat`
    /// (first run, or a stored value that no longer maps to a known case).
    private func loadPanel() -> Panel {
        guard let raw = UserDefaults.standard.string(forKey: panelKey),
              let panel = Panel(rawValue: raw)
        else { return .chat }
        return panel
    }

    private func savePanel() {
        UserDefaults.standard.set(panel.rawValue, forKey: panelKey)
    }

    // MARK: - Open width per state (matches the prototype's s-* widths)

    var openWidth: CGFloat {
        // The record surface is always one simple line — it never grows into the
        // wider load/result widths the way a chat thread does, so it keeps the
        // calm idle width whatever `mode` happens to hold underneath.
        if panel == .note { return Tokens.openWidthIdle }
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
