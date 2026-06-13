import EventKit
import Foundation

/// Why a reminder write failed, so the idle view can show the right recovery
/// hint (grant Reminders access vs. a generic retry) instead of a raw
/// EventKit message.
enum RemindersError: LocalizedError {
    /// TCC denied Reminders access (or the user clicked "Don't Allow").
    case permissionDenied
    /// No default list to file into (no Reminders account configured).
    case noList
    /// Anything else, carrying the EventKit message for debugging.
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Allow access in System Settings → Privacy & Security → Reminders."
        case .noList:
            return "No Reminders list found. Open the Reminders app once, then try again."
        case .saveFailed(let msg):
            return msg
        }
    }
}

/// Files time-bound lines into Apple's Reminders app via EventKit.
///
/// This is the second half of the note branch's split: the intent engine only
/// decides ask-vs-note (a *semantic* read); whether a note is a **reminder** is
/// a *structural* read — does the line name a future point in time? — answered
/// deterministically by `futureDate(in:)` below. The date that decides the
/// routing is the same date filed as the reminder's due date, so the "Remind"
/// hint and the alarm that fires later can never disagree.
///
/// Unlike `NotesService` there's no AppleScript here: EventKit talks to the
/// reminders store directly. `requestFullAccessToReminders` is natively async
/// (its callback arrives off-main after the one-time TCC prompt), so the
/// main-thread deadlock dance the Notes path needs doesn't apply.
enum RemindersService {
    /// One store for the app's lifetime — EKEventStore is documented
    /// thread-safe, and the TCC grant is remembered per store connection.
    private static let store = EKEventStore()

    // MARK: - Date detection (what makes a note a reminder)

    /// System date parser — handles natural phrasing in the languages the app
    /// targets ("明天下午三点", "周日早上十点", "tomorrow 3pm", "friday").
    /// Created once; matching a one-line string costs well under a millisecond,
    /// so callers can run it synchronously per keystroke.
    private static let detector =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

    /// The first *future* moment named in `text`, or `nil` when there isn't one.
    /// Past references ("上周五买的牛奶过期了", "met john last tuesday") return
    /// dates behind now and are filtered out — remembering the past is a note,
    /// not a reminder.
    static func futureDate(in text: String) -> Date? {
        guard let detector, !text.isEmpty else { return nil }
        let now = Date()
        return detector
            .matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
            .compactMap(\.date)
            .first { $0 > now }
    }

    // MARK: - Write

    /// Create a reminder from `text`, then call `completion` back **on the main
    /// thread** with the outcome. The first call shows the one-time TCC
    /// "access Reminders" prompt; everything after the prompt runs on EventKit's
    /// own queue, so this never blocks the caller.
    ///
    /// `due` is optional on purpose: a Tab override can force a line with no
    /// parseable time into Reminders — it files as a dateless reminder (shows in
    /// the list, just no alarm).
    static func createReminder(_ text: String, due: Date?,
                               completion: @escaping @MainActor (Result<Void, RemindersError>) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Task { @MainActor in completion(.success(())) }
            return
        }
        store.requestFullAccessToReminders { granted, _ in
            let result: Result<Void, RemindersError> =
                granted ? write(trimmed, due: due) : .failure(.permissionDenied)
            Task { @MainActor in completion(result) }
        }
    }

    /// The actual EventKit save. Runs on whatever queue the access callback
    /// arrives on; the store is thread-safe.
    private static func write(_ text: String, due: Date?) -> Result<Void, RemindersError> {
        guard let list = store.defaultCalendarForNewReminders() else {
            return .failure(.noList)
        }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        // Reminders titles are single-line: first line becomes the title, any
        // further lines ride along in the notes field rather than being lost.
        let parts = text.split(separator: "\n", maxSplits: 1,
                               omittingEmptySubsequences: false)
        reminder.title = String(parts[0])
        if parts.count > 1 {
            let rest = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty { reminder.notes = rest }
        }
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
            // The due date alone shows in the list but doesn't ring; the alarm is
            // what actually notifies at that moment.
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        do {
            try store.save(reminder, commit: true)
            return .success(())
        } catch {
            return .failure(.saveFailed(error.localizedDescription))
        }
    }
}
