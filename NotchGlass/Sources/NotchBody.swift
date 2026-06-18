import SwiftUI

/// The content that lives inside the glass, below the constant black notch zone.
/// Switches between idle / load / result exactly like the prototype's modes.
struct NotchBody: View {
    @ObservedObject var model: NotchModel
    /// Self-update state — read here only to badge the settings gear with a dot
    /// when a newer release is available (the action itself lives in settings).
    @ObservedObject private var updater = UpdaterService.shared
    /// Release-notes state — read here to surface the "what's new" cue in the idle
    /// input row once, on the first launch after an update (see `unseenVersion`).
    @ObservedObject private var whatsNew = WhatsNewService.shared
    /// Drives the custom field's first-responder. Set shortly after the panel
    /// opens so the caret lands without a click (the AppDelegate has just made
    /// the panel key; a tiny delay lets that settle first).
    @State private var focused = false
    /// Natural (intrinsic) height of the answer text, reported by a preference
    /// reader. Drives the scroll area's height so short answers stay short.
    @State private var measuredAnswerHeight: CGFloat = 120
    /// Phase (0→1) of the light that sweeps *across the confirmation text* after a
    /// copy. The follow-up field's placeholder momentarily becomes "Copied to
    /// clipboard", and a soft highlight glides over those glyphs once — the shimmer
    /// decorates the words rather than scanning a band across the whole box. Animated
    /// 0→1 to run a single pass.
    @State private var handoffSweep = false
    /// Whether the copy confirmation is currently showing. While true, the input's
    /// placeholder reads "Copied to clipboard" (shimmered) instead of "Ask a
    /// follow-up…", and the trailing icon shows a check. Flips back after ~2s.
    @State private var handoffCopied = false
    /// Whether the cursor is over the "continue elsewhere" copy button. While true
    /// (and the field is empty), the placeholder swaps to a one-line hint describing
    /// what that button does — an in-field stand-in for a hover tooltip.
    @State private var hoveringContinue = false
    /// Width (pt) of everything the prompt field is currently showing — committed
    /// text plus any in-progress IME composition (pinyin) — reported live by the
    /// field via `onCaretWidth`. Drives where the inline "— Ask"/"— Note" hint sits,
    /// so it trails the pinyin as you type rather than anchoring to the committed
    /// text (which lags a whole composition behind).
    @State private var caretWidth: CGFloat = 0
    /// Same live display width, but for the follow-up field. Its placeholder is a
    /// SwiftUI overlay (so the copy can cross-fade — see `followUpPlaceholderLabel`),
    /// and this is how the overlay knows to vanish the moment the editor shows
    /// anything — including pinyin that hasn't committed to `model.text` yet, which
    /// is exactly when the native placeholder would disappear.
    @State private var followUpCaretWidth: CGFloat = 0
    /// Drives the compact history filter field's first-responder. Set when the
    /// filter icon is tapped so the caret lands in the expanded field without a
    /// second click; reset when the filter collapses so it can re-arm next time.
    @State private var filterFocused = false
    /// Whether the immersive recent list is resting at its top. Drives the floating
    /// header's "manage" controls: RECENT + gear + Clear show while the list is at
    /// the top, then fade out the moment it scrolls, so rows sliding up behind the
    /// input meet only the prompt — no control row to collide with. Flipped by a 1pt
    /// sentinel at the top of the scroll content (see `setHistoryAtTop`).
    @State private var historyAtTop = true

