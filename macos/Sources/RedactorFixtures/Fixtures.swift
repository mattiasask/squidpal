import Foundation
import RedactorCore

/// One redaction expectation. Shared by the XCTest suite and the
/// `redactor-selftest` runner (which works without Xcode / XCTest).
public struct RedactionCase {
    public let name: String
    public let input: String
    /// Kind that must appear as [REDACTED:kind]; nil = nothing may be redacted.
    public let kind: String?
    /// Substrings that must be gone from the output (the secret itself).
    public let mustNotContain: [String]
    /// Substrings that must survive (the surrounding text).
    public let mustContain: [String]

    public init(_ name: String, _ input: String, kind: String?,
                gone: [String] = [], kept: [String] = []) {
        self.name = name; self.input = input; self.kind = kind
        self.mustNotContain = gone; self.mustContain = kept
    }

    /// Returns nil on success, otherwise a description of what failed.
    public func check() -> String? {
        let out = Redactor.redact(input)
        var problems: [String] = []
        if let kind {
            if !out.text.contains("[REDACTED:\(kind)]") { problems.append("expected [REDACTED:\(kind)]") }
        } else if out.count != 0 {
            problems.append("expected no redaction, got \(out.kinds)")
        }
        for s in mustNotContain where out.text.contains(s) { problems.append("still contains \"\(s)\"") }
        for s in mustContain where !out.text.contains(s) { problems.append("lost \"\(s)\"") }
        // Idempotence: running again must not find anything new.
        let again = Redactor.redact(out.text)
        if again.count != 0 { problems.append("second pass redacted \(again.kinds)") }
        return problems.isEmpty ? nil : problems.joined(separator: "; ") + " → \(out.text)"
    }
}

public struct BoolCase {
    public let name: String
    public let expected: Bool
    public let run: () -> Bool
    public init(_ name: String, _ expected: Bool, _ run: @escaping () -> Bool) {
        self.name = name; self.expected = expected; self.run = run
    }
    public func check() -> String? { run() == expected ? nil : "expected \(expected)" }
}

// Fake secrets are assembled at runtime so this file itself does not trip
// secret scanners.
private func rep(_ s: String, _ n: Int) -> String { String(repeating: s, count: n) }

