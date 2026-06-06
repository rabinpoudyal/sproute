import Foundation
import Testing
import SproutEngine
@testable import SproutApp

@Suite struct ProjectStoreLoopbackTests {
    @Test func loopbackFileLivesUnderSproutRoot() {
        let url = SproutPaths.loopbackFile
        #expect(url.lastPathComponent == "loopback.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == ".sprout")
    }
}
