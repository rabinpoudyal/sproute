import Foundation
@testable import SproutEngine

/// Records every setActive call. `failNext` makes the next call throw, to test
/// provision-failure handling.
final class FakeLoopbackProvisioner: LoopbackProvisioner, @unchecked Sendable {
    struct Call: Equatable { let ip: String; let hosts: [String]; let active: Bool }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _failNext = false

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }

    func setFailNext(_ value: Bool) { lock.lock(); _failNext = value; lock.unlock() }

    func setActive(ip: String, hosts: [String], active: Bool) async throws {
        // Snapshot state before checking fail flag. Since tests are single-threaded,
        // accessing _calls/_failNext directly in async context is safe.
        let shouldFail = _failNext
        _failNext = false
        _calls.append(Call(ip: ip, hosts: hosts, active: active))
        if shouldFail { throw ProvisionError.helperUnavailable }
    }
}
