import Testing

@testable import SproutEngine

@Suite struct AgentConfigParsingTests {
    private let toml = """
        [project]
        name = "shop"
        [worktree]
        base_dir = "/wt"
        branch_prefix = "feature/"
        [env]
        symlink_sources = []
        local_file = ".env.local"
        [database]
        create_command = "true"
        drop_command = "true"
        url_template = "unused"

        [[agent]]
        name = "builder"

        [[agent]]
        name = "reviewer"
        command = "claude --model opus"
        """

    @Test func parsesAgentsWithDefaultCommand() throws {
        let config = try TOMLConfigLoader.parse(toml)
        #expect(config.agents.count == 2)
        #expect(config.agents[0] == AgentConfig(name: "builder", command: "claude"))
        #expect(config.agents[1] == AgentConfig(name: "reviewer", command: "claude --model opus"))
    }

    @Test func absentAgentSectionYieldsEmpty() throws {
        let base = """
            [project]
            name = "shop"
            [worktree]
            base_dir = "/wt"
            branch_prefix = "feature/"
            [env]
            symlink_sources = []
            local_file = ".env.local"
            [database]
            create_command = "true"
            drop_command = "true"
            url_template = "unused"
            """
        #expect(try TOMLConfigLoader.parse(base).agents.isEmpty)
    }
}
