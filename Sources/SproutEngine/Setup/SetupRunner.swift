import Foundation

public enum SetupError: Error, Equatable {
    case stepFailed(index: Int, name: String, exitCode: Int32)
}

public struct SetupRunner: Sendable {
    let shell: ShellRunner
    let renderer: TemplateRenderer
    public init(shell: ShellRunner, renderer: TemplateRenderer) {
        self.shell = shell; self.renderer = renderer
    }

    /// Runs steps sequentially. Streams logs to `onLog`. Throws on first non-zero exit.
    public func run(
        _ steps: [SetupStep], ctx: TemplateContext, cwd: URL,
        env: [String: String],
        onLog: @Sendable (LogLine) -> Void
    ) async throws {
        for (index, step) in steps.enumerated() {
            let command = renderer.render(step.command, ctx)
            let handle = try shell.launch(command, cwd: cwd, env: env)
            for await line in handle.logs { onLog(line) }
            let code = await handle.waitForExit()
            guard code == 0 else {
                throw SetupError.stepFailed(index: index, name: step.name, exitCode: code)
            }
        }
    }
}
