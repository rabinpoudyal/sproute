import Testing
import Foundation
@testable import SproutEngine

private let sampleTOML = """
    [project]
    name = "shop"

    [worktree]
    base_dir = "/wt"
    branch_prefix = "feature/"

    [env]
    symlink_sources = [".env"]
    local_file = ".env.local"

    [database]
    create_command = "createdb {{db_name}}"
    drop_command = "dropdb --if-exists {{db_name}}"
    url_template = "postgres://localhost/{{db_name}}"

    [[setup]]
    name = "deps"
    command = "npm ci"

    [[setup]]
    name = "migrate"
    command = "npm run migrate"

    [hooks]
    post_teardown = "echo bye"
    """

@Test func parsesFullConfig() throws {
    let config = try TOMLConfigLoader.parse(sampleTOML)
    #expect(config.project.name == "shop")
    #expect(config.worktree.baseDir == "/wt")
    #expect(config.env.symlinkSources == [".env"])
    #expect(config.env.localFile == ".env.local")
    #expect(config.database.createCommand == "createdb {{db_name}}")
    #expect(config.setup.map(\.name) == ["deps", "migrate"])
    #expect(config.run.processes.isEmpty)
    #expect(config.hooks.postTeardown == "echo bye")
    #expect(config.hooks.preTeardown == nil)
}

@Test func parsesEmptyProcessListWhenAbsent() throws {
    let config = try TOMLConfigLoader.parse(sampleTOML)
    #expect(config.run.processes.isEmpty)
}

@Test func parsesAndRoundTripsMultipleProcesses() throws {
    let toml = """
        [project]
        name = "shop"
        [worktree]
        base_dir = "/wt"
        branch_prefix = "feature/"
        [env]
        symlink_sources = []
        local_file = ".env.local"
        [database]
        create_command = "createdb {{db_name}}"
        drop_command = "dropdb --if-exists {{db_name}}"
        url_template = "postgres://localhost/{{db_name}}"
        [run]
        [[run.process]]
        name = "server"
        command = "bin/rails server -p {{port}}"
        [[run.process]]
        name = "assets"
        command = "yarn build --watch"
        """
    let config = try TOMLConfigLoader.parse(toml)
    #expect(config.run.processes.map(\.name) == ["server", "assets"])
    #expect(config.run.processes[0].command == "bin/rails server -p {{port}}")

    // Round-trips through the writer.
    let reparsed = try TOMLConfigLoader.parse(TOMLConfigWriter.serialize(config))
    #expect(reparsed.run.processes == config.run.processes)
}

@Test func parsesConsoleEntries() throws {
    let toml = """
        [project]
        name = "shop"
        [worktree]
        base_dir = "../wt"
        branch_prefix = "feature/"
        [env]
        symlink_sources = []
        local_file = ".env.local"
        [database]
        create_command = "createdb {{db_name}}"
        drop_command = "dropdb {{db_name}}"
        url_template = "postgres://localhost/{{db_name}}"
        [[run.console]]
        name = "rails"
        command = "rbenv exec ruby bin/rails console"
        [[run.console]]
        name = "db"
        command = "rbenv exec ruby bin/rails dbconsole"
        """
    let config = try TOMLConfigLoader.parse(toml)
    let expected: [ConsoleConfig] = [
        ConsoleConfig(name: "rails", command: "rbenv exec ruby bin/rails console"),
        ConsoleConfig(name: "db", command: "rbenv exec ruby bin/rails dbconsole"),
    ]
    #expect(config.run.consoles == expected)
}

@Test func parsesEmptyConsoleListWhenAbsent() throws {
    let toml = """
        [project]
        name = "shop"
        [worktree]
        base_dir = "../wt"
        branch_prefix = "feature/"
        [env]
        symlink_sources = []
        local_file = ".env.local"
        [database]
        create_command = "createdb {{db_name}}"
        drop_command = "dropdb {{db_name}}"
        url_template = "postgres://localhost/{{db_name}}"
        """
    let config = try TOMLConfigLoader.parse(toml)
    #expect(config.run.consoles.isEmpty)
}

@Test func roundTripsProcessPort() throws {
    let config = Config(
        project: ProjectConfig(name: "shop"),
        worktree: WorktreeConfig(baseDir: "/wt", branchPrefix: "feature/"),
        env: EnvConfig(symlinkSources: [], localFile: ".env.local"),
        database: DatabaseConfig(
            createCommand: "createdb {{db_name}}",
            dropCommand: "dropdb {{db_name}}",
            urlTemplate: "postgres://localhost/{{db_name}}"),
        setup: [],
        run: RunConfig(processes: [
            ProcessConfig(name: "web", command: "bin/rails server", port: 4000),
            ProcessConfig(name: "worker", command: "bin/jobs"),
        ]),
        hooks: HooksConfig())
    let reparsed = try TOMLConfigLoader.parse(TOMLConfigWriter.serialize(config))
    #expect(reparsed.run.processes == config.run.processes)
}

@Test func missingRequiredKeyThrows() {
    let bad = """
        [project]
        name = "shop"
        """
    #expect(throws: ConfigError.self) { _ = try TOMLConfigLoader.parse(bad) }
}

@Test func parsesProcessPort() throws {
    let toml = """
        [project]
        name = "shop"
        [worktree]
        base_dir = "/wt"
        branch_prefix = "feature/"
        [env]
        symlink_sources = []
        local_file = ".env.local"
        [database]
        create_command = "createdb {{db_name}}"
        drop_command = "dropdb {{db_name}}"
        url_template = "postgres://localhost/{{db_name}}"
        [[run.process]]
        name = "web"
        command = "bin/rails server -p {{port}}"
        port = 4000
        [[run.process]]
        name = "worker"
        command = "bin/jobs"
        """
    let config = try TOMLConfigLoader.parse(toml)
    #expect(config.run.processes[0].port == 4000)
    #expect(config.run.processes[1].port == nil)
}

@Test func rejectsDuplicateProcessPorts() {
    let toml = """
        [project]
        name = "shop"
        [worktree]
        base_dir = "/wt"
        branch_prefix = "feature/"
        [env]
        symlink_sources = []
        local_file = ".env.local"
        [database]
        create_command = "createdb {{db_name}}"
        drop_command = "dropdb {{db_name}}"
        url_template = "postgres://localhost/{{db_name}}"
        [[run.process]]
        name = "web"
        command = "a"
        port = 4000
        [[run.process]]
        name = "api"
        command = "b"
        port = 4000
        """
    #expect(throws: ConfigError.duplicatePort(4000)) { _ = try TOMLConfigLoader.parse(toml) }
}
