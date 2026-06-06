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

    @Test func acceptsProcessProjectLocalhost() {
        #expect(isValidLoopbackHostname("web.myproj.localhost"))
        #expect(isValidLoopbackHostname("vite.my-proj.localhost"))
        #expect(isValidLoopbackHostname("sidekiq-1.app2.localhost"))
    }

    @Test func rejectsBadHostnames() {
        #expect(!isValidLoopbackHostname("web.myproj.local"))  // wrong tld
        #expect(!isValidLoopbackHostname("web.localhost"))  // only 2 labels
        #expect(!isValidLoopbackHostname("a.b.c.localhost"))  // too many labels
        #expect(!isValidLoopbackHostname("WEB.myproj.localhost"))  // uppercase
        #expect(!isValidLoopbackHostname(".myproj.localhost"))  // empty label
        #expect(!isValidLoopbackHostname("web.my_proj.localhost"))  // underscore
        #expect(!isValidLoopbackHostname("web.myproj.localhost "))  // trailing space
        #expect(!isValidLoopbackHostname(""))
        #expect(!isValidLoopbackHostname("-web.myproj.localhost"))  // leading hyphen
        #expect(!isValidLoopbackHostname("web-.myproj.localhost"))  // trailing hyphen
    }

    @Test func gateAcceptsValidRequest() throws {
        try validateLoopbackRequest(
            ip: "127.0.10.5",
            hosts: ["web.myproj.localhost", "vite.myproj.localhost"])
    }

    @Test func gateRejectsBadIP() {
        #expect(throws: ProvisionError.helperRejected("invalid ip: 10.0.0.1")) {
            try validateLoopbackRequest(ip: "10.0.0.1", hosts: ["web.myproj.localhost"])
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
}
