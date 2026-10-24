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

/// Test fixtures. The redaction cases and the field-name sensitivity cases are
/// loaded from `shared/redaction-fixtures.json` — the SAME file the Windows and
/// Linux self-tests read — so masking cannot silently drift between platforms.
/// The remaining checks (role/subrole resolution, clipboard types, blocked
/// apps, Luhn, personnummer) exercise macOS-specific API not in the shared JSON.
public enum Fixtures {

    // MARK: - Shared JSON (the one source of truth)

    /// Resolve the shared fixtures file. Preference order: the SQUIDPAL_FIXTURES
    /// environment variable (set by build.sh), then a path derived from this
    /// source file, then the working directory.
    public static var jsonURL: URL {
        let fm = FileManager.default
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["SQUIDPAL_FIXTURES"], !env.isEmpty {
            candidates.append(env)
        }
        let fromSource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RedactorFixtures
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // macos
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("shared/redaction-fixtures.json").path
        candidates.append(fromSource)
        candidates.append(fm.currentDirectoryPath + "/../shared/redaction-fixtures.json")
        candidates.append(fm.currentDirectoryPath + "/shared/redaction-fixtures.json")
        for c in candidates where fm.fileExists(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        fatalError("shared fixtures not found; tried:\n" + candidates.joined(separator: "\n"))
    }

    private struct FileModel: Decodable {
        struct Red: Decodable {
            let name: String; let input: String; let kind: String?
            let gone: [String]?; let kept: [String]?
        }
        struct Field: Decodable { let input: String; let expected: Bool }
        let redaction: [Red]
        let sensitive_field_names: [Field]
    }

    private static let model: FileModel = {
        do {
            let data = try Data(contentsOf: jsonURL)
            return try JSONDecoder().decode(FileModel.self, from: data)
        } catch {
            fatalError("could not load shared fixtures at \(jsonURL.path): \(error)")
        }
    }()

    // MARK: - Cases

    /// Redaction cases (loaded from the shared JSON).
    public static let redactionCases: [RedactionCase] = model.redaction.map {
        RedactionCase($0.name, $0.input, kind: $0.kind, gone: $0.gone ?? [], kept: $0.kept ?? [])
    }

    /// Field-name sensitivity cases (loaded from the shared JSON).
    public static let fieldNameCases: [BoolCase] = model.sensitive_field_names.map { f in
        BoolCase("field: \(f.input)", f.expected) { Redactor.isSensitiveFieldName(f.input) }
    }

    /// macOS-specific checks not part of the cross-platform JSON.
    public static let platformCases: [BoolCase] = [
        // Layer 1 — role / subrole resolution
        .init("field: secure role", true) { Redactor.isSensitiveField(role: "AXSecureTextField", subrole: nil, names: []) },
        .init("field: secure subrole", true) { Redactor.isSensitiveField(role: "AXTextField", subrole: "AXSecureTextField", names: []) },
        .init("field: message-body role", false) { Redactor.isSensitiveField(role: "AXTextArea", subrole: nil, names: ["Message Body", nil, ""]) },
        // Layer 2 — clipboard
        .init("clipboard: concealed", true) { Redactor.isConcealedPasteboard(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]) },
        .init("clipboard: transient", true) { Redactor.isConcealedPasteboard(types: ["org.nspasteboard.TransientType"]) },
        .init("clipboard: plain", false) { Redactor.isConcealedPasteboard(types: ["public.utf8-plain-text"]) },
        // Layer 3 — blocked apps
        .init("app: 1Password", true) { Redactor.isBlockedApp(bundleID: "com.1password.1password", name: "1Password") },
        .init("app: Bitwarden", true) { Redactor.isBlockedApp(bundleID: "com.bitwarden.desktop", name: "Bitwarden") },
        .init("app: Passwords", true) { Redactor.isBlockedApp(bundleID: "com.apple.Passwords", name: "Lösenord") },
        .init("app: Keychain Access", true) { Redactor.isBlockedApp(bundleID: "com.apple.keychainaccess", name: "Nyckelhanteraren") },
        .init("app: KeePassXC", true) { Redactor.isBlockedApp(bundleID: nil, name: "KeePassXC") },
        .init("app: LastPass", true) { Redactor.isBlockedApp(bundleID: nil, name: "LastPass") },
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

    /// All bool cases = shared field-name cases + macOS-specific checks.
    public static let boolCases: [BoolCase] = fieldNameCases + platformCases
}
