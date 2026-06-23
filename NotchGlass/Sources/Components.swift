import SwiftUI
import AppKit

/// A borderless prompt field styled to the design tokens.
///
/// Backed by a custom `NSTextField` rather than SwiftUI's `TextField` for one
/// specific reason: AppKit's text fields pop up a floating **autocomplete
/// suggestions panel** while typing/deleting (the empty glass box the user saw).
/// SwiftUI gives no hook to turn it off, so we wrap `NSTextField` directly and
/// disable `isAutomaticTextCompletionEnabled` (plus all the other "smart"
/// substitutions that don't belong in a prompt box).
struct PromptField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat
    /// When this flips true the field grabs first-responder (caret in the box) —
    /// our replacement for SwiftUI `@FocusState`, which can't drive an AppKit view.
    var focusTrigger: Bool = false
    var onSubmit: () -> Void
    /// Invoked when ← is pressed while the field is empty — lets a result view bind
    /// it to "back / new conversation". No-op by default (e.g. the idle prompt),
    /// so left-arrow there just moves the caret as usual.
    var onBack: () -> Void = {}
    /// Invoked when ↓ is pressed while the field is empty — the idle prompt binds
    /// it to "open / step down the recent list". Returns `true` if it consumed the
    /// key (so the field swallows it); `false` lets ↓ move the caret as usual.
    var onDown: () -> Bool = { false }
    /// Invoked when ↑ is pressed while the field is empty — steps the recent-list
    /// highlight back up (and folds it away past the top). Same return contract as
    /// `onDown`.
    var onUp: () -> Bool = { false }
    /// Invoked on Enter *before* `onSubmit` — lets the idle prompt open a
    /// keyboard-highlighted recent row instead of submitting. Returns `true` when
    /// it handled the key (a row was open); `false` falls through to `onSubmit`.
    var onSubmitNav: () -> Bool = { false }
    /// Invoked on Tab (and Shift-Tab) — the idle prompt binds it to "flip the
    /// destination" (Ask ⇄ Note), overriding the classifier for the current line.
    /// Returns `true` when consumed; `false` lets Tab do its default focus move.
    var onTab: () -> Bool = { false }
    /// Reports the width (pt) of everything the field editor is currently *showing*,
    /// in the field's own font — committed text PLUS any in-progress IME composition
    /// (the pinyin/marked text that isn't yet in `text`). The inline hint uses this
    /// to sit right after the caret, so "— Ask" trails the pinyin live and slides
    /// right as more is typed, instead of anchoring to the stale committed text.
    /// `0` when the field is empty. No-op by default.
    var onCaretWidth: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.isBezeled = false
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        // Kill the floating suggestions panel + all auto-substitutions at the
        // NSTextField level.
        field.isAutomaticTextCompletionEnabled = false
        field.allowsCharacterPickerTouchBarItem = false
        field.importsGraphics = false
        field.allowsEditingTextAttributes = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        applyStyle(to: field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        // Refresh the coordinator's view of us so its callbacks (onCaretWidth, the
        // nav hooks) run against the current closures, not the ones captured at init.
        context.coordinator.parent = self
        // NEVER touch the field while an IME composition (marked text) is in flight.
        // During composition the bound `text` lags the display (pinyin isn't
        // committed yet), so the `stringValue != text` check below would "correct"
        // the field back to the stale committed text — wiping the user's half-typed
        // pinyin. And re-renders DO happen mid-composition now: the caret-width
        // updates driving the inline hint are SwiftUI state changes.
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        let textChanged = !composing && field.stringValue != text
        if textChanged { field.stringValue = text }
        applyStyle(to: field)
        // When `text` is cleared programmatically (after submit) there's no editor
        // change notification to re-measure from, so push the new width here. Use the
        // bound `text` (the editor mirrors it; no marked text is in flight on a reset).
        if textChanged {
            let font = NSFont.systemFont(ofSize: fontSize)
            let w = text.isEmpty ? 0 : ceil((text as NSString).size(withAttributes: [.font: font]).width)
            onCaretWidth(w)
        }
        // Take focus exactly ONCE per rising edge of focusTrigger. SwiftUI calls
        // updateNSView on every render while the panel is open; without this latch
        // we'd enqueue a `makeFirstResponder` on each pass, piling up async blocks
        // that ping-pong the caret (and, with two PromptFields on screen, fight
        // each other) — a prime suspect for the recurring freeze.
        let coord = context.coordinator
        if focusTrigger {
            if !coord.didFocus, field.window != nil, field.currentEditor() == nil {
                coord.didFocus = true
                DispatchQueue.main.async { [weak field, weak coord] in
                    guard let field, field.currentEditor() == nil else { return }
                    field.window?.makeFirstResponder(field)
                    Self.disableEditorMagic(field.currentEditor())
                    // The editor exists from this moment — hook the caret-width
                    // observers NOW, not at controlTextDidBeginEditing. That delegate
                    // call only fires on the first *committed* change, so a user who
                    // starts straight into IME composition (pinyin) would compose an
                    // entire word before any observer existed.
                    coord?.attachEditorObservers(field.currentEditor())
                }
            }
        } else {
            coord.didFocus = false   // re-arm for the next open
        }
        // Belt-and-suspenders for click-to-focus and editor swaps: whenever this
        // field currently owns the field editor, make sure the caret-width observers
        // are attached (idempotent — re-attaching the same editor is a no-op).
        if let editor = field.currentEditor() {
            coord.attachEditorObservers(editor)
        }
    }

    /// The real source of the floating suggestion box: the **field editor** (the
    /// shared `NSTextView` that backs editing). Its own auto-completion / text-
    /// prediction / substitution switches are separate from the NSTextField's and
    /// stay ON unless turned off here. We can only reach it once editing starts
    /// (the editor is created lazily), so this runs right after we take focus and
    /// again whenever editing begins.
    static func disableEditorMagic(_ editor: NSText?) {
        guard let tv = editor as? NSTextView else { return }
        tv.isAutomaticTextCompletionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
    }

    /// Only writes a property when its value actually changed. AppKit setters like
    /// `placeholderAttributedString` rebuild layout/redraw on every assignment;
    /// doing that unconditionally on each keystroke was wasteful churn. Cheap
    /// equality guards keep typing smooth.
    private func applyStyle(to field: NSTextField) {
        let wantFont = NSFont.systemFont(ofSize: fontSize)
        if field.font != wantFont { field.font = wantFont }

        let wantText = NSColor(Tokens.ink).withAlphaComponent(0.96)
        if field.textColor != wantText { field.textColor = wantText }

        // Compare the *whole* attributed placeholder (string AND color/font), not
        // just the text — otherwise a color change with the same text gets
        // silently dropped and the field keeps an old, darker placeholder.
        let wantPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor(Tokens.placeholder),
                .font: wantFont,
            ]
        )
        if field.placeholderAttributedString != wantPlaceholder {
            field.placeholderAttributedString = wantPlaceholder
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        /// Refreshed on every `updateNSView` so the callbacks below (notably
        /// `onCaretWidth`) never fire through a stale closure captured at init.
        var parent: PromptField
        /// One-shot latch: true once we've taken focus for the current rising edge
        /// of `focusTrigger`, reset when it falls. Prevents re-enqueuing focus on
        /// every render. (See updateNSView.)
        var didFocus = false
        /// The field editor we've subscribed to, and its text storage. Held weakly —
        /// it's the shared window field editor, not ours to retain. The STORAGE is
        /// the one that matters: IME composition (typing pinyin before it commits)
        /// edits the marked text directly in the storage WITHOUT posting
        /// `NSText.didChangeNotification` or calling `controlTextDidChange` — those
        /// only fire for committed changes. `NSTextStorage.didProcessEditingNotification`
        /// fires for every storage edit, marked text included, so it's the only hook
        /// that lets the inline hint trail the pinyin live.
        private weak var observedEditor: NSText?
        private weak var observedStorage: NSTextStorage?
        init(_ parent: PromptField) { self.parent = parent }
        deinit { detachEditorObservers() }

        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            // Editor exists now — strip its completion/prediction behaviours.
            PromptField.disableEditorMagic(field.currentEditor())
            attachEditorObservers(field.currentEditor())
            reportCaretWidth(for: field.currentEditor())
            // Drop the island below the IME candidate window while typing so the
            // pinyin/kana/Hangul selection popup isn't covered by the panel.
            (field.window as? NotchPanel)?.beginFieldEditing()
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            detachEditorObservers()
            // Restore the resting level now that this field is done editing.
            ((obj.object as? NSTextField)?.window as? NotchPanel)?.endFieldEditing()
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            // Belt-and-suspenders: macOS can re-arm prediction on the editor as
            // you type, so keep it disabled on every change (cheap idempotent set).
            PromptField.disableEditorMagic(field.currentEditor())
            attachEditorObservers(field.currentEditor())
            reportCaretWidth(for: field.currentEditor())
        }

        // MARK: Caret-width tracking (for the inline hint, IME-aware)

        /// Subscribe to the field editor's text storage (and, for committed-change
        /// coverage, the editor's own didChange). Idempotent — re-attaching the same
        /// editor/storage is a no-op — so it's safe to call from every hook that
        /// might be the first to see the editor (focus grab, begin editing, change).
        func attachEditorObservers(_ editor: NSText?) {
            guard let editor else { return }
            if editor !== observedEditor {
                if let old = observedEditor {
                    NotificationCenter.default.removeObserver(
                        self, name: NSText.didChangeNotification, object: old)
                }
                observedEditor = editor
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(editorTextDidChange(_:)),
                    name: NSText.didChangeNotification,
                    object: editor
                )
            }
            // The IME-aware hook: marked-text (pinyin) edits land in the storage and
            // post didProcessEditing even though no "text did change" ever fires.
            if let storage = (editor as? NSTextView)?.textStorage, storage !== observedStorage {
                if let old = observedStorage {
                    NotificationCenter.default.removeObserver(
                        self, name: NSTextStorage.didProcessEditingNotification, object: old)
                }
                observedStorage = storage
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(storageDidProcessEditing(_:)),
                    name: NSTextStorage.didProcessEditingNotification,
                    object: storage
                )
            }
        }

        private func detachEditorObservers() {
            if let editor = observedEditor {
                NotificationCenter.default.removeObserver(
                    self, name: NSText.didChangeNotification, object: editor)
            }
            observedEditor = nil
            if let storage = observedStorage {
                NotificationCenter.default.removeObserver(
                    self, name: NSTextStorage.didProcessEditingNotification, object: storage)
            }
            observedStorage = nil
        }

        /// Committed-change path (kept as a cheap backstop alongside the storage hook).
        @objc private func editorTextDidChange(_ note: Notification) {
            reportCaretWidth(for: note.object as? NSText)
        }

        /// The IME path: fires on EVERY storage edit, including marked-text (pinyin)
        /// updates mid-composition. Posted from inside `processEditing`, so defer one
        /// runloop tick before reading the storage — measuring mid-edit would read a
        /// half-applied state.
        @objc private func storageDidProcessEditing(_ note: Notification) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reportCaretWidth(for: self.observedEditor)
            }
        }

        /// Measure everything the editor is currently showing — committed text plus
        /// any in-progress IME composition — in the field's font, and hand it to the
        /// inline hint so it sits right after the caret. The editor's `string`
        /// already includes the marked (composing) text, so measuring it covers the
        /// pinyin-in-progress case for free.
        private func reportCaretWidth(for editor: NSText?) {
            let shown = editor?.string ?? parent.text
            let font = NSFont.systemFont(ofSize: parent.fontSize)
            let width = shown.isEmpty
                ? 0
                : ceil((shown as NSString).size(withAttributes: [.font: font]).width)
            parent.onCaretWidth(width)
        }

        /// The authoritative kill switch for the word-completion popup: the field
        /// editor asks its delegate for completions on every edit; returning an
        /// empty list (and -1 selection) means there's never anything to show, so
        /// the panel never appears. (Calling `complete(_:)` ourselves did the
        /// OPPOSITE — it *opened* the panel and looped — so that's gone.)
        func control(_ control: NSControl, textView: NSTextView,
                     completions words: [String],
                     forPartialWordRange charRange: NSRange,
                     indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String] {
            index.pointee = -1
            return []
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            // Defensively swallow the "show completions" command too.
            if commandSelector == #selector(NSResponder.complete(_:)) {
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // Give the recent-list highlight first crack at Enter — if a row is
                // keyboard-selected, open it; otherwise submit the prompt as usual.
                if parent.onSubmitNav() { return true }
                parent.onSubmit()
                return true
            }
            // Tab flips the line's destination (Ask ⇄ Note). Shift-Tab too — the
            // toggle is binary, so "the other one" is the same either way. The
            // caller decides whether to consume it; unconsumed, Tab falls through
            // to its usual focus move.
            if commandSelector == #selector(NSResponder.insertTab(_:))
                || commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                return parent.onTab()
            }
            // ← on an empty field means "go back" (start a new conversation) rather
            // than moving a caret that has nothing to move. With text present we let
            // it fall through so normal cursor movement still works while editing.
            if commandSelector == #selector(NSResponder.moveLeft(_:)),
               parent.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parent.onBack()
                return true
            }
            // ↓ / ↑ on an empty field drive the recent-history list (open + step the
            // highlight). Only when empty — with text present the arrows move the
            // caret as usual. `onDown`/`onUp` return whether they consumed it, so a
            // ↓ with no history at all still falls through to default behaviour.
            if commandSelector == #selector(NSResponder.moveDown(_:)),
               parent.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return parent.onDown()
            }
            if commandSelector == #selector(NSResponder.moveUp(_:)),
               parent.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return parent.onUp()
            }
            return false
        }
    }
}

