// A focus timer that's always on screen (any length you set). Click: start / pause. When it's done every
// screen goes dark except the timer, which glows and shakes: click it to start again, or the red +extra
// for a little more time (you set it too). Finished timers and extras are counted per timer length. Two-finger click: length, counts.
import AppKit
import SwiftUI

final class PomodoroModel: ObservableObject {
    /// The timer's length and the extra's length, in seconds (you set both).
    @Published var seconds: Int = {
        let d = UserDefaults.standard
        if d.integer(forKey: "pomodoroSeconds") > 0 { return d.integer(forKey: "pomodoroSeconds") }
        return (d.integer(forKey: "pomodoroMinutes") > 0 ? d.integer(forKey: "pomodoroMinutes") : 10) * 60
    }() {
        didSet { UserDefaults.standard.set(seconds, forKey: "pomodoroSeconds"); if !running && !ringing { reset() } }
    }
    @Published var extraSeconds: Int = { let v = UserDefaults.standard.integer(forKey: "pomodoroExtraSeconds"); return v > 0 ? v : 30 }() {
        didSet { UserDefaults.standard.set(extraSeconds, forKey: "pomodoroExtraSeconds") }
    }
    var length: Double { Double(extra ? extraSeconds : seconds) }
    var extraLabel: String { "+" + Self.short(extraSeconds) }

    /// Finished timers and extras used, per timer length ("600" = the 10-minute timer).
    @Published var byLength: [String: Int] = (UserDefaults.standard.dictionary(forKey: "pomodoroByLength") as? [String: Int]) ?? [:] {
        didSet { UserDefaults.standard.set(byLength, forKey: "pomodoroByLength") }
    }
    @Published var extrasByLength: [String: Int] = (UserDefaults.standard.dictionary(forKey: "pomodoroExtrasByLength") as? [String: Int]) ?? [:] {
        didSet { UserDefaults.standard.set(extrasByLength, forKey: "pomodoroExtrasByLength") }
    }
    var doneHere: Int { byLength[String(seconds)] ?? 0 }
    var extrasHere: Int { extrasByLength[String(seconds)] ?? 0 }

    /// 600 → "10m", 90 → "1m 30s", 45 → "45s"
    static func short(_ s: Int) -> String {
        let m = s / 60, r = s % 60
        return m == 0 ? "\(r)s" : r == 0 ? "\(m)m" : "\(m)m \(r)s"
    }

    /// "25" = 25 minutes, "1:30" = 1 min 30 s, "90s" = 90 seconds, "2m" = 2 minutes.
    static func parse(_ text: String) -> Int? {
        let t = text.lowercased().replacingOccurrences(of: " ", with: "")
        if t.contains(":") {
            let p = t.split(separator: ":").map { Int($0) }
            guard p.count == 2, let m = p[0], let s = p[1] else { return nil }
            return m * 60 + s
        }
        if t.hasSuffix("s"), let v = Int(t.dropLast()) { return v }
        if t.hasSuffix("m"), let v = Double(t.dropLast()) { return Int(v * 60) }
        if let v = Double(t) { return Int(v * 60) }
        return nil
    }
    @Published var left: Double = 0
    @Published var extra = false                      // running a +30 s extension
    @Published var extras = UserDefaults.standard.integer(forKey: "pomodoroExtras") {
        didSet { UserDefaults.standard.set(extras, forKey: "pomodoroExtras") }
    }
    var onRing: ((Bool) -> Void)?                     // screen goes dark / comes back
    @Published var running = false
    @Published var ringing = false
    @Published var shake = false
    @Published var count = UserDefaults.standard.integer(forKey: "pomodoroCount") {
        didSet { UserDefaults.standard.set(count, forKey: "pomodoroCount") }
    }
    @Published var showCount = UserDefaults.standard.bool(forKey: "pomodoroShowCount") {
        didSet { UserDefaults.standard.set(showCount, forKey: "pomodoroShowCount") }
    }
    private var endsAt: Date?
    private var timer: Timer?
    private var shaker: Timer?

