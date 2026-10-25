import AppKit
import ApplicationServices
import CryptoKit
import RedactorCore

/// What the main thread observed this tick and hands to the recorder queue.
struct TickInput {
    var active: Bool
    var pid: pid_t?
    var appName: String?
    var bundleID: String?
    var clipboardText: String?
    var scrolledAt: Date?
}

struct DayStats {
    var day: String
    var entries: Int
    var redactions: Int
    var bytes: UInt64
}

/// All AX reads and file writes happen on one serial queue, so all mutable
/// state is confined to `queue` (hence @unchecked Sendable).
final class Recorder: @unchecked Sendable {
    let queue = DispatchQueue(label: "daylog.recorder", qos: .utility)

    var writer: LogWriter?
    var onStats: ((DayStats) -> Void)?
    var onError: ((String) -> Void)?

    private struct Context: Equatable {
        var pid: pid_t
        var app: String?
        var bundleID: String?
        var windowTitle: String?
        var url: String?
        var pageTitle: String?
        var key: String { "\(bundleID ?? "")|\(windowTitle ?? "")|\(url ?? "")" }
    }

    private var current: Context?
    private var currentSince = Date()
    private var lastTextHash: String?
    private var lastTextCheck = Date.distantPast
    private var lastScrollHandled: Date?

    private var enabledPIDs = Set<pid_t>()
    private var appleScriptURLCache: [String: String] = [:]   // window key -> url

    // typing
    private var focusedField: AXUIElement?
    private var fieldValue: String?
    private var fieldChangedAt = Date.distantPast
    private var fieldPending = false
    private var lastTypingHash: String?

    // selection
    private var selectionCandidate: String?
    private var lastSelection: String?

    /// Lines already written today, per app (bundle id). Only lines not in
    /// here are written again, so revisiting Gmail or a long Terminal session
    /// costs only what is new. Reset at midnight, on folder change and on
    /// "delete today". Process-local hashes: a restart writes everything once.
    private var seenLines: [String: Set<Int>] = [:]
    private static let maxSeenPerApp = 300_000
    private static let dayFileName = try! NSRegularExpression(pattern: "\\d{4}-\\d{2}-\\d{2}(?:-\\d+)?\\.jsonl")

    private var stats = DayStats(day: LogWriter.dayString(), entries: 0, redactions: 0, bytes: 0)
    private let defaults = UserDefaults.standard

    init() {
        // Global timeout so one hung app cannot stall the recorder.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
    }

    // MARK: Public (call on `queue`)

    func loadStats() {
        let day = LogWriter.dayString()
        let d = defaults.dictionary(forKey: "stats-\(day)") ?? [:]
        seenLines.removeAll()
        stats = DayStats(day: day,
                         entries: d["entries"] as? Int ?? 0,
                         redactions: d["redactions"] as? Int ?? 0,
                         bytes: todayBytes())
        onStats?(stats)
    }

