import AppKit
import SwiftUI
import RedactorCore

@main
struct DayLogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(state: delegate.state)
        } label: {
            MenuLabel(state: delegate.state)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon even when run unbundled
        state.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Write the final "leave" line, but never hang quit if the recorder is busy.
        let rec = state.recorder
        let done = DispatchSemaphore(value: 0)
        rec.queue.async { rec.pauseOrStop(); done.signal() }
        _ = done.wait(timeout: .now() + 1.5)
    }
}

// MARK: - State

@MainActor
final class AppState: ObservableObject {
    enum Pause: Equatable { case none, until(Date), indefinitely }

    @Published var folder: URL?
    @Published var trusted = false
    @Published var pause: Pause = .none
    @Published var locked = false
    @Published var stats = DayStats(day: LogWriter.dayString(), entries: 0, redactions: 0, bytes: 0)
    @Published var lastError: String?

    let recorder = Recorder()
    private var timer: Timer?
    private var lastPasteboardCount = NSPasteboard.general.changeCount
    private var scrolledAt: Date?
    private var scrollMonitor: Any?
    private let bookmarkKey = "folderBookmark"

    var isRecording: Bool { folder != nil && trusted && !isPaused && !locked }
    var isPaused: Bool {
        switch pause {
        case .none: return false
        case .indefinitely: return true
        case .until(let d): return d > Date()
        }
    }

    func start() {
        recorder.onStats = { [weak self] s in
            guard let self else { return }
            Task { @MainActor in self.stats = s }
        }
        recorder.onError = { [weak self] m in
            guard let self else { return }
            Task { @MainActor in self.lastError = m }
        }

        trusted = AX.isTrusted(prompt: true)
        restoreFolder()
        if folder == nil { chooseFolder() }

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.locked = true }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.locked = false }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.tick() }
        }
    }

    private func tick() {
        if !trusted {
            trusted = AX.isTrusted(prompt: false)
            if trusted { installScrollMonitor() }
        } else if scrollMonitor == nil {
            installScrollMonitor()
        }
        if case .until(let d) = pause, d <= Date() { pause = .none }

        let active = isRecording
        let front = NSWorkspace.shared.frontmostApplication
        var input = TickInput(active: active,
                              pid: front?.processIdentifier,
                              appName: front?.localizedName,
                              bundleID: front?.bundleIdentifier,
                              clipboardText: nil,
                              scrolledAt: scrolledAt)

        // Clipboard: always advance the counter so nothing copied during a
        // pause is written later.
        let pb = NSPasteboard.general
        if pb.changeCount != lastPasteboardCount {
            lastPasteboardCount = pb.changeCount
            let types = (pb.types ?? []).map(\.rawValue)
            let blockedApp = Redactor.isBlockedApp(bundleID: front?.bundleIdentifier, name: front?.localizedName)
            if active, !blockedApp, !Redactor.isConcealedPasteboard(types: types) {
                input.clipboardText = pb.string(forType: .string)
            }
        }

        let rec = recorder
        let snapshot = input
        rec.queue.async { rec.tick(snapshot) }
    }

    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.scrolledAt = Date() }
        }
    }

    // MARK: Folder

    func chooseFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Välj mapp för Squidpal"
        panel.message = "Dagsfilerna (ÅÅÅÅ-MM-DD.jsonl) sparas här. Välj en synkad mapp om du vill ha dem i Drive/Dropbox/iCloud."
        panel.prompt = "Välj"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url)
        let data = (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        if let data { UserDefaults.standard.set(data, forKey: bookmarkKey) }
    }

    private func restoreFolder() {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var stale = false
        let url = (try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
        guard let url else { return }
        setFolder(url)
        if stale, let fresh = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
    }

    private func setFolder(_ url: URL) {
        folder?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        folder = url
        let rec = recorder
        rec.queue.async {
            rec.pauseOrStop()
            rec.writer = LogWriter(folder: url)
            rec.loadStats()
        }
    }

    // MARK: Menu actions

    func pauseRecording(minutes: Int?) {
        pause = minutes.map { .until(Date().addingTimeInterval(Double($0) * 60)) } ?? .indefinitely
        let rec = recorder
        rec.queue.async { rec.pauseOrStop() }
    }

    func resume() { pause = .none }

    func showTimeline() {
        guard let folder else { return }
        let files = LogWriter.dayFiles(folder: folder, day: LogWriter.dayString())
        guard !files.isEmpty else { return }
        if let url = Timeline.build(files: files, day: LogWriter.dayString()) {
            NSWorkspace.shared.open(url)
        }
    }

    func openToday() {
        guard let folder,
              let url = LogWriter.dayFiles(folder: folder, day: LogWriter.dayString()).last else { return }
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit,
                                    configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    func revealFolder() {
        if let folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
    }

    func deleteToday() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Radera dagens fil?"
        alert.informativeText = "Alla poster från idag tas bort permanent från mappen."
        alert.addButton(withTitle: "Radera")
        alert.addButton(withTitle: "Avbryt")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let rec = recorder
        rec.queue.async { rec.deleteToday() }
    }

    func openAccessibilitySettings() {
        _ = AX.isTrusted(prompt: true)
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }
}

