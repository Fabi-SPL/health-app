import Foundation

/// Minimal, crash-proof build identification.
///
/// Only plain-string constants — no Info.plist reads, no Bundle lookups.
/// `commitHash` and `buildDate` are overwritten by the GitHub Actions workflow
/// before `xcodebuild` runs (see .github/workflows/build-ios.yml).
enum BuildInfo {
    static let commitHash:       String = "local-dev"
    static let buildDate:        String = "unknown"
    static let codeVersion:      String = "v100"
    static let migrationVersion: String = "v70"
}