/// The compact substring filter that sits above the recent list once it grows past a
/// handful of rows. An `NSViewRepresentable` over `NSTextField` — NOT a SwiftUI
/// `TextField` — for the same reason `PromptField` is: a plain SwiftUI field pops the
/// floating autocomplete/suggestions panel and applies smart substitutions, which
/// would be jarring over the glass. We reuse `PromptField.disableEditorMagic` to kill
/// all of that on the field editor. Deliberately *not* auto-focused: keyboard focus
/// stays in the main prompt so ↓/↑ still drive the list; the user clicks the field to
/// start filtering.
struct HistorySearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat
    /// When this flips true the field grabs first-responder once, so the filter
    /// icon can deposit the caret straight into the expanded field.
    var focusTrigger: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.isAutomaticTextCompletionEnabled = false
        field.allowsCharacterPickerTouchBarItem = false
        field.importsGraphics = false
        field.allowsEditingTextAttributes = false
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        applyStyle(to: field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Same composition guard as PromptField: never overwrite the field while an
        // IME composition is in flight, or half-typed pinyin gets wiped.
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        if !composing, field.stringValue != text { field.stringValue = text }
        applyStyle(to: field)
        // Kill editor-level magic whenever this field owns the field editor (the
        // editor is created lazily on first focus; re-applying is harmless).
        if let editor = field.currentEditor() {
            PromptField.disableEditorMagic(editor)
        }
        // Take focus exactly ONCE per rising edge of focusTrigger, mirroring
        // PromptField's latch so we don't fight the field editor on every render.
        let coord = context.coordinator
        if focusTrigger {
            if !coord.didFocus, field.window != nil, field.currentEditor() == nil {
                coord.didFocus = true
                DispatchQueue.main.async { [weak field] in
                    guard let field, field.currentEditor() == nil else { return }
                    field.window?.makeFirstResponder(field)
                    if let editor = field.currentEditor() {
                        PromptField.disableEditorMagic(editor)
                    }
                }
            }
        } else {
            coord.didFocus = false   // re-arm for the next expand
        }
    }

    private func applyStyle(to field: NSTextField) {
        let wantFont = NSFont.systemFont(ofSize: fontSize)
        if field.font != wantFont { field.font = wantFont }
        let wantText = NSColor(Tokens.text2)
        if field.textColor != wantText { field.textColor = wantText }
        let wantPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor(Tokens.text4),
                .font: wantFont,
            ]
        )
        if field.placeholderAttributedString != wantPlaceholder {
            field.placeholderAttributedString = wantPlaceholder
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: HistorySearchField
        /// One-shot latch: true once we've taken focus for the current rising edge
        /// of `focusTrigger`, reset when it falls.
        var didFocus = false
        init(_ parent: HistorySearchField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            PromptField.disableEditorMagic(field.currentEditor())
            // Same IME fix as PromptField: drop the island below the candidate window
            // while this filter field is being typed into.
            (field.window as? NotchPanel)?.beginFieldEditing()
        }

        func controlTextDidEndEditing(_ note: Notification) {
            ((note.object as? NSTextField)?.window as? NotchPanel)?.endFieldEditing()
        }
    }
}

