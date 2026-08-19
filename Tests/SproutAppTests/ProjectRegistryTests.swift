import Foundation
import Testing
@testable import SproutApp

@Suite struct ProjectRegistryTests {
    @Test func addDedupesUpdatesNameAndNormalizes() {
        var reg = ProjectRegistry()
        let first = reg.add(path: "/tmp/foo", name: "foo")
        let dup = reg.add(path: "/tmp/foo", name: "foo2")  // same path → updates name
        let normDup = reg.add(path: "/tmp/foo/", name: "foo3")  // normalized duplicate
        #expect(first)
        #expect(!dup)
        #expect(!normDup)
        #expect(reg.projects.map(\.path) == ["/tmp/foo"])
        #expect(reg.name(forPath: "/tmp/foo") == "foo3")
    }

    @Test func removeByPath() {
        var reg = ProjectRegistry(projects: [
            ProjectRef(path: "/tmp/a", name: "a"), ProjectRef(path: "/tmp/b", name: "b"),
        ])
        reg.remove("/tmp/a/")
        #expect(reg.projects.map(\.path) == ["/tmp/b"])
    }

    @Test func saveLoadRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sprout-reg-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var reg = ProjectRegistry()
        reg.add(path: "/tmp/one", name: "one")
        reg.add(path: "/tmp/two", name: "two")
        try reg.save(to: url)

        let loaded = ProjectRegistry.load(from: url)
        #expect(loaded == reg)
    }

    @Test func decodesLegacyProjectPathsFormat() {
        let legacy = #"{"projectPaths":["/tmp/x","/tmp/y"]}"#
        let reg = try! JSONDecoder().decode(ProjectRegistry.self, from: Data(legacy.utf8))
        #expect(reg.projects.map(\.path) == ["/tmp/x", "/tmp/y"])
        #expect(reg.projects.allSatisfy { $0.name.isEmpty })
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
