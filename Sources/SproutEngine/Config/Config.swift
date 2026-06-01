import Foundation

public struct Config: Sendable {
    public var project: ProjectConfig
    public var worktree: WorktreeConfig
    public var port: PortConfig
    public var env: EnvConfig
    public var database: DatabaseConfig
    public var setup: [SetupStep]
    public var run: RunConfig
    public var hooks: HooksConfig

    public init(
        project: ProjectConfig, worktree: WorktreeConfig, port: PortConfig,
        env: EnvConfig, database: DatabaseConfig, setup: [SetupStep],
        run: RunConfig, hooks: HooksConfig
    ) {
        self.project = project; self.worktree = worktree; self.port = port
        self.env = env; self.database = database; self.setup = setup
        self.run = run; self.hooks = hooks
    }
}

public struct ProjectConfig: Sendable {
    public var name: String
    public init(name: String) { self.name = name }
}

public struct WorktreeConfig: Sendable {
    /// Directory where worktrees are created (template-rendered).
    public var baseDir: String
    public var branchPrefix: String
    public init(baseDir: String, branchPrefix: String) {
        self.baseDir = baseDir; self.branchPrefix = branchPrefix
    }
}

public struct PortConfig: Sendable {
    public var lower: Int
    public var upper: Int
    public init(lower: Int, upper: Int) { self.lower = lower; self.upper = upper }
}

public struct EnvConfig: Sendable {
    /// Filenames in the primary repo to symlink into the worktree (e.g. [".env"]).
    public var symlinkSources: [String]
    /// File the per-workspace overrides are written to (e.g. ".env.local").
    public var localFile: String
    public init(symlinkSources: [String], localFile: String) {
        self.symlinkSources = symlinkSources; self.localFile = localFile
    }
}

public struct DatabaseConfig: Sendable {
    public var createCommand: String  // template, e.g. "createdb {{db_name}}"
    public var dropCommand: String  // template, e.g. "dropdb --if-exists {{db_name}}"
    public var urlTemplate: String  // e.g. "postgres://localhost/{{db_name}}"
    public init(createCommand: String, dropCommand: String, urlTemplate: String) {
        self.createCommand = createCommand; self.dropCommand = dropCommand
        self.urlTemplate = urlTemplate
    }
}

public struct SetupStep: Sendable, Equatable {
    public var name: String
    public var command: String  // template
    public init(name: String, command: String) { self.name = name; self.command = command }
}

public struct ProcessConfig: Sendable, Equatable {
    public var name: String
    public var command: String  // template, long-running
    public init(name: String, command: String) { self.name = name; self.command = command }
}

public struct RunConfig: Sendable {
    public var processes: [ProcessConfig]
    public init(processes: [ProcessConfig]) { self.processes = processes }
}

public struct HooksConfig: Sendable {
    public var preTeardown: String?
    public var postTeardown: String?
    public init(preTeardown: String? = nil, postTeardown: String? = nil) {
        self.preTeardown = preTeardown; self.postTeardown = postTeardown
    }
}