/// A Siri-style **inline ghost hint** that trails the typed text on the same line,
/// spelling out where Enter will send it — "— Ask" for a question, "— Note" for a
/// jot — the way Siri appends a faint "— Ask Siri" after what you've typed. The
/// classifier (via `NotchModel.submitLabel` / `effectiveSubmitPanel`)
/// already recomputes that destination on every keystroke; this just *shows* it,
/// in place, so the routing is visible before you press Return.
///
/// It's an overlay, not part of the field: the backing `NSTextField` can't host a
/// trailing accessory, so we measure the typed text's width with the field's exact
/// `NSFont` and offset the ghost label by that much inside a leading-aligned
/// `ZStack`. When the text grows toward the trailing edge, the hint doesn't vanish —
/// it **docks** at the right edge of the row and holds there while the field scrolls,
/// so the Ask/Note read is never lost on a long line. The caller reserves that
/// docking slot in the field itself (`reservedTrailingWidth`), so scrolled text can
/// never run underneath the docked hint.
///
/// Mounted by the caller *over* the same row as its `PromptField`, sharing the
/// field's `fontSize` so the measurement lines up glyph-for-glyph. Caller passes the
/// available width (usually the row's own width, via a `GeometryReader`) so the
/// dock position is known.
struct InlineSendHint: View {
    /// "Ask" / "Note" — the destination the classifier currently reads.
    var label: String
    /// The field's font size, so the hint matches the body text size exactly.
    var fontSize: CGFloat
    /// Width (pt) of everything the field is currently showing — committed text PLUS
    /// any in-progress IME composition (pinyin) — measured in the field's font by
    /// `PromptField` (`onCaretWidth`). This is where the caret sits, hence where the
    /// ghost begins; sourcing it from the editor (not from the committed `text`) is
    /// what lets "— Ask" trail the pinyin live and slide right as you type.
    var caretWidth: CGFloat
    /// Width available on the row for text + hint. The hint hides rather than clip
    /// when the content leaves it no room.
    var availableWidth: CGFloat
    /// Left inset of the NSTextField's text (its cell draws ~2pt in from the edge),
    /// so the ghost lands flush after the glyphs, not 2pt early.
    var leadingInset: CGFloat = 2

    /// The faint connector + word, e.g. "— Ask". An em dash leads into it, echoing
    /// Siri's "— Ask Siri" framing; no ⏎ glyph (it rendered as an ugly box beside the
    /// text). Just the destination, spelled out.
    private var hintString: String { "— \(label)" }

    /// Breathing room between the last glyph and the ghost.
    private static let gap: CGFloat = 8

    /// Trailing room the caller should reserve INSIDE the field (as trailing
    /// padding) so text can never scroll under the docked hint. Sized to the *current*
    /// label ("— Ask", "— Note", "— Remind · Weekly · …") rather than the widest
    /// possible label, so the field uses all available width when the destination is
    /// short and no dead strip appears to the right of the ghost. The caller animates
    /// this padding alongside the hint so Ask→Note→Remind transitions stay smooth.
    static func reservedTrailingWidth(label: String, fontSize: CGFloat) -> CGFloat {
        return width(of: "— \(label)", fontSize: fontSize) + gap
    }

    var body: some View {
        // Sit the ghost just past the glyphs, with a small breathing gap — but never
        // past the dock at the row's trailing edge. A short line reads inline
        // (Siri-style, right after the caret); as the line grows the hint glides
        // right until it reaches the dock and holds there, staying visible while the
        // field scrolls underneath (the caller reserved that slot, so no overlap).
        // Visibility keys on `caretWidth` (not the committed `text`) so the hint
        // stays up while pinyin is still composing.
        //
        // The dock anchors to the LEFT edge of the reserved strip the caller padded
        // into the field. Both the field's usable width and the dock reference the SAME
        // reserved width (now sized to the current label) so the ghost lands flush where
        // the text area ends — no gap, no overlap — while short labels reclaim the rest
        // of the row for the editable area.
        let reserved = Self.reservedTrailingWidth(label: label, fontSize: fontSize)
        let dock = availableWidth - reserved + Self.gap
        let start = min(leadingInset + caretWidth + Self.gap, dock)
        let visible = caretWidth > 0

        // Motion notes — tuned to Apple's current language for ghost text:
        //  · FOLLOW is a critically-damped spring, not a fixed-duration ease. Typing
        //    retargets the animation every keystroke; a spring merges those
        //    retargets velocity-continuously (each new target inherits the current
        //    velocity), where an ease restarts from zero each time and reads as a
        //    mechanical stutter under fast input. No bounce — the hint is "pulled
        //    along" behind the caret, it never overshoots past it.
        //  · APPEAR/DISAPPEAR is a materialize (blur + fade, in place) — the same
        //    treatment Apple Intelligence uses for ghost text (`.blurReplace` on
        //    macOS 15; recreated below for our 14 target). Structurally inserting
        //    the Text (`if visible`) is what keeps the appearance anchored: a freshly
        //    inserted view is born at its final offset, so it condenses into
        //    position rather than flying in from wherever the hint last sat.
        //  · The WORD swap (Ask⇄Note) is a quiet in-place cross-fade
        //    (`contentTransition`), not a scale/bounce — the meaning changes, the
        //    object doesn't.
        return ZStack(alignment: .leading) {
            if visible {
                // Match the body text exactly — same size, same (regular) weight as
                // the field's own glyphs — so the hint reads as a quiet continuation
                // of the line rather than a smaller label. Only the colour sets it
                // apart (placeholder grey vs. near-white typed text).
                Text(hintString)
                    .font(.system(size: fontSize, weight: .regular))
                    .foregroundStyle(Tokens.placeholder)
                    .lineLimit(1)
                    .fixedSize()
                    .contentTransition(.opacity)
                    .animation(.smooth(duration: 0.25), value: label)
                    .offset(x: start)
                    .animation(.smooth(duration: 0.25), value: start)
                    .transition(.materialize)
            }
        }
        .allowsHitTesting(false)
        // Drives the insertion/removal (materialize) transition above.
        .animation(.smooth(duration: 0.3), value: visible)
    }

