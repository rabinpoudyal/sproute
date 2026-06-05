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
        #expect(parsed.env.symlinkSources == original.env.symlinkSources)
        #expect(parsed.env.localFile == original.env.localFile)
        #expect(parsed.database.createCommand == original.database.createCommand)
        #expect(parsed.database.dropCommand == original.database.dropCommand)
        #expect(parsed.database.urlTemplate == original.database.urlTemplate)
        #expect(parsed.setup == original.setup)
        #expect(parsed.run.processes == original.run.processes)
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

    @Test func roundTripsConsoles() throws {
        let original = Config(
            project: ProjectConfig(name: "shop"),
            worktree: WorktreeConfig(baseDir: "../wt", branchPrefix: "feature/"),
            env: EnvConfig(symlinkSources: [], localFile: ".env.local"),
            database: DatabaseConfig(
                createCommand: "createdb {{db_name}}",
                dropCommand: "dropdb {{db_name}}",
                urlTemplate: "postgres://localhost/{{db_name}}"),
            setup: [],
            run: RunConfig(
                processes: [ProcessConfig(name: "web", command: "npm run dev")],
                consoles: [
                    ConsoleConfig(name: "rails", command: "rbenv exec ruby bin/rails console"),
                    ConsoleConfig(name: "db", command: "rbenv exec ruby bin/rails dbconsole"),
                ]),
            hooks: HooksConfig())
        let reparsed = try TOMLConfigLoader.parse(TOMLConfigWriter.serialize(original))
        let expectedConsoles = original.run.consoles
        let expectedProcesses = original.run.processes
        #expect(reparsed.run.consoles == expectedConsoles)
        #expect(reparsed.run.processes == expectedProcesses)
    }
}