public enum Fixtures {
    public static let redactionCases: [RedactionCase] = [
        // Known key formats
        .init("OpenAI key", "my key " + "sk-" + "proj-AbCdEf1234567890GhIjKlMn" + " here",
              kind: "api_key", gone: ["AbCdEf1234567890"], kept: ["my key", "here"]),
        .init("Anthropic key", "export K=" + "sk-ant-" + "api03-Zx9Yw8Vu7Ts6Rq5Po4Nm3Lk2Ji1Hg0Fe",
              kind: "api_key", gone: ["Zx9Yw8Vu7Ts6"]),
        .init("GitHub ghp_", "token ghp_" + rep("aB3d", 9) + " used",
              kind: "github_token", gone: ["aB3daB3d"], kept: ["used"]),
        .init("GitHub fine-grained", "github_pat_" + rep("11ABCDEFG", 3) + "_xyz",
              kind: "github_token", gone: ["11ABCDEFG"]),
        .init("Slack token", "bot: " + "xoxb-" + "1234567890-abcdefghij", kind: "slack_token",
              gone: ["abcdefghij"], kept: ["bot:"]),
        .init("AWS key id", "aws " + "AKIA" + "IOSFODNN7EXAMPLE" + " ok", kind: "aws_key",
              gone: ["IOSFODNN7EXAMPLE"], kept: ["ok"]),
        .init("Google API key", "AIza" + rep("Ab1_", 8) + "Ab1" + " end", kind: "google_api_key",
              gone: ["Ab1_Ab1_"], kept: ["end"]),
        .init("Stripe secret key", "STRIPE=" + "sk_" + "live_" + rep("4eC39HqLyjWDarjtT1zdp7dc", 1) + " ok",
              kind: "api_key", gone: ["4eC39HqLyjWDarjtT1zdp7dc"], kept: ["ok"]),
        .init("Stripe restricted key", "rk_" + "test_" + "51Hxyz" + rep("Ab12", 6), kind: "api_key", gone: ["Ab12Ab12"]),
        .init("Stripe webhook secret", "whsec_" + rep("Zx9Yw8Vu", 4), kind: "webhook_secret", gone: ["Zx9Yw8Vu"]),
        .init("GitLab token", "glpat-" + "xY7zW9vU5tS3rQ1pO8nM", kind: "gitlab_token", gone: ["xY7zW9vU5"]),
        .init("npm token", "npm_" + rep("aB3c", 9), kind: "npm_token", gone: ["aB3caB3c"]),
        .init("Bearer header", "Authorization: Bearer abc.DEF-123_xyz~456", kind: "bearer_token",
              gone: ["abc.DEF-123_xyz~456"], kept: ["Authorization:"]),
        .init("JWT", "cookie " + "eyJ" + "hbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.abcDEF123_-xyz",
              kind: "jwt", gone: ["hbGciOiJIUzI1NiJ9"], kept: ["cookie"]),

        // PEM
        .init("PEM RSA", "before\n-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA1234\nabcd\n-----END RSA PRIVATE KEY-----\nafter",
              kind: "private_key", gone: ["MIIEowIBAAKCAQEA1234", "abcd"], kept: ["before", "after"]),
        .init("PEM OpenSSH", "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk\n-----END OPENSSH PRIVATE KEY-----",
              kind: "private_key", gone: ["b3BlbnNzaC1rZXk"]),

        // key = value
        .init("password: value", "user: bob password: hunter2 role: admin", kind: "secret",
              gone: ["hunter2"], kept: ["user: bob", "role: admin"]),
        .init("lösenord=", "lösenord=Sommar2024! klart", kind: "secret", gone: ["Sommar2024"], kept: ["klart"]),
        .init("api_key quoted", "api_key = 'abc123def'", kind: "secret", gone: ["abc123def"]),
        .init("JSON client_secret", "{\"client_secret\": \"zz9yy8xx\"}", kind: "secret", gone: ["zz9yy8xx"]),
        .init("ENV DB_PASSWORD", "DB_PASSWORD=foo42bar", kind: "secret", gone: ["foo42bar"]),
        .init("secret_key=", "secret_key=qwe123", kind: "secret", gone: ["qwe123"]),

        // URLs
        .init("URL with credentials", "connect https://admin:s3cr3t@db.example.com/x now",
              kind: "url_credentials", gone: ["s3cr3t"], kept: ["db.example.com/x", "now"]),
        .init("OAuth code param", "https://example.com/cb?code=abc123xyz&state=ok",
              kind: "url_param", gone: ["abc123xyz"], kept: ["state=ok", "example.com/cb"]),
        .init("sig param", "https://cdn.example.com/f.png?w=10&sig=XyZ987&x=1",
              kind: "url_param", gone: ["XyZ987"], kept: ["w=10", "x=1"]),

        // Card numbers and personnummer
        .init("Card number (Luhn ok)", "Kort 4111 1111 1111 1111 exp 12/27", kind: "card_number",
              gone: ["4111 1111 1111 1111"], kept: ["Kort", "exp 12/27"]),
        .init("Personnummer 12 digits", "pnr 19900101-1239 tack", kind: "personnummer",
              gone: ["19900101-1239"], kept: ["pnr", "tack"]),
        .init("Personnummer 10 digits", "811218-9876", kind: "personnummer", gone: ["811218-9876"]),

        // One-time codes
        .init("OTP sv", "Din verifieringskod är 482913", kind: "otp", gone: ["482913"], kept: ["Din"]),
        .init("OTP BankID", "BankID code: 7731", kind: "otp", gone: ["7731"]),

        // Entropy
        .init("High entropy token", "value Qm9xT2pL8vR4nZ7wK1sY6hB3dF5gJ0cX end", kind: "high_entropy",
              gone: ["Qm9xT2pL8vR4nZ7wK1sY6hB3dF5gJ0cX"], kept: ["value", "end"]),
        .init("High entropy lower+digits", "k=(a8kf3lq9zx2mv7pw4rt6yb1n)", kind: "high_entropy",
              gone: ["a8kf3lq9zx2mv7pw4rt6yb1n"]),

        // ---- Must NOT be redacted ----
        .init("Plain Swedish text", "Möte med Sam om budgeten imorgon kl 14:00, rum Ö-3.", kind: nil,
              kept: ["Möte med Sam om budgeten imorgon kl 14:00, rum Ö-3."]),
        .init("Card failing Luhn", "Ref 4111 1111 1111 1112", kind: nil, kept: ["4111 1111 1111 1112"]),
        .init("Number without code context", "Order 482913 shipped", kind: nil, kept: ["482913"]),
        .init("Date and year near 'code'", "Code review 2026-10-13, deadline 2026", kind: nil,
              kept: ["2026-10-13", "deadline 2026"]),
        .init("Normal URL", "https://www.linkedin.com/feed/update/urn:li:activity:7251234567890123456/?trk=abcDEF123ghiJKL456",
              kind: nil, kept: ["linkedin.com/feed"]),
        .init("Bare domain URL", "linkedin.com/in/alex-example-1a2b3c4d5e6f7g8h", kind: nil,
              kept: ["linkedin.com/in/"]),
        .init("File path", "/Users/alex/Projects/acme-backend/src/main2.swift", kind: nil,
              kept: ["/Users/alex/Projects/acme-backend/src/main2.swift"]),
        .init("Git hash", "commit 3f786850e387550fdab836ed7e6dc881de23001b", kind: nil,
              kept: ["3f786850e387550fdab836ed7e6dc881de23001b"]),
        .init("UUID", "id 550e8400-e29b-41d4-a716-446655440000", kind: nil,
              kept: ["550e8400-e29b-41d4-a716-446655440000"]),
        .init("CamelCase identifier", "UIApplicationDidFinishLaunching2 SquidlerFundraisingNotes2026v3",
              kind: nil, kept: ["UIApplicationDidFinishLaunching2", "SquidlerFundraisingNotes2026v3"]),
        .init("Long word with digits", "internationalization2024readiness", kind: nil,
              kept: ["internationalization2024readiness"]),
        .init("Email address", "alex.longname1234@acme-example.io", kind: nil,
              kept: ["alex.longname1234@acme-example.io"]),
        .init("Word 'author' is not 'auth'", "author: Mattias", kind: nil, kept: ["author: Mattias"]),
        .init("Long numeric ID in URN (passes Luhn)", "urn:li:activity:7251234567890123456", kind: nil,
              kept: ["7251234567890123456"]),
        .init("Stripe object ids", "Customer cus_NffrFeUfNV2Hib, payment pi_3PxYzAbCdEf1234567890Gh, session cs_test_a1B2c3D4e5F6g7H8i9J0kLmN",
              kind: nil, kept: ["cus_NffrFeUfNV2Hib", "pi_3PxYzAbCdEf1234567890Gh", "cs_test_a1B2c3D4e5F6g7H8i9J0kLmN"]),
        .init("Random-looking id in URL path", "Öppna https://lovable.dev/projects/Qm9xT2pL8vR4nZ7wK1sY6hB3dF5gJ0cX nu",
              kind: nil, kept: ["Qm9xT2pL8vR4nZ7wK1sY6hB3dF5gJ0cX"]),
        .init("Gmail thread URL", "https://mail.google.com/mail/u/0/#inbox/FMfcgzQXJWhGkbsDmTrLpqwXcVbNmKjh",
              kind: nil, kept: ["FMfcgzQXJWhGkbsDmTrLpqwXcVbNmKjh"]),
        .init("Number far from 'code'", "Source code for the new onboarding flow is merged, see ticket 482913", kind: nil,
              kept: ["482913"]),
        .init("Unicode / barcode are not 'code'", "Unicode 15104 och barcode 734512", kind: nil, kept: ["15104", "734512"]),
        .init("Plural 'codes'", "We shipped 3 promo codes: 8812 redemptions", kind: nil, kept: ["8812"]),
        .init("OTP after 'passcode'", "Zoom passcode: 551204", kind: "otp", gone: ["551204"]),
        .init("Phone number", "Ring 070-123 45 67", kind: nil, kept: ["070-123 45 67"]),
        .init("Prose about passwords", "Remember to rotate the password policy next week", kind: nil,
              kept: ["rotate the password policy"]),
    ]

