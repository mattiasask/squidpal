import Foundation

/// One line in the day file. Field order is fixed so files diff/grep well.
struct LogEvent {
    var ts: Date
    var event: String          // focus, update, scroll, typing, selection, clipboard, leave
    var app: String?
    var bundleID: String?
    var windowTitle: String?
    var url: String?
    var pageTitle: String?
    var text: String?
    var redactions: Int = 0
    /// Kind → count, e.g. ["otp": 2]. Never the values.
    var redactionKinds: [String: Int] = [:]
    var dwellSeconds: Double?
}

/// Append-only JSONL writer. Every line is written with a single write() and
/// fsync'd, so a sync client never sees half a line.
final class LogWriter {
    static let maxFileBytes: UInt64 = 50 * 1024 * 1024

    let folder: URL
    private let tsFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f
    }()

    init(folder: URL) { self.folder = folder }

    static func dayString(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func partURL(folder: URL, day: String, part: Int) -> URL {
        folder.appendingPathComponent(part == 1 ? "\(day).jsonl" : "\(day)-\(part).jsonl")
    }

    /// All existing files for a day, in order.
    static func dayFiles(folder: URL, day: String) -> [URL] {
        var out: [URL] = []
        var part = 1
        while true {
            let u = partURL(folder: folder, day: day, part: part)
            guard FileManager.default.fileExists(atPath: u.path) else { break }
            out.append(u)
            part += 1
        }
        return out
    }

    static func size(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// The file the next line goes to: the last part, or a new one past 50 MB.
    private func currentFile(day: String) -> URL {
        let existing = Self.dayFiles(folder: folder, day: day)
        guard let last = existing.last else { return Self.partURL(folder: folder, day: day, part: 1) }
        if Self.size(last) >= Self.maxFileBytes {
            return Self.partURL(folder: folder, day: day, part: existing.count + 1)
        }
        return last
    }

    @discardableResult
    func append(_ e: LogEvent) throws -> Int {
        var line = "{"
        line += "\"ts\":\(json(tsFormatter.string(from: e.ts)))"
        line += ",\"event\":\(json(e.event))"
        line += ",\"app\":\(json(e.app))"
        line += ",\"bundle_id\":\(json(e.bundleID))"
        line += ",\"window_title\":\(json(e.windowTitle))"
        line += ",\"url\":\(json(e.url))"
        line += ",\"page_title\":\(json(e.pageTitle))"
        line += ",\"text\":\(json(e.text))"
        line += ",\"redactions\":\(e.redactions)"
        if !e.redactionKinds.isEmpty {
            let parts = e.redactionKinds.sorted { $0.key < $1.key }.map { "\(json($0.key)):\($0.value)" }
            line += ",\"redaction_kinds\":{\(parts.joined(separator: ","))}"
        }
        if let d = e.dwellSeconds {
            line += ",\"dwell_seconds\":\(String(format: "%.1f", d))"
        } else {
            line += ",\"dwell_seconds\":null"
        }
        line += "}\n"

        let data = Data(line.utf8)
        let url = currentFile(day: Self.dayString(e.ts))
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let written = data.withUnsafeBytes { buf in write(fd, buf.baseAddress, buf.count) }
        guard written == data.count else { throw POSIXError(.EIO) }
        fsync(fd)
        return data.count
    }

    // MARK: JSON string escaping

    private func json(_ s: String?) -> String {
        guard let s else { return "null" }
        var out = "\""
        out.reserveCapacity(s.utf8.count + 2)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{2028}": out += "\\u2028"
            case "\u{2029}": out += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
