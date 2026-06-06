import Testing
import Foundation
@testable import SproutEngine

@Test func hostnamesCoversOnlyPortBindingProcesses() {
    let procs = [
        ProcessConfig(name: "web", command: "rails", port: 3000),
        ProcessConfig(name: "vite", command: "vite", port: 5173),
        ProcessConfig(name: "worker", command: "jobs"),  // no port
    ]
    let hosts = loopbackHostnames(project: "My Shop", branch: "feature/login", processes: procs)
    #expect(hosts == ["web.feature-login.my-shop.test", "vite.feature-login.my-shop.test"])
}

@Test func hostnamesEmptyWhenNoBinders() {
    let procs = [ProcessConfig(name: "worker", command: "jobs")]
    #expect(loopbackHostnames(project: "shop", branch: "main", processes: procs).isEmpty)
}

/// The gate (`validateLoopbackRequest`) must accept everything the generator
/// emits, even for names with spaces/symbols — otherwise Plan 2b's helper would
/// reject its own hostnames at runtime.
@Test func generatedHostnamesAlwaysPassTheGate() {
    let procs = [
        ProcessConfig(name: "Web Server", command: "rails", port: 3000),
        ProcessConfig(name: "vite_dev!", command: "vite", port: 5173),
    ]
    let hosts = loopbackHostnames(
        project: "My Shop & Co.", branch: "Wild/Branch #2", processes: procs)
    #expect(hosts.allSatisfy { isValidLoopbackHostname($0) })
}

@Test func noopProvisionerDoesNothingAndDoesNotThrow() async throws {
    let p = NoopLoopbackProvisioner()
    try await p.setActive(ip: "127.0.10.1", hosts: ["web.shop.localhost"], active: true)
    try await p.setActive(ip: "127.0.10.1", hosts: ["web.shop.localhost"], active: false)
}

@Test func noopListManagedReturnsEmpty() async throws {
    let p = NoopLoopbackProvisioner()
    let managed = try await p.listManaged()
    #expect(managed.isEmpty)
}