    init() {
        left = Double(seconds)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// Click: start / pause. When it's done: start the next timer right away.
    func tap() {
        if ringing { stopRinging(); reset(); start(); return }
        if running { left = max(0, (endsAt ?? Date()).timeIntervalSinceNow); running = false; endsAt = nil }
        else { start() }
    }

    private func start() { endsAt = Date().addingTimeInterval(left); running = true }

    /// The red +extra: a little more time, counted on its own (against the timer it extended).
    func plusThirty() {
        stopRinging()
        extras += 1
        extrasByLength[String(seconds), default: 0] += 1
        extra = true; left = Double(extraSeconds); start()
    }

    func reset() { running = false; endsAt = nil; extra = false; left = Double(seconds) }

    private func tick() {
        guard running, let e = endsAt else { return }
        left = max(0, e.timeIntervalSinceNow)
        if left <= 0 {
            running = false; endsAt = nil
            if !extra { count += 1; byLength[String(seconds), default: 0] += 1 }   // an extra isn't another timer
            ring()
        }
    }

    private func ring() {
        ringing = true
        onRing?(true)
        shaker?.invalidate()
        shaker = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { [weak self] t in
            guard let self, self.ringing else { t.invalidate(); return }
            self.shake.toggle()                          // until you pick: restart or +30
        }
    }

    func stopRinging() { ringing = false; shaker?.invalidate(); shaker = nil; onRing?(false) }

    var label: String {
        let s = Int(left.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct PomodoroView: View {
    @ObservedObject var m: PomodoroModel
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.12), lineWidth: 2.5)
                Circle().trim(from: 0, to: m.left / m.length)
                    .stroke(Color.white.opacity(m.running ? 0.9 : 0.45), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: m.left)
                Image(systemName: m.ringing ? "checkmark" : (m.running ? "pause.fill" : "play.fill"))
                    .font(.system(size: 7, weight: .bold)).foregroundColor(.white.opacity(0.8))
            }
            .frame(width: 18, height: 18)
            Text(m.ringing ? "Done" : m.label)
                .font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundColor(.white.opacity(m.running || m.ringing ? 1 : 0.6))
            if m.ringing {
                Text(m.extraLabel).font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundColor(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.red))
                    .overlay(AnchorReader { _, _ in m.plusThirty() })
                    .help("\(PomodoroModel.short(m.extraSeconds)) more")
                    .transition(.scale.combined(with: .opacity))
            } else if m.extra {
                Text(m.extraLabel).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(.red.opacity(0.9))
            }
            if m.showCount {
                Text("×\(m.doneHere)" + (m.extrasHere > 0 ? " · +×\(m.extrasHere)" : ""))
                    .font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundColor(.white.opacity(0.55))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(
            Capsule().fill(Color(white: 0.09).opacity(0.92))
                .overlay(Capsule().stroke(Color.white.opacity(m.ringing ? 0.9 : 0.10), lineWidth: m.ringing ? 1.5 : 1))
                .shadow(color: m.ringing ? .white.opacity(m.shake ? 0.75 : 0.35) : .black.opacity(0.5),
                        radius: m.ringing ? (m.shake ? 16 : 9) : 8, y: m.ringing ? 0 : 2))
        .rotationEffect(.degrees(m.ringing ? (m.shake ? 4 : -4) : 0))
        .scaleEffect(m.ringing && m.shake ? 1.06 : 1)
        .animation(.interpolatingSpring(stiffness: 260, damping: 5), value: m.shake)
        .animation(OSMotion.show, value: m.showCount)
        .animation(.easeInOut(duration: 0.3), value: m.ringing)
        .fixedSize()
        .padding(14)                                                     // room for the glow and the shake
        .help(m.ringing ? "Click to start again, or \(m.extraLabel) for a little more"
              : m.running ? "Click to pause" : "Click to start a \(PomodoroModel.short(m.seconds)) timer")
    }
}

