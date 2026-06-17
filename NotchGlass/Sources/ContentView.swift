import SwiftUI

/// The full transparent canvas. The notch island is pinned to the top-center;
/// everything else is empty space that lets clicks fall through to apps below.
struct ContentView: View {
    @ObservedObject var model: NotchModel
    /// The live string store. Observing it here, at the root of every panel, plus
    /// the `.id(loc.language)` below, rebuilds the whole SwiftUI subtree when the
    /// App Language changes — so every `L(_:)` lookup re-evaluates at once, no
    /// relaunch, without each child view having to observe the store itself.
    @EnvironmentObject private var loc: Localization
    @Environment(\.notchMetrics) private var metrics

    var body: some View {
        ZStack(alignment: .top) {
            // Transparent backdrop. While the panel is open, a faint scrim over
            // the whole canvas catches outside-clicks to dismiss (like the web
            // "click outside to close"); while closed it's fully click-through.
            if model.isOpen(on: metrics.displayID) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        // A tap outside the island while the Clear confirmation is
                        // armed cancels just the dialog — it shouldn't also blow the
                        // whole panel shut. Closing mid-request is fine: the answer
                        // keeps streaming detached and lands in Recent.
                        if model.confirmingClear {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                model.confirmingClear = false
                            }
                        } else {
                            model.fullClose()
                        }
                    }
            }

            NotchIsland(model: model)
                // Rebuild the island's subtree on an App Language switch so every
                // localized string re-evaluates at once. The island is collapsed
                // (or being opened) when the user returns from a switch, so the
                // identity change never interrupts a visible animation.
                .id(loc.language)
        }
        .frame(width: metrics.canvasWidth, alignment: .top)
        .ignoresSafeArea()
        .background(KeyEventCatcher { event in
            // ⌘F summons the recent-list filter. The chip is gone — this is the only
            // way in. Only meaningful when there's a list worth filtering (matches the
            // field's own > 6 render gate). If the list is collapsed, open it first so
            // the field has somewhere to land; if the filter's already up, ⌘F is a
            // no-op rather than a toggle (Esc clears/closes it — see below).
            if event.keyCode == 3, event.modifierFlags.contains(.command),
               !model.showSettings, model.history.count > 6 {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    if !model.showHistory { model.showHistory = true }
                    model.showHistoryFilter = true
                }
                return true
            }
            // Esc: if the recent list is open, fold just that back to the input
            // first (one step "out"); only a second Esc closes the whole panel.
            // Works mid-request too — closing detaches the in-flight answer, which
            // finishes in the background and lands in Recent (see NotchModel).
            if event.keyCode == 53 {
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
                    // Stepped Esc while filtering, unwinding the ⌘F summon in reverse:
                    //   1. non-empty query  → clear the query (keep the field open)
                    //   2. empty query, field up → close just the filter field
                    //   3. field down        → fold the list back to the prompt
                    // Must run before collapseHistory() — this catcher fires ahead of
                    // SwiftUI's own exit handling.
                    if !model.historySearchQuery.isEmpty {
                        model.historySearchQuery = ""
                        return true
                    }
                    if model.showHistoryFilter {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                            model.showHistoryFilter = false
                        }
                        return true
                    }
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                        model.collapseHistory()
                    }
                    return true
                }
                model.fullClose()
                return true
            }
            // ← goes "back" to a fresh conversation from the thread view — also
            // while the answer is still loading/streaming (the back chevron is
            // visible then, and the round finishes detached into Recent). Only
            // when the follow-up field is empty, so a left-arrow while editing
            // still just moves the caret instead of leaving the thread.
            if event.keyCode == 123, model.mode != .idle, !model.hasText {
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
    @Environment(\.notchMetrics) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the black bleeds above the screen's top edge, guaranteeing no gap.
    private let topBleed: CGFloat = 6

    /// The transient "entry kick" — the cursor's momentum, absorbed by the
    /// glass. Set to a small displacement in the direction of approach the
    /// instant the island opens, then released to zero on an underdamped
    /// spring, so the form gets gently shoved and settles back. Deliberately
    /// subtle: the island is hinged to the bezel, so this reads as the material
    /// giving, never as the island flying around.
    @State private var kick = EntryKick.zero

    /// THIS screen's open state — gated on `activeDisplay` so hovering one
    /// screen's notch never unfurls the islands on the others. Every read that
    /// used to consult `model.open` goes through here (including the animation
    /// `value:`s — a display *switch* flips this while `model.open` stays true,
    /// and the fold/unfurl must still animate).
    private var isOpen: Bool {
        model.isOpen(on: metrics.displayID)
    }

    private var width: CGFloat {
        isOpen ? model.openWidth : Tokens.notchWidth
    }

    private var bottomRadius: CGFloat {
        isOpen ? 30 : Tokens.notchRestRadius
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
                // No camera dot on screens without a real camera housing — a
                // fake lens on an external monitor reads as a smudge, not charm.
                if !isOpen, metrics.hasHardwareNotch {
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
            .frame(height: metrics.restHeight + topBleed)

            // The glass body unfurls below the notch zone when open.
            if isOpen {
                NotchBody(model: model)
                    .transition(.opacity)
            }
        }
        .frame(width: width)
        .padding(.top, -topBleed)   // pull the form up so it bleeds off the top
        .background(GlassMaterial(bottomRadius: bottomRadius,
                                  expanded: isOpen,
                                  cameraZone: metrics.restHeight))
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
                        // Two beats, not one: the card fades out first while the
                        // island holds its height, THEN the emptied recent list
                        // collapses on the panel's standard module spring. Clearing
                        // immediately (and outside the transaction) yanked the
                        // island short mid-dismiss, re-centering and clipping the
                        // still-fading card — a visible jump.
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            model.confirmingClear = false
                        } completion: {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                                model.clearHistory()
                            }
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .clipShape(NotchShape(bottomRadius: bottomRadius))
        // The "slab of glass" look (per the reference): the dark body holds and
        // stays readable, the top reads near-solid and the lower body eases more
        // translucent (that vertical gradient lives in GlassMaterial's veil), and
        // the EDGES are defined by a lit beveled rim — bright along the bottom and
        // sides, brightest at the rounded corners. Stamped on top of the composited
        // island so the highlight traces the edge crisply instead of being clipped.
        .overlay(IslandRim(shape: NotchShape(bottomRadius: bottomRadius)))
        // The entry kick deforms the whole composited island — anchored at the
        // top edge so it hinges off the bezel. The system glass backdrop does
        // NOT ride along with SwiftUI render transforms, so the deform briefly
        // desyncs the veil/rim from the glass region — but with the panel's
        // base darkening baked into the glass material itself (see
        // `nativeGlass(in:)`), the slivers that escape on either side read as
        // the same smoked glass / dark veil, not a bright band. That's what
        // makes the whole-island lean safe; on the content alone the kick was
        // imperceptible (it plays out while the body is still fading in).
        // `ignoredByLayout()` keeps the deform render-only: nothing reads the
        // island's transformed frame, and letting layout see it would force
        // anchor/geometry recomputation on every frame of the kick — right on
        // top of the open spring's own per-frame layout work.
        .modifier(EntryKickEffect(tx: kick.tx, shear: kick.shear, squash: kick.squash).ignoredByLayout())
        .contentShape(NotchShape(bottomRadius: bottomRadius))
        // Spring expand (eased by how hard the cursor arrived — see
        // `openSpring`); snappier, non-springy collapse — distinct in/out feel.
        .animation(isOpen ? openSpring : .easeOut(duration: 0.30), value: isOpen)
        // The kick fires on the open *edge*, reading the entry vector the hover
        // just recorded. Closing lets any residual kick decay on its own.
        .onChange(of: isOpen) { _, nowOpen in
            if nowOpen { applyEntryKick() }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: model.openWidth)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: model.mode)
        // The note-save feedback line (Saving… → Added to Notes → gone) changes the
        // body's intrinsic height. Without these, only the inner idleView spring
        // governed that change — it animates the line's own fade/scale but does NOT
        // propagate up to this island's frame, glass background, or clip shape, so
        // the outer form resized on a mismatched (or no) transaction while the inner
        // text eased out. Keying the island's grow/shrink on the same note states,
        // with the SAME spring idleView uses (response 0.42, damping 0.82), makes the
        // whole island — content and glass shell — settle as one smooth motion.
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.noteSaving)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.lastSavedNote)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: model.noteError)
        .onHover { inside in
            if inside {
                model.openPanel(on: metrics.displayID,
                                velocity: MouseVelocityTracker.shared.entryVelocity())
            } else {
                model.collapseOnLeave(from: metrics.displayID)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)   // center within canvas
    }

    // MARK: - Entry physics

    /// 0…1 measure of how energetically the cursor arrived. √-compressed so the
    /// difference between a lazy drift and a normal move reads, while slamming
    /// the mouse can't push past the cap.
    private var entryEnergy: CGFloat {
        let v = model.entryVelocity
        let speed = (v.dx * v.dx + v.dy * v.dy).squareRoot()
        return min(speed / 2500, 1).squareRoot()
    }

    /// The unfurl spring, eased by approach speed. The resting end is *calmer*
    /// than the old fixed spring (longer response, more damping — an unhurried
    /// bloom); a fast entry only tightens it back to roughly the old feel, so
    /// momentum shows up as the energetic end of the range, never as haste
    /// beyond what the panel already had.
    private var openSpring: Animation {
        guard !reduceMotion else {
            return .spring(response: 0.50, dampingFraction: 0.85)
        }
        let s = entryEnergy
        return .spring(response: 0.50 - 0.06 * s,
                       dampingFraction: 0.82 - 0.10 * s)
    }

    /// Seed the kick from the entry vector, then release it. Two writes on
    /// purpose: the displacement lands in a no-animation transaction (one
    /// imperceptible frame — it reads as the island being struck), and the
    /// release to zero rides a soft underdamped spring, giving one gentle
    /// wobble that settles. All gains are deliberately small — a hint of give,
    /// not a stunt.
    private func applyEntryKick() {
        guard !reduceMotion else { return }
        let v = model.entryVelocity
        let speed = (v.dx * v.dx + v.dy * v.dy).squareRoot()
        // A slow deliberate approach gets no kick at all — the physics only
        // wakes up once there's real momentum to absorb.
        guard speed > 250 else { return }

        var seeded = EntryKick.zero
        // Sideways momentum: a slight nudge plus a top-hinged lean (shear), the
        // bottom edge trailing in the direction of travel.
        seeded.tx = max(-5, min(5, v.dx * 0.003))
        seeded.shear = max(-0.025, min(0.025, v.dx * 0.000015))
        // Upward momentum (dy < 0): the glass compresses a touch, absorbing the
        // hit. The clamp is asymmetric — compression reads as material give,
        // but there's almost no stretch case (you can't approach from above).
        seeded.squash = max(-0.030, min(0.010, v.dy * 0.000020))

        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { kick = seeded }
        withAnimation(.spring(response: 0.60, dampingFraction: 0.62)) {
            kick = .zero
        }
    }
}