    /// Measured height of the immersive floating header (input, plus the quote
    /// preview and action chips when a clipboard quote is pending). The list's top
    /// runway and frost band are derived from this so the first row always rests
    /// clear of the header no matter how tall it gets — a plain input is short, a
    /// quote-with-chips header is tall. Seeded to the plain-input baseline so the
    /// first frame (before the preference lands) already clears a no-quote header.
    @State private var measuredImmersiveHeaderHeight: CGFloat = NotchBody.immersiveHeaderBaseline

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.mode {
            case .result:
                resultView
            case .load:
                // A follow-up already has the thread on screen — keep showing the
                // conversation (its last bubble renders the thinking dots) so the
                // prior turns don't vanish while the answer is in flight. Only the
                // very first question, with nothing on screen yet, gets the bare
                // centered load view.
                if model.turns.isEmpty {
                    loadView
                } else {
                    resultView
                }
            case .idle:
                idleView
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 15)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: model.open) { _, isOpen in
            if isOpen {
                refocusInput()
            } else {
                focused = false
            }
        }
        // Returning to the idle prompt (← / back button / Enter-submit-then-finish)
        // tears down the result/follow-up field and builds a fresh idle PromptField,
        // which has never held focus — so its ↓/↑ history-nav keys went dead. Re-arm
        // the focus latch on every switch *into* idle while open, so the caret (and
        // the keyboard history nav that rides on it) always lands back in the prompt.
        .onChange(of: model.mode) { _, newMode in
            if model.open, newMode == .idle {
                refocusInput()
            }
        }
        // Collapsing the recent list returns the caret to the prompt. Without this, a
        // user who clicked into the new HistorySearchField (taking first-responder off
        // the prompt) and then pressed Esc to fold the list would be left in focus
        // limbo on the now-removed filter field — unable to type until they click.
        .onChange(of: model.showHistory) { _, isShowing in
            if model.open, !isShowing, model.mode == .idle {
                refocusInput()
            }
        }
        .onAppear {
            if model.open {
                refocusInput()
            }
        }
    }

    /// Re-arm the PromptField's first-responder latch. `focusTrigger` only fires on
    /// a false→true edge, so when `focused` is already true (e.g. coming back to
    /// idle without the panel ever closing) we must drop it first, then raise it
    /// next runloop — otherwise there's no edge and the new field never grabs focus.
    /// The small delay also lets SwiftUI finish swapping the field in.
    private func refocusInput() {
        focused = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { focused = true }
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Settings owns the whole body when open — the "Ask anything" prompt is
            // hidden, since you're configuring the app, not asking a question. Its
            // own "‹ SETTINGS" header carries the way back (gear / Esc / chevron).
            if model.showSettings {
                InlineSettingsView(model: model)
                    .transition(moduleTransition)
            } else if model.showWhatsNew {
                // What's New owns the whole body, like settings — the idle prompt is
                // hidden while the user reads the release notes. Its own back chevron
                // (and Esc) carries the way home.
                WhatsNewView(model: model)
                    .transition(moduleTransition)
            } else if useImmersiveHistory {
                // Immersive recent list: the input floats as a translucent header
                // over a tall scroll surface that reaches UP behind it. Rows scroll
                // under the input and frost + fade out — present but pushed back —
                // so the panel reads as one continuous surface, not a stack of
                // blocks. Only taken once the list overflows (`useImmersiveHistory`);
                // a short list keeps the calm compact layout below.
                immersiveHistoryView
            } else {
                if let clip = model.pendingClipboard {
                    clipboardPreviewLine(clip)
                        .transition(moduleTransition)
                }

                idleInputRow

                // The one-tap action chips for the pending clipboard sit *below* the
                // prompt — the field stays the focus, with the shortcuts as a quiet
                // row beneath it. Suppressed while the recent list is open: the list
                // takes that same space below the prompt, and showing both stacks the
                // chips on top of the RECENT rows (a visible collision). Recent wins —
                // it's what the user just summoned — so the shortcuts fold away until
                // the list is closed again. Also suppressed while a note-save cue is up
                // ("Saving…" / "Added to Notes" / error): the save just consumed the
                // clipboard, so the action row is stale — fold it away and let the calm
                // confirmation stand alone rather than crowding it with shortcuts.
                if model.pendingClipboard != nil && !model.showHistory && noteFeedbackContent == nil {
                    clipboardPresetChips()
                        .transition(moduleTransition)
                }

                // The recent list expands below the prompt once the clock is tapped.
                // (The immersive variant above handles the overflowing case.)
                if !model.hasText && !model.history.isEmpty && model.showHistory {
                    historySection
                        .transition(moduleTransition)
                }

                // The note-save feedback line (Saving… / Added to Notes / error).
                // Only present when there's something to say — when there's nothing it
                // takes ZERO height, so the resting prompt is just the 48pt input. A
                // line classified as a note routes to Apple Notes without changing the
                // surface, and this quiet cue is the only sign it landed there.
                if let feedback = noteFeedbackContent {
                    feedback
                        .padding(.top, 8)
                        .transition(moduleTransition)
                }
            }
        }
        // The note-save feedback unfurls/fades on the panel's standard module spring,
        // matching the recent list right above it.
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.noteSaving)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.lastSavedNote)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.noteError)
    }

    /// The idle prompt field, with the live note-error reset wired in. Shared by
    /// the flat idle layout and the immersive history header so the field — and
    /// all its focus/IME plumbing — exists exactly once, never duplicated.
    private var idleInputRow: some View {
        inputRow(placeholder: L("input.placeholder"), followUp: false)
            .onChange(of: model.text) { _, _ in
                // Editing the field clears a stale note-save error so the cue
                // doesn't linger over a line the user is actively rewriting.
                if model.noteError != nil { model.noteError = nil }
            }
    }

    /// Take the immersive (input-floats-over-scroll) layout only when the recent
    /// list is both open and long enough to scroll. A short list that fits has
    /// nothing to flow under the input, so it keeps the calm compact layout —
    /// matching the same `> 6` overflow calibration the list itself uses.
    ///
    /// A pending clipboard quote no longer forces the compact fallback: the quote
    /// preview and its action chips ride inside the immersive floating header (above
    /// and below the input), and the runway grows to clear that taller header — so the
    /// frosted immersive surface stays consistent whether or not a quote is present.
    private var useImmersiveHistory: Bool {
        !model.hasText
            && model.showHistory
            && noteFeedbackContent == nil
            && model.recentVisible.count > 6
    }

    // MARK: - Immersive history

    /// The immersive recent layout: a tall scroll surface with the prompt floating
    /// over its top as a translucent header. The list's content reaches up behind
    /// the header (`immersiveTopReach`), so rows scroll under the input and frost +
    /// fade out rather than ending on a hard cut — the panel reads as one
    /// continuous surface. The header (input + RECENT controls) draws ON TOP of the
    /// scroll via z-order, but a soft scrim under it (not an opaque fill) keeps the
    /// prompt legible while the rows behind stay perceivable.
    private var immersiveHistoryView: some View {
        ZStack(alignment: .top) {
            // Back: the tall list, its top runway tucked behind the header.
            historyList(immersive: true)
        }
        .overlay(alignment: .top) {

            // Front: the floating header — NO background of its own. The glass shell
            // must read identically whether the panel is collapsed or expanded, so the
            // prompt sits directly on the same translucent material as the resting
            // state; a dark scrim here repainted the top into an opaque black slab and
            // broke that. Legibility of the rows passing behind comes entirely from the
            // list's own top fade + blur (see `historyList(immersive:)`), and the
            // manage controls (RECENT + gear + Clear) simply lift away once the list
            // scrolls, so nothing they could collide with stays on screen.
            VStack(alignment: .leading, spacing: 0) {
                // A pending clipboard quote rides INSIDE the floating header: the
                // preview line above the prompt (the context the query folds in) and
                // the one-tap action chips below it. Unlike the RECENT controls these
                // stay put while scrolling — they belong to the input, not to list
                // management — and the runway (`immersiveTopReach`, measured from this
                // header's real height) grows to keep the first row clear of them.
                if let clip = model.pendingClipboard {
                    clipboardPreviewLine(clip)
                }
                idleInputRow
                // No preset chips here: this header IS the expanded Recent state, and
                // the list owns the space directly below the prompt. The flat layout
                // suppresses the chips whenever `showHistory` is open for exactly this
                // reason (a visible collision with the RECENT rows); the immersive
                // variant is that same open list, just tall enough to scroll — so the
                // chips fold away here too, matching the flat path. The clipboard
                // quote preview above still rides along (it's context for the query,
                // not a shortcut menu), only the action chips drop.
                if !historyScrolled {
                    recentHeaderRow
                        .padding(.top, 6)
                        // Fade + slide up as it leaves, so dismissing the controls
                        // reads as them lifting away behind the prompt.
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(.bottom, 6)
            // Measure the header's real height so the runway/frost band below track it
            // (a quote+chips header is much taller than a bare input). Mirror the
            // `AnswerHeightKey` pattern: report via preference, store in @State.
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ImmersiveHeaderHeightKey.self, value: geo.size.height
                    )
                }
            )
        }
        .onPreferenceChange(ImmersiveHeaderHeightKey.self) { h in
            // Animate the runway shift so a quote appearing/clearing slides the list
            // rather than snapping it.
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                measuredImmersiveHeaderHeight = max(h, NotchBody.immersiveHeaderBaseline)
            }
        }
        .transition(moduleTransition)
    }

    /// True once the immersive list has scrolled away from its top.
    private var historyScrolled: Bool { !historyAtTop }

    /// Flip the at-top flag on the standard module spring so the manage controls
    /// fade/collapse rather than snap. Driven by the top sentinel's appear/disappear.
    private func setHistoryAtTop(_ atTop: Bool) {
        guard historyAtTop != atTop else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            historyAtTop = atTop
        }
    }

    // MARK: - Note save feedback

    /// The line under the input after a note save — `nil` when there's nothing to
    /// report, so the row simply doesn't exist (zero height) and the resting prompt
    /// is just the input.
    ///
    /// Deliberately quiet: no icons, no colour, no echo of what was typed — just one
    /// small line in the same `text4` grey as RECENT and the timestamps, so a save
    /// confirms without ever shouting. The success path settles to "Added to Notes";
    /// "Saving…" reads the same grey while the write is in flight. The error path is
    /// the one exception — it's actionable (usually "grant permission"), so it gets
    /// a touch more presence (text2, still no loud icon/colour) to make sure it's
    /// seen, since silently failing to save would be worse than a quiet cue.
    private var noteFeedbackContent: AnyView? {
        if let err = model.noteError {
            return AnyView(
                Text(err)
                    .font(.sf(12))
                    .foregroundStyle(Tokens.text2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            )
        }
        // Both save paths now store their full display string (e.g.
        // "Added to Reminders · Daily" / "Added to Notes") in lastSavedNote,
        // so the cue text is whatever the model put there — no binary rebuild here.
        if let cue = model.lastSavedNote {
            return AnyView(feedbackLine(cue))
        }
        if model.noteSaving {
            return AnyView(feedbackLine(L("input.saving")))
        }
        return nil
    }

    /// One line of the calm note-save feedback: small, `text4` grey, no icon —
    /// the same whisper as the RECENT label.
    private func feedbackLine(_ text: String) -> some View {
        Text(text)
            .font(.sf(12))
            .tracking(0.2)
            .foregroundStyle(Tokens.text4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The copied-clip preview shown above the prompt when there's eligible
    /// clipboard content — context for the input below, so the user can see what a
    /// referential query ("summarize this") will fold in. Rendered as a *quote*: a
    /// thin vertical accent bar leads the copied text, so it reads as the lifted,
    /// referenced material rather than a status line. The one-tap action chips that
    /// act on this clip live *below* the input, in `clipboardPresetChips`.
    private func clipboardPreviewLine(_ clip: String) -> some View {
        let preview = clip.count > 40 ? String(clip.prefix(40)) + "…" : clip
        return HStack(spacing: 8) {
            // The quote's accent bar: a thin rounded rule that runs the height of the
            // copied line, the visual cue that what follows is quoted material.
            Capsule()
                .fill(Tokens.text4)
                .frame(width: 2)
            Text(preview)
                .font(.sf(11))
                .tracking(0.2)
                .foregroundStyle(Tokens.text3)
                .lineLimit(1)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 8)
    }

    /// A *short* row of one-tap preset actions for the pending clipboard, sitting just
    /// beneath the prompt. Deliberately auxiliary — the prompt above is the focus — so
    /// by default only the few most-common actions (Summarize / Proofread / Translate)
    /// show, with a small "⋯" chip to reveal the rest (Key Points / Rewrite / tone) on
    /// demand. Tapping an action chip authors a referential query into the prompt and
    /// submits it, so the existing clipboard-injection path in `submit()` folds the
    /// copied text in — the chip is just a shortcut for typing "summarize this". The
    /// label/phrase script follows the copied text (CJK chips for CJK clips), so a
    /// Chinese clipboard offers 总结 / 校对 / 翻译 etc.
    private func clipboardPresetChips() -> some View {
        FlowLayout(hSpacing: 6, vSpacing: 6) {
            // When the copied text itself reads as a note/reminder, lead with a one-tap
            // capture chip — filing the jot is the more likely intent than asking the AI
            // about it, so it sits ahead of the Ask presets. The verdict lands
            // asynchronously (~15ms after the row is up); the chip fades+scales in (and
            // the presets glide right) via the `.animation(value:)` on the row below.
            if let capture = model.pendingClipboardCapture {
                ClipboardPresetChip(title: captureChipTitle(capture),
                                    tint: captureChipTint(capture),
                                    keyHint: true) {
                    model.runClipboardCapture(capture)
                }
                .transition(.scale(scale: 0.7, anchor: .leading).combined(with: .opacity))
            }
            ForEach(model.visibleClipboardPresets) { preset in
                ClipboardPresetChip(title: preset.label) {
                    model.runClipboardPreset(preset)
                }
                // The overflow chips (everything past the primary set) unfurl from the
                // leading edge — scaling up and fading in as they push out to the right
                // on hover, and collapsing back the same way. The primary chip is always
                // present, so it carries no transition (identity stays put). Asymmetric
                // so the fold-back reads as a tuck-in rather than a mirror of the reveal.
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.55, anchor: .leading)
                            .combined(with: .opacity),
                        removal: .scale(scale: 0.7, anchor: .leading)
                            .combined(with: .opacity)
                    )
                )
                .zIndex(NotchModel.ClipboardPreset.primary.contains(preset) ? 1 : 0)
            }
            // The "⋯" affordance: only shown when there's actually more to reveal
            // than the primary set. Unlike a button, it expands on *hover* — the
            // whole row's `onHover` below drives `clipboardPresetsExpanded`, so the
            // extra chips unfurl in place when the pointer is over the row and fold
            // back when it leaves. Collapsed, it's just a quiet "⋯" hint; expanded,
            // the trailing chips have replaced it, so it disappears on its own. It
            // fades rather than snaps as the overflow chips take its place.
            if !model.clipboardPresetsExpanded
                && model.clipboardPresets.count > NotchModel.ClipboardPreset.primary.count {
                ClipboardPresetChip(title: "⋯") {
                    // Tap still works as a fallback for non-hover input.
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        model.clipboardPresetsExpanded = true
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
        // Hover anywhere over the chip row to unfurl the overflow actions in place;
        // leaving the row folds them back to the single primary chip. Driving the
        // expansion off the *row's* hover (not the tiny "⋯" chip's) means the pointer
        // can travel onto the newly-revealed chips without collapsing them.
        .onHover { hovering in
            guard model.clipboardPresets.count > NotchModel.ClipboardPreset.primary.count else { return }
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                model.clipboardPresetsExpanded = hovering
            }
        }
        // Drive the row's reflow as chips appear/disappear: the capture chip landing,
        // AND the overflow set unfurling on hover. Both change `visibleClipboardPresets`,
        // so keying the animation on its count (plus the capture chip) ties the
        // FlowLayout's re-place — which has no Animatable inputs of its own — to the same
        // spring that carries the per-chip insert/remove transitions, so the existing
        // chips glide to their new x-positions while the new ones scale in beside them.
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.visibleClipboardPresets.count)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: model.pendingClipboardCapture)
    }

    /// Label for the leading clipboard-capture chip, in the copied text's script and
    /// naming where the tap files it: Apple Notes vs. Apple Reminders. Mirrors the
    /// inline send hint's wording so the chip reads as the same destination.
    private func captureChipTitle(_ panel: NotchModel.Panel) -> String {
        switch panel {
        case .reminder: return L("capture.remind")
        case .note, .chat: return L("capture.note")
        }
    }

    /// The faint background hue for the capture chip — keyed to its destination's app
    /// colour so the chip reads as "this goes to Reminders/Notes": Reminders' orange,
    /// Notes' amber-yellow. Washed in at low opacity by `glassCapsule`, so it stays a
    /// whisper of colour over the same glass material, not a solid fill.
    private func captureChipTint(_ panel: NotchModel.Panel) -> Color {
        switch panel {
        case .reminder: return .orange
        case .note, .chat: return .yellow
        }
    }

    /// Shared open/close feel for the modules that unfurl below the prompt
    /// (recent list, inline settings): the whole block grows in from the top and
    /// fades, rather than popping in instantly.
    private var moduleTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .top)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.97, anchor: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
        )
    }

    /// The gear entry that swaps the recent list for the inline settings panel
    /// (same view ⌘, opens). Rendered as a Liquid Glass chip so it reads as part
    /// of the glass island. Only shown alongside the expanded history (the settings
    /// affordance lives in the same "manage" row as Clear).
    private var settingsEntry: some View {
        GlassIconButton(systemName: "gearshape", help: L("recent.settings"), size: 26) {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                model.toggleSettings()
            }
        }
        // The whole passive update cue: a 5pt neutral dot on the gear when a
        // newer release is known. Clicking through to settings shows the update
        // action — the dot itself never interrupts anything, and never shouts in
        // colour.
        .overlay(alignment: .topTrailing) {
            if case .available = updater.phase {
                Circle()
                    .fill(Tokens.text2)
                    .frame(width: 5, height: 5)
                    .offset(x: -1, y: 1)
            }
        }
    }

    /// The manage controls (gear, Clear) for the recent list. Shared by the
    /// compact `historySection` header and the immersive floating header, so the
    /// row reads the same in both layouts. Both controls only exist while the
    /// recent list is expanded, so the idle panel stays minimal. No "RECENT"
    /// label — the list speaks for itself, so the heading would just be noise.
    private var recentHeaderRow: some View {
        HStack(spacing: 6) {
            Spacer()
            // The filter has no chip of its own — it's summoned with ⌘F (handled in
            // ContentView's key catcher) and unfurls the field below the header.
            settingsEntry
            // Clear is destructive, so it arms a confirmation rather than wiping
            // history on first tap. The card itself is rendered centered over the
            // whole island (see NotchIsland) — not anchored here — so it lands in
            // the middle of the panel instead of down by the pill.
            GlassTextButton(title: L("recent.clear")) {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                    model.confirmingClear = true
                }
            }
        }
        .padding(.horizontal, 8)
    }

    /// RECENT header + the scrollable list, as one block so the open animation
    /// moves the whole module together.
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            recentHeaderRow
                .padding(.top, 12)
                .padding(.bottom, 4)

            // Live filter — hidden behind the filter icon by default. Only shown
            // once the list is long enough to be worth searching (matches historyList's
            // own > 6 overflow calibration) AND the user has explicitly expanded it.
            // The field spans the section width so its text aligns with the list rows
            // below, and its vertical padding is kept tight since it's a revealed
            // secondary control.
            if model.history.count > 6, model.showHistoryFilter {
                HistorySearchField(
                    text: $model.historySearchQuery,
                    placeholder: L("recent.filter"),
                    fontSize: 12,
                    focusTrigger: filterFocused
                )
                .frame(height: 18)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Tokens.hairline, lineWidth: 0.5)
                        )
                )
                .padding(.bottom, 4)
                .transition(.opacity)
                .onAppear {
                    // The field is summoned with ⌘F (ContentView's key catcher flips
                    // showHistoryFilter). It only mounts once that's true, so grabbing
                    // focus on appear lands the caret without a click. The tiny delay
                    // lets SwiftUI finish inserting the field before the focus grab.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        filterFocused = true
                    }
                }
                .onChange(of: model.showHistoryFilter) { _, showing in
                    if !showing { filterFocused = false }
                }
            }

            historyList()
        }
    }

    /// Plain-input header baseline: the height the floating header measures with just
    /// the input + RECENT controls row (no quote). Seeds `measuredImmersiveHeaderHeight`
    /// so the very first frame already reserves the right runway, and combined with
    /// `immersiveHeaderGap` reproduces the original 84pt reach for the no-quote case.
    private static let immersiveHeaderBaseline: CGFloat = 72

    /// Breathing room between the bottom of the floating header and the first row's
    /// resting top. `baseline (72) + gap (12) = 84`, the runway the no-quote layout
    /// always used; a quote/chips header measures taller and the runway grows with it.
    private let immersiveHeaderGap: CGFloat = 12

    /// How far the immersive list's content reaches UP behind the floating header so
    /// the first row rests just clear of it. Derived from the *measured* header height
    /// (`measuredImmersiveHeaderHeight`) rather than a constant, because the header is
    /// not fixed: a plain input is short, but a pending clipboard quote adds a preview
    /// line above the input and a row of action chips below it. Tracking the real
    /// height keeps the first row clear whether or not a quote is present.
    private var immersiveTopReach: CGFloat { measuredImmersiveHeaderHeight + immersiveHeaderGap }

    /// Height of the top frost band, in points. Kept SHORTER than the layout runway
    /// (`immersiveTopReach`) on purpose: the band must taper fully to clear before it
    /// reaches the first row's resting position, or the blurred light-grey glyphs of
    /// that row stack into a bright halo (see `ProgressiveTopBlur`). A 4pt margin under
    /// the runway is the tuned ceiling — over the 320pt viewport the deepest frost layer
    /// is also the faintest, so its tail grazing the runway edge stays imperceptible
    /// while the opaque bulk of the frost sits above. Derived from the runway (not a
    /// constant) so the band tracks the header: it grows when a quote raises the header
    /// and shrinks back for a plain input, always ending just above the first row.
    private var immersiveBlurReach: CGFloat { max(immersiveTopReach - 4, 0) }

    /// Total height of the immersive scroll region — deliberately taller than the
    /// compact 220 so the recent list fills the panel and reads as one continuous
    /// surface flowing under the header. Older rows are a scroll (or ↓) away.
    private let immersiveListHeight: CGFloat = 320

    /// The recent list. `immersive` swaps the compact, below-the-header list for
    /// the tall variant whose content scrolls UP behind the floating input —
    /// frosting and fading as it goes (see `immersiveTopReach`). Only used once
    /// the list overflows; a short list stays compact under the header.
    private func historyList(immersive: Bool = false) -> some View {
        // More rows than fit the window → the list scrolls. In the compact layout
        // the first row sits right under the (non-scrolling) RECENT header, so the
        // TOP never needs a fade — a fixed top pad there would just open a dead gap
        // below the header. The immersive layout is the opposite: its top reaches
        // up behind the floating input, so it DOES taper (fade + frost) there.
        // The compact frame holds ~6 rows (~35pt each in 220pt); the fade + scroll
        // only earn their keep past that. Calibrated to the current height so the
        // bottom taper turns on right when the list actually overflows.
        let overflowing = model.recentVisible.count > 6
        return ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Index into the SAME slice the model navigates (`recentVisible`),
                // so the keyboard highlight and the rendered rows can't drift.
                ForEach(Array(model.recentVisible.enumerated()), id: \.element.id) { index, item in
                    Button { model.openHistory(item) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(item.displayTitle)
                                .font(.sf(14))
                                .tracking(-0.1)
                                .foregroundStyle(Tokens.text2)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            // Ask rows show how long ago; Note/Reminder captures
                            // show where tapping goes, in the same trailing slot —
                            // so the Recent list reads as one ledger of everything
                            // the notch did, not just AI answers. The capture badge
                            // pairs the destination with an up-right arrow (the same
                            // "opens elsewhere" glyph the footer uses) so the row
                            // reads as a live jump into Notes/Reminders, not a dead
                            // label — tapping it lands on that exact note/reminder.
                            if item.source == .ask {
                                Text(relativeTime(item.t))
                                    .font(.sf(11).monospacedDigit())
                                    .tracking(0.2)
                                    .foregroundStyle(Tokens.text4)
                            } else {
                                HStack(spacing: 3) {
                                    Text(item.source == .note ? L("recent.badge.notes") : L("recent.badge.reminders"))
                                        .font(.sf(11).weight(.medium))
                                        .tracking(0.2)
                                    Image(systemName: "arrow.up.right")
                                        .font(.sf(9, weight: .semibold))
                                }
                                .foregroundStyle(Tokens.text4)
                            }
                        }
                        .padding(.vertical, 9)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HistoryRowStyle(selected: model.highlightedHistoryIndex == index))
                    // VoiceOver: name the row by its title, and spell out what
                    // activating it does — a capture jumps out to Notes/Reminders
                    // (the up-right arrow glyph isn't announced), an Ask row reopens
                    // the conversation in place.
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(item.displayTitle)
                    .accessibilityHint(
                        item.source == .note ? L("recent.hint.note")
                        : item.source == .reminder ? L("recent.hint.reminder")
                        : L("recent.hint.ask")
                    )
                    // A deleted row collapses up and fades rather than vanishing on a
                    // hard cut — the rows below slide into the gap on the same spring
                    // that drives the list's other module motion. Paired with the
                    // `withAnimation` around the delete below; the removal edge is what
                    // SwiftUI plays this transition against.
                    .transition(
                        .move(edge: .leading)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.96, anchor: .leading))
                    )
                    // Right-click a row to drop just that entry (Clear still wipes
                    // the whole list). Single-item delete needs no confirmation —
                    // one row is cheap to retype, unlike the destructive Clear-all.
                    .contextMenu {
                        Button(L("recent.delete"), role: .destructive) {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                model.deleteHistory(id: item.id)
                            }
                        }
                    }
                    // Target for keyboard-follow scrolling: ↓/↑ moves the highlight,
                    // and the onChange below scrolls that row's id into view.
                    .id(item.id)
                }
            }
            // Breathing room only BELOW the last row, so the bottom fade tapers over
            // this gap rather than slicing a row. In the immersive layout the TOP
            // also gets an inset (`immersiveTopReach`): it's the runway the rows
            // scroll up into, behind the floating input, so the first row rests
            // *below* the input at idle but can travel up under it. The compact
            // layout keeps its top tight under the (non-floating) RECENT header.
            .padding(.top, immersive ? immersiveTopReach : 0)
            .padding(.bottom, overflowing ? edgeFade : 0)
            // Immersive only: watch the real scroll offset (via the AppKit clip view)
            // so the floating header can hide its manage controls the moment the list
            // leaves the top. A few points of slack absorbs rest-state jitter.
            .background {
                if immersive {
                    ScrollOffsetObserver { y in setHistoryAtTop(y <= 6) }
                }
            }
        }
        // Immersive: a tall surface that fills the panel and flows under the header.
        // Compact: ~6 rows before the list scrolls, so a short Recent list doesn't
        // reserve a tall empty band under the header. Older rows are a scroll (↓) away.
        .frame(maxHeight: immersive ? immersiveListHeight : 220)
        .scrollIndicators(.never)
        // Compact: only the bottom fades (the RECENT header caps the top). Immersive:
        // BOTH edges taper — the top dissolves the rows sliding up behind the input,
        // the bottom tells the user there's more below. Gated on overflow either way.
        .scrollEdgeFade(top: immersive, bottom: overflowing, fade: edgeFade)
        // Immersive only: frost the rows as they scroll UP into the runway behind the
        // floating input, so they read as pushed back — present but soft — not
        // hard-clipped. The band is kept SHORTER than the runway (`immersiveBlurReach`
        // < `immersiveTopReach`) so it tapers out before the first resting row: idle
        // rows stay crisp (no blurred-glyph halo), only rows travelling up under
        // "Type anything…" frost. Decoupled from `immersiveTopReach` (which is layout:
        // where rows rest) so tuning the blur never shifts the list. Glass translucency
        // is untouched — this only softens focus, never darkens.
        .modifier(ConditionalTopBlur(active: immersive, height: immersiveBlurReach, maxRadius: 36))
        // Keep the keyboard-highlighted row visible: stepping ↓/↑ past the visible
        // window would otherwise leave the selection offscreen. Mirrors the
        // streaming tail-follow in `conversationScroll` — a reactive scroll in its
        // OWN transaction, separate from the highlight mutation, so SwiftUI doesn't
        // silently drop the `scrollTo` mid-reconciliation.
        .onChange(of: model.highlightedHistoryIndex) { _, newIndex in
            guard let i = newIndex, model.recentVisible.indices.contains(i) else { return }
            let id = model.recentVisible[i].id
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
        }
    }

    // MARK: - Load

    private var loadView: some View {
        VStack(alignment: .leading, spacing: 0) {
            resultHeader
            // No drawn rule here — the gap alone separates the chevron from the
            // content below. Roughly the rhythm the old Divider held (its 9pt
            // top/bottom pad plus the hairline) so the spacing reads the same.
            Spacer().frame(height: 18)
            ThinkingDots()
                .padding(.vertical, 5)
                .padding(.horizontal, 2)
        }
    }

    // MARK: - Result

    /// The tallest the answer area is ever allowed to grow. Short answers size to
    /// their own content (below this); only long ones clip + scroll at the ceiling.
    private let answerMaxHeight: CGFloat = 300

    private var resultView: some View {
        VStack(alignment: .leading, spacing: 0) {
            resultHeader
            // No drawn rule between the chevron and the thread — a quiet gap does
            // the separating instead. Matches the rhythm the old Divider held (its
            // 9pt top/bottom pad plus the hairline) so the layout doesn't shift.
            Spacer().frame(height: 18)

            conversationScroll

            // Extra breathing room between the thread and the row below so the
            // last line never sits right under the fade / against the input.
            //
            // Without a live backend a follow-up would only ever return another
            // stub placeholder, so instead of an input that can't really answer we
            // show a call-to-action that takes the user straight to Settings to set
            // up a model. Once configured, the normal follow-up field returns.
            Group {
                if model.isConfigured {
                    followUpRow
                } else {
                    setupModelRow
                }
            }
            .padding(.top, 24)

            // Note/Reminder save feedback for lines filed FROM the result view (now
            // that the follow-up field routes by intent). The idle prompt shows this
            // same calm cue via `noteFeedbackContent`, but that path never renders in
            // `.result` — so mirror it here: "Saving…" in flight, then the model's
            // "Added to Reminders · Daily" / "Added to Notes" cue, which the model
            // auto-clears after ~1.7s. The error slot above owns the failure case.
            if model.noteSaving {
                feedbackLine(L("input.saving"))
                    .padding(.top, 6)
                    .transition(.opacity)
            } else if let cue = model.lastSavedNote {
                feedbackLine(cue)
                    .padding(.top, 6)
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.lastSavedNote)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.noteSaving)
    }

    /// Stand-in for the follow-up field while on the offline stub: a full-width
    /// button that opens Settings (same path as the gear / ⌘,) so the user can
    /// paste an API key and get live answers. Styled like the follow-up box it
    /// replaces, so the result view's footprint doesn't jump.
    private var setupModelRow: some View {
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                model.openSettings()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .medium))
                Text(L("result.setUpModel"))
                    .font(.sf(14.5, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
            }
            .foregroundStyle(Tokens.text1)
            .padding(.leading, 13)
            .padding(.trailing, 12)
            .frame(height: 39)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SetupModelButtonStyle())
    }

    /// The whole conversation, scrolling: every user/assistant turn stacked, the
    /// newest at the bottom. Sizes to its content up to `answerMaxHeight`, then
    /// clips + scrolls; a `ScrollViewReader` keeps the latest turn pinned in view
    /// as a follow-up streams in. The bottom fade is the "more below" cue.
    private var conversationScroll: some View {
        let clipped = measuredAnswerHeight > answerMaxHeight
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.turns) { turn in
                        turnView(turn)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(turn.id)
                    }
                    // Trailing pad inside the scroll so the final line can clear the
                    // fade band when scrolled to the bottom, plus an anchor the
                    // reader scrolls to so new turns always land in view.
                    Color.clear.frame(height: 2).id(scrollBottomID)
                }
                .padding(.trailing, 8)
                // Top/bottom breathing room INSIDE the scroll content — but ONLY when
                // the thread actually overflows and the fade bands are showing, so the
                // first/last lines have room to dissolve into them. For a short answer
                // that fits (no fade), this padding must be ZERO: it's measured into
                // `measuredAnswerHeight` below, which drives the scroll's frame height,
                // so an unconditional 2×edgeFade (60pt) would inflate the frame past
                // the real content and leave a dead band under short answers. Gating it
                // on `clipped` keeps the resting result view exactly as tall as its text.
                .padding(.top, clipped ? edgeFade : 0)
                .padding(.bottom, clipped ? edgeFade : 0)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: AnswerHeightKey.self, value: geo.size.height
                        )
                    }
                )
            }
            .frame(height: min(measuredAnswerHeight, answerMaxHeight))
            .scrollIndicators(.never)
            .onPreferenceChange(AnswerHeightKey.self) { newHeight in
                measuredAnswerHeight = newHeight
                // The content just relaid out (a turn appended, or the answer grew).
                // Re-pin the bottom in the SAME pass, with no animation, so the
                // submit's height jump can't leave the scroll stranded at the top.
                proxy.scrollTo(scrollBottomID, anchor: .bottom)
            }
            // Submitting a follow-up appends two turns and flips mode
            // result→load→result, which rebuilds the ScrollView and resets its
            // offset to the top. Snap straight back to the bottom (no animation) so
            // there's no visible jump up — the streaming tail-follow below is what
            // gets the smooth motion.
            .onChange(of: model.turns.count) { _, _ in
                proxy.scrollTo(scrollBottomID, anchor: .bottom)
            }
            // Follow the tail smoothly as the answer streams in, so the freshest
            // text stays in view without the user scrolling by hand.
            .onChange(of: model.turns.last?.text) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(scrollBottomID, anchor: .bottom)
                }
            }
        }
        // The shared soft fade at both edges, but only once the thread overflows —
        // a short conversation that fits stays crisp top-to-bottom. The scroll
        // content carries matching top/bottom padding (`edgeFade`) so the taper
        // falls across breathing room, not over live text.
        .scrollEdgeFade(top: clipped, bottom: clipped, fade: edgeFade)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: measuredAnswerHeight)
    }

    /// Height of the taper at each scroll edge, in points. Generous on purpose so
    /// the dissolve is a long, gentle gradient — not a thin line that still reads
    /// as a cut. The scroll content carries matching top/bottom padding, so the
    /// fade falls across that breathing room rather than over live text.
    private let edgeFade: CGFloat = 64

    /// Stable id for the invisible spacer at the very bottom of the thread; the
    /// `ScrollViewReader` scrolls to it to keep the newest text in view.
    private let scrollBottomID = "conversation-bottom"

    /// One bubble in the thread. A user turn reads as a quiet, dimmer line tagged
    /// "You"; an assistant turn renders full markdown at body weight. A streaming
    /// assistant turn with no text yet shows the thinking dots, so the wait reads
    /// the same in a follow-up as it does on the first question.
    @ViewBuilder
    private func turnView(_ turn: NotchModel.Turn) -> some View {
        if turn.role == "user" {
            VStack(alignment: .leading, spacing: 5) {
                // Permanent clipboard trace: when this question's message was enriched
                // with what the user copied, a quiet line says so — sitting right above
                // the "You" row and staying for the life of the answer (unlike the
                // load-only "Using clipboard" cue). It lines up under the "You" column
                // so it reads as a caption on this turn. `paperclip`-free on purpose:
                // one small grey line, same whisper as the note-save cue.
                if turn.usedClipboard {
                    Text(L("result.basedOnCopied"))
                        .font(.sf(11))
                        .tracking(0.2)
                        .foregroundStyle(Tokens.text4)
                        .padding(.leading, 38)   // 30pt "You" column + 8pt HStack gap
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L("result.you"))
                        .font(.sf(11, weight: .semibold))
                        .tracking(0.3)
                        .foregroundStyle(Tokens.text4)
                        .frame(width: 30, alignment: .leading)
                    Text(turn.text)
                        .font(.sf(14.5, weight: .medium))
                        .tracking(-0.1)
                        .foregroundStyle(Tokens.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else if turn.text.isEmpty && turn.streaming {
            ThinkingDots()
                .padding(.vertical, 2)
                .padding(.horizontal, 2)
        } else {
            // Selection stays off while the answer streams: the per-token
            // tail-follow scroll (onChange → scrollTo(.bottom)) would collapse
            // any in-progress drag-selection. The instant the stream finishes,
            // every prose block becomes selectable/copyable. `.disabled` and
            // `.enabled` are distinct types, so this branches at the view level
            // rather than ternary-ing the modifier's argument.
            if turn.streaming {
                MarkdownBlocks(source: turn.text, baseFont: 15, color: Tokens.text1, onInAppCopy: { model.rebaselineClipboardAfterInAppWrite() })
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.disabled)
            } else {
                // A settled answer carries its own quiet "file this in Notes" button
                // directly beneath it — one per answer, so a long thread can save any
                // segment, not just the latest. (It lived in the input row before, where
                // it read as a property of the field rather than of this answer.)
                VStack(alignment: .leading, spacing: 6) {
                    MarkdownBlocks(source: turn.text, baseFont: 15, color: Tokens.text1, onInAppCopy: { model.rebaselineClipboardAfterInAppWrite() })
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // Just the back chevron — the question itself already leads the thread below
    // as the "You" turn, so a title here would only repeat it.
    private var resultHeader: some View {
        HStack(spacing: 10) {
            backButton
            Spacer(minLength: 0)
        }
    }

    /// Back to a fresh conversation: clears this Q&A off the screen and returns to
    /// the idle prompt (panel stays open). Safe mid-answer — an in-flight stream
    /// finishes detached and lands in Recent (see `NotchModel.newChat`). Also bound
    /// to the ← arrow key (see ContentView's key handler), so a glance-and-go feels
    /// keyboard-native.
    private var backButton: some View {
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                model.newChat()
            }
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.text2)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(RecentEntryStyle())
        .help(L("result.newConversation"))
    }

    // MARK: - Inputs

    private func inputRow(placeholder: String, followUp: Bool) -> some View {
        let fontSize: CGFloat = followUp ? 14.5 : 16.5
        return HStack(spacing: 12) {
            // The field, with a Siri-style ghost hint trailing the typed text on the
            // same line. This `inputRow` renders the hint only for the idle prompt
            // (`!followUp`); the mid-thread field is `followUpRow`, which carries its
            // own copy of the same hint. A `GeometryReader` hands the hint the row's
            // width so it knows where to dock once a long line runs out of room.
            ZStack(alignment: .leading) {
                GeometryReader { geo in
                    if !followUp {
                        InlineSendHint(
                            label: model.submitLabel,
                            fontSize: fontSize,
                            caretWidth: caretWidth,
                            availableWidth: geo.size.width
                        )
                        .frame(height: geo.size.height, alignment: .center)
                    }
                }
                .allowsHitTesting(false)

                PromptField(
                    text: $model.text,
                    placeholder: placeholder,
                    fontSize: fontSize,
                    focusTrigger: focused,
                    // Enter routes by intent (ask / note / remind) from the idle
                    // prompt. The real mid-thread field is `followUpRow`, which now
                    // also routes by intent; this `followUp` branch is only the
                    // defensive path if `inputRow` is ever reused with `followUp: true`,
                    // and it keeps the plain-ask behaviour for that unused case.
                    onSubmit: { followUp ? model.submit() : model.submitCurrent() },
                    // Idle prompt only: ↓/↑ open and step the recent list, and Enter
                    // opens a keyboard-highlighted row instead of submitting. The
                    // follow-up field leaves these at their no-op defaults.
                    onDown: followUp ? { false } : {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                            model.historyNavigateDown()
                        }
                    },
                    onUp: followUp ? { false } : {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                            model.historyNavigateUp()
                        }
                    },
                    onSubmitNav: followUp ? { false } : {
                        // Enter first confirms a keyboard-highlighted Recent row; failing
                        // that, on an empty prompt it fires the leading capture chip
                        // (save the copied jot). Either short-circuits the empty submit.
                        model.historyConfirmHighlighted() || model.confirmClipboardCaptureIfIdle()
                    },
                    // Tab steps where Enter sends this line (Ask → Note → Remind →…)
                    // when the classifier guessed wrong — the inline hint steps with
                    // it. Only meaningful with text in the field; an empty field's Tab
                    // is still swallowed so focus never wanders out of the prompt.
                    onTab: followUp ? { false } : {
                        if model.hasText { model.toggleSubmitPanel() }
                        return true
                    },
                    // Live width of committed text + any composing pinyin, so the
                    // inline hint trails the caret as the IME composes. Only the idle
                    // prompt feeds `caretWidth` here; `followUpRow` owns its own
                    // `followUpCaretWidth` tracking and its own hint overlay.
                    onCaretWidth: followUp ? { _ in } : { caretWidth = $0 }
                )
                // Reserve the hint's docking slot at the row's trailing edge: a long
                // line scrolls within this narrower field while "— Ask"/"— Note"
                // holds in the reserved strip beside it, never overlapped, never lost.
                // The reserved width follows the current label so short labels don't
                // waste space; the ZStack animation keeps the resize smooth.
                .padding(.trailing, followUp ? 0 : InlineSendHint.reservedTrailingWidth(label: model.submitLabel, fontSize: fontSize))
                .animation(.smooth(duration: 0.25), value: model.submitLabel)
            }

            // With the destination now spelled out inline beside the caret, the
            // trailing send pill would just repeat it — so while there's text the
            // inline hint owns that job and the trailing slot stays empty. When the
            // field is empty the faint clock entry tucks in there to toggle Recent,
            // and — on the first launch after an update — a "what's new" cue leads
            // it, the one-tap (or ⌘↵) way into the release notes.
            if !model.hasText && !followUp {
                HStack(spacing: 8) {
                    if whatsNew.unseenVersion != nil {
                        whatsNewCue
                            .transition(.opacity)
                    }
                    if !model.history.isEmpty {
                        recentEntry
                            .transition(.opacity)
                    }
                }
            }
        }
        .frame(height: followUp ? 30 : 48)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.hasText)
    }

    /// The first-launch-after-update cue: a quiet "what's new" pill in the idle
    /// input's trailing slot. Tapping it (or ⌘↵) opens the release-notes panel;
    /// either way `openWhatsNew` marks this version seen, so the cue shows once.
    private var whatsNewCue: some View {
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                model.openWhatsNew(on: nil)
            }
        } label: {
            Text(L("whatsnew.cue"))
                .font(.sf(12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(Tokens.text3)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(L("whatsnew.title"))
    }

    /// The minimal clock entry that opens / closes the recent list.
    private var recentEntry: some View {
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                model.showHistory.toggle()
                // Closing via the clock drops any keyboard highlight; opening via
                // the clock starts un-highlighted (the caret stays in the input).
                model.highlightedHistoryIndex = nil
            }
        } label: {
            // A downward chevron reads as "pull the recent list down"; it flips to
            // point up once the list is open, so the same control says "close" on
            // the way back — the natural disclosure direction for a panel that
            // unfurls below the prompt.
            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.showHistory ? Tokens.text2 : Tokens.text4)
                .rotationEffect(.degrees(model.showHistory ? 180 : 0))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
                .animation(.spring(response: 0.32, dampingFraction: 0.8), value: model.showHistory)
        }
        .buttonStyle(RecentEntryStyle())
        .help(L("recent.recent"))
    }

    private var followUpRow: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                // Same Siri-style ghost hint the idle prompt carries, now on the
                // mid-thread field too: "— Ask"/"— Note"/"— Remind" trailing the caret
                // so a routed-by-intent follow-up shows its destination, and Tab's
                // correction step is finally visible here. Rendered behind the field
                // and hit-transparent. Gated on `followUpCaretWidth > 0` (not
                // `model.hasText`) so it appears during CJK/IME pre-composition —
                // before pinyin commits to `model.text` — matching the idle row.
                GeometryReader { geo in
                    if followUpCaretWidth > 0 {
                        InlineSendHint(
                            label: model.submitLabel,
                            fontSize: 14.5,
                            caretWidth: followUpCaretWidth,
                            availableWidth: geo.size.width
                        )
                        .frame(height: geo.size.height, alignment: .center)
                    }
                }
                .allowsHitTesting(false)

                PromptField(
                    // The native placeholder stays empty on purpose: NSTextField can
                    // only hard-swap its placeholder string, so the slot is owned by
                    // the SwiftUI labels below, which cross-fade their copy instead.
                    text: $model.text,
                    placeholder: "",
                    fontSize: 14.5,
                    focusTrigger: focused,
                    // Route by intent, same as the idle prompt — a follow-up line
                    // like "remind me to ping Alex tomorrow at 9am" files to
                    // Reminders instead of being asked to the AI. A plain question
                    // still resolves to `.chat` → `submit()`, which continues the
                    // existing thread (firstTurn = turns.isEmpty), so the common
                    // follow-up path is unchanged.
                    onSubmit: { model.submitCurrent() },
                    onBack: {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                            model.newChat()
                        }
                    },
                    // Tab cycles where Enter sends this line (Ask → Note → Remind →…)
                    // when the classifier guessed wrong — the correction escape hatch,
                    // matching the idle prompt. Empty-field Tab is still swallowed so
                    // focus never wanders out of the field.
                    onTab: {
                        if model.hasText { model.toggleSubmitPanel() }
                        return true
                    },
                    // Lets the overlay placeholder hide itself the instant the editor
                    // shows ANYTHING — committed text or still-composing pinyin (which
                    // isn't in `model.text` yet) — matching the native behaviour.
                    onCaretWidth: { followUpCaretWidth = $0 }
                )
                // Reserve the hint's docking slot at the trailing edge, exactly like
                // the idle row, so typed text scrolls within a narrower field and the
                // "— Ask"/"— Remind" ghost never overlaps it. Width follows the current
                // label so short labels don't leave a dead strip on the right.
                .padding(.trailing, InlineSendHint.reservedTrailingWidth(label: model.submitLabel, fontSize: 14.5))
                .animation(.smooth(duration: 0.25), value: model.submitLabel)
                // The placeholder slot does double duty while the field is empty, and
                // every change of copy moves through a fade rather than a hard string
                // swap:
                //  • copy confirmation up → "Copied to clipboard", shimmered, with a
                //    light gliding across the glyphs, then fades back;
                //  • hovering the continue-elsewhere button → a one-line hint for
                //    what that button does, in place of a tooltip;
                //  • otherwise → the usual "Ask a follow-up…" prompt.
                if !model.hasText && followUpCaretWidth == 0 {
                    Group {
                        if handoffCopied {
                            copiedShimmerLabel
                        } else {
                            followUpPlaceholderLabel
                        }
                    }
                    // Nudge to sit on the NSTextField cell's own ~2pt left inset
                    // so the labels land where the placeholder was, not 2pt left.
                    .padding(.leading, 2)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }

            // Light "take this elsewhere" affordance — copies the whole thread as
            // portable context so it can be pasted into ChatGPT/Claude. Kept faint
            // and icon-only so it sits quietly beside the input; it steps aside for
            // the send button the moment the user starts typing a follow-up.
            if model.hasText {
                SendButton(compact: true) { model.submitCurrent() }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                // The input row keeps only the "continue elsewhere" escape hatch.
                continueElsewhereButton
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        // Pin the row to the height it has WITH the send button (27pt button),
        // so it stays put when the button shows/hides instead of growing.
        .frame(height: 27)
        .padding(.leading, 13)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(focused ? 0.08 : 0.05))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(focused ? 0.20 : 0.10), lineWidth: 0.5)
        )
        // Flash the field's rim when the destination flips (Ask⇄Note⇄Remind) — the
        // peripheral twin of the inline "— Ask"/"— Note" word swap. Keyed on the
        // intent *category* so a recurrence-suffix edit doesn't pulse.
        .intentChangePulse(on: model.effectiveSubmitPanel, shape: RoundedRectangle(cornerRadius: 12))
        .animation(.easeOut(duration: 0.2), value: focused)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.hasText)
    }

    /// The copy confirmation that lives in the placeholder slot: the words "Copied
    /// to clipboard" sitting exactly where "Ask a follow-up…" sits, with a soft
    /// highlight gliding once across the glyphs. The base text reads at the same
    /// quiet placeholder weight; over it, a narrow brighter band is *masked to the
    /// text itself* (not the box) and swept left→right by `handoffSweep`, so the
    /// light catches the letters rather than scanning the field. One pass, then it
    /// settles, then the whole label fades back out (see `runHandoffCopy`).
    private var copiedShimmerLabel: some View { shimmerLabel(L("result.copiedToClipboard"), sweep: handoffSweep) }

    /// The shared shimmer confirmation that lives in the placeholder slot: `copy`
    /// sitting exactly where "Ask a follow-up…" sits, with a soft highlight gliding
    /// once across the glyphs when `sweep` flips true. Parameterized so the copy and
    /// save confirmations share one recipe instead of two near-identical copies.
    private func shimmerLabel(_ copy: String, sweep: Bool) -> some View {
        Text(copy)
            .font(.sf(14.5))
            .foregroundStyle(Tokens.placeholder)
            // The travelling highlight, drawn only where the glyphs are.
            .overlay(
                GeometryReader { geo in
                    let w = geo.size.width
                    let band = max(w * 0.5, 70)
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0),    location: 0),
                            .init(color: .white.opacity(0.85), location: 0.5),
                            .init(color: .white.opacity(0),    location: 1),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: band)
                    .offset(x: sweep ? w + band : -band)
                    .blendMode(.screen)
                }
                .mask(Text(copy).font(.sf(14.5)))
                .allowsHitTesting(false)
            )
    }

    /// The follow-up field's placeholder, drawn as a SwiftUI label in the slot the
    /// native placeholder would occupy (same font, colour and inset — the recipe the
    /// shimmer label already proved out). SwiftUI ownership is what buys the motion:
    /// hovering the continue-elsewhere button swaps the wording to a hint for what
    /// that button does — our in-place stand-in for a tooltip — through the same
    /// quiet in-place cross-fade as the inline Ask⇄Note hint, where an NSTextField
    /// placeholder could only hard-cut between strings.
    private var followUpPlaceholderLabel: some View {
        Text(hoveringContinue ? L("result.copyToContinue")
             : L("result.followUp"))
            .font(.sf(14.5))
            .foregroundStyle(Tokens.placeholder)
            .lineLimit(1)
            .contentTransition(.opacity)
            .animation(.smooth(duration: 0.25), value: hoveringContinue)
    }

    /// A small, faint icon button that copies the conversation to the clipboard so
    /// the user can continue it in a full chat (ChatGPT / Claude). No hard round
    /// limit — this is always available as an escape hatch, sitting quietly at the
    /// trailing edge of the follow-up field. Flips to a check for a beat on copy.
    /// Hovering it turns the field's placeholder into a one-line "what this does"
    /// hint (see `followUpPlaceholderLabel`), so the affordance explains itself
    /// without a tooltip.
    private var continueElsewhereButton: some View {
        Button { runHandoffCopy() } label: {
            // The icon briefly snaps to a check; the "Copied to clipboard" label in
            // the field is the real confirmation, so the button itself stays quiet.
            Image(systemName: handoffCopied ? "checkmark" : "square.on.square.dashed")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(handoffCopied ? Tokens.text2 : Tokens.text3)
                .frame(width: 27, height: 27)
                .contentShape(Rectangle())
        }
        .buttonStyle(RecentEntryStyle())
        .onHover { hoveringContinue = $0 }
    }

    /// Copy the conversation and play the in-field confirmation: the placeholder
    /// becomes "Copied to clipboard", a light sweeps once across those glyphs, the
    /// message holds for a beat, then the whole label fades back to "Ask a
    /// follow-up…". The trailing icon shows a check for the same window. Sequence:
    /// reveal → one ~0.9s sweep → hold → ~2s after the start, fade out.
    private func runHandoffCopy() {
        model.copyHandoffContext()
        handoffSweep = false                       // park the highlight off the left
        withAnimation(.easeOut(duration: 0.18)) { handoffCopied = true }
        // Kick the sweep on the next runloop so the reveal and the highlight don't
        // collide into one frame.
        Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            withAnimation(.easeInOut(duration: 0.9)) { handoffSweep = true }
            try? await Task.sleep(nanoseconds: 1_880_000_000)
            withAnimation(.easeOut(duration: 0.35)) { handoffCopied = false }
            try? await Task.sleep(nanoseconds: 400_000_000)
            handoffSweep = false                   // reset for the next copy
        }
    }

}

