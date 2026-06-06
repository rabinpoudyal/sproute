import Testing

@testable import SproutEngine

@Suite struct CodeSignRequirementTests {
    @Test func buildsIdentifierAndLeafHashRequirement() {
        let req = codeSigningRequirement(
            identifier: "com.sprout.app",
            leafCertSHA1Hex: "ABCD1234")
        let expected = "identifier \"com.sprout.app\" and certificate leaf = H\"ABCD1234\""
        #expect(req == expected)
    }
}