    /// Measure a string's rendered width in `NSFont.systemFont(ofSize:)` — the same
    /// font family `PromptField` installs — so the ghost's start matches the real
    /// caret. Uses AppKit's text sizing (not a SwiftUI `Text` measurement) because
    /// the field itself is an `NSTextField`; same engine, same metrics.
    private static func width(of string: String, fontSize: CGFloat) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: fontSize)
        let size = (string as NSString).size(withAttributes: [.font: font])
        return ceil(size.width)
    }
}

/// The two ends of the ghost-text materialize: hidden is a soft transparent haze
/// (blurred + clear), shown is the sharp resting glyphs. Used via
/// `AnyTransition.materialize` so insertion condenses the text into place and
/// removal dissolves it — Apple Intelligence's ghost-text treatment (macOS 15's
/// `.blurReplace`), recreated with a modifier transition for our macOS 14 target.
private struct MaterializeEffect: ViewModifier {
    var shown: Bool
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 4)
    }
}

extension AnyTransition {
    /// Blur-and-fade in place: condense in on insertion, dissolve out on removal.
    static let materialize = AnyTransition.modifier(
        active: MaterializeEffect(shown: false),
        identity: MaterializeEffect(shown: true)
    )
}

/// The send button — a piece of the same **Liquid Glass** as the rest of the
/// island (native `.glassEffect` on macOS 26+, blur fallback below), brightening
/// gently on hover rather than flooding to a flat white fill.
///
/// Two shapes, one control:
///   • Given a `label` ("Ask" / "Note"), it renders a **pill that spells out the
///     destination in words** — because a glyph alone (arrow vs. pencil) doesn't
///     read as "ask vs. note" at a glance. The classifier watches the text as it's
///     typed and swaps the word in place; the glyph beside it is a plain ⏎, marking
///     the key you press. So the button tells you in plain language where Enter
///     sends the line, before you press it.
///   • With no `label` (the mid-thread follow-up), it stays a bare arrow circle:
///     a follow-up is always an ask, so there's nothing to disambiguate and the
///     small inline field has no room for a word.
///
/// The label cross-fades when it flips, so ask⇄note reads as one control changing
/// meaning rather than two different buttons.
struct SendButton: View {
    var compact: Bool = false
    /// SF Symbol for the action the current text will trigger. Defaults to the
    /// classic send arrow; callers pass a note glyph when the input reads as a jot.
    var icon: String = "arrow.right"
    /// The destination spelled out ("Ask" / "Note"). When set, the button renders
    /// as a labeled pill; when `nil`, it's the bare arrow circle (follow-up).
    var label: String? = nil
    var action: () -> Void
    @State private var hovering = false

    private var size: CGFloat { compact ? 27 : 30 }

    var body: some View {
        Button(action: action) {
            if let label {
                pill(label)
            } else {
                glyphCircle
            }
        }
        // Same press-give as the island's other glass chips.
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
        // The flip rides a quick spring so ask⇄note feels like the control morphing,
        // in step with the rest of the panel's motion language.
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: icon)
        .animation(.spring(response: 0.32, dampingFraction: 0.7), value: label)
    }

    /// The labeled form: a glass pill reading "Ask ⏎" / "Note ⏎", the word leading
    /// so the destination is the first thing you read. Whole contents keyed on the
    /// label so a change cross-fades rather than hard-cuts.
    private func pill(_ label: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
        .id(label)
        .transition(.scale(scale: 0.7).combined(with: .opacity))
        .padding(.horizontal, 13)
        .frame(height: size)
        .glassCapsule(in: Capsule(), brighter: hovering)
        .contentShape(Capsule())
    }

    /// The bare form: just the send arrow in a glass circle (mid-thread follow-up).
    private var glyphCircle: some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
            .id(icon)
            .transition(.scale(scale: 0.55).combined(with: .opacity))
            .frame(width: size, height: size)
            .glassCapsule(in: Circle(), brighter: hovering)
            .contentShape(Circle())
    }
}

/// A small circular icon button rendered in the **Liquid Glass** language: a
/// real translucent glass capsule (native `.glassEffect` on macOS 26+, a blurred
/// `NSVisualEffectView` fallback below that) with the signature soft specular rim
/// and a gentle brighten-on-hover. Used for the in-panel settings entry so the
/// affordance reads as a piece of the same glass island, not a flat icon.
struct GlassIconButton: View {
    var systemName: String
    var help: String
    var size: CGFloat = 30
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(hovering ? Tokens.text1 : Tokens.text3)
                .frame(width: size, height: size)
                .glassCapsule(in: Circle(), brighter: hovering)
                .contentShape(Circle())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .help(help)
    }
}

/// A small **text** pill in the same Liquid Glass language as `GlassIconButton`
/// — a translucent glass capsule that brightens on hover. Used for word actions
/// like "Clear" so they read as part of the glass island, not flat link text.
struct GlassTextButton: View {
    var title: String
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.sf(11, weight: .medium))
                .foregroundStyle(hovering ? Tokens.text2 : Tokens.text4)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .glassCapsule(in: Capsule(), brighter: hovering)
                .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
    }
}

/// Scales the glass capsule down a touch on press for a tactile, physical feel —
/// the glass "gives" under the cursor like the rest of the island.
private struct GlassPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// A one-shot **rim glow** that pulses whenever a watched value changes — the input
/// field's outer acknowledgement that its *destination* just flipped (Ask → Note →
/// Remind). The inline "— Ask"/"— Note" ghost already cross-fades the word beside the
/// caret; this brightens the field's own border for a beat so the change registers in
/// peripheral vision too, not only where the eye is reading.
///
/// Mechanics: brighten instantly (no animation) on the change, then ease back to rest —
/// a struck-then-settles curve, the same shape the entry kick uses, so the field reads
/// as having been *tapped* by the switch rather than slowly glowing. Keyed on an
/// `Equatable` trigger so it fires once per real transition; passing the intent
/// *category* (not the full label) keeps a "Remind · Daily" → "Remind · Weekly" suffix
/// edit from pulsing, since the destination itself didn't move.
private struct IntentChangePulse<Trigger: Equatable, S: InsettableShape>: ViewModifier {
    var trigger: Trigger
    var shape: S
    @State private var glow: Double = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                shape
                    .strokeBorder(Color.white.opacity(0.5 * glow), lineWidth: 1)
                    .blur(radius: 1.5)
                    .allowsHitTesting(false)
            )
            .onChange(of: trigger) { _, _ in
                // Strike: jump to full on its own (instant) transaction so the brighten
                // is a hit, not a ramp; then release back to rest on a soft ease.
                var instant = Transaction(); instant.disablesAnimations = true
                withTransaction(instant) { glow = 1 }
                withAnimation(.easeOut(duration: 0.45)) { glow = 0 }
            }
    }
}