/// History row highlight — a *hint* of glass, not a slab of it. The earlier
/// `.ultraThinMaterial` plate rendered at full strength and turned the whole row
/// into a bright frosted block that upstaged the text. Here the same idea is kept
/// but dialled right down: a barely-there white wash to say "this row", with a thin
/// material laid over it at very low opacity so a touch of real glass refraction
/// shows through — present enough to feel like the panel's own material, faint
/// enough that the text stays the hero. Keyboard selection (↑/↓) reads a little
/// firmer than a passing hover; a hovered-selected row firmer still.
struct HistoryRowStyle: ButtonStyle {
    var selected: Bool = false
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        // 0 → nothing, up to 1 → most present. Even "most" is gentle.
        let presence: Double = selected ? (hovering ? 1.0 : 0.72) : (hovering ? 0.5 : 0)
        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    // Faint white floor so the row reads even where the material has
                    // nothing dark behind it to refract.
                    .fill(.white.opacity(0.03 * presence))
                    // A whisper of real glass on top — thin material, held to a low
                    // opacity so it shimmers rather than slabs.
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.thinMaterial)
                            .opacity(0.22 * presence)
                    )
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.16), value: selected)
            .animation(.easeOut(duration: 0.16), value: hovering)
    }
}

/// Carries the answer text's intrinsic height up to the body so the scroll area
/// can size itself to the content (capped at the ceiling).
private struct AnswerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        // Take the latest reported height, NOT max(). There's a single reader (the
        // scroll content's GeometryReader), so this just carries its current height
        // through — which must be able to SHRINK, not only grow. `max` latched the
        // measurement to the largest value ever seen (a tall earlier answer, or a
        // transient layout pass), so when a short answer replaced a long one the
        // scroll frame stayed tall and left a dead band under the text. Last-value
        // lets the frame track the real content up and down.
        let next = nextValue()
        if next > 0 { value = next }
    }
}

