import Testing
import Foundation
@testable import SproutEngine

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("sprout-loopback-\(UUID().uuidString).json")
}

@Test func allocateAssignsSequentialFromBase() async throws {
    let a = IPAllocator(fileURL: tempFile())
    #expect(try await a.allocate(project: "shop", branch: "main") == "127.0.10.1")
    #expect(try await a.allocate(project: "shop", branch: "feature/login") == "127.0.10.2")
}

@Test func allocateIsIdempotentPerProjectBranch() async throws {
    let a = IPAllocator(fileURL: tempFile())
    let first = try await a.allocate(project: "shop", branch: "main")
    let again = try await a.allocate(project: "shop", branch: "main")
    #expect(first == again)
}

@Test func releaseFreesSlotForReuse() async throws {
    let a = IPAllocator(fileURL: tempFile())
    _ = try await a.allocate(project: "shop", branch: "main")  // .1
    _ = try await a.allocate(project: "shop", branch: "feature/login")  // .2
    try await a.release(project: "shop", branch: "main")  // frees .1
    // lowest-free is now .1 again
    #expect(try await a.allocate(project: "shop", branch: "feature/two") == "127.0.10.1")
}

@Test func ipReturnsNilWhenUnallocated() async throws {
    let a = IPAllocator(fileURL: tempFile())
    #expect(await a.ip(project: "shop", branch: "nope") == nil)
    _ = try await a.allocate(project: "shop", branch: "main")
    #expect(await a.ip(project: "shop", branch: "main") == "127.0.10.1")
}

@Test func persistsAcrossInstances() async throws {
    let url = tempFile()
    let a = IPAllocator(fileURL: url)
    _ = try await a.allocate(project: "shop", branch: "main")
    let b = IPAllocator(fileURL: url)  // fresh instance, same file
    #expect(await b.ip(project: "shop", branch: "main") == "127.0.10.1")
}

@Test func exhaustionThrows() async throws {
    let a = IPAllocator(fileURL: tempFile())
    for i in 1...254 { _ = try await a.allocate(project: "p", branch: "b\(i)") }
    await #expect(throws: LoopbackError.exhausted) {
        _ = try await a.allocate(project: "p", branch: "overflow")
    }
}
