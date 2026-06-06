import ServiceManagement
import Testing

@testable import SproutApp

@Suite struct HelperManagerTests {
    @Test func mapsNotRegisteredToNeedsInstall() {
        #expect(HelperManager.label(for: .notRegistered) == "Not installed")
    }

    @Test func mapsEnabledToInstalled() {
        #expect(HelperManager.label(for: .enabled) == "Installed")
    }

    @Test func mapsRequiresApprovalToApproval() {
        #expect(
            HelperManager.label(for: .requiresApproval)
                == "Needs approval in System Settings")
    }
}
