import Testing
import Foundation
@testable import SproutEngine

@Suite struct TOMLConfigWriterTests {
    @Test func roundTripsThroughParse() throws {
        let original = Fixtures.config()
        let toml = TOMLConfigWriter.serialize(original)
        let parsed = try TOMLConfigLoader.parse(toml)

        #expect(parsed.project.name == original.project.name)
        #expect(parsed.worktree.baseDir == original.worktree.baseDir)
        #expect(parsed.worktree.branchPrefix == original.worktree.branchPrefix)
        #expect(parsed.port.lower == original.port.lower)
        #expect(parsed.port.upper == original.port.upper)
        #expect(parsed.env.symlinkSources == original.env.symlinkSources)
        #expect(parsed.env.localFile == original.env.localFile)
        #expect(parsed.database.createCommand == original.database.createCommand)
        #expect(parsed.database.dropCommand == original.database.dropCommand)
        #expect(parsed.database.urlTemplate == original.database.urlTemplate)
        #expect(parsed.setup == original.setup)
        #expect(parsed.run.serverCommand == original.run.serverCommand)
    }

    @Test func roundTripsHooksWhenPresent() throws {
        var c = Fixtures.config()
        c.hooks = HooksConfig(preTeardown: "echo pre", postTeardown: "echo post")
        let parsed = try TOMLConfigLoader.parse(TOMLConfigWriter.serialize(c))
        #expect(parsed.hooks.preTeardown == "echo pre")
        #expect(parsed.hooks.postTeardown == "echo post")
    }

    @Test func omitsHooksTableWhenEmpty() {
        let toml = TOMLConfigWriter.serialize(Fixtures.config())
        #expect(!toml.contains("[hooks]"))
    }
}
