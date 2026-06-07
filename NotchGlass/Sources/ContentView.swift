import SwiftUI

/// The full transparent canvas. The notch island is pinned to the top-center;
/// everything else is empty space that lets clicks fall through to apps below.
struct ContentView: View {
    @ObservedObject var model: NotchModel
    @Environment(\.notchMetrics) private var metrics

    var body: some View {
        ZStack(alignment: .top) {
            // Transparent backdrop. While the panel is open, a faint scrim over
            // the whole canvas catches outside-clicks to dismiss (like the web
            // "click outside to close"); while closed it's fully click-through.
            if model.open {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // A tap outside the island while the Clear confirmation is
                        // armed cancels just the dialog — it shouldn't also blow the
                        // whole panel shut.
                        if model.confirmingClear {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                model.confirmingClear = false
                            }
                        } else if model.mode != .load {
                            model.fullClose()
                        }
                    }
            }

            NotchIsland(model: model)
        }
        .frame(width: metrics.canvasWidth, alignment: .top)
        .ignoresSafeArea()
        .background(KeyEventCatcher { event in
            // Tab flips between the chat and record surfaces while the panel is
            // open. Only a bare Tab — let ⌘⇥ (app switch) and ⌥⇥ etc. pass through
            // untouched. Caught before everything else so it works from either field.
            if event.keyCode == 48,
               event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
               model.open {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    model.togglePanel()
                }
                return true
            }
            // Esc: if the recent list is open, fold just that back to the input
            // first (one step "out"); only a second Esc closes the whole panel.
            // Mid-request is still guarded so Esc can't close while loading.
            if event.keyCode == 53, model.mode != .load {
                // Clear confirmation armed → first Esc dismisses just the dialog,
                // before any panel-level step-out / close.
                if model.confirmingClear {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                        model.confirmingClear = false
                    }
                    return true
                }
                // Settings open → first Esc folds back to the prompt, not a full
                // close (mirrors the recent-list step-out below).
                if model.showSettings {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                        model.closeSettings()
                    }
                    return true
                }
                if model.showHistory {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                        model.collapseHistory()
                    }
                    return true
                }
                model.fullClose()
                return true
            }
            // ← goes "back" to a fresh conversation from a result detail view —
            // but only when the follow-up field is empty, so a left-arrow while
            // editing still just moves the caret instead of nuking the answer.
            if event.keyCode == 123, model.mode == .result, !model.hasText {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    model.newChat()
                }
                return true
            }
            return false
        })
    }
}

/// The continuous black→glass island that grows out of the notch.
struct NotchIsland: View {
    @ObservedObject var model: NotchModel

    /// How far the black bleeds above the screen's top edge, guaranteeing no gap.
    private let topBleed: CGFloat = 6

    private var width: CGFloat {
        model.open ? model.openWidth : Tokens.notchWidth
    }

    private var bottomRadius: CGFloat {
        model.open ? 30 : Tokens.notchRestRadius
    }

    var body: some View {
        // The island sizes its HEIGHT to its content (the constant black zone +,
        // when open, the glass body). We deliberately do NOT pin height to a
        // measured value — that creates a clip↔measure deadlock. Width is the
        // only explicit dimension; height follows the VStack intrinsically, and
        // the layout `.animation` springs the grow/shrink.
        VStack(spacing: 0) {
            // Constant black "hardware" zone with the camera dot. It overshoots
            // the screen's top edge by `topBleed` so the black always reaches the
            // very top — no sliver of wallpaper between the bezel and the form.
            ZStack {
                if !model.open {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color(white: 0.17), Color(white: 0.02)],
                                center: UnitPoint(x: 0.35, y: 0.30),
                                startRadius: 0, endRadius: 5
                            )
                        )
                        .frame(width: 7, height: 7)
                        .offset(y: topBleed / 2)
                }
            }
            .frame(height: Tokens.notchTopHeight + topBleed)

            // The glass body unfurls below the notch zone when open.
            if model.open {
                NotchBody(model: model)
                    .transition(.opacity)
            }
        }
        .frame(width: width)
        .padding(.top, -topBleed)   // pull the form up so it bleeds off the top
        .background(GlassMaterial(bottomRadius: bottomRadius, expanded: model.open, warm: model.panel == .note))
        // The destructive "Clear recent history?" confirmation floats centered over
        // the whole island (scrim + card), instead of a popover anchored under the
        // Clear pill that landed it near the bottom of the panel. Mounted here so it
        // centers in the full glass body; clipped to the island shape below.
        .overlay {
            if model.confirmingClear {
                ClearHistoryConfirm(
                    onCancel: {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            model.confirmingClear = false
                        }
                    },
                    onConfirm: {
                        model.clearHistory()
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            model.confirmingClear = false
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .clipShape(NotchShape(bottomRadius: bottomRadius))
        .contentShape(NotchShape(bottomRadius: bottomRadius))
        // Spring expand; snappier, non-springy collapse — distinct in/out feel.
        .animation(
            model.open
                ? .spring(response: 0.42, dampingFraction: 0.72)
                : .easeOut(duration: 0.30),
            value: model.open
        )
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: model.openWidth)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: model.mode)
        // The record-mode feedback line (Saving… → Added to Notes → gone) changes
        // the body's intrinsic height. Without these, only the inner noteView spring
        // governed that change — it animates the line's own fade/scale but does NOT
        // propagate up to this island's frame, glass background, or clip shape, so
        // the outer form resized on a mismatched (or no) transaction while the inner
        // text eased out. Keying the island's grow/shrink on the same note states,
        // with the SAME spring noteView uses (response 0.42, damping 0.82), makes the
        // whole island — content and glass shell — settle as one smooth motion.
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.noteSaving)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.lastSavedNote)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.noteError)
        // Cross-fade the glass tint (cold black ⇄ warm champagne) when Tab flips
        // the surface, so switching modes feels like a smooth temperature change
        // rather than a hard recolour.
        .animation(.easeInOut(duration: 0.32), value: model.panel)
        .onHover { inside in
            if inside { model.openPanel() } else { model.collapseOnLeave() }
        }
        .frame(maxWidth: .infinity, alignment: .center)   // center within canvas
    }
}

/// Bridges global key events (Esc) into SwiftUI without stealing focus.
struct KeyEventCatcher: NSViewRepresentable {
    var handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> NSView {
        let v = CatcherView()
        v.handler = handler
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.handler = handler
    }

    final class CatcherView: NSView {
        var handler: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    if self?.handler?(event) == true { return nil }
                    return event
                }
            }
        }
        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}
