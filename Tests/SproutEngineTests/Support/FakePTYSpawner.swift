import Foundation
@testable import SproutEngine

/// In-memory PTYHandle that records sent bytes and can be made to "exit" on demand.
final class FakePTYHandle: PTYHandle, @unchecked Sendable {
    let pid: Int32
    let output: AsyncStream<Data>
    private let cont: AsyncStream<Data>.Continuation
    private let exitContinuation = ExitBox()
    private(set) var sent = Data()
    private(set) var terminated = false

    final class ExitBox: @unchecked Sendable {
        var resume: ((Int32) -> Void)?
        var code: Int32?
    }

    init(pid: Int32) {
        self.pid = pid
        var c: AsyncStream<Data>.Continuation!
        self.output = AsyncStream { c = $0 }
        self.cont = c
    }

    func emit(_ text: String) { cont.yield(Data(text.utf8)) }
    func finishOutput() { cont.finish() }

    /// Cause `waitForExit` to return `code`.
    func simulateExit(code: Int32) {
        exitContinuation.code = code
        exitContinuation.resume?(code)
    }

    func send(_ data: Data) { sent.append(data) }
    func resize(cols: Int, rows: Int) {}
    func terminate(graceSeconds: Double) async {
        terminated = true
        simulateExit(code: 0)
    }
    func waitForExit() async -> Int32 {
        if let code = exitContinuation.code { return code }
        return await withCheckedContinuation { c in
            exitContinuation.resume = { c.resume(returning: $0) }
        }
    }
}

final class FakePTYSpawner: PTYSpawner, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var handles: [FakePTYHandle] = []
    private(set) var commands: [String] = []
    private var nextPid: Int32 = 1000

    func spawn(command: String, cwd: URL, env: [String: String]) throws -> PTYHandle {
        lock.lock(); defer { lock.unlock() }
        commands.append(command)
        let h = FakePTYHandle(pid: nextPid)
        nextPid += 1
        handles.append(h)
        return h
    }
}
