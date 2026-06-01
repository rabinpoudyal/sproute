import Foundation
import TOMLKit

/// Serializes a `Config` back to `.sprout.toml`. Symmetric with `TOMLConfigLoader`:
/// `parse(serialize(c))` round-trips. Only keys the loader understands are emitted,
/// so a written file is always re-loadable.
public enum TOMLConfigWriter {
    public static func serialize(_ config: Config) -> String {
        let root = TOMLTable()

        root["project"] = TOMLTable(["name": config.project.name])

        root["worktree"] = TOMLTable([
            "base_dir": config.worktree.baseDir,
            "branch_prefix": config.worktree.branchPrefix,
        ])

        root["port"] = TOMLTable([
            "lower": config.port.lower,
            "upper": config.port.upper,
        ])

        let env = TOMLTable()
        env["symlink_sources"] = TOMLArray(config.env.symlinkSources)
        env["local_file"] = config.env.localFile
        root["env"] = env

        root["database"] = TOMLTable([
            "create_command": config.database.createCommand,
            "drop_command": config.database.dropCommand,
            "url_template": config.database.urlTemplate,
        ])

        let setup = TOMLArray()
        for step in config.setup {
            setup.append(TOMLTable(["name": step.name, "command": step.command]))
        }
        root["setup"] = setup

        let run = TOMLTable()
        run["server_command"] = config.run.serverCommand
        let procs = TOMLArray()
        for p in config.run.processes {
            procs.append(TOMLTable(["name": p.name, "command": p.command]))
        }
        run["process"] = procs
        root["run"] = run

        if config.hooks.preTeardown != nil || config.hooks.postTeardown != nil {
            let hooks = TOMLTable()
            if let pre = config.hooks.preTeardown { hooks["pre_teardown"] = pre }
            if let post = config.hooks.postTeardown { hooks["post_teardown"] = post }
            root["hooks"] = hooks
        }

        return root.convert()
    }
}
