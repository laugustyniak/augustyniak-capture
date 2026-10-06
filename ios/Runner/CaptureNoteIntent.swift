import AppIntents
import Foundation

/// Saves dictated text into the capture inbox without opening the app. The
/// Dart side drains `<Application Support>/inbox` once its index has loaded and
/// whenever the app returns to the foreground.
///
/// The persist-before-confirm rule applies here too: the note is written to
/// `<uuid>.txt.tmp`, moved to `<uuid>.txt`, and its size re-read before Siri
/// says "Saved." The uuid becomes the Recording id, so ingesting a file twice
/// is idempotent.
@available(iOS 16.0, *)
struct CaptureNoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture Note"
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Note", requestValueDialog: "What should I capture?")
    var text: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw CaptureNoteError.empty }

        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let inbox = support.appendingPathComponent("inbox", isDirectory: true)
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)

        let id = UUID().uuidString.lowercased()
        let tmp = inbox.appendingPathComponent("\(id).txt.tmp")
        let target = inbox.appendingPathComponent("\(id).txt")

        try Data(body.utf8).write(to: tmp, options: .atomic)
        try fm.moveItem(at: tmp, to: target)

        let attributes = try fm.attributesOfItem(atPath: target.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            try? fm.removeItem(at: target)
            throw CaptureNoteError.notPersisted
        }
        return .result(dialog: "Saved.")
    }
}

@available(iOS 16.0, *)
enum CaptureNoteError: Error, CustomLocalizedStringResourceConvertible {
    case empty
    case notPersisted

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .empty: return "There was nothing to capture."
        case .notPersisted: return "The note could not be saved."
        }
    }
}

@available(iOS 16.0, *)
struct CaptureShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureNoteIntent(),
            phrases: [
                "Capture in \(.applicationName)",
                "Take a note in \(.applicationName)",
            ],
            shortTitle: "Capture Note",
            systemImageName: "mic"
        )
    }
}
