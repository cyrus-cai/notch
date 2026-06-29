import AppKit
import SwiftUI

/// First-run state for the very first time someone opens Notch.
///
/// First run has two beats, and neither is a separate window — the whole point of
/// "native, not bolted on" is that onboarding looks like the app, not like a tour
/// bolted onto it:
///
///   1. `showGestureHint` — a slow breathing glow at the notch on first launch,
///      with the line "hover — or ⌘,". It teaches the one invisible affordance
///      (how to summon the panel) and dies the first time the panel opens. Its job
///      is only to get the user *to* the panel.
///   2. `showGuide` — once the panel opens, it leads with a short guided flow that
///      lives INSIDE the glass, exactly like Settings and What's New: a few steps
///      that name what Notch does and walk the user through connecting a model
///      (the one real setup step). Rendered in the same material and spring, so it
///      reads as Notch introducing itself, not a wizard. Retired once the user
///      finishes or skips it — and only then; quitting mid-guide re-opens it next
///      launch, so an interrupted first run still gets walked through.
///
/// The "once, ever" behaviour mirrors `WhatsNewService`: `UserDefaults` flags,
/// resolved at launch, flipped when each beat is done. First-run and What's New
/// are deliberately independent (cold install vs. update) but cooperate at one
/// seam: a brand-new install must not stack the What's New panel on top of the
/// guide (see `WhatsNewService`'s "first-ever launch stays quiet" rule, which
/// already suppresses it).
@MainActor
final class OnboardingService: ObservableObject {
    static let shared = OnboardingService()

    /// Whether the breathing gesture hint should still render at the notch. Retires
    /// the first time the panel opens (`markPanelOpened()`).
    @Published private(set) var showGestureHint: Bool

    /// Whether the guided first-run flow should own the idle body. True until the
    /// user finishes or skips it (`finishGuide()`). Survives a mid-guide quit so an
    /// interrupted first run is re-offered the guide on the next launch.
    @Published private(set) var showGuide: Bool

    /// The key recording that the user has opened Notch at least once. Absent on a
    /// brand-new install; written the first time the panel opens. Retires the glow.
    private let openedOnceKey = "onboarding_opened_once"

    /// The key recording that the user has finished (or skipped) the guide. Absent
    /// until then; once set, the guide never leads again.
    private let guideDoneKey = "onboarding_guide_done"

    /// Debug switch: when on, the first-run beats always show and never record
    /// "done", so the gesture glow and the guide can be inspected any number of
    /// times. Off by default. Flip it without a rebuild via either:
    ///   · `defaults write com.notchglass.app onboarding_always_show -bool YES`
    ///   · launching with the `NOTCH_ONBOARDING_ALWAYS=1` environment variable
    /// (Set the default back to NO / unset the env var to restore normal
    /// once-ever behaviour.)
    static let alwaysShowKey = "onboarding_always_show"
    static var alwaysShow: Bool {
        if let env = ProcessInfo.processInfo.environment["NOTCH_ONBOARDING_ALWAYS"],
           env == "1" || env.lowercased() == "true" {
            return true
        }
        return UserDefaults.standard.bool(forKey: alwaysShowKey)
    }

    private init() {
        let forced = Self.alwaysShow
        showGestureHint = forced || !UserDefaults.standard.bool(forKey: openedOnceKey)
        showGuide = forced || !UserDefaults.standard.bool(forKey: guideDoneKey)
    }

    /// Record that Notch has now been opened, retiring the gesture glow. Called the
    /// first time the panel opens (from `AppDelegate`'s open observer). A no-op once
    /// already recorded, so repeated opens cost nothing. Does NOT touch the guide —
    /// the guide retires only when actually finished/skipped, not merely shown.
    func markPanelOpened() {
        guard !Self.alwaysShow else { return }
        guard showGestureHint else { return }
        UserDefaults.standard.set(true, forKey: openedOnceKey)
        showGestureHint = false
    }

    /// Record that the user has finished or skipped the guided flow, so it never
    /// leads again. Clears `showGuide`, which returns the idle body to the prompt.
    func finishGuide() {
        // With the debug switch on, the guide is meant to persist — don't record it
        // done and don't clear the flag, so it keeps coming back for inspection.
        guard !Self.alwaysShow else {
            showGuide = false   // still let THIS run dismiss it
            return
        }
        guard showGuide else { return }
        UserDefaults.standard.set(true, forKey: guideDoneKey)
        showGuide = false
    }
}
