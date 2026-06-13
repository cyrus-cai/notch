import AppKit
import SwiftUI

/// Settings rendered *inside* the notch panel, in place of the recent list —
/// not a separate window. Carries the same logic as the old native `SettingsView`
/// (active provider, its API key, an optional model override, all in
/// `UserDefaults` via `APIKeyStore`) but wears the panel's Liquid Glass skin so it
/// reads as part of the island. The gear and ⌘, both swap the RECENT block for
/// this; the back chevron returns to the idle prompt.
struct InlineSettingsView: View {
    @ObservedObject var model: NotchModel
    /// Self-update state (shared app-wide — the gear badge reads the same object).
    /// Drives the Version row: a quiet number normally, an Update action when a
    /// newer release is known.
    @ObservedObject private var updater = UpdaterService.shared
    /// The one-click OpenRouter OAuth flow. Observed so the Account row tracks
    /// its phases (waiting on the browser, exchanging, failed) live.
    @ObservedObject private var orAuth = OpenRouterAuth.shared

    @State private var provider: Provider = APIKeyStore.selectedProvider
    @State private var apiKey: String = APIKeyStore.stored(for: APIKeyStore.selectedProvider)
    /// Empty string = "use the provider's default" (the sentinel the model menu's
    /// "Default (…)" row binds to).
    @State private var modelID: String = APIKeyStore.storedModel(for: APIKeyStore.selectedProvider)
    @State private var saved = false
    /// False once a key is saved: the row shows a masked, read-only summary of
    /// the stored key (so screenshots never carry the full secret) until the
    /// user explicitly hits Change. Starts true only when nothing is stored.
    @State private var editingKey: Bool =
        APIKeyStore.stored(for: APIKeyStore.selectedProvider).isEmpty
            && !APIKeyStore.hasEnvOverride(for: APIKeyStore.selectedProvider)

    /// Model ids offered in the menu. Seeded from the provider's bundled shortlist,
    /// then replaced by the live `/v1/models` list once it loads (see `refreshModels`).
    @State private var modelOptions: [String] = APIKeyStore.selectedProvider.availableModels
    @State private var loadingModels = false

    /// Connectivity-test state. `testing` drives the spinner; `testResult` is the
    /// last verdict shown under the key field (nil = nothing tested yet).
    @State private var testing = false
    @State private var testResult: ConnectivityTest.Result?

    /// True while an env var forces a key for the current provider — then the field
    /// is informational only, since the env override wins over what's typed.
    private var envOverride: Bool { APIKeyStore.hasEnvOverride(for: provider) }

    /// OpenRouter normally connects via the one-click OAuth row; this flips to the
    /// standard paste field for users who'd rather supply a key by hand.
    @State private var manualKeyEntry = false

    private var canSave: Bool {
        guard !envOverride else { return false }
        let keyChanged = editingKey
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && apiKey != APIKeyStore.stored(for: provider)
        return keyChanged || modelID != APIKeyStore.storedModel(for: provider)
    }

    /// The stored key rendered safe for display: enough of the head and tail to
    /// recognize which key it is, bullets for everything in between. Short keys
    /// mask entirely rather than leak most of their characters.
    private var maskedKey: String {
        let key = APIKeyStore.current(for: provider) ?? APIKeyStore.stored(for: provider)
        guard key.count > 12 else { return String(repeating: "•", count: max(key.count, 8)) }
        return "\(key.prefix(4))••••••••\(key.suffix(4))"
    }

    /// Every option plus, if the saved model isn't in the live/bundled list (a
    /// custom or newly-renamed one), that value too — so selecting it round-trips.
    private var modelRows: [String] {
        var rows = modelOptions
        if !modelID.isEmpty, !rows.contains(modelID) { rows.insert(modelID, at: 0) }
        return rows
    }

    /// The left-hand category list — the point of the column is that the next
    /// setting gets a home without redesigning the panel.
    enum Section: String, CaseIterable, Identifiable {
        case model = "Model"      // provider, API key, model override
        case display = "Display"  // which screens carry a notch island
        case about = "About"      // version + self-update
        var id: String { rawValue }
    }
    @State private var section: Section = .model

