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

    public func create(
        _ config: DatabaseConfig, ctx: TemplateContext, cwd: URL,
        onLog: (@Sendable (LogLine) -> Void)? = nil
    ) async throws {
        try await runChecked(renderer.render(config.createCommand, ctx), cwd: cwd, onLog: onLog)
    }

    public func drop(_ config: DatabaseConfig, ctx: TemplateContext, cwd: URL) async throws {
        try await runChecked(renderer.render(config.dropCommand, ctx), cwd: cwd)
    }

    public func databaseURL(_ config: DatabaseConfig, ctx: TemplateContext) -> String {
        renderer.render(config.urlTemplate, ctx)
    }

    private func runChecked(
        _ command: String, cwd: URL, onLog: (@Sendable (LogLine) -> Void)? = nil
    ) async throws {
        guard let onLog else {
            let r = try await shell.run(command, cwd: cwd, env: [:])
            guard r.succeeded else {
                throw DatabaseError.commandFailed(
                    command: command, exitCode: r.exitCode, stderr: r.stderr)
            }
            return
        }
        onLog(LogLine(source: .stdout, text: "$ \(command)"))
        let handle = try shell.launch(command, cwd: cwd, env: [:])
        var captured: [String] = []
        for await line in handle.logs {
            onLog(line)
            captured.append(line.text)
        }
        let code = await handle.waitForExit()
        guard code == 0 else {
            throw DatabaseError.commandFailed(
                command: command, exitCode: code, stderr: captured.joined(separator: "\n"))
        }
    }
}
