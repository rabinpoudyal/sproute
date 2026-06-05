import Foundation
import Testing
@testable import SproutEngine

@Suite struct PTYProcessTests {
    private var integration: Bool {
        ProcessInfo.processInfo.environment["SPROUT_INTEGRATION"] == "1"
    }

    @Test func ptyReportsTtyAndEchoesOutput() async throws {
        guard integration else { return }
        let spawner = ForkPTYSpawner()
        // `tty` prints the terminal device name and exits 0 when stdin is a real tty.
        let handle = try spawner.spawn(
            command: "tty; exit", cwd: URL(fileURLWithPath: "/tmp"), env: [:])
        var collected = Data()
        for await chunk in handle.output { collected.append(chunk) }
        let text = String(decoding: collected, as: UTF8.self)
        let code = await handle.waitForExit()
        #expect(text.contains("/dev/"))  // a tty device path, proves isatty() == true
        #expect(code == 0)
    }

    @Test func sendWritesToChildStdin() async throws {
        guard integration else { return }
        let spawner = ForkPTYSpawner()
        // `cat` echoes stdin back to stdout (the same pty), then we kill it.
        let handle = try spawner.spawn(
            command: "cat", cwd: URL(fileURLWithPath: "/tmp"), env: [:])
        handle.send(Data("hello\n".utf8))
        var seen = ""
        for await chunk in handle.output {
            seen += String(decoding: chunk, as: UTF8.self)
            if seen.contains("hello") {
                await handle.terminate(graceSeconds: 1)
            }
        }
        #expect(seen.contains("hello"))
    }

    @Test func loginArgsWrapCommand() {
        #expect(
            ForkPTYSpawner.loginArgs("/bin/zsh", "tty") == ["/bin/zsh", "-l", "-c", "tty"])
    }

    @Test func interactiveArgsAreLoginInteractive() {
        #expect(
            ForkPTYSpawner.interactiveArgs("/bin/zsh") == ["/bin/zsh", "-l", "-i"])
    }
}