    /// Which screens carry an island — mirrors the persisted value; writes go
    /// through `selectPlacement` so `AppDelegate` rebuilds panels immediately.
    @State private var placement: DisplayPlacement = .current

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            HStack(alignment: .top, spacing: 0) {
                sidebar

                // Hairline column boundary, full height of whichever side is taller
                // (the .fixedSize on the HStack is what lets the greedy rectangle
                // resolve to the content height instead of expanding forever).
                Rectangle()
                    .fill(.white.opacity(0.08))
                    .frame(width: 0.5)
                    .frame(maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 14) {
                    switch section {
                    case .model:
                        providerRow
                        // OpenRouter gets the one-click Connect row instead of a
                        // paste field — unless the user asked to paste by hand, or
                        // an env var forces a key (the standard row displays that).
                        if provider == .openrouter && !manualKeyEntry && !envOverride {
                            openRouterAccountRow
                        } else {
                            keyRow
                        }
                        modelRow
                        footer
                    case .display:
                        placementRow
                        placementFooter
                    case .about:
                        aboutSection
                    }
                }
                .padding(.leading, 14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.top, 12)
        }
        .task {
            // Un-throttled freshness check while the user is actually looking at
            // the Version row (one tiny request; failures stay silent).
            updater.check()
            await refreshModels()
        }
        .onChange(of: orAuth.phase) {
            // The OAuth flow just wrote a key from outside this view — sync the
            // cached state, prove the key live (green pill), and load the free
            // model list it unlocks.
            guard orAuth.phase == .connected, provider == .openrouter else { return }
            apiKey = APIKeyStore.stored(for: .openrouter)
            modelID = APIKeyStore.storedModel(for: .openrouter)
            editingKey = false
            manualKeyEntry = false
            orAuth.acknowledge()
            test()
            Task { await refreshModels() }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Section.allCases) { s in
                SidebarItem(
                    title: s.rawValue,
                    selected: section == s,
                    // The gear's update dot continues here: it leads to settings,
                    // then the About entry carries it the rest of the way to the
                    // update action — a quiet neutral dot, never a coloured one.
                    badged: s == .about && isUpdateAvailable
                ) {
                    withAnimation(.easeOut(duration: 0.16)) { section = s }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 96, alignment: .topLeading)
        .padding(.trailing, 12)
    }

    private var isUpdateAvailable: Bool {
        if case .available = updater.phase { return true }
        return false
    }