// MARK: - Views

struct MenuLabel: View {
    @ObservedObject var state: AppState
    var body: some View {
        if state.isRecording {
            // Coloured (non-template) so "recording" stands out on any menu bar.
            Image(nsImage: MenuIcon.image(.recording)).renderingMode(.original)
        } else if state.folder == nil || !state.trusted {
            Image(nsImage: MenuIcon.image(.warning)).renderingMode(.template)
        } else {
            Image(nsImage: MenuIcon.image(.paused)).renderingMode(.template)
        }
    }
}

struct MenuContent: View {
    @ObservedObject var state: AppState

    var statusLine: String {
        if state.folder == nil { return "⚠︎ Ingen mapp vald – spelar inte in" }
        if !state.trusted { return "⚠︎ Tillgänglighetstillstånd saknas – spelar inte in" }
        if state.locked { return "Skärmen är låst – spelar inte in" }
        switch state.pause {
        case .indefinitely: return "⏸ Pausad tills du slår på igen"
        case .until(let d) where d > Date():
            return "⏸ Pausad till \(d.formatted(date: .omitted, time: .shortened))"
        default: return "● Spelar in"
        }
    }

    var body: some View {
        Text(statusLine)
        Divider()
        Text("Idag: \(state.stats.entries) poster · \(state.stats.redactions) maskeringar")
        Text("Filstorlek: \(ByteCountFormatter.string(fromByteCount: Int64(state.stats.bytes), countStyle: .file))")
        if let err = state.lastError { Text(err) }
        Divider()
        if state.isPaused {
            Button("Slå på inspelning") { state.resume() }
        } else {
            Menu("Pausa") {
                Button("15 minuter") { state.pauseRecording(minutes: 15) }
                Button("1 timme") { state.pauseRecording(minutes: 60) }
                Button("Tills jag slår på igen") { state.pauseRecording(minutes: nil) }
            }
        }
        if !state.trusted {
            Button("Ge tillgänglighetstillstånd…") { state.openAccessibilitySettings() }
        }
        Divider()
        Button("Visa dagens tidslinje") { state.showTimeline() }
        Button("Öppna dagens fil") { state.openToday() }
        Button("Visa mappen i Finder") { state.revealFolder() }
        Button("Radera dagens fil…") { state.deleteToday() }
        Button(state.folder == nil ? "Välj mapp…" : "Byt mapp…") { state.chooseFolder() }
        if let f = state.folder { Text(f.path).font(.caption) }
        Divider()
        Button("Avsluta Squidpal") { NSApp.terminate(nil) }
    }
}
