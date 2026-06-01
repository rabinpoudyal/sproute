import Foundation
import Testing
@testable import SproutApp

@Suite struct ProjectRegistryTests {
    @Test func addDedupesAndNormalizes() {
        var reg = ProjectRegistry()
        let first = reg.add("/tmp/foo")
        let dup = reg.add("/tmp/foo")
        let normDup = reg.add("/tmp/foo/")  // normalized duplicate
        #expect(first)
        #expect(!dup)
        #expect(!normDup)
        #expect(reg.projectPaths == ["/tmp/foo"])
    }

    @Test func removeByPath() {
        var reg = ProjectRegistry(projectPaths: ["/tmp/a", "/tmp/b"])
        reg.remove("/tmp/a/")
        #expect(reg.projectPaths == ["/tmp/b"])
    }

    @Test func saveLoadRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sprout-reg-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var reg = ProjectRegistry()
        reg.add("/tmp/one")
        reg.add("/tmp/two")
        try reg.save(to: url)

        let loaded = ProjectRegistry.load(from: url)
        #expect(loaded == reg)
    }

    @Test func loadMissingFileReturnsEmpty() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        #expect(ProjectRegistry.load(from: url).isEmpty)
    }

    @Test func slugifyProducesFileSafeNames() {
        #expect(SproutPaths.slugify("My Shop!") == "my-shop")
        #expect(SproutPaths.slugify("") == "project")
    }
}
