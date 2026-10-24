import AppKit
import ApplicationServices
import RedactorCore

/// Thin helpers around the Accessibility C API.
enum AX {
    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? {
        attr(el, name) as? String
    }

    static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    /// Fetch several attributes in one IPC round trip. Missing ones come back nil.
    static func multiple(_ el: AXUIElement, _ names: [String]) -> [Any?] {
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            el, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard err == .success, let arr = values as? [AnyObject], arr.count == names.count else {
            return Array(repeating: nil, count: names.count)
        }
        return arr.map { obj -> Any? in
            if CFGetTypeID(obj) == AXValueGetTypeID(), AXValueGetType(obj as! AXValue) == .axError {
                return nil
            }
            return obj
        }
    }

    static func urlString(_ v: Any?) -> String? {
        if let u = v as? URL { return u.absoluteString }
        if let s = v as? String, !s.isEmpty { return s }
        return nil
    }

    @discardableResult
    static func setBool(_ el: AXUIElement, _ name: String, _ value: Bool) -> AXError {
        AXUIElementSetAttributeValue(el, name as CFString, value as CFTypeRef)
    }

    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }
}

/// Reading a window's text and a browser's URL.
enum AXReader {
    static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta",
        "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]
    static let browsers: Set<String> = chromiumBrowsers.union(["com.apple.Safari", "org.mozilla.firefox"])

    static let textInputRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    static let labelledRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXMenuButton", "AXTab", "AXLink", "AXDisclosureTriangle",
    ]

    static let nodeFields = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute, kAXTitleAttribute,
        kAXDescriptionAttribute, kAXChildrenAttribute,
    ] as [String]
    static let nameFields = [
        kAXPlaceholderValueAttribute, kAXIdentifierAttribute, "AXDOMIdentifier", kAXHelpAttribute,
    ] as [String]

    /// Make Chromium and Electron apps build their accessibility trees.
    static func enableAccessibility(pid: pid_t, bundleID: String?) {
        let app = AXUIElementCreateApplication(pid)
        AX.setBool(app, "AXManualAccessibility", true)   // Electron (Slack, VS Code, ...)
        if let b = bundleID, chromiumBrowsers.contains(b) {
            AX.setBool(app, "AXEnhancedUserInterface", true)
        }
    }

    /// True if this text-input element must never be read.
    static func isSensitive(_ el: AXUIElement, role: String?, subrole: String?, title: String?, desc: String?) -> Bool {
        if Redactor.isSensitiveField(role: role, subrole: subrole, names: [title, desc]) { return true }
        let extra = AX.multiple(el, nameFields).map { $0 as? String }
        if Redactor.isSensitiveField(role: nil, subrole: nil, names: extra) { return true }
        if let labelEl = AX.element(el, kAXTitleUIElementAttribute) {
            let label = AX.string(labelEl, kAXValueAttribute) ?? AX.string(labelEl, kAXTitleAttribute)
            if Redactor.isSensitiveFieldName(label ?? "") { return true }
        }
        return false
    }

    struct Snapshot {
        var text: String
        var truncated: Bool
    }

    /// Walk the window's tree and collect readable text, one line per node.
    static func windowText(_ window: AXUIElement, timeBudget: TimeInterval = 3, nodeBudget: Int = 60_000) -> Snapshot {
        var lines: [String] = []
        var visited = 0
        let deadline = Date().addingTimeInterval(timeBudget)
        var truncated = false

        func add(_ s: String?) {
            guard var s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return }
            if s.count > 200_000 { s = String(s.prefix(200_000)) }
            if lines.last != s { lines.append(s) }
        }

        // Iterative DFS keeps document order and avoids deep recursion.
        var stack: [AXUIElement] = [window]
        while let el = stack.popLast() {
            visited += 1
            if visited > nodeBudget || (visited % 200 == 0 && Date() > deadline) {
                truncated = true
                break
            }
            let v = AX.multiple(el, nodeFields)
            let role = v[0] as? String
            let subrole = v[1] as? String
            let value = v[2]
            let title = v[3] as? String
            let desc = v[4] as? String
            let kids = (v[5] as? [AXUIElement]) ?? []

            if role == "AXSecureTextField" || subrole == "AXSecureTextField" { continue }

            switch role ?? "" {
            case "AXStaticText":
                add(value as? String ?? title)
            case let r where textInputRoles.contains(r):
                if isSensitive(el, role: role, subrole: subrole, title: title, desc: desc) { continue }
                add(value as? String)
            case "AXHeading":
                add(title ?? desc)
            case let r where labelledRoles.contains(r):
                add((title?.isEmpty == false) ? title : desc)
            case "AXImage":
                break
            default:
                break
            }
            // Push children reversed so the first child is processed first.
            stack.append(contentsOf: kids.reversed())
        }
        return Snapshot(text: lines.joined(separator: "\n"), truncated: truncated)
    }

    static func menuTitles(app: AXUIElement) -> String? {
        guard let bar = AX.element(app, kAXMenuBarAttribute) else { return nil }
        let titles = AX.children(bar).compactMap { AX.string($0, kAXTitleAttribute) }.filter { !$0.isEmpty }
        return titles.isEmpty ? nil : titles.joined(separator: " · ")
    }

    /// Breadth-first search for the first AXWebArea (limited depth).
    static func findWebArea(_ root: AXUIElement, maxDepth: Int = 12) -> AXUIElement? {
        var level: [AXUIElement] = [root]
        for _ in 0..<maxDepth {
            var next: [AXUIElement] = []
            for el in level {
                if AX.string(el, kAXRoleAttribute) == "AXWebArea" { return el }
                next.append(contentsOf: AX.children(el))
            }
            if next.isEmpty { return nil }
            level = next
        }
        return nil
    }

    /// URL from the web area, falling back to the address bar text field.
    static func browserURL(window: AXUIElement, webArea: AXUIElement?) -> String? {
        if let wa = webArea, let u = AX.urlString(AX.attr(wa, kAXURLAttribute)), !u.hasPrefix("about:") {
            return u
        }
        return nil
    }

    /// AppleScript fallback (asks for Automation permission once per browser).
    static func appleScriptURL(bundleID: String) -> String? {
        let source: String
        switch bundleID {
        case "com.apple.Safari":
            source = "tell application id \"com.apple.Safari\" to get URL of front document"
        case let b where chromiumBrowsers.contains(b):
            source = "tell application id \"\(b)\" to get URL of active tab of front window"
        default:
            return nil
        }
        var result: String?
        let run = {
            var err: NSDictionary?
            result = NSAppleScript(source: source)?.executeAndReturnError(&err).stringValue
        }
        if Thread.isMainThread { run() } else { DispatchQueue.main.sync(execute: run) }
        return result
    }
}
