// Task timer in the menu bar: click, name the task, and it runs. Pause / resume / stop from its menu.
// Stopping saves the task's name, start and finish, time worked, every pause, and which apps you were in,
// to ~/.claude/voice/timelog/ (sessions.jsonl for data, timelog.md to read). A running timer survives restarts.
import AppKit
import Combine
import SwiftUI

struct TimerPause: Codable { var start: Date; var end: Date? }

struct TimerRun: Codable {
    var name: String
    var start: Date
    var pauses: [TimerPause] = []
    var apps: [String: Double] = [:]          // app name -> seconds while running (not paused)
    var end: Date? = nil

    var paused: Bool { pauses.last.map { $0.end == nil } ?? false }
    func pausedSeconds(at now: Date = Date()) -> Double {
        pauses.reduce(0) { $0 + (($1.end ?? now).timeIntervalSince($1.start)) }
    }
    func activeSeconds(at now: Date = Date()) -> Double {
        max(0, (end ?? now).timeIntervalSince(start) - pausedSeconds(at: end ?? now))
    }
}

final class TaskTimer: ObservableObject {
    static let shared = TaskTimer()
    @Published private(set) var run: TimerRun? = nil
    @Published var now = Date()
    @Published var promptShown = false
    @Published var draft = ""
    var busy: Bool { promptShown || menuOpen }           // keep the menu bar down while you're using it
    private(set) var menuOpen = false

    static let dir = NSHomeDirectory() + "/.claude/voice/timelog"
    private static var current: String { dir + "/current.json" }
    private var tick: Timer?
    private var lastTick = Date()
    private var prompt: TypePanel?
    private var statusItem: NSStatusItem?
    private var sinks: [AnyCancellable] = []

    private init() {
        try? FileManager.default.createDirectory(atPath: Self.dir, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: URL(fileURLWithPath: Self.current)),
           let r = try? Self.decoder.decode(TimerRun.self, from: d) { run = r }      // a timer that was running
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(tick!, forMode: .common)
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    /// Every second: the clock, and a second for whichever app is in front (only while running).
    private func step() {
        let t = Date()
        let dt = min(5, t.timeIntervalSince(lastTick))       // the Mac slept: don't credit the gap to an app
        lastTick = t
        now = t
        guard var r = run, !r.paused else { updateStatusItem(); return }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        r.apps[app, default: 0] += dt
        run = r
        if Int(t.timeIntervalSince1970) % 15 == 0 { persist() }
        updateStatusItem()
    }

    private func persist() {
        if let r = run, let d = try? Self.encoder.encode(r) { try? d.write(to: URL(fileURLWithPath: Self.current), options: .atomic) }
        else { try? FileManager.default.removeItem(atPath: Self.current) }
    }

    // MARK: actions

    func start(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        run = TimerRun(name: n.isEmpty ? "Untitled task" : n, start: Date())
        lastTick = Date()
        persist(); updateStatusItem()
    }

    func togglePause() {
        guard var r = run else { return }
        if r.paused { r.pauses[r.pauses.count - 1].end = Date() } else { r.pauses.append(TimerPause(start: Date())) }
        run = r; persist(); updateStatusItem()
    }

    func stop(save: Bool = true) {
        guard var r = run else { return }
        let t = Date()
        if r.paused { r.pauses[r.pauses.count - 1].end = t }
        r.end = t
        if save { write(r) }
        run = nil; persist(); updateStatusItem()
    }

    private func write(_ r: TimerRun) {
        let end = r.end ?? Date()
        let apps = r.apps.sorted { $0.value > $1.value }.filter { $0.value >= 1 }
        // data: one JSON object per task
        let row: [String: Any] = [
            "name": r.name,
            "start": ISO8601DateFormatter().string(from: r.start),
            "end": ISO8601DateFormatter().string(from: end),
            "worked_seconds": Int(r.activeSeconds(at: end)),
            "paused_seconds": Int(r.pausedSeconds(at: end)),
            "total_seconds": Int(end.timeIntervalSince(r.start)),
            "pauses": r.pauses.map { ["start": ISO8601DateFormatter().string(from: $0.start),
                                      "end": ISO8601DateFormatter().string(from: $0.end ?? end),
                                      "seconds": Int(($0.end ?? end).timeIntervalSince($0.start))] },
            "apps": apps.map { ["app": $0.key, "seconds": Int($0.value)] },
        ]
        if let d = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
            append(Self.dir + "/sessions.jsonl", d + Data("\n".utf8))
        }
        // readable log
        let day = DateFormatter(); day.dateFormat = "EEE, MMM d, yyyy"
        let clock = DateFormatter(); clock.dateFormat = "h:mm a"
        var md = "\n## \(r.name)\n"
        md += "*\(day.string(from: r.start)), \(clock.string(from: r.start)) → \(clock.string(from: end))*\n\n"
        md += "- **Worked:** \(Self.dur(r.activeSeconds(at: end)))"
        if !r.pauses.isEmpty { md += " · paused \(Self.dur(r.pausedSeconds(at: end))) in \(r.pauses.count) break\(r.pauses.count == 1 ? "" : "s")" }
        md += "\n"
        for p in r.pauses {
            md += "  - Pause \(clock.string(from: p.start)) → \(clock.string(from: p.end ?? end)) (\(Self.dur((p.end ?? end).timeIntervalSince(p.start))))\n"
        }
        if !apps.isEmpty {
            md += "- **Apps:** " + apps.prefix(8).map { "\($0.key) \(Self.dur($0.value))" }.joined(separator: " · ") + "\n"
        }
        let path = Self.dir + "/timelog.md"
        if !FileManager.default.fileExists(atPath: path) { append(path, Data("# Time log\n".utf8)) }
        append(path, Data(md.utf8))
    }

