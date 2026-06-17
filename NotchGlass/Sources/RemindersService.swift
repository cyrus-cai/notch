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
            return L("reminders.error.permission")
        case .noList:
            return L("reminders.error.noList")
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

    // MARK: - Recurrence detection

    /// The repeat pattern named in `text`, or `nil` for a one-shot line. This is
    /// the keyword companion to `futureDate(in:)`: NSDataDetector finds *when* the
    /// first fire is, this finds *whether it repeats*. Plain lowercased substring
    /// checks (no regex — avoids escaping pitfalls) over the phrasings the app's
    /// users actually type, EN + 中文. A `.weekly(nil)` means "repeats weekly but no
    /// specific weekday was named" — `write` resolves that to the due date's own
    /// weekday (so "remind me weekly" typed on a Thursday repeats on Thursdays).
    /// Weekday-specific patterns are checked BEFORE the generic weekly fallback.
    enum RecurrenceKind: Equatable {
        case daily
        case weekly(EKWeekday?)
        case monthly
    }

    static func recurrenceKind(in text: String) -> RecurrenceKind? {
        let s = text.lowercased()
        func has(_ needles: [String]) -> Bool { needles.contains { s.contains($0) } }

        // Monthly — checked first so "每月" / "monthly" never get shadowed by a
        // stray "week"/"day" substring elsewhere in the line.
        if has(["every month", "each month", "monthly", "每月", "每个月"]) {
            return .monthly
        }

        // Specific weekday (EN + 中文) — must precede the generic weekly check.
        let weekdayMap: [(needles: [String], day: EKWeekday)] = [
            (["every monday", "every mon ", "每周一", "每週一", "每星期一", "每礼拜一"], .monday),
            (["every tuesday", "每周二", "每週二", "每星期二", "每礼拜二"], .tuesday),
            (["every wednesday", "每周三", "每週三", "每星期三", "每礼拜三"], .wednesday),
            (["every thursday", "每周四", "每週四", "每星期四", "每礼拜四"], .thursday),
            (["every friday", "每周五", "每週五", "每星期五", "每礼拜五"], .friday),
            (["every saturday", "每周六", "每週六", "每星期六", "每礼拜六"], .saturday),
            (["every sunday", "每周日", "每周天", "每週日", "每星期日", "每星期天", "每礼拜日", "每礼拜天"], .sunday),
        ]
        for entry in weekdayMap where has(entry.needles) {
            return .weekly(entry.day)
        }

        // Generic weekly (no day named) — resolved against the due date in `write`.
        if has(["every week", "each week", "weekly", "每周", "每週", "每星期", "每礼拜"]) {
            return .weekly(nil)
        }

        // Daily.
        if has(["every day", "each day", "everyday", "daily", "every morning",
                "every night", "every evening",
                "每天", "每日", "每早", "每晚", "每天早上", "每晚上"]) {
            return .daily
        }

        return nil
    }

    /// A *synthetic* base date for a recurrence phrase that names no concrete time
    /// — "每天喝水", "remind me every Monday", "monthly rent". Called by NotchModel
    /// ONLY as a fallback when `futureDate(in:)` returns nil, so that dateless
    /// recurring lines still produce a non-nil `detectedDue` and therefore route to
    /// Reminders instead of falling into the Notes branch. Returns nil when there's
    /// no recurrence keyword at all (so `futureDate` stays the sole authority for
    /// ordinary lines). All synthetic times anchor to 9am, the least-surprising
    /// default for "every X" with no clock time.
    static func recurrenceDate(in text: String) -> Date? {
        guard let kind = recurrenceKind(in: text) else { return nil }
        let cal = Calendar.current
        let now = Date()
        switch kind {
        case .daily:
            // Tomorrow at 9am.
            let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
            return cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
        case .weekly(let day):
            if let day {
                // Next occurrence of that weekday at 9am.
                let comps = DateComponents(hour: 9, minute: 0,
                                           weekday: calendarWeekday(from: day))
                return cal.nextDate(after: now, matching: comps,
                                    matchingPolicy: .nextTime)
            }
            // No specific day → tomorrow 9am (weekday derived from this in `write`).
            let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
            return cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
        case .monthly:
            // First of next month at 9am.
            guard let nextMonth = cal.date(byAdding: .month, value: 1, to: now)
            else { return nil }
            var c = cal.dateComponents([.year, .month], from: nextMonth)
            c.day = 1; c.hour = 9; c.minute = 0; c.second = 0
            return cal.date(from: c)
        }
    }

    /// EKWeekday (Sunday = 1 ... Saturday = 7) → Calendar's `.weekday` int, which
    /// uses the same 1...7 Sunday-first convention. Kept explicit so the mapping is
    /// obvious at the call site rather than relying on the raw values lining up.
    private static func calendarWeekday(from day: EKWeekday) -> Int { day.rawValue }

    /// Inverse of `calendarWeekday(from:)`: Calendar's `.weekday` int (1...7,
    /// Sunday-first) → EKWeekday, used to derive a bare "weekly" line's repeat day
    /// from its due date. Falls back to Sunday for an out-of-range value (can't
    /// happen for a real date, but keeps the initializer total).
    private static func ekWeekday(from calendarWeekday: Int) -> EKWeekday {
        EKWeekday(rawValue: calendarWeekday) ?? .sunday
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
    /// On success the value is a deep link to the saved reminder
    /// (`x-apple-reminderkit://REMCDReminder/<externalID>`), so the record row can
    /// jump back to it; `nil` when EventKit gave back no external identifier
    /// (treated as a soft success — the reminder exists, we just can't link it).
    static func createReminder(_ text: String, due: Date?,
                               completion: @escaping @MainActor (Result<String?, RemindersError>) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Task { @MainActor in completion(.success(nil)) }
            return
        }
        store.requestFullAccessToReminders { granted, _ in
            let result: Result<String?, RemindersError> =
                granted ? write(trimmed, due: due) : .failure(.permissionDenied)
            Task { @MainActor in completion(result) }
        }
    }

    /// Deep link that opens a specific reminder in Reminders.app, built from its
    /// `calendarItemExternalIdentifier` (the iCloud/server UUID, stable for
    /// iCloud-backed lists — the common case). The `REMCDReminder/` path segment
    /// is what makes Reminders navigate to the item rather than just opening to
    /// its default view. The scheme is undocumented but has worked from macOS
    /// Monterey through Tahoe; `openCapture` falls back to opening the app if it
    /// ever stops resolving.
    static func deepLink(externalID: String) -> String {
        "x-apple-reminderkit://REMCDReminder/\(externalID)"
    }

    /// The actual EventKit save. Runs on whatever queue the access callback
    /// arrives on; the store is thread-safe.
    private static func write(_ text: String, due: Date?) -> Result<String?, RemindersError> {
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

            // If the line names a repeat ("every Monday", "每天", "monthly"), attach
            // the matching recurrence rule so the reminder actually repeats instead
            // of firing once and vanishing. Only when there IS a due date — a
            // dateless reminder with infinite recurrence reads as broken in the
            // Reminders app, so a Tab-forced dateless line stays one-shot.
            if let kind = recurrenceKind(in: text) {
                let rule: EKRecurrenceRule
                switch kind {
                case .daily:
                    rule = EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
                case .weekly(let day):
                    // A named weekday repeats on that day; a bare "weekly" repeats on
                    // the due date's own weekday (least surprise).
                    let weekday = day ?? ekWeekday(from:
                        Calendar.current.component(.weekday, from: due))
                    rule = EKRecurrenceRule(
                        recurrenceWith: .weekly, interval: 1,
                        daysOfTheWeek: [EKRecurrenceDayOfWeek(weekday)],
                        daysOfTheMonth: nil, monthsOfTheYear: nil,
                        weeksOfTheYear: nil, daysOfTheYear: nil,
                        setPositions: nil, end: nil)
                case .monthly:
                    rule = EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
                }
                reminder.addRecurrenceRule(rule)
            }
        }
        do {
            try store.save(reminder, commit: true)
            // `calendarItemExternalIdentifier` is only populated after the commit
            // succeeds; read it now to build the row's jump-back link. Empty/absent
            // → nil link (soft success: the reminder saved, it just won't deep-link).
            let link: String?
            if let externalID = reminder.calendarItemExternalIdentifier, !externalID.isEmpty {
                link = deepLink(externalID: externalID)
            } else {
                link = nil
            }
            return .success(link)
        } catch {
            return .failure(.saveFailed(error.localizedDescription))
        }
    }
}
