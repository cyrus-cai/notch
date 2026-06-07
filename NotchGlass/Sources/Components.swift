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
        if field.stringValue != text { field.stringValue = text }
        applyStyle(to: field)
        // Take focus exactly ONCE per rising edge of focusTrigger. SwiftUI calls
        // updateNSView on every render while the panel is open; without this latch
        // we'd enqueue a `makeFirstResponder` on each pass, piling up async blocks
        // that ping-pong the caret (and, with two PromptFields on screen, fight
        // each other) — a prime suspect for the recurring freeze.
        let coord = context.coordinator
        if focusTrigger {
            if !coord.didFocus, field.window != nil, field.currentEditor() == nil {
                coord.didFocus = true
                DispatchQueue.main.async { [weak field] in
                    guard let field, field.currentEditor() == nil else { return }
                    field.window?.makeFirstResponder(field)
                    Self.disableEditorMagic(field.currentEditor())
                }
            }
        } else {
            coord.didFocus = false   // re-arm for the next open
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
        private let parent: PromptField
        /// One-shot latch: true once we've taken focus for the current rising edge
        /// of `focusTrigger`, reset when it falls. Prevents re-enqueuing focus on
        /// every render. (See updateNSView.)
        var didFocus = false
        init(_ parent: PromptField) { self.parent = parent }

        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            // Editor exists now — strip its completion/prediction behaviours.
            PromptField.disableEditorMagic(field.currentEditor())
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            // Belt-and-suspenders: macOS can re-arm prediction on the editor as
            // you type, so keep it disabled on every change (cheap idempotent set).
            PromptField.disableEditorMagic(field.currentEditor())
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

/// The circular send button — frosted glass at rest, fills white on hover,
/// matching the prototype's `.send-btn`.
struct SendButton: View {
    var compact: Bool = false
    var action: () -> Void
    @State private var hovering = false

    private var size: CGFloat { compact ? 27 : 30 }

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hovering ? Color(white: 0.09) : Tokens.text1)
                .frame(width: size, height: size)
                .background(
                    Circle().fill(hovering ? Color.white.opacity(0.95) : Color.white.opacity(0.12))
                )
                .overlay(
                    Circle().strokeBorder(.white.opacity(hovering ? 0 : 0.22), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: hovering)
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

private extension View {
    /// Wrap the content in a Liquid Glass chip of the given shape — genuine system
    /// glass on macOS 26+, a dark blur fallback below — topped with the same
    /// whisper-thin specular rim the island uses, so it sits in the same material
    /// family. Works for both circular icon chips and capsule text pills.
    @ViewBuilder
    func glassCapsule<S: InsettableShape>(in shape: S, brighter: Bool) -> some View {
        self
            .background {
                if #available(macOS 26.0, *) {
                    shape.fill(.clear)
                        .glassEffect(.clear.interactive(), in: shape)
                } else {
                    LegacyGlassBackdrop().clipShape(shape)
                }
            }
            .overlay(
                shape.fill(.white.opacity(brighter ? 0.10 : 0.04))
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
            )
            // Real Liquid Glass barely casts a shadow — it reads as a thin chip of
            // glass, not a floating card. Just a whisper of a contact shadow to
            // seat it on the island; the specular rim does the rest of the work.
            .shadow(color: .black.opacity(0.10), radius: 1.5, y: 0.5)
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
                    Text("Clear recent history?")
                        .font(.sf(15, weight: .semibold))
                        .foregroundStyle(Tokens.text1)
                    Text("This permanently removes all recent questions. This can't be undone.")
                        .font(.sf(12))
                        .foregroundStyle(Tokens.text3)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    ConfirmDialogButton(title: "Cancel", role: .cancel, action: onCancel)
                    ConfirmDialogButton(title: "Clear History", role: .destructive, action: onConfirm)
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
/// an in-notch assistant actually produces — headings and lists — plus plain
/// paragraphs. Everything else (code fences, quotes, tables) falls through to a
/// paragraph, so unknown syntax still reads cleanly rather than breaking. Inline
/// `**bold**` / `*italic*` / `code` is handled per-line by `InlineMarkdownText`.
enum MarkdownBlock: Identifiable {
    case heading(level: Int, text: String)
    case bullet(text: String)
    case ordered(number: Int, text: String)
    case paragraph(text: String)

    var id: String {
        switch self {
        case .heading(let l, let t):  return "h\(l):\(t)"
        case .bullet(let t):          return "b:\(t)"
        case .ordered(let n, let t):  return "o\(n):\(t)"
        case .paragraph(let t):       return "p:\(t)"
        }
    }
}

/// A line-based markdown parser. Deliberately tiny: it walks the answer line by
/// line and classifies each non-empty line as a heading (`#`…`######`), an
/// unordered item (`-`, `*`, `+`), an ordered item (`1.`, `2)`), or a paragraph.
/// No nesting, no multi-line blocks — enough for short, streamed AI answers and
/// nothing more, in keeping with the app's minimalism (no markdown library).
enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        for rawLine in source.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if let (level, text) = heading(line) {
                blocks.append(.heading(level: level, text: text))
            } else if let text = bullet(line) {
                blocks.append(.bullet(text: text))
            } else if let (number, text) = ordered(line) {
                blocks.append(.ordered(number: number, text: text))
            } else {
                blocks.append(.paragraph(text: line))
            }
        }
        return blocks
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

    private var blocks: [MarkdownBlock] { MarkdownParser.parse(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                row(for: block)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func row(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            // h1 largest, tapering down; all a touch heavier than body text.
            let size = max(baseFont, baseFont + CGFloat(7 - min(level, 5)) * 1.5)
            InlineMarkdownText(text)
                .font(.sf(size, weight: .semibold))
                .tracking(-0.1)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)

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
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
