import Foundation
import Carbon.OpenScripting   // kASAppleScriptSuite / kASSubroutineEvent / keyASSubroutineName

/// Why an error happened writing to Notes, so the record view can show the right
/// recovery hint (grant Automation access vs. a generic retry) instead of a raw
/// AppleScript code.
enum NotesError: LocalizedError {
    /// TCC denied Automation access to Notes (or the user clicked "Don't Allow").
    case permissionDenied
    /// Notes.app couldn't be reached / launched.
    case notesUnavailable
    /// Anything else, carrying the raw AppleScript message for debugging.
    case scriptError(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Allow access to Notes in System Settings → Privacy & Security → Automation."
        case .notesUnavailable:
            return "Couldn't reach Notes. Try again."
        case .scriptError(let msg):
            return msg
        }
    }
}

/// Writes typed lines straight into Apple's native Notes app.
///
/// One note per submit: the user's text becomes a new note in the default
/// account's "Notes" folder, with the first line as the title (Notes' own
/// behaviour when only `body` is set).
///
/// The user's text is **never** interpolated into the AppleScript source — it's
/// passed to a named handler as an Apple Event parameter (the injection-safe,
/// "parameterised query" pattern), so quotes / newlines / `¬` in what the user
/// types can't break or hijack the script.
///
/// **Threading — why this runs OFF the main thread.** `executeAppleEvent` blocks
/// the calling thread until the script returns. On the *first* write, macOS shows
/// the TCC "wants access to control Notes" prompt — a modal that needs the **main
/// runloop** to handle the user's click. If we block the main thread inside
/// `executeAppleEvent`, the prompt can paint but never receives the click: the
/// main thread waits on the script, the script waits on the user, the user's
/// click waits on the main thread → the whole app deadlocks (the freeze seen when
/// the permission dialog appeared). So the script runs on a dedicated **serial**
/// background queue, leaving the main runloop free to drive the prompt. The
/// `NSAppleScript` "not thread-safe" caveat is satisfied because the instance is
/// created on, and only ever touched from, that one serial queue — never shared
/// across threads, never run concurrently.
enum NotesService {
    /// A dedicated serial queue that owns the script. Serial = at most one write
    /// at a time, so the single `NSAppleScript` instance is never used concurrently.
    private static let queue = DispatchQueue(label: "com.notchglass.notes-applescript")

    /// The compiled script, created and used **only** on `queue`. Lazily built on
    /// the first write so we don't pay the compile cost at launch. `nil` if it
    /// failed to compile.
    private static var _script: NSAppleScript?
    private static var compiled = false

    /// Compile (once) and return the script. MUST be called on `queue`.
    private static func scriptOnQueue() -> NSAppleScript? {
        if compiled { return _script }
        compiled = true
        // A handler that takes the body as a parameter. Notes' `body` is HTML, so
        // the Swift side escapes the text and turns newlines into <br> before this
        // ever sees it; here we only place it into a new note. Setting only `body`
        // (no `name`) makes Notes use the first line as the title automatically.
        let source = """
        on notchCreateNote(noteBody)
            tell application "Notes"
                make new note at folder "Notes" of default account with properties {body:noteBody}
            end tell
        end notchCreateNote
        """
        let s = NSAppleScript(source: source)
        s?.compileAndReturnError(nil)
        _script = s
        return s
    }

    /// Create a new note from `text`, off the main thread, then call `completion`
    /// back **on the main thread** with the outcome. Safe to call from the main
    /// thread (it won't block it — that's the whole point: see the type comment).
    static func writeNote(_ text: String, completion: @escaping @MainActor (Result<Void, NotesError>) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Nothing to write — treat an empty submit as a (no-op) success.
            Task { @MainActor in completion(.success(())) }
            return
        }
        let body = htmlBody(from: trimmed)

        queue.async {
            let result = runWrite(body: body)
            // Hop back to the main actor to touch any UI/model state.
            Task { @MainActor in completion(result) }
        }
    }

    /// The actual Apple Event send. Runs on `queue`. Returns a typed result rather
    /// than throwing so the queue closure stays simple.
    private static func runWrite(body: String) -> Result<Void, NotesError> {
        guard let script = scriptOnQueue() else {
            return .failure(.scriptError("Couldn't prepare the Notes script."))
        }

        // Build the Apple Event that calls `notchCreateNote(body)` on the script
        // itself, passing the body as a string parameter — user text travels as
        // structured Apple Event data, not as script source.
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil,                          // the script itself
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        // Handler name must be lowercase for the subroutine-call convention.
        event.setParam(NSAppleEventDescriptor(string: "notchcreatenote"),
                       forKeyword: AEKeyword(keyASSubroutineName))
        let args = NSAppleEventDescriptor.list()
        args.insert(NSAppleEventDescriptor(string: body), at: 1)
        event.setParam(args, forKeyword: keyDirectObject)

        var error: NSDictionary?
        script.executeAppleEvent(event, error: &error)
        if let error { return .failure(mapError(error)) }
        return .success(())
    }

    // MARK: - Helpers

    /// Map an AppleScript error dictionary onto a typed `NotesError`, so the UI can
    /// tell "you need to grant permission" apart from a transient failure.
    private static func mapError(_ dict: NSDictionary) -> NotesError {
        let number = dict[NSAppleScript.errorNumber] as? Int ?? 0
        let message = dict[NSAppleScript.errorMessage] as? String ?? "Couldn't save to Notes."
        switch number {
        case -1743, -1744:           // errAEEventNotPermitted / not authorised → TCC denied
            return .permissionDenied
        case -600, -609, -1708:      // procNotFound / connectionInvalid / event not handled
            return .notesUnavailable
        default:
            return .scriptError(message)
        }
    }

    /// Turn plain text into the HTML body Notes expects: escape the markup-significant
    /// characters so the literal text shows through, and convert newlines to `<br>`
    /// (a bare `\n` is swallowed by the HTML body). Order matters — `&` first, so we
    /// don't double-escape the entities we introduce.
    private static func htmlBody(from text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "&", with: "&amp;")
        s = s.replacingOccurrences(of: "<", with: "&lt;")
        s = s.replacingOccurrences(of: ">", with: "&gt;")
        s = s.replacingOccurrences(of: "\r\n", with: "<br>")
        s = s.replacingOccurrences(of: "\r", with: "<br>")
        s = s.replacingOccurrences(of: "\n", with: "<br>")
        return s
    }
}
