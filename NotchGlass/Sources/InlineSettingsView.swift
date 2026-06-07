import SwiftUI

/// Settings rendered *inside* the notch panel, in place of the recent list —
/// not a separate window. Carries the same logic as the old native `SettingsView`
/// (active provider, its API key, an optional model override, all in
/// `UserDefaults` via `APIKeyStore`) but wears the panel's Liquid Glass skin so it
/// reads as part of the island. The gear and ⌘, both swap the RECENT block for
/// this; the back chevron returns to the idle prompt.
struct InlineSettingsView: View {
    @ObservedObject var model: NotchModel

    @State private var provider: Provider = APIKeyStore.selectedProvider
    @State private var apiKey: String = APIKeyStore.stored(for: APIKeyStore.selectedProvider)
    /// Empty string = "use the provider's default" (the sentinel the model menu's
    /// "Default (…)" row binds to).
    @State private var modelID: String = APIKeyStore.storedModel(for: APIKeyStore.selectedProvider)
    @State private var saved = false

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

    private var canSave: Bool {
        guard !envOverride else { return false }
        return apiKey != APIKeyStore.stored(for: provider)
            || modelID != APIKeyStore.storedModel(for: provider)
    }

    /// Every option plus, if the saved model isn't in the live/bundled list (a
    /// custom or newly-renamed one), that value too — so selecting it round-trips.
    private var modelRows: [String] {
        var rows = modelOptions
        if !modelID.isEmpty, !rows.contains(modelID) { rows.insert(modelID, at: 0) }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 14) {
                providerRow
                keyRow
                modelRow
                footer
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)
        }
        .task { await refreshModels() }
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
        NotificationCenter.default.post(name: .aiBackendChanged, object: nil)
        Task { await refreshModels() }
    }

    private var keyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("API key")
                    .font(.sf(13, weight: .medium))
                    .foregroundStyle(Tokens.text2)
                Spacer()
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
                // One control: the button itself flips to "Saved" for a beat after
                // a save, then settles back to "Save" — no separate badge, no green
                // checkmark, just the panel's own light text.
                Button(saved ? "Saved" : "Save") { save() }
                    .buttonStyle(.plain)
                    .font(.sf(11, weight: .semibold))
                    .foregroundStyle(saved ? Tokens.text2 : (canSave ? Tokens.text1 : Tokens.text4))
                    .disabled(!canSave && !saved)
                    .animation(.easeOut(duration: 0.2), value: saved)
            }

            ZStack(alignment: .leading) {
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
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
            .opacity(envOverride ? 0.5 : 1)

            if let result = testResult {
                testVerdict(result)
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
        let tint = result.isOK ? Tokens.success : Tokens.danger
        HStack(spacing: 7) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(result.message)
                .font(.sf(11.5, weight: .medium))
                .foregroundStyle(tint.opacity(0.92))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 0.5)
        )
        .padding(.top, 1)
    }

    /// Whether the Test button is actionable: a non-blank key, not env-overridden,
    /// not already running.
    private var canTest: Bool {
        !testing && !envOverride
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        APIKeyStore.save(apiKey, for: provider)
        APIKeyStore.saveModel(modelID, for: provider)
        apiKey = APIKeyStore.stored(for: provider)
        modelID = APIKeyStore.storedModel(for: provider)
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
