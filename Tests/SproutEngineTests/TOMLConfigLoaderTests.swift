import Testing
import Foundation
@testable import SproutEngine

private let sampleTOML = """
    [project]
    name = "shop"

    [worktree]
    base_dir = "/wt"
    branch_prefix = "feature/"

    [port]
    lower = 4000
    upper = 4010

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

    [run]
    server_command = "npm run dev"

    [hooks]
    post_teardown = "echo bye"
    """

@Test func parsesFullConfig() throws {
    let config = try TOMLConfigLoader.parse(sampleTOML)
    #expect(config.project.name == "shop")
    #expect(config.worktree.baseDir == "/wt")
    #expect(config.port.lower == 4000)
    #expect(config.port.upper == 4010)
    #expect(config.env.symlinkSources == [".env"])
    #expect(config.env.localFile == ".env.local")
    #expect(config.database.createCommand == "createdb {{db_name}}")
    #expect(config.setup.map(\.name) == ["deps", "migrate"])
    #expect(config.run.serverCommand == "npm run dev")
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
        [port]
        lower = 4000
        upper = 4010
        [env]
        symlink_sources = []
        local_file = ".env.local"
        [database]
        create_command = "createdb {{db_name}}"
        drop_command = "dropdb --if-exists {{db_name}}"
        url_template = "postgres://localhost/{{db_name}}"
        [run]
        server_command = "npm run dev"
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

@Test func missingRequiredKeyThrows() {
    let bad = """
        [project]
        name = "shop"
        """
    #expect(throws: ConfigError.self) { _ = try TOMLConfigLoader.parse(bad) }
}