extension View {
    /// Pulse a soft rim glow on `shape` each time `trigger` changes — see
    /// `IntentChangePulse`. Used on the prompt field to flash its border when the
    /// Ask/Note/Remind destination flips.
    func intentChangePulse<T: Equatable, S: InsettableShape>(on trigger: T, shape: S) -> some View {
        modifier(IntentChangePulse(trigger: trigger, shape: shape))
    }
}

extension View {
    /// Wrap the content in a Liquid Glass chip of the given shape — genuine system
    /// glass on macOS 26+, a dark blur fallback below — topped with the same
    /// whisper-thin specular rim the island uses, so it sits in the same material
    /// family. Works for both circular icon chips and capsule text pills.
    @ViewBuilder
    func glassCapsule<S: InsettableShape>(in shape: S, brighter: Bool, tint: Color? = nil) -> some View {
        self
            .background {
                if #available(macOS 26.0, *) {
                    shape.fill(.clear)
                        .glassEffect(.clear.interactive(), in: shape)
                } else {
                    LegacyGlassBackdrop().clipShape(shape)
                }
            }
            // Both overlays are purely decorative (tint + specular rim). They sit ON
            // TOP of the content, and a filled/stroked Shape is hit-testable by
            // default — which would swallow taps meant for any control *nested* inside
            // a capsule (e.g. a remove × or inline button). Mark them non-interactive
            // so clicks pass through to the content below.
            //
            // `tint`, when set, washes the fill in a colour instead of plain white — a
            // whisper of hue so a chip can read as a slightly different colour from its
            // untinted siblings while staying in the same glass material.
            .overlay(
                shape.fill((tint ?? .white)
                    .opacity(tint != nil ? (brighter ? 0.30 : 0.20) : (brighter ? 0.10 : 0.04)))
                    .allowsHitTesting(false)
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(brighter ? 0.32 : 0.20),
                            .white.opacity(0.06),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
                .allowsHitTesting(false)
            )
            // Real Liquid Glass barely casts a shadow — it reads as a thin chip of
            // glass, not a floating card. Just a whisper of a contact shadow to
            // seat it on the island; the specular rim does the rest of the work.
            .shadow(color: .black.opacity(0.10), radius: 1.5, y: 0.5)
    }
}

/// One clipboard-preset chip — a small glass capsule labelled with a Writing-Tools
/// style action ("Summarize", "Proofread", "更友好"…) that, on tap, runs that preset
/// against the copied text. Same Liquid Glass language as `GlassTextButton`, sized a
/// touch larger so a row of them reads as tappable actions, not metadata.
struct ClipboardPresetChip: View {
    var title: String
    /// A faint background tint for the leading capture chip ("Note"/"Remind"), set so
    /// it reads as a slightly different *colour* from the plain-glass Ask presets beside
    /// it — same size, same text weight, same hover feel, just a coloured wash over the
    /// glass. `nil` (the default) leaves the chip untinted, identical to the presets.
    var tint: Color? = nil
    /// When set, a trailing "↵" key cap rides inside the chip — the discoverability cue
    /// for the leading capture chip, which Enter on an empty prompt already fires. Only
    /// the capture chip passes this; the plain Ask presets leave it `nil`.
    var keyHint: Bool = false
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.sf(12, weight: .medium))
                    .foregroundStyle(hovering ? Tokens.text1 : Tokens.text2)
                    .lineLimit(1)
                // The "↵" cue: a small return glyph, so the capture chip advertises its
                // keyboard twin without spelling out the word "Enter". Brightens with the
                // chip on hover. No background — it rides as a bare glyph beside the label.
                if keyHint {
                    Image(systemName: "return")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(hovering ? Tokens.text2 : Tokens.text3)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, keyHint ? 10 : 12)
            .padding(.vertical, 6)
            .glassCapsule(in: Capsule(), brighter: hovering, tint: tint)
            .contentShape(Capsule())
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.18), value: hovering)
    }
}

/// A minimal left-aligned flow layout: lays children left-to-right, wrapping to the
/// next line when the next child would overflow the proposed width. Used for the
/// clipboard-preset chip row, which carries more chips than fit the panel on one
/// line. Deliberately tiny — no alignment knobs beyond leading — since that's all the
/// chip row needs; reach for a real grid if a second caller wants more.
struct FlowLayout: Layout {
    var hSpacing: CGFloat = 6
    var vSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                // Wrap: bank the finished row's width, drop to the next line.
                widest = max(widest, x - hSpacing)
                x = 0; y += rowHeight + vSpacing; rowHeight = 0
            }
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
        widest = max(widest, x - hSpacing)
        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0; y += rowHeight + vSpacing; rowHeight = 0
            }
            view.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + hSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// The destructive "Clear recent history?" confirmation, rendered as a card
/// **centered over the whole island** rather than a popover anchored to the Clear
/// pill (which dropped it down near the bottom of the panel). A dim scrim catches
/// outside taps to cancel; the card itself floats in the middle of the glass.
struct ClearHistoryConfirm: View {
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        ZStack {
            // Scrim over the whole island — darkens the panel behind the card and
            // catches a tap-outside to dismiss, like the native dialog's backdrop.
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)

            VStack(spacing: 14) {
                VStack(spacing: 6) {
                    Text(L("clear.title"))
                        .font(.sf(15, weight: .semibold))
                        .foregroundStyle(Tokens.text1)
                    Text(L("clear.body"))
                        .font(.sf(12))
                        .foregroundStyle(Tokens.text3)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    ConfirmDialogButton(title: L("clear.cancel"), role: .cancel, action: onCancel)
                    ConfirmDialogButton(title: L("clear.confirm"), role: .destructive, action: onConfirm)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: 280)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    // Real glass: a thin blur of whatever sits behind the card,
                    // dropped onto a dark tint so the text keeps its contrast.
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.black.opacity(0.28))
                    )
                    // A soft top-down sheen, like light catching the upper edge.
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.10), .clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                            .blendMode(.plusLighter)
                    )
                    // Gradient hairline — bright along the top, fading down the sides.
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [.white.opacity(0.30), .white.opacity(0.08)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.75
                            )
                    )
                    .shadow(color: .black.opacity(0.45), radius: 20, y: 10)
            }
            .padding(24)
        }
    }
}

/// A flat, full-width-ish button for the confirmation card — a neutral capsule for
/// Cancel, a soft-red one for the destructive Clear. Brightens on hover.
private struct ConfirmDialogButton: View {
    var title: String
    var role: ButtonRole
    var action: () -> Void

    @State private var hovering = false

    private var isDestructive: Bool { role == .destructive }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.sf(13, weight: .semibold))
                .foregroundStyle(isDestructive ? Tokens.danger : Tokens.text1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(
                            isDestructive
                                ? Tokens.danger.opacity(hovering ? 0.26 : 0.16)
                                : Color.white.opacity(hovering ? 0.16 : 0.09)
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: hovering)
    }
}

