import AppKit
import SwiftUI

/// Release-notes source for the "What's New" panel. The notes ship *inside* the
/// app bundle — there's no network fetch — so the panel always has exactly the
/// notes that were built into this copy of Notch, online or off.
///
/// To publish notes for a new release, add an entry to `bundled` below (newest
/// versions can go anywhere in the list — they're sorted newest-first for you)
/// and ship the build. That's the single place to edit.
///
/// The "first launch after an update shows what changed once" behaviour is owned
/// here: `unseenVersion` compares the running build against the last version the
/// user actually saw the panel for, and `markSeen()` records the current one.
@MainActor
final class WhatsNewService: ObservableObject {
    static let shared = WhatsNewService()

    /// One published release. `version` is the only required field; `date` is an
    /// optional adornment. The notes are split into two sections the panel renders
    /// under their own headings — `features` (what's new) and `fixes` (what got
    /// fixed). Either can be empty; an empty section is omitted entirely.
    struct Entry: Identifiable, Equatable {
        var version: String
        var date: String?
        var features: [String]
        var fixes: [String]

        var id: String { version }

        init(
            version: String,
            date: String? = nil,
            features: [String] = [],
            fixes: [String] = []
        ) {
            self.version = version; self.date = date
            self.features = features; self.fixes = fixes
        }
    }

    /// The release notes to render — newest first. Bundled, so always populated.
    @Published private(set) var entries: [Entry]

    /// The version (e.g. "1.0.5") to announce in the idle input cue, or `nil` once
    /// the user has seen the notes for this build. Resolved once at launch (a pure
    /// `@Published` the view can read on every render) and cleared by `markSeen()`.
    @Published private(set) var unseenVersion: String?

    // MARK: - Source

    /// The release notes, written straight into the app. **Edit here each release.**
    ///
    /// Each release has two sections — `features` (what's new) and `fixes` (what
    /// got fixed). Write for the user, not the code: say what changed for *them*
    /// and why it's nice, in plain language. Skip internal/refactor churn they'd
    /// never notice. Leave a section empty (omit it) if there's nothing for it.
    /// English-only by design. Order doesn't matter — `sorted` puts the newest
    /// version first. Each string is one bullet; no leading `•`.
    private static let bundled: [Entry] = [
        Entry(
            version: "1.0.7",
            date: "2026-06-22",
            features: [
                "Double-tap ⌥ to summon Notch — the new default shortcut.",
                "Choose which clipboard quick-tools (Summarize, Translate, Proofread…) show up, in Settings → General.",
                "Closing now settles with a soft spring instead of snapping shut.",
            ],
            fixes: [
                "Long clipboard summaries and translations are no longer cut off mid-thought.",
                "Timed reminders no longer occasionally lose their time and never fire.",
            ]
        ),
        Entry(
            version: "1.0.6",
            date: "2026-06-19",
            features: [
                "Set a global shortcut to summon Notch (default ⌥Space) in Settings → General.",
                "Chinese relative dates now become reminders.",
                "Closing now fades the content out before the shell retracts.",
            ],
            fixes: [
                "Chinese/Japanese/Korean input candidates now show above the island while typing.",
                "Re-granting Reminders access after revoking it no longer needs a restart.",
                "A corrupted Recent entry no longer wipes the whole history.",
                "Interrupted answers are marked instead of cut off silently.",
            ]
        ),
        Entry(
            version: "1.0.5",
            date: "2026-06-19",
            features: [
                "Copied text now previews inside the prompt without collapsing Recent.",
                "Clipboard actions show one chip; the rest unfurl on hover.",
                "\"What's New\" is now a permanent link in Settings.",
            ],
            fixes: [
                "Saving to Apple Notes is more reliable, including non-English Notes folders.",
                "Recent rows no longer leave a text halo when scrolling behind the prompt.",
            ]
        ),
        Entry(
            version: "1.0.4",
            date: "2026-06-18",
            features: [
                "After an update, a quiet \"what's new\" hint shows up next to the prompt.",
                "Press ⌘↵ from the prompt to read what changed in each release, any time.",
            ]
        ),
        Entry(
            version: "1.0.3",
            date: "2026-06-10",
            features: [
                "Notch wakes up noticeably faster when you first hover.",
            ],
            fixes: [
                "Coming back from Settings now lands you right back in the prompt.",
            ]
        ),
    ]

    private let lastSeenVersionKey = "whatsnew_last_seen_version"

    /// Debug switch: when on, the cue and panel always appear and never record
    /// "seen", so What's New can be re-opened any number of times. Off by default.
    /// Flip it without a rebuild via either:
    ///   · `defaults write com.notchglass.app whatsnew_always_show -bool YES`
    ///   · launching with the `NOTCH_WHATSNEW_ALWAYS=1` environment variable
    /// (Set the default back to NO / unset the env var to restore normal once-per
    /// -version behaviour.)
    static let alwaysShowKey = "whatsnew_always_show"
    static var alwaysShow: Bool {
        if let env = ProcessInfo.processInfo.environment["NOTCH_WHATSNEW_ALWAYS"],
           env == "1" || env.lowercased() == "true" {
            return true
        }
        return UserDefaults.standard.bool(forKey: alwaysShowKey)
    }

    private init() {
        entries = Self.sorted(Self.bundled)
        unseenVersion = Self.resolveUnseenVersion(key: lastSeenVersionKey)
    }

    // MARK: - "Seen once per version"

    /// The running build, normalized to the same string `UpdaterService` compares.
    private var currentVersion: String { UpdaterService.currentVersion }

    /// Resolve, once at launch, whether the cue should announce this build — and
    /// record a baseline on a brand-new install so the very first launch stays
    /// quiet. A first-ever launch (no stored version) is treated as "seen": we
    /// don't pop What's New before the user has done anything. Only a genuine
    /// version *change* from a known baseline announces.
    private static func resolveUnseenVersion(key: String) -> String? {
        let current = UpdaterService.currentVersion
        // Debug switch wins: always announce, and never record a baseline.
        if alwaysShow { return current }
        guard let seen = UserDefaults.standard.string(forKey: key) else {
            UserDefaults.standard.set(current, forKey: key)
            return nil
        }
        return seen != current ? current : nil
    }

    /// Record that the user has now seen the notes for the running build, so the
    /// cue doesn't fire again until the next update. Clears `unseenVersion`, which
    /// dismisses the input-row cue.
    func markSeen() {
        // With the debug switch on, the cue is meant to persist — don't record a
        // baseline and don't clear the announce, so What's New keeps coming back.
        guard !Self.alwaysShow else { return }
        UserDefaults.standard.set(currentVersion, forKey: lastSeenVersionKey)
        unseenVersion = nil
    }

    // MARK: - Ordering

    /// Newest version first, so the panel leads with the latest release.
    private static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { UpdaterService.isNewer($0.version, than: $1.version) }
    }
}