/// Click = start/pause; drag = move; two-finger click = menu.
final class PomodoroHost: NSHostingView<PomodoroView> {
    var onMenu: ((NSEvent) -> Void)?
    var onTap: (() -> Void)?
    private var downAt: NSPoint?, moved = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        if e.modifierFlags.contains(.control) { onMenu?(e); return }
        downAt = NSEvent.mouseLocation; moved = false
    }
    override func mouseDragged(with e: NSEvent) {
        guard let d = downAt, let w = window else { return }
        let p = NSEvent.mouseLocation
        if !moved, hypot(p.x - d.x, p.y - d.y) < 3 { return }
        moved = true
        w.setFrameOrigin(NSPoint(x: w.frame.minX + p.x - d.x, y: w.frame.minY + p.y - d.y))
        downAt = p
    }
    override func mouseUp(with e: NSEvent) {
        if !moved { onTap?() } else if let w = window { UserDefaults.standard.set(NSStringFromPoint(w.frame.origin), forKey: "pomodoroOrigin") }
        downAt = nil
    }
    override func rightMouseDown(with e: NSEvent) { onMenu?(e) }
}

final class Pomodoro {
    let m = PomodoroModel()
    private var panel: NSPanel?

    var hidden: Bool { UserDefaults.standard.bool(forKey: "pomodoroHidden") }

