import Testing
@testable import SproutEngine

@Suite struct LoopbackValidationTests {
    @Test func acceptsInRangeLoopbackIPs() {
        #expect(isValidLoopbackIP("127.0.10.1"))
        #expect(isValidLoopbackIP("127.0.10.42"))
        #expect(isValidLoopbackIP("127.0.10.254"))
    }

    @Test func rejectsOutOfRangeOctet() {
        #expect(!isValidLoopbackIP("127.0.10.0"))  // .0 network address
        #expect(!isValidLoopbackIP("127.0.10.255"))  // .255 broadcast
        #expect(!isValidLoopbackIP("127.0.10.256"))
    }

    @Test func rejectsWrongPrefix() {
        #expect(!isValidLoopbackIP("127.0.11.1"))
        #expect(!isValidLoopbackIP("127.0.0.1"))
        #expect(!isValidLoopbackIP("10.0.0.1"))
    }

    @Test func rejectsMalformed() {
        #expect(!isValidLoopbackIP("127.0.10.01"))  // non-canonical leading zero
        #expect(!isValidLoopbackIP("127.0.10.1 "))  // trailing space
        #expect(!isValidLoopbackIP("127.0.10."))
        #expect(!isValidLoopbackIP("127.0.10.1.5"))
        #expect(!isValidLoopbackIP(""))
    }

    @Test func acceptsProcessBranchProjectTest() {
        #expect(isValidLoopbackHostname("web.main.myproj.test"))
        #expect(isValidLoopbackHostname("vite.feature-login.my-proj.test"))
        #expect(isValidLoopbackHostname("sidekiq-1.br2.app2.test"))
    }

    @Test func rejectsBadHostnames() {
        #expect(!isValidLoopbackHostname("web.main.myproj.local"))  // wrong tld
        #expect(!isValidLoopbackHostname("web.myproj.localhost"))  // localhost tld rejected
        #expect(!isValidLoopbackHostname("web.myproj.test"))  // only 3 labels
        #expect(!isValidLoopbackHostname("a.b.c.d.test"))  // too many labels
        #expect(!isValidLoopbackHostname("WEB.main.myproj.test"))  // uppercase
        #expect(!isValidLoopbackHostname(".main.myproj.test"))  // empty label
        #expect(!isValidLoopbackHostname("web.main.my_proj.test"))  // underscore
        #expect(!isValidLoopbackHostname("web.main.myproj.test "))  // trailing space
        #expect(!isValidLoopbackHostname(""))
        #expect(!isValidLoopbackHostname("-web.main.myproj.test"))  // leading hyphen
        #expect(!isValidLoopbackHostname("web-.main.myproj.test"))  // trailing hyphen
    }

    @Test func gateAcceptsValidRequest() throws {
        try validateLoopbackRequest(
            ip: "127.0.10.5",
            hosts: ["web.main.myproj.test", "vite.main.myproj.test"])
    }

    @Test func gateRejectsBadIP() {
        #expect(throws: ProvisionError.helperRejected("invalid ip: 10.0.0.1")) {
            try validateLoopbackRequest(ip: "10.0.0.1", hosts: ["web.main.myproj.test"])
        }
    }

    @Test func gateRejectsBadHostname() {
        #expect(throws: ProvisionError.helperRejected("invalid hostname: evil.com")) {
            try validateLoopbackRequest(ip: "127.0.10.5", hosts: ["evil.com"])
        }
    }

    @Test func gateAcceptsEmptyHosts() throws {
        // Deactivation passes [] hostnames; the IP must still be in range.
        try validateLoopbackRequest(ip: "127.0.10.5", hosts: [])
    }

    @Test func gateRejectsBadHostnameInMixedList() {
        #expect(throws: ProvisionError.helperRejected("invalid hostname: evil.com")) {
            try validateLoopbackRequest(
                ip: "127.0.10.5",
                hosts: ["web.main.myproj.test", "evil.com"])
        }
    }
}
