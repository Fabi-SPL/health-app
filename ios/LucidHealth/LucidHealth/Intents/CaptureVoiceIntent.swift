import AppIntents
import SwiftUI

/// App Intent — the system-level entry point for the voice capture flow.
/// Surfaces through: Action Button shortcut, Siri ("Hey Siri, capture voice
/// to Lucid Health"), Shortcuts app, and Apple Intelligence personal context.
///
/// On invocation it foregrounds the app and posts `lucidStartVoiceCapture`
/// — `LucidHealthApp.swift` listens and presents `VoiceCaptureView` as a sheet.
struct CaptureVoiceIntent: AppIntent {

    static var title: LocalizedStringResource = "Capture Voice to Lucid"

    static var description = IntentDescription(
        "Record a voice note. Lucid classifies it (task / event / brain dump / mood / habit) and routes it into the right place."
    )

    /// Brings LucidHealth to the foreground so the sheet can present.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .lucidStartVoiceCapture, object: nil)
        return .result()
    }
}

extension Notification.Name {
    /// Fired by `CaptureVoiceIntent.perform()` — root view subscribes and
    /// presents `VoiceCaptureView` as a sheet.
    static let lucidStartVoiceCapture = Notification.Name("lucidStartVoiceCapture")
}

/// Shortcuts app surface. Makes the intent discoverable as a pre-built shortcut
/// the user can bind to the Action Button (Settings → Action Button → Shortcut
/// → "Capture Voice to Lucid Health").
struct LucidHealthShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaptureVoiceIntent(),
            phrases: [
                "Capture voice to \(.applicationName)",
                "Brain dump to \(.applicationName)",
                "Log to \(.applicationName)",
                "Note to \(.applicationName)",
            ],
            shortTitle: "Capture Voice",
            systemImageName: "mic.fill"
        )
    }
}
