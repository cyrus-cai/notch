import SwiftUI

/// The content that lives inside the glass, below the constant black notch zone.
/// Switches between idle / load / result exactly like the prototype's modes.
struct NotchBody: View {
    @ObservedObject var model: NotchModel
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
    /// Whether the record mode's "what does this do?" explainer is expanded. Toggled
    /// by the info button at the trailing edge of the record field; when on, a short
    /// paragraph unfurls below the prompt explaining that Enter saves to Apple Notes.
    @State private var showNoteInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The record surface owns the whole body when active — it's its own
            // simple input, independent of the chat idle/load/result state machine.
            if model.panel == .note {
                noteView
            } else {
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
        // Tab tears down one field and builds the other (chat ⇄ note). The new
        // field has never held focus, so re-arm the latch on every panel switch —
        // same reasoning as the mode-change refocus below — so the caret lands in
        // whichever input just came up.
        .onChange(of: model.panel) { _, _ in
            if model.open { refocusInput() }
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
            } else {
                inputRow(placeholder: "Ask anything", followUp: false)

                // The recent list expands below the prompt once the clock is tapped.
                if !model.hasText && !model.history.isEmpty && model.showHistory {
                    historySection
                        .transition(moduleTransition)
                }
            }
        }
    }

    // MARK: - Note (record mode)

    /// The record surface: one line in, straight to Apple Notes on Enter. Mirrors
    /// the idle prompt's chrome so the two modes feel like the same island wearing
    /// a different coat — a record field, a faint "press Tab to switch" hint, and a
    /// transient line under the input that confirms a save (or explains a failure).
    private var noteView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                PromptField(
                    text: $model.text,
                    placeholder: "Jot a note…",
                    fontSize: 16.5,
                    focusTrigger: focused,
                    // Enter writes the line to Notes (no AI). The recent-list nav
                    // hooks stay at their no-op defaults — record mode has no list.
                    onSubmit: { model.submitNote() }
                )
                .onChange(of: model.text) { _, _ in
                    // Editing the field clears a stale error so the hint doesn't
                    // linger over a line the user is actively rewriting.
                    if model.noteError != nil { model.noteError = nil }
                }

                if model.hasText {
                    SendButton(compact: false) { model.submitNote() }
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                } else {
                    noteInfoButton
                        .transition(.opacity)
                }
            }
            .frame(height: 48)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.hasText)

            // The "what is this?" explainer, unfurled by the info button. Shown only
            // when toggled on and the field is empty (a typed draft + send button
            // takes precedence). Same downward-unfurl as the recent list.
            if showNoteInfo && !model.hasText {
                noteInfoPanel
                    .padding(.top, 12)
                    .transition(moduleTransition)
            }

            // Feedback line (saving / saved / error). Only present when there's
            // something to say — when idle it takes ZERO height, so the resting
            // record view is exactly as tall as the chat idle view (just the 48pt
            // input). It unfurls below the prompt the same way the recent list does.
            if let feedback = noteFeedbackContent {
                feedback
                    .padding(.top, 8)
                    .transition(moduleTransition)
            }
        }
        // One spring drives every block that unfurls under the prompt — the info
        // panel AND the feedback line (saving / saved / error). They share the same
        // `moduleTransition`, so they must share the same curve too, or the feedback
        // would pop in with a different, snappier feel than the explainer right above
        // it. This is the panel's standard module spring (recent list, settings, …),
        // so a save confirmation eases in exactly like everything else here, instead
        // of with the ad-hoc easeInOut it had before.
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: showNoteInfo)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.noteSaving)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.lastSavedNote)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.noteError)
    }

    /// A single quiet info chip at the trailing edge of the record field — where the
    /// chat clock sits. Tapping it unfurls the explainer below (and tapping again
    /// folds it). `text4` grey at rest, lifting to `text2` while the panel is open,
    /// so the icon reads as "active" when its explainer is showing.
    private var noteInfoButton: some View {
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                showNoteInfo.toggle()
            }
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(showNoteInfo ? Tokens.text2 : Tokens.text4)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(RecentEntryStyle())
        .help("About record mode")
    }

    /// The explainer that unfurls under the prompt: a short, plain account of what
    /// record mode does — where a line goes (a brand-new note in Apple Notes), how
    /// the title is derived, and how to get back to chat. Kept to the panel's quiet
    /// type scale; no headers or icons, just two calm lines.
    private var noteInfoPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Press Enter to save this line to Apple Notes.")
                .font(.sf(13, weight: .medium))
                .tracking(-0.05)
                .foregroundStyle(Tokens.text2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Each line becomes its own new note in your default account — its first line is the title. Press Tab to switch back to chat.")
                .font(.sf(12))
                .tracking(-0.05)
                .lineSpacing(2)
                .foregroundStyle(Tokens.text4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }

    /// The line under the record input — `nil` when there's nothing to report, so
    /// the row simply doesn't exist (zero height) and the resting record view
    /// matches the chat idle height.
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
        if model.lastSavedNote != nil {
            return AnyView(feedbackLine("Added to Notes"))
        }
        if model.noteSaving {
            return AnyView(feedbackLine("Saving…"))
        }
        return nil
    }

    /// One line of the calm record-mode feedback: small, `text4` grey, no icon —
    /// the same whisper as the RECENT label.
    private func feedbackLine(_ text: String) -> some View {
        Text(text)
            .font(.sf(12))
            .tracking(0.2)
            .foregroundStyle(Tokens.text4)
            .frame(maxWidth: .infinity, alignment: .leading)
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
        GlassIconButton(systemName: "gearshape", help: "Settings (⌘,)", size: 26) {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                model.toggleSettings()
            }
        }
    }

    /// RECENT header + the scrollable list, as one block so the open animation
    /// moves the whole module together.
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("RECENT")
                    .font(.sf(10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Tokens.text4)
                Spacer()
                // Settings + Clear share this "manage" row; both only exist while
                // the recent list is expanded, so the idle panel stays minimal.
                settingsEntry
                // Clear is destructive, so it arms a confirmation rather than wiping
                // history on first tap. The card itself is rendered centered over the
                // whole island (see NotchIsland) — not anchored here — so it lands in
                // the middle of the panel instead of down by the pill.
                GlassTextButton(title: "Clear") {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        model.confirmingClear = true
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)

            historyList
        }
    }

    private var historyList: some View {
        // More rows than fit the window → the list scrolls. The first row sits right
        // under the (non-scrolling) RECENT header, so the TOP never needs a fade — a
        // fixed top pad there would just open a dead gap below the header. Only the
        // bottom taper earns its keep, telling the user there's more below.
        let overflowing = model.recentVisible.count > 4
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Index into the SAME slice the model navigates (`recentVisible`),
                // so the keyboard highlight and the rendered rows can't drift.
                ForEach(Array(model.recentVisible.enumerated()), id: \.element.id) { index, item in
                    Button { model.openHistory(item) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(item.q)
                                .font(.sf(14))
                                .tracking(-0.1)
                                .foregroundStyle(Tokens.text2)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(relativeTime(item.t))
                                .font(.sf(11).monospacedDigit())
                                .tracking(0.2)
                                .foregroundStyle(Tokens.text4)
                        }
                        .padding(.vertical, 9)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HistoryRowStyle(selected: model.highlightedHistoryIndex == index))
                }
            }
            // Breathing room only BELOW the last row, so the bottom fade tapers over
            // this gap rather than slicing a row. The top stays tight under the
            // header — no dead space between "RECENT" and the first entry.
            .padding(.bottom, overflowing ? edgeFade : 0)
        }
        .frame(maxHeight: 184)
        .scrollIndicators(.never)
        // Only the bottom edge fades (the header caps the top), and only once the
        // list overflows — a short list that fits stays crisp.
        .scrollEdgeFade(top: false, bottom: overflowing, fade: edgeFade)
    }

    // MARK: - Load

    private var loadView: some View {
        VStack(alignment: .leading, spacing: 0) {
            resultHeader
            Divider().background(Tokens.hairline).padding(.vertical, 9).padding(.horizontal, -20)
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
            Divider().background(Tokens.hairline).padding(.vertical, 9).padding(.horizontal, -20)

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
        }
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
                Text("Set up your model")
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
    private let edgeFade: CGFloat = 30

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
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("You")
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
        } else if turn.text.isEmpty && turn.streaming {
            ThinkingDots()
                .padding(.vertical, 2)
                .padding(.horizontal, 2)
        } else {
            MarkdownBlocks(source: turn.text, baseFont: 15, color: Tokens.text1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var resultHeader: some View {
        HStack(spacing: 10) {
            backButton
            Text(model.question)
                .font(.sf(13, weight: .medium))
                .tracking(-0.1)
                .foregroundStyle(Tokens.text2)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Back to a fresh conversation: drops this Q&A and returns to the idle
    /// prompt (panel stays open). Also bound to the ← arrow key (see ContentView's
    /// key handler), so a glance-and-go feels keyboard-native.
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
        .help("New conversation (←)")
    }

    // MARK: - Inputs

    private func inputRow(placeholder: String, followUp: Bool) -> some View {
        HStack(spacing: 12) {
            PromptField(
                text: $model.text,
                placeholder: placeholder,
                fontSize: followUp ? 14.5 : 16.5,
                focusTrigger: focused,
                onSubmit: { model.submit() },
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
                    model.historyConfirmHighlighted()
                }
            )

            if model.hasText {
                SendButton(compact: followUp) { model.submit() }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else if !model.history.isEmpty {
                // Weak, top-right history entry — a faint clock icon tucked at the
                // end of the prompt row (up in the dark zone). Toggles the inline
                // list below. Replaces the old full-width "Recent" block.
                recentEntry
                    .transition(.opacity)
            }
        }
        .frame(height: followUp ? 30 : 48)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: model.hasText)
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
            Image(systemName: "clock")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(model.showHistory ? Tokens.text2 : Tokens.text4)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(RecentEntryStyle())
        .help("Recent")
    }

    private var followUpRow: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                PromptField(
                    // While the copy confirmation is up the field's own placeholder
                    // is blanked, so "Copied to clipboard" owns the slot cleanly with
                    // no "Ask a follow-up…" bleeding through underneath.
                    text: $model.text,
                    placeholder: (handoffCopied && !model.hasText) ? "" : "Ask a follow-up…",
                    fontSize: 14.5,
                    focusTrigger: focused,
                    onSubmit: { model.submit() },
                    onBack: {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                            model.newChat()
                        }
                    }
                )
                // On copy, the placeholder slot momentarily reads "Copied to
                // clipboard" with a light gliding across the glyphs, then fades back
                // to the real field. Only shown while the field is empty (the
                // placeholder's own territory), so it never covers typed text.
                if handoffCopied && !model.hasText {
                    copiedShimmerLabel
                        // Nudge to sit on the NSTextField cell's own ~2pt left inset
                        // so the label lands where the placeholder was, not 2pt left.
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
                SendButton(compact: true) { model.submit() }
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
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
    private var copiedShimmerLabel: some View {
        let label = "Copied to clipboard"
        return Text(label)
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
                    .offset(x: handoffSweep ? w + band : -band)
                    .blendMode(.screen)
                }
                .mask(Text(label).font(.sf(14.5)))
                .allowsHitTesting(false)
            )
    }

    /// A small, faint icon button that copies the conversation to the clipboard so
    /// the user can continue it in a full chat (ChatGPT / Claude). No hard round
    /// limit — this is always available as an escape hatch, sitting quietly at the
    /// trailing edge of the follow-up field. Flips to a check for a beat on copy.
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
        .help("Copy chat to continue in ChatGPT or Claude")
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
            .background(
                Circle().fill(.white.opacity(hovering ? 0.08 : 0))
            )
            .opacity(configuration.isPressed ? 0.5 : (hovering ? 1 : 0.85))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
