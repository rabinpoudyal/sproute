import Foundation
import TOMLKit

public enum ConfigError: Error, Equatable {
    case missingKey(String)
    case parseFailed(String)
    case duplicatePort(Int)
}

public enum TOMLConfigLoader {
    public static func load(path: URL) throws -> Config {
        let text: String
        do { text = try String(contentsOf: path, encoding: .utf8) } catch {
            throw ConfigError.parseFailed("cannot read \(path.path)")
        }
        return try parse(text)
    }

    public static func parse(_ toml: String) throws -> Config {
        let table: TOMLTable
        do { table = try TOMLTable(string: toml) } catch {
            throw ConfigError.parseFailed("\(error)")
        }

        func tbl(_ key: String) throws -> TOMLTable {
            guard let t = table[key]?.table else { throw ConfigError.missingKey(key) }
            return t
        }
        func str(_ t: TOMLTable, _ key: String, _ path: String) throws -> String {
            guard let v = t[key]?.string else { throw ConfigError.missingKey(path) }
            return v
        }

        let projectT = try tbl("project")
        let worktreeT = try tbl("worktree")
        let envT = try tbl("env")
        let dbT = try tbl("database")
        let runT = table["run"]?.table

        let sources: [String] = (envT["symlink_sources"]?.array?.compactMap { $0.string }) ?? []

        var steps: [SetupStep] = []
        if let arr = table["setup"]?.array {
            for entry in arr {
                guard let st = entry.table,
                    let name = st["name"]?.string,
                    let cmd = st["command"]?.string
                else {
                    throw ConfigError.missingKey("setup[].name/command")
                }
                steps.append(SetupStep(name: name, command: cmd))
            }
        }

        var processes: [ProcessConfig] = []
        var seenPorts: Set<Int> = []
        if let arr = runT?["process"]?.array {
            for entry in arr {
                guard let pt = entry.table,
                    let name = pt["name"]?.string,
                    let cmd = pt["command"]?.string
                else {
                    throw ConfigError.missingKey("run.process[].name/command")
                }
                let port = pt["port"]?.int
                if let port {
                    guard seenPorts.insert(port).inserted else {
                        throw ConfigError.duplicatePort(port)
                    }
                }
                processes.append(ProcessConfig(name: name, command: cmd, port: port))
            }
        }

        var consoles: [ConsoleConfig] = []
        if let arr = runT?["console"]?.array {
            for entry in arr {
                guard let ct = entry.table,
                    let name = ct["name"]?.string,
                    let cmd = ct["command"]?.string
                else {
                    throw ConfigError.missingKey("run.console[].name/command")
                }
                consoles.append(ConsoleConfig(name: name, command: cmd))
            }
        }

        var agents: [AgentConfig] = []
        if let arr = table["agent"]?.array {
            for entry in arr {
                guard let at = entry.table, let name = at["name"]?.string else {
                    throw ConfigError.missingKey("agent[].name")
                }
                agents.append(AgentConfig(name: name, command: at["command"]?.string ?? "claude"))
            }
        }

        let hooksT = table["hooks"]?.table
        let hooks = HooksConfig(
            preTeardown: hooksT?["pre_teardown"]?.string,
            postTeardown: hooksT?["post_teardown"]?.string)

        return Config(
            project: ProjectConfig(name: try str(projectT, "name", "project.name")),
            worktree: WorktreeConfig(
                baseDir: try str(worktreeT, "base_dir", "worktree.base_dir"),
                branchPrefix: try str(worktreeT, "branch_prefix", "worktree.branch_prefix")),
            env: EnvConfig(
                symlinkSources: sources,
                localFile: try str(envT, "local_file", "env.local_file")),
            database: DatabaseConfig(
                createCommand: try str(dbT, "create_command", "database.create_command"),
                dropCommand: try str(dbT, "drop_command", "database.drop_command"),
                urlTemplate: try str(dbT, "url_template", "database.url_template")),
            setup: steps,
            run: RunConfig(processes: processes, consoles: consoles),
            hooks: hooks, agents: agents)
    }
}
