import Testing
import Foundation
@testable import SproutEngine

enum Fixtures {
    static func config() -> Config {
        Config(
            project: ProjectConfig(name: "shop"),
            worktree: WorktreeConfig(baseDir: "/wt", branchPrefix: "feature/"),
            port: PortConfig(lower: 4000, upper: 4010),
            env: EnvConfig(symlinkSources: [".env"], localFile: ".env.local"),
            database: DatabaseConfig(
                createCommand: "createdb {{db_name}}",
                dropCommand: "dropdb --if-exists {{db_name}}",
                urlTemplate: "postgres://localhost/{{db_name}}"
            ),
            setup: [
                SetupStep(name: "deps", command: "npm ci"),
                SetupStep(name: "migrate", command: "npm run migrate"),
            ],
            run: RunConfig(
                serverCommand: "npm run dev",
                processes: [ProcessConfig(name: "server", command: "npm run dev")]),
            hooks: HooksConfig()
        )
    }
}

@Test func fixtureConfigBuilds() {
    let c = Fixtures.config()
    #expect(c.project.name == "shop")
    #expect(c.setup.count == 2)
    #expect(c.port.lower == 4000)
}