    private func append(_ path: String, _ d: Data) {
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(d); try? h.close() }
        else { FileManager.default.createFile(atPath: path, contents: d) }
    }

    static func dur(_ s: Double) -> String {
        let t = Int(s.rounded()), h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? "\(h)h \(m)m" : m > 0 ? "\(m)m \(sec)s" : "\(sec)s"
    }

    static func clock(_ s: Double) -> String {
        let t = Int(s), h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    // MARK: clicking it

    /// Not running: ask for the task's name. Running: its menu.
    func click(_ v: NSView, _ pt: CGPoint) {
        if run == nil { askName(below: v) } else { showMenu(v, pt) }
    }

    func showMenu(_ v: NSView, _ pt: CGPoint) {
        guard let r = run else { return }
        let m = NSMenu(); m.autoenablesItems = false
        let h = NSMenuItem(title: "\(r.name) · \(Self.clock(r.activeSeconds()))", action: nil, keyEquivalent: ""); h.isEnabled = false
        m.addItem(h)
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        let s = NSMenuItem(title: "Started \(f.string(from: r.start))" + (r.pauses.isEmpty ? "" : " · \(r.pauses.count) pause\(r.pauses.count == 1 ? "" : "s")"),
                           action: nil, keyEquivalent: ""); s.isEnabled = false
        m.addItem(s)
        m.addItem(.separator())
        m.addItem(ActionItem(r.paused ? "Resume" : "Pause") { [weak self] in self?.togglePause() })
        m.addItem(ActionItem("Stop and save") { [weak self] in self?.stop() })
        m.addItem(.separator())
        m.addItem(ActionItem("Discard (don't save)") { [weak self] in self?.stop(save: false) })
        m.addItem(ActionItem("Open time log") { Self.openLog() })
        menuOpen = true
        m.popUp(positioning: nil, at: pt, in: v)
        menuOpen = false
    }

    static func openLog() {
        let path = dir + "/timelog.md"
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: Data("# Time log\n".utf8)) }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func askName(below v: NSView) {
        guard let w = v.window else { return }
        let r = w.convertToScreen(v.convert(v.bounds, to: nil))
        askName(at: NSPoint(x: r.midX, y: r.minY - 6))
    }

    func askName(at top: NSPoint) {
        if prompt == nil {
            let p = TypePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: TimerPromptView(t: self))
            p.onResign = { [weak self] in self?.closePrompt() }
            prompt = p
        }
        let w: CGFloat = 300, h: CGFloat = 110
        let screen = NSScreen.screens.first { $0.frame.contains(top) }?.frame ?? NSScreen.screens[0].frame
        let x = min(max(top.x - w / 2, screen.minX + 8), screen.maxX - w - 8)
        prompt?.setFrame(NSRect(x: x, y: top.y - h, width: w, height: h), display: true)
        draft = ""
        NSApp.activate(ignoringOtherApps: true)
        prompt?.makeKeyAndOrderFront(nil)
        promptShown = true
    }

    func closePrompt() {
        guard promptShown else { return }
        promptShown = false
        let p = prompt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in if self?.promptShown == false { p?.orderOut(nil) } }
    }

    // MARK: the macOS menu bar too (outside OS mode)

    func installStatusItem() {
        guard statusItem == nil else { return }
        let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        s.button?.target = self
        s.button?.action = #selector(statusClick(_:))
        statusItem = s
        updateStatusItem()
    }

    @objc private func statusClick(_ b: NSStatusBarButton) {
        if run == nil { askName(below: b) } else { showMenu(b, NSPoint(x: 0, y: b.bounds.height + 4)) }
    }

    private func updateStatusItem() {
        guard let b = statusItem?.button else { return }
        let img = NSImage(systemSymbolName: run == nil ? "timer" : (run!.paused ? "pause.circle" : "timer"), accessibilityDescription: "Task timer")
        b.image = img; b.imagePosition = .imageLeading
        b.title = run.map { " " + Self.clock($0.activeSeconds()) } ?? ""
    }
}

