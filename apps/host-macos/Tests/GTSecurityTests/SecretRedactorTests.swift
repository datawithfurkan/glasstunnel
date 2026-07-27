import XCTest
@testable import GTSecurity

final class SecretRedactorTests: XCTestCase {
    func testRedactsAwsAccessKey() {
        let r = SecretRedactor()
        let (out, hits) = r.redact("pre AKIAIOSFODNN7EXAMPLE post")
        XCTAssertTrue(out.contains("<redacted:aws_access_key>"))
        XCTAssertFalse(out.contains("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertTrue(hits.contains("aws_access_key"))
    }

    func testRedactsGitHubPAT() {
        let r = SecretRedactor()
        let token = "ghp_" + String(repeating: "a", count: 36)
        let (out, _) = r.redact("auth: \(token)")
        XCTAssertFalse(out.contains(token))
    }

    func testRedactsOpenAIKey() {
        let r = SecretRedactor()
        let key = "sk-" + String(repeating: "x", count: 40)
        let (out, _) = r.redact("OPENAI_API_KEY=\(key)")
        XCTAssertFalse(out.contains(key))
    }

    func testRedactsSSHPrivateKey() {
        let r = SecretRedactor()
        let blob = """
        before
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAA...truncated
        -----END OPENSSH PRIVATE KEY-----
        after
        """
        let (out, _) = r.redact(blob)
        XCTAssertTrue(out.contains("<redacted:ssh_private_key>"))
        XCTAssertFalse(out.contains("BEGIN OPENSSH PRIVATE KEY"))
    }

    func testRedactsEnvSecretLine() {
        let r = SecretRedactor()
        let input = "API_SECRET_TOKEN=superduperhush\nOK=fine\n"
        let (out, hits) = r.redact(input)
        XCTAssertFalse(out.contains("superduperhush"))
        XCTAssertTrue(out.contains("OK=fine"))
        XCTAssertTrue(hits.contains("env_secret_line"))
    }

    func testPassesBenignText() {
        let r = SecretRedactor()
        let input = "this is a perfectly normal chat message"
        let (out, hits) = r.redact(input)
        XCTAssertEqual(out, input)
        XCTAssertEqual(hits, [])
    }

    func testCustomPatterns() {
        let r = SecretRedactor(patterns: [
            SecretRedactor.Pattern(name: "my_secret", regex: #"SUPER_[A-Z]+"#),
        ])
        let (out, _) = r.redact("leak SUPER_SECRET here")
        XCTAssertFalse(out.contains("SUPER_SECRET"))
        XCTAssertTrue(out.contains("<redacted:my_secret>"))
    }
}