    func tick(_ input: TickInput) {
        let now = Date()
        if stats.day != LogWriter.dayString(now) { loadStats() }

        guard input.active, let pid = input.pid else {
            closeCurrent(now)
            return
        }
        if pid == ProcessInfo.processInfo.processIdentifier { return }

        let blocked = Redactor.isBlockedApp(bundleID: input.bundleID, name: input.appName)

        if !blocked, !enabledPIDs.contains(pid) {
            AXReader.enableAccessibility(pid: pid, bundleID: input.bundleID)
            enabledPIDs.insert(pid)
        }

        let appEl = AXUIElementCreateApplication(pid)

        var ctx = Context(pid: pid, app: input.appName, bundleID: input.bundleID)
        var window: AXUIElement?
        var webArea: AXUIElement?
        if !blocked {
            window = AX.element(appEl, kAXFocusedWindowAttribute) ?? AX.element(appEl, kAXMainWindowAttribute)
            if let w = window {
                ctx.windowTitle = AX.string(w, kAXTitleAttribute)
                if let b = input.bundleID, AXReader.browsers.contains(b) {
                    webArea = AXReader.findWebArea(w)
                    ctx.pageTitle = webArea.flatMap { AX.string($0, kAXTitleAttribute) } ?? ctx.windowTitle
                    ctx.url = AXReader.browserURL(window: w, webArea: webArea)
                    if ctx.url == nil {
                        let cacheKey = "\(b)|\(ctx.windowTitle ?? "")"
                        if let cached = appleScriptURLCache[cacheKey] {
                            ctx.url = cached
                        } else if let u = AXReader.appleScriptURL(bundleID: b) {
                            appleScriptURLCache[cacheKey] = u
                            ctx.url = u
                        }
                    }
                }
            }
        }

        // Our own log open in an editor, Terminal, Quick Look …: record that
        // the window was used, never its text (it would record itself).
        let selfView = !blocked && isLogView(window: window, ctx: ctx)
        let textless = blocked || selfView

        // 1. Context switch → leave + focus
        if current?.key != ctx.key {
            closeCurrent(now)
            current = ctx
            currentSince = now
            var text: String? = nil
            if !textless, let w = window {
                let snap = AXReader.windowText(webArea ?? w)
                var parts: [String] = []
                if let menus = AXReader.menuTitles(app: appEl) { parts.append("[menu] " + menus) }
                if webArea != nil {
                    // Browser chrome (tabs, toolbar) lives outside the web area.
                    let chrome = AXReader.windowText(w, timeBudget: 1, nodeBudget: 3000).text
                    if !chrome.isEmpty { parts.append("[window] " + String(chrome.prefix(4000))) }
                }
                parts.append(snap.text)
                text = newLines(parts.joined(separator: "\n"), app: ctx.bundleID)
                lastTextHash = hash(snap.text)
            } else {
                lastTextHash = nil
            }
            lastTextCheck = now
            emit("focus", ctx, text: text, blocked: blocked)
            resetField()
        } else if !textless, let w = window {
            // 2. Every 10 s: content changed?
            let scrollDue: Bool = {
                guard let s = input.scrolledAt, now.timeIntervalSince(s) >= 1 else { return false }
                return lastScrollHandled != s
            }()
            if scrollDue || now.timeIntervalSince(lastTextCheck) >= 10 {
                let snap = AXReader.windowText(webArea ?? w)
                let h = hash(snap.text)
                if h != lastTextHash {
                    if let added = newLines(snap.text, app: ctx.bundleID) {
                        emit(scrollDue ? "scroll" : "update", ctx, text: added, blocked: false)
                    }
                    lastTextHash = h
                }
                lastTextCheck = now
                if scrollDue { lastScrollHandled = input.scrolledAt }
            }
        }

        // 3. Typing and selection in the focused element
        if !textless {
            trackFocusedField(appEl: appEl, ctx: ctx, now: now)
        } else {
            resetField()
        }

        // 4. Clipboard (already filtered for concealed types on main)
        if let clip = input.clipboardText, !textless, !looksLikeOwnLog(clip) {
            emit("clipboard", ctx, text: clip, blocked: false)
        }
    }

    func pauseOrStop() {
        closeCurrent(Date())
    }

    func deleteToday() {
        guard let w = writer else { return }
        let day = LogWriter.dayString()
        for u in LogWriter.dayFiles(folder: w.folder, day: day) {
            try? FileManager.default.removeItem(at: u)
        }
        defaults.removeObject(forKey: "stats-\(day)")
        current = nil
        lastTextHash = nil
        lastTypingHash = nil
        lastSelection = nil
        loadStats()
    }

    // MARK: Internals

    private func closeCurrent(_ now: Date) {
        flushTyping(force: true)
        guard let c = current else { return }
        let blocked = Redactor.isBlockedApp(bundleID: c.bundleID, name: c.app)
        emit("leave", c, text: nil, blocked: blocked, dwell: now.timeIntervalSince(currentSince))
        current = nil
        lastTextHash = nil
    }

    private func resetField() {
        focusedField = nil
        fieldValue = nil
        fieldPending = false
        selectionCandidate = nil
    }

    private func trackFocusedField(appEl: AXUIElement, ctx: Context, now: Date) {
        guard let el = AX.element(appEl, kAXFocusedUIElementAttribute) else { return }
        let v = AX.multiple(el, [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
                                 kAXDescriptionAttribute, kAXValueAttribute, kAXSelectedTextAttribute])
        let role = v[0] as? String
        let subrole = v[1] as? String
        let title = v[2] as? String
        let desc = v[3] as? String

        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            flushTyping(force: true)
            resetField()
            return
        }
        let isInput = role.map { AXReader.textInputRoles.contains($0) } ?? false
        let sensitive = isInput && AXReader.isSensitive(el, role: role, subrole: subrole, title: title, desc: desc)
        if sensitive {
            flushTyping(force: true)
            resetField()
            return
        }