/// The menu bar chip: a timer icon; running, the task's name and time.
struct TimerChip: View {
    @ObservedObject var t: TaskTimer = .shared
    var body: some View {
        HStack(spacing: 5) {
            if let r = t.run {
                Circle().fill(Color.white.opacity(r.paused ? 0.35 : 1)).frame(width: 6, height: 6)
                    .opacity(r.paused ? 1 : (Int(t.now.timeIntervalSince1970) % 2 == 0 ? 1 : 0.45))
                    .animation(.easeInOut(duration: 0.6), value: t.now)
                Text(r.name).font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.7)).lineLimit(1).frame(maxWidth: 120, alignment: .leading)
                Text(TaskTimer.clock(r.activeSeconds(at: t.now)))
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundColor(r.paused ? .white.opacity(0.5) : .white)
                if r.paused { Image(systemName: "pause.fill").font(.system(size: 8, weight: .bold)).foregroundColor(.white.opacity(0.5)) }
            } else {
                Image(systemName: "timer").font(.system(size: 12, weight: .semibold)).foregroundColor(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, t.run == nil ? 0 : 8).frame(minWidth: 22, minHeight: 22)
        .background(Capsule().fill(Color.white.opacity(t.run == nil ? 0 : 0.08)))
        .animation(OSMotion.show, value: t.run == nil)
        .contentShape(Rectangle())
        .help(t.run == nil ? "Start a task timer" : "Pause, stop or open the time log")
    }
}

/// "What are you working on?" — Return starts the timer, Esc cancels.
struct TimerPromptView: View {
    @ObservedObject var t: TaskTimer
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What are you working on?").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.55))
            HStack(spacing: 8) {
                TextField("Task name", text: $t.draft)
                    .textFieldStyle(.plain).font(.system(size: 14, design: .rounded)).foregroundColor(.white)
                    .focused($focused)
                    .onSubmit(go)
                Button(action: go) {
                    Image(systemName: "play.fill").font(.system(size: 10, weight: .bold)).foregroundColor(.black)
                        .frame(width: 24, height: 24).background(Circle().fill(Color.white))
                }.buttonStyle(.plain).help("Start")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(width: 280)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.08).opacity(0.97))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 12, y: 3))
        .scaleEffect(t.promptShown ? 1 : 0.92, anchor: .top)
        .offset(y: t.promptShown ? 0 : -6)
        .opacity(t.promptShown ? 1 : 0)
        .animation(t.promptShown ? OSMotion.show : .easeInOut(duration: 0.3), value: t.promptShown)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onExitCommand { t.closePrompt() }
        .onChange(of: t.promptShown) { on in if on { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } } }
    }
    func go() { t.start(t.draft); t.closePrompt() }
}
