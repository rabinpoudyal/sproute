import Foundation
import ServiceManagement

/// Registers/unregisters the privileged helper as a launchd daemon via
/// `SMAppService` and reports its status for the UI. The daemon plist
/// (`com.sprout.helper`) ships in the app bundle in Plan 2b-3; registration is
/// wired here but only succeeds once that plist exists and the app is signed.
@MainActor
final class HelperManager: ObservableObject {
    static let daemonPlistName = "com.sprout.helper"

    @Published private(set) var status: SMAppService.Status = .notRegistered

    private var service: SMAppService {
        SMAppService.daemon(plistName: Self.daemonPlistName)
    }

    func refresh() {
        status = service.status
    }

    /// Prompts the user (System Settings > Login Items) to approve the daemon.
    func install() throws {
        try service.register()
        refresh()
    }

    func uninstall() throws {
        try service.unregister()
        refresh()
    }

    /// UI label for a status. Pure + static so it is unit-testable without a
    /// real `SMAppService`.
    nonisolated static func label(for status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "Not installed"
        case .enabled: return "Installed"
        case .requiresApproval: return "Needs approval in System Settings"
        case .notFound: return "Helper bundle missing"
        @unknown default: return "Unknown"
        }
    }
}