    public static let boolCases: [BoolCase] = [
        // Layer 1
        .init("field: secure role", true) { Redactor.isSensitiveField(role: "AXSecureTextField", subrole: nil, names: []) },
        .init("field: secure subrole", true) { Redactor.isSensitiveField(role: "AXTextField", subrole: "AXSecureTextField", names: []) },
        .init("field: Password label", true) { Redactor.isSensitiveFieldName("Password") },
        .init("field: Lösenord", true) { Redactor.isSensitiveFieldName("Lösenord") },
        .init("field: pinCode id", true) { Redactor.isSensitiveFieldName("pinCode") },
        .init("field: PIN-kod", true) { Redactor.isSensitiveFieldName("PIN-kod") },
        .init("field: cvc", true) { Redactor.isSensitiveFieldName("cvc") },
        .init("field: Säkerhetskod", true) { Redactor.isSensitiveFieldName("Säkerhetskod") },
        .init("field: one-time 2FA code", true) { Redactor.isSensitiveFieldName("Enter 2FA code") },
        .init("field: otp_input", true) { Redactor.isSensitiveFieldName("otp_input") },
        .init("field: Email", false) { Redactor.isSensitiveFieldName("Email") },
        .init("field: Shipping address", false) { Redactor.isSensitiveFieldName("Shipping address") },
        .init("field: Spinner", false) { Redactor.isSensitiveFieldName("Spinner") },
        .init("field: Search", false) { Redactor.isSensitiveFieldName("Search or type URL") },
        .init("field: Message body", false) { Redactor.isSensitiveField(role: "AXTextArea", subrole: nil, names: ["Message Body", nil, ""]) },
        // Layer 2
        .init("clipboard: concealed", true) { Redactor.isConcealedPasteboard(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]) },
        .init("clipboard: transient", true) { Redactor.isConcealedPasteboard(types: ["org.nspasteboard.TransientType"]) },
        .init("clipboard: plain", false) { Redactor.isConcealedPasteboard(types: ["public.utf8-plain-text"]) },
        // Layer 3
        .init("app: 1Password", true) { Redactor.isBlockedApp(bundleID: "com.1password.1password", name: "1Password") },
        .init("app: Bitwarden", true) { Redactor.isBlockedApp(bundleID: "com.bitwarden.desktop", name: "Bitwarden") },
        .init("app: Passwords", true) { Redactor.isBlockedApp(bundleID: "com.apple.Passwords", name: "Lösenord") },
        .init("app: Keychain Access", true) { Redactor.isBlockedApp(bundleID: "com.apple.keychainaccess", name: "Nyckelhanteraren") },
        .init("app: Chrome", false) { Redactor.isBlockedApp(bundleID: "com.google.Chrome", name: "Google Chrome") },
        .init("app: Notes", false) { Redactor.isBlockedApp(bundleID: "com.apple.Notes", name: "Anteckningar") },
        // Checks
        .init("luhn ok", true) { Redactor.luhn("4111111111111111") },
        .init("luhn bad", false) { Redactor.luhn("4111111111111112") },
        .init("pnr bad month", false) { Redactor.isPersonnummer("901301-1239") },
        .init("count reported", true) {
            let r = Redactor.redact("password: a1 and token=b2")
            return r.count == 2 && !r.text.contains("a1") && !r.text.contains("b2")
        },
    ]
}
