import Foundation

/// Builds a faithful, human-readable HTML timeline from a day's JSONL files.
/// Self-contained (inline CSS, no network). Redaction markers [REDACTED:kind]
/// are shown as a lock chip, never expanded. Newest activity first.
/// Shared design with the Windows/Linux builds.
enum Timeline {

    static func build(files: [URL], day: String) -> URL? {
        let events = readEvents(files)
        var groups = group(events)
        let totalRed = events.reduce(0) { $0 + intOf($1["redactions"]) }
        let apps = Set(events.compactMap { strOrNil($0["app"]) }).count

        groups = groups.filter { g in
            !title(g).isEmpty || g.url != nil || g.items.contains { strOrNil($0["text"]) != nil }
        }

        let cards = groups.isEmpty
            ? "<div class=\"empty\">Nothing recorded today yet.</div>"
            : groups.reversed().map { groupHTML($0) }.joined()

        let sub = plural(events.count, "entry", "entries") + " · "
            + plural(totalRed, "redaction", "redactions") + " · "
            + plural(apps, "app", "apps")

        let doc = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
            + "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
            + "<title>Squidpal — \(esc(day))</title><style>\(css)</style></head>"
            + "<body><div class=\"wrap\"><header><h1>Squidpal</h1>"
            + "<div class=\"date\">\(esc(prettyDate(day)))</div>"
            + "<div class=\"sub\">\(sub)</div>"
            + "</header><main>\(cards)</main>"
            + "<footer>Generated \(hm(Date())) · all data stays on your computer</footer>"
            + "</div></body></html>"

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("squidpal-timeline-\(day).html")
        do { try doc.write(to: url, atomically: true, encoding: .utf8); return url }
        catch { return nil }
    }

    // MARK: Parsing

