import Foundation

public enum DatabaseError: Error, Equatable {
    case commandFailed(command: String, exitCode: Int32, stderr: String)
}

public struct DatabaseService: Sendable {
    let shell: ShellRunner
    let renderer: TemplateRenderer
    public init(shell: ShellRunner, renderer: TemplateRenderer) {
        self.shell = shell; self.renderer = renderer
    }

    public func create(_ config: DatabaseConfig, ctx: TemplateContext, cwd: URL) async throws {
        try await runChecked(renderer.render(config.createCommand, ctx), cwd: cwd)
    }

    public func drop(_ config: DatabaseConfig, ctx: TemplateContext, cwd: URL) async throws {
        try await runChecked(renderer.render(config.dropCommand, ctx), cwd: cwd)
    }

    public func databaseURL(_ config: DatabaseConfig, ctx: TemplateContext) -> String {
        renderer.render(config.urlTemplate, ctx)
    }

    private func runChecked(_ command: String, cwd: URL) async throws {
        let r = try await shell.run(command, cwd: cwd, env: [:])
        guard r.succeeded else {
            throw DatabaseError.commandFailed(
                command: command, exitCode: r.exitCode, stderr: r.stderr)
        }
    }
}