/// Carries the immersive floating header's measured height up to `NotchBody` so the
/// list's top runway and frost band can be sized to whatever the header actually
/// holds — a bare input, or an input flanked by a clipboard quote and its chips.
private struct ImmersiveHeaderHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        // Single reader; last value wins so the runway can SHRINK back when the quote
        // clears, not just grow (same rationale as `AnswerHeightKey`).
        let next = nextValue()
        if next > 0 { value = next }
    }
}

/// The "Set up your model" row that stands in for the follow-up field on the
/// offline stub. Mirrors the follow-up box's chrome — rounded rect, faint fill,
/// hairline border — and brightens on hover / gives slightly on press so it reads
/// as the same kind of affordance, just leading somewhere instead of accepting text.
struct SetupModelButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.white.opacity(hovering ? 0.10 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(hovering ? 0.22 : 0.10), lineWidth: 0.5)
            )
            .scaleEffect(pressed ? 0.985 : 1)
            .opacity(pressed ? 0.85 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.18), value: hovering)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressed)
    }
}

/// The faint clock entry: brightens slightly on hover, dims on press.
struct RecentEntryStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            // A Capsule, not a Circle: it collapses to a perfect circle behind a
            // square icon button (e.g. the 27×27 continue-elsewhere icon) but reads
            // as a proper pill behind a wide text label. A Circle stretched to the
            // label's wide rectangular bounds rendered as an oversized ellipse that
            // bled above and below the text.
            .background(
                Capsule().fill(.white.opacity(hovering ? 0.08 : 0))
            )
            .opacity(configuration.isPressed ? 0.5 : (hovering ? 1 : 0.85))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
