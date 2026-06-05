import Testing
import Foundation
@testable import SproutEngine

@Test func hostnamesCoversOnlyPortBindingProcesses() {
    let procs = [
        ProcessConfig(name: "web", command: "rails", port: 3000),
        ProcessConfig(name: "vite", command: "vite", port: 5173),
        ProcessConfig(name: "worker", command: "jobs"),  // no port
    ]
    let hosts = loopbackHostnames(project: "My Shop", processes: procs)
    #expect(hosts == ["web.my_shop.localhost", "vite.my_shop.localhost"])
}

@Test func hostnamesEmptyWhenNoBinders() {
    let procs = [ProcessConfig(name: "worker", command: "jobs")]
    #expect(loopbackHostnames(project: "shop", processes: procs).isEmpty)
}

@Test func noopProvisionerDoesNothingAndDoesNotThrow() async throws {
    let p = NoopLoopbackProvisioner()
    try await p.setActive(ip: "127.0.10.1", hosts: ["web.shop.localhost"], active: true)
    try await p.setActive(ip: "127.0.10.1", hosts: ["web.shop.localhost"], active: false)
}