/// The components of the entry kick, in render terms: a horizontal nudge (pt),
/// a top-hinged x-shear (x shift per pt of y), and a vertical squash (scaleY
/// delta, negative = compressed).
struct EntryKick: Equatable {
    var tx: CGFloat = 0
    var shear: CGFloat = 0
    var squash: CGFloat = 0
    static let zero = EntryKick()
}

/// Renders the entry kick as one affine transform anchored at the island's
/// top-center — the point where the glass meets the bezel, which must never
/// move. Volume is loosely conserved: vertical squash buys a little horizontal
/// spread, which is what sells the jelly read over a flat scale.
struct EntryKickEffect: GeometryEffect {
    var tx: CGFloat
    var shear: CGFloat
    var squash: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(tx, AnimatablePair(shear, squash)) }
        set {
            tx = newValue.first
            shear = newValue.second.first
            squash = newValue.second.second
        }
    }


    func effectValue(size: CGSize) -> ProjectionTransform {
        let sy = 1 + squash
        let sx = 1 - squash * 0.5
        let recenter = CGAffineTransform(translationX: -size.width / 2, y: 0)
        let deform = CGAffineTransform(a: sx, b: 0, c: shear, d: sy, tx: 0, ty: 0)
        let back = CGAffineTransform(translationX: size.width / 2 + tx, y: 0)
        return ProjectionTransform(recenter.concatenating(deform).concatenating(back))
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
                    // One catcher lives in every per-screen panel, and local
                    // monitors all see every app key event — only the panel that
                    // actually holds the keyboard may act, or N panels would each
                    // consume/act on the same Esc.
                    guard let self, self.window?.isKeyWindow == true else { return event }
                    if self.handler?(event) == true { return nil }
                    return event
                }
            }
        }
        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}
