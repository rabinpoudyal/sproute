import Testing

@testable import SproutEngine

@Suite struct LoopbackIfconfigTests {
    @Test func aliasUpArguments() {
        #expect(LoopbackIfconfig.tool == "/sbin/ifconfig")
        let args = LoopbackIfconfig.arguments(ip: "127.0.10.7", active: true)
        #expect(args.count == 4)
        #expect(args.first == "lo0")
        #expect(args.last == "up")
        #expect(args[1] == "alias")
        #expect(args[2] == "127.0.10.7")
    }

    @Test func aliasDownArguments() {
        let args = LoopbackIfconfig.arguments(ip: "127.0.10.7", active: false)
        #expect(args.count == 3)
        #expect(args[1] == "-alias")
        #expect(args[2] == "127.0.10.7")
    }
}