/// The calm three-dot "thinking" wave used while the AI works.
struct ThinkingDots: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Tokens.text2)
                    .frame(width: 6, height: 6)
                    .scaleEffect(phase ? 1.0 : 0.82)
                    .opacity(phase ? 0.95 : 0.22)
                    .offset(y: phase ? -2 : 0)
                    .animation(
                        .easeInOut(duration: 0.62)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.16),
                        value: phase
                    )
            }
        }
        .frame(minHeight: 22)
        .onAppear { phase = true }
    }
}

/// The streaming assistant bubble while the answer is still in flight: the
/// thinking dots until the first token lands, then the live `StreamingMarkdown`.
/// The point of this wrapper is the *seam* between the two — without it the dots
/// hard-cut out the instant `text` goes non-empty and the first words snap in.
/// Here the two share one leading-anchored slot in a `ZStack` and cross-fade on
/// the first-token edge: the dots ease out (`thinkingToStreamFade`) while the
/// first words ease in over the same window, so the wait dissolves into the
/// answer instead of blinking over to it. Subsequent chunks are owned by
/// `StreamingMarkdown`'s own per-chunk `TailFadeIn`; this view only choreographs
/// the dots → first-字 handoff and then stays out of the way.
struct StreamingTurnContent: View {
    let text: String
    var baseFont: CGFloat = 15
    var color: Color = Tokens.text1
    var onInAppCopy: (() -> Void)? = nil

    /// Duration of the dots-out / first-token-in cross-fade. Matched to the
    /// 80ms-ish opacity beat the rest of the streaming UI uses so the handoff
    /// reads as part of the same typewriter rhythm, not a separate flourish.
    static let fade: Double = 0.12

    /// Latched true on the first non-empty `text`. We key the cross-fade on this
    /// edge (not on `text.isEmpty` directly) so it fires exactly once — later
    /// chunks never re-run the dots fade, and a turn that arrives with text
    /// already present (none do today, but cheap insurance) still settles lit.
    @State private var hasFirstToken = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Dots: present (and animating) only until the first token, then
            // faded fully out. Kept mounted across the fade so it can ease away
            // rather than vanish; `allowsHitTesting(false)` and zero opacity make
            // the settled state inert.
            ThinkingDots()
                .opacity(hasFirstToken ? 0 : 1)
                .allowsHitTesting(false)

            // First words: start transparent, ease in as the dots ease out. Once
            // lit, `StreamingMarkdown` carries every following chunk's own fade.
            StreamingMarkdown(source: text, baseFont: baseFont, color: color, onInAppCopy: onInAppCopy)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(hasFirstToken ? 1 : 0)
        }
        .animation(.easeInOut(duration: Self.fade), value: hasFirstToken)
        .onChange(of: text.isEmpty) { _, isEmpty in
            if !isEmpty { hasFirstToken = true }
        }
        .onAppear { if !text.isEmpty { hasFirstToken = true } }
    }
}

/// Renders inline `**bold**` markdown into styled text — the same lightweight
/// transform the prototype applied to AI answers.
struct InlineMarkdownText: View {
    let raw: String
    init(_ raw: String) { self.raw = raw }

    var body: some View {
        Text(attributed)
    }

    private var attributed: AttributedString {
        // SwiftUI's built-in inline-markdown parsing covers **bold**, *italic*,
        // and `code` — exactly the subset we need.
        if var parsed = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            // The markdown parser also turns `[label](url)` into a tappable link.
            // The answer text comes from an LLM endpoint we don't fully trust, so a
            // rogue/compromised backend could embed `[ok](file:///…)` or a custom
            // scheme that fires on click. We render answers as read-only text, so
            // strip every `.link` run — keep the styling, drop the clickable URL.
            for run in parsed.runs where run.link != nil {
                parsed[run.range].link = nil
            }
            return parsed
        }
        return AttributedString(raw)
    }
}

// MARK: - Block-level markdown

/// One parsed block of an answer. We intentionally support only the block kinds
/// an in-notch assistant actually produces — headings, lists, fenced code blocks,
/// and horizontal rules — plus plain paragraphs. Everything else (quotes, tables)
/// falls through to a paragraph, so unknown syntax still reads cleanly rather
/// than breaking. Inline `**bold**` / `*italic*` / `code` is handled per-line by
/// `InlineMarkdownText`; code blocks render verbatim without inline parsing.
enum MarkdownBlock {
    case heading(level: Int, text: String)
    case bullet(text: String)
    case ordered(number: Int, text: String)
    case paragraph(text: String)
    case code(language: String?, text: String)
    case divider
}

/// A line-based markdown parser. Deliberately tiny: it walks the answer line by
/// line and classifies each non-empty line as a heading (`#`…`######`), an
/// unordered item (`-`, `*`, `+`), an ordered item (`1.`, `2)`), a horizontal
/// rule (`---` / `***` / `___`), or a paragraph. Fenced code blocks (``` `…` ```)
/// span multiple lines and capture their content verbatim — including blank
/// lines — until the closing fence. No nesting beyond that, in keeping with the
/// app's minimalism (no markdown library).
enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = source.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let rawLine = lines[i]
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Fenced code block — capture everything (including blank lines)
            // until the matching closing fence. The opening fence may carry a
            // language hint (e.g. ```swift); we keep it but don't syntax-color.
            if let lang = codeFence(line) {
                var body: [String] = []
                i += 1
                while i < lines.count {
                    let inner = lines[i]
                    if codeFence(inner.trimmingCharacters(in: .whitespaces)) != nil { break }
                    body.append(inner)
                    i += 1
                }
                blocks.append(.code(language: lang.isEmpty ? nil : lang, text: body.joined(separator: "\n")))
                i += 1
                continue
            }

            if line.isEmpty {
                i += 1
                continue
            }

            if isDivider(line) {
                blocks.append(.divider)
            } else if let (level, text) = heading(line) {
                blocks.append(.heading(level: level, text: text))
            } else if let text = bullet(line) {
                blocks.append(.bullet(text: text))
            } else if let (number, text) = ordered(line) {
                blocks.append(.ordered(number: number, text: text))
            } else {
                blocks.append(.paragraph(text: line))
            }
            i += 1
        }
        return blocks
    }

    /// `` ``` `` or `` ```swift `` → optional language tag (empty string if bare).
    /// Returns `nil` for any line that isn't a fence opener/closer, so the caller
    /// can use it for both opening and closing detection.
    private static func codeFence(_ line: String) -> String? {
        guard line.hasPrefix("```") else { return nil }
        let after = line.dropFirst(3)
        // Disallow extra backticks on the same line — that's an inline `code`
        // span gone weird, not a fence.
        if after.contains("`") { return nil }
        return String(after).trimmingCharacters(in: .whitespaces)
    }

    /// `---` / `***` / `___` (3+ of the same char, optional internal spaces).
    /// Conservative: requires the line to be made up of only that marker (after
    /// stripping spaces) so a real `***bold***` paragraph isn't swallowed.
    private static func isDivider(_ line: String) -> Bool {
        let stripped = line.filter { $0 != " " }
        guard stripped.count >= 3, let first = stripped.first else { return false }
        guard first == "-" || first == "*" || first == "_" else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    /// `# Title` … `###### Title` → (level, text). Requires a space after the
    /// hashes so a bare `#tag` stays a paragraph.
    private static func heading(_ line: String) -> (Int, String)? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }
        let text = String(line[idx...]).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (level, text)
    }

    /// `- item` / `* item` / `+ item` → text. The marker must be followed by a
    /// space, so a stray `*emphasis*` at line start isn't mistaken for a bullet.
    private static func bullet(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// `1. item` / `2) item` → (number, text).
    private static func ordered(_ line: String) -> (Int, String)? {
        var digits = ""
        var idx = line.startIndex
        while idx < line.endIndex, line[idx].isNumber {
            digits.append(line[idx])
            idx = line.index(after: idx)
        }
        guard !digits.isEmpty, let number = Int(digits), idx < line.endIndex else { return nil }
        let sep = line[idx]
        guard sep == "." || sep == ")" else { return nil }
        let afterSep = line.index(after: idx)
        guard afterSep < line.endIndex, line[afterSep] == " " else { return nil }
        let text = String(line[afterSep...]).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (number, text)
    }
}