    private static func readEvents(_ files: [URL]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for url in files {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for raw in content.split(separator: "\n", omittingEmptySubsequences: true) {
                let line = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }
                if let data = line.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data),
                   let dict = obj as? [String: Any] {
                    out.append(dict)
                }
            }
        }
        out.sort { strOf($0["ts"]) < strOf($1["ts"]) }
        return out
    }

    // MARK: Grouping

    private struct Group {
        var ts = ""
        var app: String?
        var win: String?
        var url: String?
        var page: String?
        var items: [[String: Any]] = []
        var dwell: Double?
        var red = 0
        var key = ""
    }

    private static func group(_ events: [[String: Any]]) -> [Group] {
        var groups: [Group] = []
        for e in events {
            let app = strOrNil(e["app"]), win = strOrNil(e["window_title"]), url = strOrNil(e["url"])
            let k = (app ?? "") + "\u{1}" + (win ?? "") + "\u{1}" + (url ?? "")
            if strOf(e["event"]) == "focus" || groups.isEmpty || groups[groups.count - 1].key != k {
                var g = Group()
                g.ts = strOf(e["ts"]); g.app = app; g.win = win
                g.url = url; g.page = strOrNil(e["page_title"]); g.key = k
                groups.append(g)
            }
            let i = groups.count - 1
            groups[i].items.append(e)
            groups[i].red += intOf(e["redactions"])
            if strOf(e["event"]) == "leave", let d = doubleOrNil(e["dwell_seconds"]), d > 0 {
                groups[i].dwell = d
            }
        }
        return groups
    }

    /// Display title: prefer the page title, strip a trailing " - <app>" suffix
    /// (browsers append " - Google Chrome - <profile>" to window titles).
    private static func title(_ g: Group) -> String {
        var t = (g.page ?? g.win ?? "").trimmingCharacters(in: .whitespaces)
        if let app = g.app, !app.isEmpty, let r = t.range(of: " - \(app)") {
            t = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    private static func groupHTML(_ g: Group) -> String {
        var head = "<span class=\"time\">\(hhmm(g.ts))</span>"
            + "<span class=\"app\">\(esc(g.app ?? "Unknown app"))</span>"
        let t = title(g)
        if !t.isEmpty { head += "<span class=\"win\">\(esc(t))</span>" }
        if let d = g.dwell { head += "<span class=\"dur\">· \(fmtDur(d))</span>" }
        if g.red > 0 { head += "<span class=\"lock\" title=\"\(g.red) redactions in this block\">🔒</span>" }

        var urlLine = ""
        if let u = g.url, !u.isEmpty { urlLine = "<div class=\"url\">\(esc(u))</div>" }

        var body = ""
        for e in g.items {
            guard let tx = strOrNil(e["text"]) else { continue }
            let tag = tagFor(strOf(e["event"]))
            let tagHTML = tag.isEmpty ? "" : "<span class=\"tag\">\(tag)</span>"
            body += "<div class=\"ev\">\(tagHTML)<div class=\"text\">\(renderText(tx))</div></div>"
        }
        let bodyHTML = body.isEmpty ? "" : "<div class=\"body\">\(body)</div>"
        return "<section class=\"card\"><div class=\"chead\">\(head)</div>\(urlLine)\(bodyHTML)</section>"
    }

    // MARK: Text / redaction

    private static let redRE = try! NSRegularExpression(pattern: "\\[REDACTED:([^\\]]+)\\]")

    private static func renderText(_ t: String) -> String {
        let normalized = t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var items: [(String?, String)] = []   // (prefix, html)
        var prev: String? = nil
        for rawLine in normalized.components(separatedBy: "\n") {
            var line = rawLine.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line == prev { continue }
            prev = line
            var pfx: String? = nil
            for p in ["menu", "window"] {
                let tag = "[\(p)] "
                if line.hasPrefix(tag) {
                    pfx = p
                    line = String(line.dropFirst(tag.count))
                    break
                }
            }
            items.append((pfx, redChips(esc(line))))
        }
        // Consecutive menu/window lines collapse into one muted line.
        var out: [String] = []
        var i = 0
        while i < items.count {
            guard let pfx = items[i].0 else { out.append(items[i].1); i += 1; continue }
            var parts: [String] = []
            while i < items.count, items[i].0 == pfx { parts.append(items[i].1); i += 1 }
            out.append("<span class=\"pfx\">\(pfx)</span><span class=\"chrome\">\(parts.joined(separator: " · "))</span>")
        }
        return out.joined(separator: "<br>")
    }

    private static func redChips(_ escaped: String) -> String {
        let ns = escaped as NSString
        let matches = redRE.matches(in: escaped, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return escaped }
        var out = ""
        var last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let kind = ns.substring(with: m.range(at: 1))
            out += "<span class=\"red\" title=\"hidden: \(esc(kind))\">🔒 hidden</span>"
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    private static func esc(_ s: String) -> String {
        var r = ""
        r.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": r += "&amp;"
            case "<": r += "&lt;"
            case ">": r += "&gt;"
            case "\"": r += "&quot;"
            case "'": r += "&#39;"
            default: r.append(c)
            }
        }
        return r
    }

    // MARK: Values

    private static func strOf(_ v: Any?) -> String { (v as? String) ?? "" }
    private static func strOrNil(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        return nil
    }
    private static func intOf(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
    private static func doubleOrNil(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    private static func tagFor(_ event: String) -> String {
        switch event {
        case "update": return "updated"
        case "scroll": return "scrolled"
        case "typing": return "typed"
        case "selection": return "selected"
        case "clipboard": return "copied"
        default: return ""
        }
    }

    // MARK: Dates / format

    private static let weekdays = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    private static let months = ["", "January", "February", "March", "April", "May", "June",
                                 "July", "August", "September", "October", "November", "December"]

    private static func hhmm(_ ts: String) -> String {
        guard ts.count >= 16 else { return ts }
        let start = ts.index(ts.startIndex, offsetBy: 11)
        let end = ts.index(start, offsetBy: 5)
        return String(ts[start..<end])
    }

    private static func hm(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: date)
    }

    private static func fmtDur(_ sec: Double) -> String {
        let s = Int(sec.rounded())
        if s < 60 { return "\(s)s" }
        let m = s / 60, rs = s % 60
        if m < 60 { return rs > 0 ? "\(m)m \(rs)s" : "\(m)m" }
        let h = m / 60, rm = m % 60
        return rm > 0 ? "\(h)h \(rm)m" : "\(h)h"
    }

    private static func plural(_ n: Int, _ s: String, _ p: String) -> String { "\(n) \(n == 1 ? s : p)" }

    private static func prettyDate(_ day: String) -> String {
        let p = day.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return day }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        var c = DateComponents(); c.year = p[0]; c.month = p[1]; c.day = p[2]
        guard let d = cal.date(from: c) else { return day }
        let wd = cal.component(.weekday, from: d)
        let wdName = (1...7).contains(wd) ? weekdays[wd] : ""
        let moName = (1...12).contains(p[1]) ? months[p[1]] : ""
        let s = "\(wdName) \(p[2]) \(moName) \(p[0])"
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    // MARK: Style

    private static let css = """
    :root{--bg:#f6f3ec;--card:#fffdf8;--ink:#17293b;--muted:#6a7787;--line:#e7e0d3;
    --accent:#c2411f;--chip-bg:#efe7db;--chip-ink:#8a6038;--tag-bg:#e9eef2;--tag-ink:#5b6b7c}
    @media (prefers-color-scheme:dark){:root{--bg:#0e1a26;--card:#15222f;--ink:#e9eef3;
    --muted:#8599ab;--line:#223342;--accent:#e2683f;--chip-bg:#2a2016;--chip-ink:#e0b483;
    --tag-bg:#1d2b39;--tag-ink:#8fa3b6}}
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--ink);
    font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Ubuntu,sans-serif}
    .wrap{max-width:760px;margin:0 auto;padding:32px 16px 80px}
    header{margin-bottom:24px}
    h1{font-size:20px;margin:0 0 2px;letter-spacing:.2px}
    .date{color:var(--muted)}
    .sub{color:var(--muted);font-size:13px;margin-top:6px}
    .card{background:var(--card);border:1px solid var(--line);border-radius:12px;
    padding:14px 16px;margin:10px 0;box-shadow:0 1px 2px rgba(0,0,0,.03)}
    .chead{display:flex;flex-wrap:wrap;align-items:baseline;gap:8px}
    .time{font-variant-numeric:tabular-nums;color:var(--accent);font-weight:600;font-size:13px}
    .app{font-weight:650}
    .win{color:var(--muted)}
    .dur{color:var(--muted);font-size:13px}
    .lock{margin-left:auto;font-size:13px}
    .url{color:var(--muted);font-size:12.5px;margin-top:3px;word-break:break-all;
    font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
    .body{margin-top:10px;display:flex;flex-direction:column;gap:8px}
    .ev{display:flex;gap:8px;align-items:flex-start}
    .tag{flex:none;font-size:11px;text-transform:uppercase;letter-spacing:.4px;
    background:var(--tag-bg);color:var(--tag-ink);padding:2px 7px;border-radius:6px;margin-top:2px}
    .text{word-break:break-word}
    .pfx{display:inline-block;font-size:10px;text-transform:uppercase;letter-spacing:.4px;
    color:var(--muted);border:1px solid var(--line);border-radius:4px;padding:0 5px;margin-right:6px}
    .chrome{color:var(--muted);font-size:13px}
    .red{background:var(--chip-bg);color:var(--chip-ink);border-radius:5px;
    padding:0 6px;font-size:12.5px;white-space:nowrap}
    .empty{color:var(--muted);text-align:center;padding:60px 0}
    footer{color:var(--muted);font-size:12px;text-align:center;margin-top:30px}
    """
}
