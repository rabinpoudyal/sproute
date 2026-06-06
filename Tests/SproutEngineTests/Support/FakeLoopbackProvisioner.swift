import Foundation
@testable import SproutEngine

/// Records every setActive call. `failNext` makes the next call throw, to test
/// provision-failure handling. Uses scoped `withLock` (not bare lock/unlock) so
/// the locking is safe to call from the async `setActive`, while keeping the
/// `calls`/`setFailNext` accessors synchronous for use inside `#expect`.
final class FakeLoopbackProvisioner: LoopbackProvisioner, @unchecked Sendable {
    struct Call: Equatable { let ip: String; let hosts: [String]; let active: Bool }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _failNext = false
    private var _managed: [String] = []

    var calls: [Call] { lock.withLock { _calls } }

    func setFailNext(_ value: Bool) { lock.withLock { _failNext = value } }
    func setManaged(_ ips: [String]) { lock.withLock { _managed = ips } }

    func setActive(ip: String, hosts: [String], active: Bool) async throws {
        let shouldFail = lock.withLock { () -> Bool in
            let fail = _failNext
            _failNext = false
            _calls.append(Call(ip: ip, hosts: hosts, active: active))
            return fail
        }
        if shouldFail { throw ProvisionError.helperUnavailable }
    }

    func listManaged() async throws -> [String] {
        lock.withLock { _managed }
    }
}
