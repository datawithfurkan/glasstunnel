import Foundation

/// Applies a set of regex patterns to outbound text (CLI output, chat messages)
/// before it leaves the Mac, replacing matches with `<redacted>`.
///
/// The redaction pipeline is applied by the host BEFORE the WebRTC DataChannel
/// send. It cannot be bypassed from the phone side.
public final class SecretRedactor: @unchecked Sendable {
    public struct Pattern: Sendable, Hashable {
        public let name: String
        public let regex: String
        public let replacement: String

        public init(name: String, regex: String, replacement: String = "<redacted:\(#function)>") {
            self.name = name
            self.regex = regex
            // Avoid interpolation of #function inside default value at decl time.
            self.replacement = replacement == "<redacted:\(#function)>" ? "<redacted:\(name)>" : replacement
        }
    }

    public static let defaultPatterns: [Pattern] = [
        // AWS access keys
        Pattern(name: "aws_access_key", regex: #"\bAKIA[0-9A-Z]{16}\b"#),
        Pattern(name: "aws_secret_access_key", regex: #"(?i)aws_secret_access_key\s*[:=]\s*[A-Za-z0-9/+=]{30,}"#),
        // Google API keys
        Pattern(name: "google_api_key", regex: #"\bAIza[0-9A-Za-z\-_]{35}\b"#),
        // GitHub tokens
        Pattern(name: "github_pat", regex: #"\bghp_[A-Za-z0-9]{36}\b"#),
        Pattern(name: "github_oauth", regex: #"\bgho_[A-Za-z0-9]{36}\b"#),
        Pattern(name: "github_server_token", regex: #"\bghs_[A-Za-z0-9]{36}\b"#),
        // OpenAI keys
        Pattern(name: "openai_api_key", regex: #"\bsk-[A-Za-z0-9]{20,}\b"#),
        // Anthropic keys
        Pattern(name: "anthropic_api_key", regex: #"\bsk-ant-[A-Za-z0-9\-_]{20,}\b"#),
        // Stripe keys
        Pattern(name: "stripe_secret_key", regex: #"\bsk_live_[A-Za-z0-9]{24,}\b"#),
        // Generic bearer tokens on Authorization headers
        Pattern(name: "authorization_bearer", regex: #"(?i)authorization:\s*bearer\s+[A-Za-z0-9\-_\.~\+/=]+"#),
        // SSH private key blocks
        Pattern(name: "ssh_private_key", regex: #"-----BEGIN (?:RSA |OPENSSH |EC |DSA |)PRIVATE KEY-----[\s\S]+?-----END (?:RSA |OPENSSH |EC |DSA |)PRIVATE KEY-----"#),
        // JWT tokens (three base64url-ish segments separated by dots)
        Pattern(name: "jwt", regex: #"\beyJ[A-Za-z0-9_\-]+\.eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\b"#),
        // Generic .env lines (key=value where key looks secret-ish)
        Pattern(name: "env_secret_line", regex: #"(?im)^([A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|API[_-]?KEY|PRIVATE[_-]?KEY)[A-Z0-9_]*)\s*=\s*(\S+)"#),
    ]

    private var patterns: [Pattern]
    private var compiled: [(Pattern, NSRegularExpression)]
    private let lock = NSLock()

    public init(patterns: [Pattern] = SecretRedactor.defaultPatterns) {
        self.patterns = patterns
        self.compiled = SecretRedactor.compile(patterns)
    }

    public func setPatterns(_ new: [Pattern]) {
        lock.lock(); defer { lock.unlock() }
        self.patterns = new
        self.compiled = SecretRedactor.compile(new)
    }

    public func appendCustom(_ new: [Pattern]) {
        lock.lock(); defer { lock.unlock() }
        self.patterns.append(contentsOf: new)
        self.compiled = SecretRedactor.compile(self.patterns)
    }

    public var activePatterns: [Pattern] {
        lock.lock(); defer { lock.unlock() }
        return patterns
    }

    /// Returns the redacted string and a list of pattern names that matched.
    public func redact(_ input: String) -> (String, [String]) {
        lock.lock()
        let snapshot = compiled
        lock.unlock()

        var out = input
        var hits: [String] = []
        for (pattern, regex) in snapshot {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            if regex.firstMatch(in: out, options: [], range: range) == nil {
                continue
            }
            let replacement = "<redacted:\(pattern.name)>"
            let replaced = regex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
            out = replaced
            hits.append(pattern.name)
        }
        return (out, hits)
    }

    public static func placeholderReasons(in input: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"<redacted:([^>\s]+)>"#, options: []) else {
            return []
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        var seen = Set<String>()
        return regex.matches(in: input, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1, let reasonRange = Range(match.range(at: 1), in: input) else {
                return nil
            }
            let reason = String(input[reasonRange])
            return seen.insert(reason).inserted ? reason : nil
        }
    }

    public static func mergedReasons(_ reasonLists: [String]...) -> [String] {
        var seen = Set<String>()
        return reasonLists.flatMap { $0 }.filter { seen.insert($0).inserted }
    }

    private static func compile(_ patterns: [Pattern]) -> [(Pattern, NSRegularExpression)] {
        var result: [(Pattern, NSRegularExpression)] = []
        for p in patterns {
            if let r = try? NSRegularExpression(pattern: p.regex, options: []) {
                result.append((p, r))
            }
        }
        return result
    }
}