/// Renders a parsed answer as stacked block-level markdown — headings and lists
/// laid out vertically, each line's inline markdown handled by
/// `InlineMarkdownText`. Caller controls the base font/colour; this only adds the
/// per-block structure (sizing for headings, the bullet/number gutter for lists).
struct MarkdownBlocks: View {
    let source: String
    var baseFont: CGFloat = 15
    var color: Color = Tokens.text1
    /// Called when a code block's copy button writes its text to the pasteboard,
    /// so the owner (NotchBody) can re-baseline the clipboard and stop that in-app
    /// copy from poisoning the next Ask's clipboard-context injection. `nil` in the
    /// (non-result) contexts that don't care.
    var onInAppCopy: (() -> Void)? = nil

    private var blocks: [MarkdownBlock] { MarkdownParser.parse(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                // Per-block styling lives in `MarkdownBlockRow`, shared with the
                // streaming renderer (`StreamingMarkdown`) so a settled answer and a
                // live one are laid out identically — they differ only in the tail
                // fade/selection wrapping, never in how a block kind looks.
                MarkdownBlockRow(block: block, baseFont: baseFont, color: color, onInAppCopy: onInAppCopy)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The streaming face of `MarkdownBlocks`: same layout, but the live tail
/// **fades in** as chunks land instead of snapping. The result is the "逐字出现"
/// typewriter feel the answer is supposed to have — text appears to dissolve into
/// place rather than blink on in jumps.
///
/// Why only the tail: re-parsing the whole `source` every chunk and re-fading all
/// of it would make the entire (already-read) answer flicker on each token. So we
/// split the parsed blocks into the *settled head* (every block but the last) and
/// the *growing tail* (the final block). The head renders through the plain
/// `MarkdownBlocks` with no animation; the tail is keyed on its own text so that
/// each time it grows, SwiftUI re-runs an 80ms opacity ramp from `tailFloor` → 1
/// over just that block — the freshly-arrived words shimmer in, the rest holds.
///
/// Settles to nothing once streaming ends: the caller swaps back to a plain
/// `MarkdownBlocks` for the finished, fully-selectable answer (see `turnView`),
/// so none of this fade machinery touches a settled turn.
struct StreamingMarkdown: View {
    let source: String
    var baseFont: CGFloat = 15
    var color: Color = Tokens.text1
    var onInAppCopy: (() -> Void)? = nil

    private var blocks: [MarkdownBlock] { MarkdownParser.parse(source) }

    var body: some View {
        let parsed = blocks
        // The tail is the block currently growing; the head is everything already
        // settled above it. An empty source yields no blocks — the caller shows
        // ThinkingDots in that case, so we just render nothing here.
        let headCount = max(0, parsed.count - 1)
        return VStack(alignment: .leading, spacing: 8) {
            if headCount > 0 {
                // Settled blocks: render verbatim through the plain renderer so they
                // never re-fade as later chunks arrive. Rebuilt from the same
                // `source` prefix; cheap, and keeps inline/code handling identical.
                ForEach(Array(parsed.prefix(headCount).enumerated()), id: \.offset) { _, block in
                    MarkdownBlockRow(block: block, baseFont: baseFont, color: color, onInAppCopy: onInAppCopy)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let tail = parsed.last {
                MarkdownBlockRow(block: tail, baseFont: baseFont, color: color, onInAppCopy: onInAppCopy)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(TailFadeIn(token: tailToken(for: tail)))
            }
        }
    }

    /// A change-key for the tail's fade: re-ramps opacity whenever the tail's text
    /// grows. We key on the rendered character count (per block kind) rather than
    /// the whole `source` so head edits never re-trigger the tail's fade.
    private func tailToken(for block: MarkdownBlock) -> Int {
        switch block {
        case .heading(_, let t), .bullet(let t), .ordered(_, let t), .paragraph(let t):
            return t.count
        case .code(_, let t):
            return t.count
        case .divider:
            return -1
        }
    }
}

/// Drives the per-chunk fade: each time `token` changes (the tail grew), opacity
/// drops to `floor` for one frame and eases back to 1 over 80ms, so the newly
/// landed text dissolves in. `.animation(value:)` makes the ramp fire on the
/// change without a manual `withAnimation`, and the explicit `.opacity` keeps the
/// floor from compounding across rapid chunks.
private struct TailFadeIn: ViewModifier {
    let token: Int
    @State private var lit = false

    private static let floor: Double = 0.55

    func body(content: Content) -> some View {
        content
            .opacity(lit ? 1 : Self.floor)
            .animation(.easeOut(duration: 0.08), value: lit)
            // Flip to lit on the next runloop turn so the floor→1 ramp actually
            // animates; re-arm to dim on each new token so the next chunk fades too.
            .onChange(of: token) { _, _ in
                lit = false
                DispatchQueue.main.async { lit = true }
            }
            .onAppear { lit = true }
    }
}

/// One block of an answer, extracted from `MarkdownBlocks.row(for:)` so both the
/// settled renderer and the streaming renderer share identical block styling. The
/// two callers differ only in animation/selection wrapping, never in how a given
/// block kind looks.
struct MarkdownBlockRow: View {
    let block: MarkdownBlock
    var baseFont: CGFloat = 15
    var color: Color = Tokens.text1
    var onInAppCopy: (() -> Void)? = nil

    var body: some View {
        switch block {
        case .heading(let level, let text):
            let size = max(baseFont, baseFont + CGFloat(7 - min(level, 5)) * 1.5)
            InlineMarkdownText(text)
                .font(.sf(size, weight: .semibold))
                .tracking(-0.1)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .bullet(let text):
            listRow(marker: "•", text: text)

        case .ordered(let number, let text):
            listRow(marker: "\(number).", text: text)

        case .paragraph(let text):
            InlineMarkdownText(text)
                .font(.sf(baseFont))
                .tracking(-0.05)
                .lineSpacing(baseFont * 0.6)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .code(_, let text):
            CodeBlockView(text: text, baseFont: baseFont, color: color, onInAppCopy: onInAppCopy)

        case .divider:
            Rectangle()
                .fill(Tokens.hairline)
                .frame(height: 0.5)
                .padding(.vertical, 4)
        }
    }

    /// A list item: a fixed-width gutter holds the marker so wrapped lines hang
    /// neatly under the text, not under the bullet.
    private func listRow(marker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker)
                .font(.sf(baseFont, weight: .medium).monospacedDigit())
                .foregroundStyle(color.opacity(0.7))
                .frame(minWidth: 16, alignment: .trailing)
            InlineMarkdownText(text)
                .font(.sf(baseFont))
                .tracking(-0.05)
                .lineSpacing(baseFont * 0.5)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A code island with its own ghost one-tap copy button. Split out of
/// `MarkdownBlocks.row(for:)` so it can hold the `hovering`/`copied` `@State` the
/// button needs. The button is a tap target overlaid on the island — independent of
/// scroll position and text-selection hit-testing — so it works identically while
/// the answer streams (once the closing fence parses this block into the tree) and
/// after it settles, where multi-line drag-select on the narrow panel is unreliable.
private struct CodeBlockView: View {
    let text: String
    let baseFont: CGFloat
    let color: Color
    /// Fired after the in-app pasteboard write so the owner can re-baseline the
    /// clipboard and keep this copy from being re-injected into the next Ask.
    let onInAppCopy: (() -> Void)?

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        // NOTE: the parent `MarkdownBlocks` container in NotchBody wraps the whole
        // answer in `.textSelection(.disabled)` WHILE STREAMING (so tail-follow
        // scroll can't collapse a drag) and `.enabled` once settled — so the inner
        // `.textSelection(.enabled)` here is only effective post-stream. The copy
        // button below works in BOTH states; don't remove the parent wrapper without
        // auditing this.
        Text(text)
            .font(.system(size: baseFont - 1, weight: .regular, design: .monospaced))
            .foregroundStyle(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Tokens.hairline, lineWidth: 0.5)
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    onInAppCopy?()
                    withAnimation(.easeOut(duration: 0.15)) { copied = true }
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        withAnimation(.easeOut(duration: 0.25)) { copied = false }
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(copied ? Tokens.text2 : Tokens.text3)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(5)
                // Ghost by default; brightens on hover; full while showing the check.
                .opacity(copied ? 1.0 : hovering ? 0.7 : 0.3)
                .animation(.easeOut(duration: 0.18), value: hovering)
                .animation(.easeOut(duration: 0.15), value: copied)
            }
            .onHover { hovering = $0 }
    }
}

/// The floating source popup's request, published up the view tree by the hovered
/// badge: where it is (`anchor`, the pill's frame) and what to show (`sources`).
/// `nil` when no badge is hovered. An ancestor *outside* the conversation
/// ScrollView reads this and draws the panel, so the popup escapes the scroll's
/// clip that was chopping it off (XII-118).
struct SourcePopoverRequest: Equatable {
    let id: UUID
    let anchor: Anchor<CGRect>
    let sources: [WebSource]
    static func == (a: SourcePopoverRequest, b: SourcePopoverRequest) -> Bool { a.id == b.id }
}

struct SourcePopoverKey: PreferenceKey {
    static let defaultValue: SourcePopoverRequest? = nil
    static func reduce(value: inout SourcePopoverRequest?, nextValue: () -> SourcePopoverRequest?) {
        // Last writer wins — at most one badge is hovered at a time.
        if let next = nextValue() { value = next }
    }
}

/// A source badge shown under a search-grounded answer (XII-118). Rests as a
/// compact pill — just the first source's site name plus "+N" for the rest, e.g.
/// "tmtpost + 3", no icons. **Hover** the pill and a floating panel pops up over
/// the content listing every source as "site · title (date)"; click a row to open
/// the original page. The panel is rendered by an ancestor (see
/// `conversationOverlay`) so it floats above the answer and is never clipped by
/// the scroll view.
///
/// `hoveredID` is the shared "which badge is open" state owned by `NotchBody`: the
/// badge sets it to its own `id` on hover and clears it on exit; the floating
/// panel keeps it set while the cursor is over the panel, so moving up onto a row
/// doesn't dismiss it. The pill only *publishes its anchor* when it's the open one.
struct SourceBadge: View {
    let sources: [WebSource]
    @Binding var hoveredID: UUID?
    /// Shared deferred-close handle (owned by `NotchBody`): when the cursor leaves
    /// the pill we don't close immediately — we schedule a close ~140ms out, and
    /// the floating panel cancels it the moment the cursor lands on it. Without
    /// this, the 6pt gap between pill and panel is a dead zone that snaps the popup
    /// shut before the cursor can cross it.
    @Binding var pendingClose: DispatchWorkItem?

    private let id = UUID()
    private var isOpen: Bool { hoveredID == id }

    var body: some View {
        Text(pillLabel)
            .font(.sf(11, weight: .medium))
            .tracking(0.1)
            .foregroundStyle(Tokens.text3)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Color.white.opacity(isOpen ? 0.10 : 0.06))
            )
            .overlay(Capsule().stroke(Tokens.hairline, lineWidth: 0.5))
            .contentShape(Capsule())
            // Publish this pill's frame + sources up to the ancestor overlay, but
            // only while it's the open one — so the ancestor knows where to float
            // the panel. A hidden tracking value when closed keeps the key present.
            .anchorPreference(key: SourcePopoverKey.self, value: .bounds) { anchor in
                isOpen ? SourcePopoverRequest(id: id, anchor: anchor, sources: sources) : nil
            }
            .onHover { hovering in
                if hovering {
                    pendingClose?.cancel()      // re-entered the pill — cancel any close
                    pendingClose = nil
                    hoveredID = id
                } else if isOpen {
                    scheduleClose()             // grace period to reach the panel
                }
            }
            .help(L("source.badge.help"))
    }

    /// Close after a short grace period, unless something (the panel's hover, or
    /// re-entering the pill) cancels it first.
    private func scheduleClose() {
        pendingClose?.cancel()
        let work = DispatchWorkItem {
            if hoveredID == id { hoveredID = nil }
        }
        pendingClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
    }

    /// "tmtpost + 3" — the first source's short site name, plus a count of the
    /// rest. A single source just shows its site, no "+".
    private var pillLabel: String {
        let lead = sources.first?.site ?? L("source.badge.fallback")
        let extra = sources.count - 1
        return extra > 0 ? "\(lead) + \(extra)" : lead
    }
}

/// The floating source list — a self-contained dark card with a hairline border
/// and soft shadow so it reads as a layer above the answer, not part of it.
/// Rendered by an ancestor overlay (escaping the scroll clip) and positioned over
/// the badge by the caller. `keepOpen`/`dismiss` let it hold the badge open while
/// the cursor is over its rows.
struct SourcePopoverPanel: View {
    let sources: [WebSource]
    let keepOpen: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(sources) { source in
                SourceRow(source: source)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        // A fixed width gives the rows a definite bound to truncate long titles
        // against (instead of stretching the popup to the longest line).
        .frame(width: 320, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.black.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Tokens.hairline, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
        // Hovering the panel keeps the badge open; leaving it dismisses — so the
        // round-trip pill → row works, and moving away closes.
        .onHover { $0 ? keepOpen() : dismiss() }
    }
}

/// One expanded source row: "site · title", with the date trailing if known.
/// Clicking opens the URL. Hover lifts it slightly so it reads as actionable.
private struct SourceRow: View {
    let source: WebSource
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = URL(string: source.url) { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(source.site)
                    .font(.sf(11, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
                    .lineLimit(1)
                    .fixedSize()
                Text(source.title)
                    .font(.sf(11))
                    .foregroundStyle(hovering ? Tokens.text2 : Tokens.text4)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let date = source.date {
                    Text(date)
                        .font(.sf(10))
                        .foregroundStyle(Tokens.text4)
                        .fixedSize()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