    /// One category row: quiet text that brightens on hover, a faint fill when
    /// selected — same translucent-chip language as GlassMenu, minus the border.
    private struct SidebarItem: View {
        var title: String
        var selected: Bool
        var badged: Bool
        var action: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.sf(12.5, weight: .medium))
                        .foregroundStyle(selected ? Tokens.text1 : (hovering ? Tokens.text2 : Tokens.text3))
                    if badged {
                        Circle()
                            .fill(Tokens.text2)
                            .frame(width: 5, height: 5)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white.opacity(selected ? 0.08 : (hovering ? 0.04 : 0)))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    model.closeSettings()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.text2)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RecentEntryStyle())
            .help("Back to prompt")

            Text("SETTINGS")
                .font(.sf(10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Tokens.text4)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Rows

    private var providerRow: some View {
        settingRow(label: "Provider") {
            GlassMenu(title: provider.displayName) {
                ForEach(Provider.allCases) { p in
                    Button(p.displayName) { selectProvider(p) }
                }
            }
        }
    }

    /// Persist a provider switch and reload that provider's saved key + model, so
    /// each provider keeps its own settings.
    private func selectProvider(_ newValue: Provider) {
        guard newValue != provider else { return }
        provider = newValue
        APIKeyStore.selectedProvider = newValue
        apiKey = APIKeyStore.stored(for: newValue)
        modelID = APIKeyStore.storedModel(for: newValue)
        modelOptions = newValue.availableModels
        saved = false
        testResult = nil   // last verdict belonged to the old provider/key
        editingKey = apiKey.isEmpty && !APIKeyStore.hasEnvOverride(for: newValue)
        manualKeyEntry = false   // back to the Connect row next time OpenRouter shows
        NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
        Task { await refreshModels() }
    }

    /// The key row keeps the form's two-column grid: label in the left column,
    /// the field in the control column (sharing its left edge with the provider /
    /// model chips), and Test/Save trailing the field as quiet word-buttons —
    /// the action sits right next to the thing it acts on.
    private var keyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("API key")
                    .font(.sf(13, weight: .medium))
                    .foregroundStyle(Tokens.text2)
                    .frame(width: 64, alignment: .leading)

                ZStack(alignment: .leading) {
                    if editingKey {
                        // Our own placeholder, shown only while empty — SwiftUI's built-in
                        // `prompt:` ignores the color we set and renders its own dim gray,
                        // so we overlay a Text we fully control to get a clean bright hint.
                        if apiKey.isEmpty {
                            Text("Paste your API key")
                                .font(.sf(13))
                                .foregroundStyle(Tokens.text2)
                                .allowsHitTesting(false)
                        }
                        TextField("", text: $apiKey)
                            .textFieldStyle(.plain)
                            .font(.sf(13))
                            .foregroundStyle(Tokens.text1)
                            .disabled(envOverride)
                            // A freshly-pasted key unlocks the live model list.
                            .onSubmit { Task { await refreshModels() } }
                            // Editing the key invalidates the last connectivity verdict.
                            .onChange(of: apiKey) { testResult = nil }
                    } else {
                        // Saved state: a masked, read-only summary — the full key
                        // never sits on screen where a screenshot would catch it.
                        Text(maskedKey)
                            .font(.sf(13))
                            .foregroundStyle(Tokens.text2)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.white.opacity(editingKey ? 0.06 : 0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(.white.opacity(editingKey ? 0.12 : 0.07), lineWidth: 0.5)
                )
                .opacity(envOverride ? 0.5 : 1)

                if editingKey {
                    // Connectivity test: a token-free probe of the entered key against
                    // the provider, so the user can confirm it works before relying on
                    // it. Disabled while empty, env-overridden, or already running.
                    if testing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Test") { test() }
                            .buttonStyle(.plain)
                            .font(.sf(11, weight: .semibold))
                            .foregroundStyle(canTest ? Tokens.text1 : Tokens.text4)
                            .disabled(!canTest)
                    }
                    // Back out of editing without touching the stored key — only
                    // offered when there is a stored key to fall back to.
                    if !APIKeyStore.stored(for: provider).isEmpty {
                        Button("Cancel") { stopEditingKey() }
                            .buttonStyle(.plain)
                            .font(.sf(11, weight: .semibold))
                            .foregroundStyle(Tokens.text2)
                    }
                } else if !envOverride {
                    // Saved state still allows a quick liveness check of the
                    // stored key, plus the way back into editing.
                    if testing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Test") { test() }
                            .buttonStyle(.plain)
                            .font(.sf(11, weight: .semibold))
                            .foregroundStyle(Tokens.text1)
                    }
                    Button("Change") { startEditingKey() }
                        .buttonStyle(.plain)
                        .font(.sf(11, weight: .semibold))
                        .foregroundStyle(Tokens.text1)
                }
                // One control: the button itself flips to "Saved" for a beat after
                // a save, then settles back to "Save" — no separate badge, no green
                // checkmark, just the panel's own light text.
                if editingKey || canSave || saved {
                    Button(saved ? "Saved" : "Save") { save() }
                        .buttonStyle(.plain)
                        .font(.sf(11, weight: .semibold))
                        .foregroundStyle(saved ? Tokens.text2 : (canSave ? Tokens.text1 : Tokens.text4))
                        .disabled(!canSave && !saved)
                        .animation(.easeOut(duration: 0.2), value: saved)
                }
            }

            if let result = testResult {
                testVerdict(result)
                    // Indent under the control column so the verdict hangs off the
                    // field it judges, not the label gutter.
                    .padding(.leading, 76)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// The connectivity-test result, shown as a restrained inline pill rather than
    /// the old harsh filled-circle-plus-red-text. A small status dot (the only
    /// saturated mark), the verdict in a softened status color, sitting on a faint
    /// wash of that same color so it reads as a calm badge inside the glass — green
    /// for a working key, red for a rejected one, never shouting.
    @ViewBuilder
    private func testVerdict(_ result: ConnectivityTest.Result) -> some View {
        statusPill(ok: result.isOK, message: result.message)
    }

    /// The status line under a key/account field. Success reads as a quiet aside —
    /// a small green dot and faint text in the same register as the rest of the
    /// panel — while a failure keeps the louder red pill so a real problem still
    /// catches the eye.
    @ViewBuilder
    private func statusPill(ok: Bool, message: String) -> some View {
        if ok {
            Text(message)
                .font(.sf(11.5))
                .foregroundStyle(Tokens.text3)
                .padding(.top, 1)
        } else {
            // A failure stays a touch heavier so it reads as a problem, but in the
            // same neutral ink as the rest of the panel — no coloured dot, no pill.
            Text(message)
                .font(.sf(11.5, weight: .medium))
                .foregroundStyle(Tokens.text2)
                .padding(.top, 1)
        }
    }

    // MARK: - OpenRouter one-click connect

    /// Whether OpenRouter has a stored key. Read straight from the store on each
    /// render — the OAuth flow writes it from outside this view, so a cached
    /// `@State` would go stale the moment Connect succeeds.
    private var openRouterConnected: Bool {
        !APIKeyStore.stored(for: .openrouter).isEmpty
    }

    /// The Account row OpenRouter shows instead of a paste field. Disconnected,
    /// it's one Connect button (browser sign-in → key lands automatically) plus a
    /// quiet manual-paste escape hatch; connected, the familiar masked summary
    /// with Test and Disconnect.
    private var openRouterAccountRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Account")
                    .font(.sf(13, weight: .medium))
                    .foregroundStyle(Tokens.text2)
                    .frame(width: 64, alignment: .leading)

                if openRouterConnected {
                    // Same masked, read-only summary as the saved key row.
                    Text(maskedKey)
                        .font(.sf(13))
                        .foregroundStyle(Tokens.text2)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(.white.opacity(0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
                        )

                    if testing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Test") { test() }
                            .buttonStyle(.plain)
                            .font(.sf(11, weight: .semibold))
                            .foregroundStyle(Tokens.text1)
                    }
                    Button("Disconnect") { disconnectOpenRouter() }
                        .buttonStyle(.plain)
                        .font(.sf(11, weight: .semibold))
                        .foregroundStyle(Tokens.text1)
                } else {
                    switch orAuth.phase {
                    case .waiting, .exchanging:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(orAuth.phase == .exchanging
                                 ? "Connecting…"
                                 : "Finish signing in in your browser…")
                                .font(.sf(12.5))
                                .foregroundStyle(Tokens.text2)
                        }
                        .frame(height: 30)
                        Button("Cancel") { orAuth.cancel() }
                            .buttonStyle(.plain)
                            .font(.sf(11, weight: .semibold))
                            .foregroundStyle(Tokens.text2)
                    default:
                        connectButton
                        Button("Paste a key instead") {
                            orAuth.acknowledge()
                            manualKeyEntry = true
                            startEditingKey()
                        }
                        .buttonStyle(.plain)
                        .font(.sf(11, weight: .semibold))
                        .foregroundStyle(Tokens.text3)
                    }
                }
            }

            if case .failed(let why) = orAuth.phase {
                statusPill(ok: false, message: why)
                    .padding(.leading, 76)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if openRouterConnected, let result = testResult {
                testVerdict(result)
                    .padding(.leading, 76)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// The primary action of the whole onboarding: one click, sign in (or sign
    /// up, free) in the browser, and the key arrives by itself. Slightly brighter
    /// than the surrounding chips because it IS the setup.
    private var connectButton: some View {
        Button {
            testResult = nil
            orAuth.connect()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "link")
                    .font(.system(size: 11, weight: .semibold))
                Text("Connect OpenRouter")
                    .font(.sf(13, weight: .medium))
            }
            .foregroundStyle(Tokens.text1)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(.white.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(.white.opacity(0.20), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    /// Drop the stored OpenRouter key and return the row to its Connect state.
    /// (The key created during Connect stays in the user's OpenRouter account —
    /// they can revoke it at openrouter.ai/settings/keys.)
    private func disconnectOpenRouter() {
        APIKeyStore.save("", for: .openrouter)   // empty clears the entry
        apiKey = ""
        testResult = nil
        orAuth.acknowledge()
        editingKey = true
        NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
        Task { await refreshModels() }
    }

    /// Whether the Test button is actionable: a non-blank key, not env-overridden,
    /// not already running.
    private var canTest: Bool {
        !testing && !envOverride
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Swap the masked summary for an empty field ready for a fresh paste —
    /// editing never re-surfaces the stored secret on screen.
    private func startEditingKey() {
        apiKey = ""
        testResult = nil
        withAnimation(.easeOut(duration: 0.16)) { editingKey = true }
    }

    /// Abandon the edit and fall back to the stored key's masked summary.
    private func stopEditingKey() {
        apiKey = APIKeyStore.stored(for: provider)
        testResult = nil
        withAnimation(.easeOut(duration: 0.16)) { editingKey = false }
    }

    /// What the model chip shows: the saved id, or the resolved default when the
    /// sentinel empty string is selected.
    private var modelLabel: String {
        modelID.isEmpty ? "Default (\(provider.defaultModel))" : modelID
    }

    private var modelRow: some View {
        settingRow(label: "Model") {
            HStack(spacing: 6) {
                GlassMenu(title: modelLabel) {
                    Button("Default (\(provider.defaultModel))") { modelID = "" }
                    Divider()
                    ForEach(modelRows, id: \.self) { id in
                        Button(id) { modelID = id }
                    }
                }
                .disabled(envOverride)
                .opacity(envOverride ? 0.5 : 1)
                if loadingModels {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    /// Which screens carry a notch island. External monitors get a virtual
    /// notch that nests inside their menu bar; the choice applies immediately
    /// (AppDelegate listens and rebuilds the per-screen panels).
    private var placementRow: some View {
        settingRow(label: "Show on") {
            GlassMenu(title: placement.label) {
                ForEach(DisplayPlacement.allCases) { p in
                    Button(p.label) { selectPlacement(p) }
                }
            }
        }
    }

    private func selectPlacement(_ newValue: DisplayPlacement) {
        guard newValue != placement else { return }
        placement = newValue
        DisplayPlacement.current = newValue
        NotificationCenter.default.post(name: .displayPlacementChanged, object: nil)
    }

    private var placementFooter: some View {
        Text("All displays gives every connected screen its own island — the real notch on this Mac, a menu-bar-height one on external monitors. Hover any of them.")
            .font(.sf(11))
            .foregroundStyle(Tokens.text4)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }

    // MARK: - About

    /// The About pane: who the app is before the version mechanics. An identity
    /// block (name, tagline, one-line description) sits above the Version row so
    /// the panel reads as more than a build number, then a quiet links row hands
    /// off to the source and release pages.
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                // App icon, if the bundle carries one — falls back gracefully.
                if let icon = NSApp.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Notch")
                        .font(.sf(17, weight: .semibold))
                        .foregroundStyle(Tokens.text1)

                    Text(UpdaterService.currentVersion)
                        .font(.sf(12, weight: .medium))
                        .foregroundStyle(Tokens.text4)
                }

                Spacer(minLength: 0)
            }

            updateRow

            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(height: 0.5)

            aboutLinks
        }
    }

    /// The update affordance, shown only when there's something to act on — an
    /// "Update to X" button, an in-flight spinner, or the failure pill. When the
    /// build is current this collapses to nothing; the version under the app name
    /// already says all there is to say.
    private var updateRow: some View {
        Group {
            switch updater.phase {
            case .available(let v):
                Button("Update to \(v)") { updater.update() }
                    .buttonStyle(.plain)
                    .font(.sf(12, weight: .semibold))
                    .foregroundStyle(Tokens.text1)
            case .updating:
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Updating…")
                        .font(.sf(12, weight: .semibold))
                        .foregroundStyle(Tokens.text2)
                }
            case .failed:
                Button {
                    NSWorkspace.shared.open(UpdaterService.releasesPage)
                } label: {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Tokens.danger)
                            .frame(width: 6, height: 6)
                        Text("Update failed — get it from the releases page")
                            .font(.sf(11.5, weight: .medium))
                            .foregroundStyle(Tokens.danger.opacity(0.92))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule(style: .continuous).fill(Tokens.danger.opacity(0.12)))
                    .overlay(Capsule(style: .continuous).strokeBorder(Tokens.danger.opacity(0.22), lineWidth: 0.5))
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            default:
                EmptyView()
            }
        }
        .animation(.easeOut(duration: 0.2), value: updater.phase)
    }

    /// Quiet text-button links — source on GitHub, the releases page — in the
    /// same understated language as the Model footer's signup host.
    private var aboutLinks: some View {
        HStack(spacing: 14) {
            Button("GitHub") {
                NSWorkspace.shared.open(URL(string: "https://github.com/\(UpdaterService.repo)")!)
            }
            .buttonStyle(.plain)
            .font(.sf(11.5, weight: .medium))
            .foregroundStyle(Tokens.text2)

            Button("Releases") {
                NSWorkspace.shared.open(UpdaterService.releasesPage)
            }
            .buttonStyle(.plain)
            .font(.sf(11.5, weight: .medium))
            .foregroundStyle(Tokens.text2)
        }
    }

    private var footer: some View {
        Group {
            if envOverride {
                Text("A key from the \(provider.envVarName) environment variable is in use; it overrides these fields.")
            } else {
                Text(footerText)
            }
        }
        .font(.sf(11))
        .foregroundStyle(Tokens.text4)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 2)
    }

    /// Footer help with the signup host as a clickable link, built as an
    /// `AttributedString` so the sentence stays one `Text` while only the host
    /// opens `provider.signupURL`.
    private var footerText: AttributedString {
        if provider == .openrouter {
            // The free-by-default story: connect once, the key lives in the
            // user's own account, and the daily cap is theirs alone.
            var text = AttributedString("Free to use — Connect signs you in to ")
            var host = AttributedString("openrouter.ai")
            host.link = URL(string: "https://openrouter.ai")
            host.foregroundColor = Tokens.text2
            text.append(host)
            text.append(AttributedString(" and stores a key for your own account on this Mac. Free models have a daily request cap; adding credits there raises it."))
            return text
        }
        var text = AttributedString("Stored on this Mac. Without a key the app uses an offline stub. Get a key at ")
        var host = AttributedString(provider.signupHost)
        host.link = provider.signupURL
        host.foregroundColor = Tokens.text2
        text.append(host)
        text.append(AttributedString("."))
        return text
    }

    // MARK: - Row scaffold

    /// A label-on-the-left, control-on-the-right row, sized so the provider and
    /// model menus line up.
    private func settingRow<Content: View>(
        label: String,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.sf(13, weight: .medium))
                .foregroundStyle(Tokens.text2)
                .frame(width: 64, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    // MARK: - Logic (mirrors the old SettingsView)

    /// Replace `modelOptions` with the provider's *live* model list when a key is
    /// available, so the menu reflects what the vendor serves right now. Falls back
    /// to the bundled shortlist on any failure, so the menu is never empty.
    @MainActor
    private func refreshModels() async {
        let target = provider
        guard let key = APIKeyStore.current(for: target) else {
            modelOptions = target.availableModels
            return
        }
        loadingModels = true
        let live = await ModelCatalog.fetch(for: target, apiKey: key)
        // Guard against a stale response after the user switched providers.
        guard target == provider else { return }
        loadingModels = false
        modelOptions = live ?? target.availableModels
    }

    /// Probe the entered key against the current provider and surface the verdict.
    /// Tests the *typed* key (not the saved one) so the user can verify before
    /// committing. Guarded against overlapping runs via `canTest`/`testing`.
    private func test() {
        guard canTest else { return }
        let target = provider
        let key = apiKey
        testing = true
        testResult = nil
        Task {
            let result = await ConnectivityTest.run(provider: target, apiKey: key)
            await MainActor.run {
                // Drop a stale result if the user switched providers mid-flight.
                guard target == provider else { return }
                testing = false
                withAnimation(.easeOut(duration: 0.2)) { testResult = result }
            }
        }
    }

    private func save() {
        // Only an explicit non-blank edit replaces the stored key — a model-only
        // change saved mid-edit must not wipe it with the empty field.
        if editingKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            APIKeyStore.save(apiKey, for: provider)
        }
        APIKeyStore.saveModel(modelID, for: provider)
        apiKey = APIKeyStore.stored(for: provider)
        modelID = APIKeyStore.storedModel(for: provider)
        if !apiKey.isEmpty {
            withAnimation(.easeOut(duration: 0.16)) { editingKey = false }
        }
        NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
        withAnimation(.easeOut(duration: 0.18)) { saved = true }
        // A newly-saved key may unlock the live model list — refresh it.
        Task { await refreshModels() }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation(.easeOut(duration: 0.3)) { saved = false }
        }
    }
}

/// A dropdown styled to match the panel instead of the stock `Picker`'s
/// white-on-light `.menu` button (which read as a bright patch on the dark
/// glass). The trigger is a translucent dark chip — faint fill, hairline border,
/// light text, a up/down chevron — that brightens on hover; the popped-open list
/// stays the system's native (dark) context menu. `content` supplies the rows as
/// plain `Button`s that mutate the bound selection.
struct GlassMenu<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content

    @State private var hovering = false

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 7) {
                Text(title)
                    .font(.sf(13))
                    .foregroundStyle(Tokens.text1)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
            }
            .padding(.leading, 11)
            .padding(.trailing, 9)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(.white.opacity(hovering ? 0.10 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(.white.opacity(hovering ? 0.20 : 0.12), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
