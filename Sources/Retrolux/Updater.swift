import AppKit
import Sparkle

/// Automatic updates through Sparkle. Active only in the packaged app (the feed URL and public key come from Info.plist),
/// so `swift run` and the test binaries never contact a server.
final class AppUpdater {
    static let shared = AppUpdater()
    private let controller: SPUStandardUpdaterController?
    private init() {
        let configured = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil && Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
        controller = configured && !CommandLine.arguments.contains("--selftest") ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) : nil
    }
    var isAvailable: Bool { controller != nil }
    func start() { _ = controller }
    func checkForUpdates() {
        guard let controller else {
            let a = NSAlert(); a.messageText = "Updates"; a.informativeText = "Update checks are only available in the packaged app."; a.runModal(); return
        }
        controller.checkForUpdates(nil)
    }
}