        // Focus moved to another element → write what was typed in the old one.
        if let f = focusedField, !CFEqual(f, el) {
            flushTyping(force: true)
            resetField()
        }
        if focusedField == nil { focusedField = el; fieldValue = v[4] as? String }

        if isInput, let value = v[4] as? String, value != fieldValue {
            fieldValue = value
            fieldChangedAt = now
            fieldPending = true
        }
        if fieldPending, now.timeIntervalSince(fieldChangedAt) >= 2 {
            flushTyping(force: false)
        }

        // Selection: write once it has been stable for one tick.
        let sel = (v[5] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let s = sel, !s.isEmpty {
            if s == selectionCandidate, s != lastSelection {
                emit("selection", ctx, text: s, blocked: false)
                lastSelection = s
            }
            selectionCandidate = s
        } else {
            selectionCandidate = nil
        }
    }

    private func flushTyping(force: Bool) {
        guard fieldPending, let c = current, let value = fieldValue else { return }
        fieldPending = false
        let h = hash(value)
        guard h != lastTypingHash, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lastTypingHash = h
        // Fields like Terminal's scrollback hold everything ever shown; write
        // only lines not already logged for this app.
        guard let added = newLines(value, app: c.bundleID) else { return }
        emit("typing", c, text: added, blocked: false)
    }

    private func emit(_ event: String, _ c: Context, text: String?, blocked: Bool, dwell: Double? = nil) {
        guard let writer else { return }
        var e = LogEvent(ts: Date(), event: event, app: c.app, bundleID: c.bundleID)
        var n = 0
        var kinds: [String: Int] = [:]
        func clean(_ s: String?) -> String? {
            guard let s, !s.isEmpty else { return nil }
            let r = Redactor.redact(s)
            n += r.count
            for k in r.kinds { kinds[k, default: 0] += 1 }
            return r.text
        }
        if !blocked {
            e.windowTitle = clean(c.windowTitle)
            e.url = clean(c.url)
            e.pageTitle = clean(c.pageTitle)
            e.text = clean(text)
        }
        e.redactions = n
        e.redactionKinds = kinds
        e.dwellSeconds = dwell
        do {
            let bytes = try writer.append(e)
            stats.entries += 1
            stats.redactions += n
            stats.bytes += UInt64(bytes)
            defaults.set(["entries": stats.entries, "redactions": stats.redactions], forKey: "stats-\(stats.day)")
            onStats?(stats)
        } catch {
            onError?("Kunde inte skriva: \(error.localizedDescription)")
        }
    }

    /// Lines of `text` not yet written today for this app (nil if none).
    /// Also drops lines that are our own JSONL records.
    private func newLines(_ text: String, app: String?) -> String? {
        let key = app ?? "?"
        var set = seenLines[key] ?? []
        if set.count > Self.maxSeenPerApp { set.removeAll() }
        var out: [Substring] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || isOwnLogLine(line) { continue }
            if set.insert(line.hashValue).inserted { out.append(raw) }
        }
        seenLines[key] = set
        return out.isEmpty ? nil : out.joined(separator: "\n")
    }

    private func isOwnLogLine(_ line: String) -> Bool {
        line.hasPrefix("{\"ts\":\"") || (line.contains("\"event\":\"") && line.contains("\"bundle_id\":"))
    }

    private func looksLikeOwnLog(_ text: String) -> Bool {
        text.split(separator: "\n").prefix(3).contains { isOwnLogLine($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// True if the focused window shows one of our day files.
    private func isLogView(window: AXUIElement?, ctx: Context) -> Bool {
        for s in [ctx.windowTitle, ctx.pageTitle, ctx.url].compactMap({ $0 }) {
            if Redactor.matches(Self.dayFileName, s) { return true }
        }
        guard let w = window, let folder = writer?.folder,
              let doc = AX.string(w, kAXDocumentAttribute), let docURL = URL(string: doc), docURL.isFileURL
        else { return false }
        let logDir = folder.resolvingSymlinksInPath().path
        return docURL.resolvingSymlinksInPath().path.hasPrefix(logDir + "/")
    }

    private func todayBytes() -> UInt64 {
        guard let w = writer else { return 0 }
        return LogWriter.dayFiles(folder: w.folder, day: LogWriter.dayString()).reduce(0) { $0 + LogWriter.size($1) }
    }

    private func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
