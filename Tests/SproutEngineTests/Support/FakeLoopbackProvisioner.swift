import Foundation
@testable import SproutEngine

/// Records every setActive call. `failNext` makes the next call throw, to test
/// provision-failure handling.
final actor FakeLoopbackProvisioner: LoopbackProvisioner {
    struct Call: Equatable { let ip: String; let hosts: [String]; let active: Bool }

    private var _calls: [Call] = []
    private var _failNext = false

    var calls: [Call] {
        _calls
    }

    func setFailNext(_ value: Bool) {
        _failNext = value
    }

    func setActive(ip: String, hosts: [String], active: Bool) async throws {
        let shouldFail = _failNext
        _failNext = false
        _calls.append(Call(ip: ip, hosts: hosts, active: active))
        if shouldFail { throw ProvisionError.helperUnavailable }
    }
}