    /// Hide / show the timer (from any orb's menu). It keeps counting while hidden.
    func toggleHidden() {
        UserDefaults.standard.set(!hidden, forKey: "pomodoroHidden")
        if hidden {
            if let p = panel { NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }) { p.orderOut(nil) } }
        } else if let p = panel {
            p.alphaValue = 0; p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; p.animator().alphaValue = 1 }
        } else { show() }
    }

    func show() {
        guard panel == nil else { return }
        let p = FirstClickPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let h = PomodoroHost(rootView: PomodoroView(m: m))
        h.onTap = { [weak self] in self?.m.tap() }
        h.onMenu = { [weak self, weak h] e in
            guard let self, let h else { return }
            NSMenu.popUpContextMenu(self.menu(), with: e, for: h)
        }
        p.contentView = h
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)   // above the dark screen
        m.onRing = { [weak self] on in self?.darken(on) }
        let size = NSSize(width: 260, height: 64)
        var origin: NSPoint
        if let s = UserDefaults.standard.string(forKey: "pomodoroOrigin") { origin = NSPointFromString(s) }
        else {                                                           // first time: bottom left
            let v = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            origin = NSPoint(x: v.minX + 4, y: v.minY + 2)
        }
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        panel = p
        if !hidden { p.orderFrontRegardless() }
    }

    private var dark: [NSPanel] = []
    private var keyMonitors: [Any] = []

    /// Time's up: every screen goes black except the timer, until you restart or take +30.
    private func darken(_ on: Bool) {
        if on {
            for s in NSScreen.screens {
                let d = NSPanel(contentRect: s.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                d.isOpaque = false; d.backgroundColor = .black; d.hasShadow = false
                d.level = .screenSaver
                d.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
                d.setFrame(s.frame, display: true)
                d.alphaValue = 0
                d.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { $0.duration = 0.6; d.animator().alphaValue = 1 }
                dark.append(d)
            }
            panel?.alphaValue = 1
            panel?.orderFrontRegardless()
            // any key (space, anything) = back to the screen and start the next timer
            let go: (NSEvent) -> Void = { [weak self] _ in
                DispatchQueue.main.async { if self?.m.ringing == true { self?.m.tap() } }
            }
            if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: go) { keyMonitors.append(g) }
            if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { go($0); return nil }) { keyMonitors.append(l) }
        } else {
            keyMonitors.forEach { NSEvent.removeMonitor($0) }; keyMonitors = []
            if hidden { panel?.orderOut(nil) }
            let old = dark; dark = []
            for d in old {
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.45; d.animator().alphaValue = 0 }) { d.orderOut(nil) }
            }
        }
    }

    private func setLength(_ s: Int) {
        m.seconds = s
        if m.running || m.ringing { m.stopRinging(); m.reset() }
    }

    /// Ask for a time: "25" minutes, "1:30", "90s" or "2m".
    private func ask(_ title: String, _ current: Int) -> Int? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = "Minutes (25), minutes:seconds (1:30), or seconds (90s)."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        f.stringValue = String(format: "%d:%02d", current / 60, current % 60)
        a.accessoryView = f
        a.addButton(withTitle: "Set"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn, let s = PomodoroModel.parse(f.stringValue), s >= 5, s <= 24 * 3600 else { return nil }
        return s
    }

    private func menu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let h = NSMenuItem(title: "\(PomodoroModel.short(m.seconds)) timer: \(m.doneHere) finished · extra used \(m.extrasHere)×",
                           action: nil, keyEquivalent: "")
        h.isEnabled = false; menu.addItem(h)
        let all = NSMenuItem(title: "All counts (\(m.count) finished · extra \(m.extras)×)", action: nil, keyEquivalent: "")
        let cs = NSMenu(); cs.autoenablesItems = false
        let lens = Set(m.byLength.keys).union(m.extrasByLength.keys).compactMap { Int($0) }.sorted()
        if lens.isEmpty { let e = NSMenuItem(title: "Nothing finished yet", action: nil, keyEquivalent: ""); e.isEnabled = false; cs.addItem(e) }
        for s in lens {
            let i = NSMenuItem(title: "\(PomodoroModel.short(s)) timer:  \(m.byLength[String(s)] ?? 0) finished · extra used \(m.extrasByLength[String(s)] ?? 0)×",
                               action: nil, keyEquivalent: ""); i.isEnabled = false; cs.addItem(i)
        }
        all.submenu = cs; menu.addItem(all)
        menu.addItem(.separator())
        let len = NSMenuItem(title: "Timer: \(PomodoroModel.short(m.seconds))", action: nil, keyEquivalent: "")
        let ls = NSMenu(); ls.autoenablesItems = false
        for s in [60, 120, 300, 600, 900, 1500] {
            ls.addItem(ActionItem(PomodoroModel.short(s), checked: m.seconds == s) { [weak self] in self?.setLength(s) })
        }
        ls.addItem(.separator())
        ls.addItem(ActionItem("Custom…") { [weak self] in
            guard let self, let s = self.ask("Timer length", self.m.seconds) else { return }
            self.setLength(s)
        })
        len.submenu = ls; menu.addItem(len)
        let ext = NSMenuItem(title: "Extra time: \(PomodoroModel.short(m.extraSeconds))", action: nil, keyEquivalent: "")
        let es = NSMenu(); es.autoenablesItems = false
        for s in [15, 30, 60, 120, 300] {
            es.addItem(ActionItem(PomodoroModel.short(s), checked: m.extraSeconds == s) { [weak self] in self?.m.extraSeconds = s })
        }
        es.addItem(.separator())
        es.addItem(ActionItem("Custom…") { [weak self] in
            guard let self, let s = self.ask("Extra time", self.m.extraSeconds) else { return }
            self.m.extraSeconds = s
        })
        ext.submenu = es; menu.addItem(ext)
        menu.addItem(.separator())
        menu.addItem(ActionItem(m.running ? "Pause" : "Start") { [weak self] in self?.m.tap() })
        menu.addItem(ActionItem("Restart from \(PomodoroModel.short(m.seconds))") { [weak self] in self?.m.stopRinging(); self?.m.reset() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Show count", checked: m.showCount) { [weak self] in self?.m.showCount.toggle() })
        menu.addItem(ActionItem("Reset counts") { [weak self] in
            self?.m.count = 0; self?.m.extras = 0; self?.m.byLength = [:]; self?.m.extrasByLength = [:]
        })
        return menu
    }
}
