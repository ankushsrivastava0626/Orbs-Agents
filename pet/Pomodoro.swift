// A focus timer that's always on screen (1, 2 or 10 minutes). Click: start / pause. When it's done every
// screen goes dark except the timer, which glows and shakes: click it to start again, or the red +30 for
// thirty more seconds. Finished timers and +30s are counted separately. Two-finger click: length, counts.
import AppKit
import SwiftUI

final class PomodoroModel: ObservableObject {
    @Published var minutes: Int = { let v = UserDefaults.standard.integer(forKey: "pomodoroMinutes"); return v > 0 ? v : 10 }() {
        didSet { UserDefaults.standard.set(minutes, forKey: "pomodoroMinutes"); if !running && !ringing { reset() } }
    }
    var length: Double { extra ? 30 : Double(minutes) * 60 }
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
        left = Double(minutes) * 60
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

    /// The red +30: thirty more seconds, counted on their own.
    func plusThirty() {
        stopRinging()
        extras += 1
        extra = true; left = 30; start()
    }

    func reset() { running = false; endsAt = nil; extra = false; left = Double(minutes) * 60 }

    private func tick() {
        guard running, let e = endsAt else { return }
        left = max(0, e.timeIntervalSinceNow)
        if left <= 0 {
            running = false; endsAt = nil
            if !extra { count += 1 }                     // a +30 isn't another timer
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
                Text("+30").font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundColor(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.red))
                    .overlay(AnchorReader { _, _ in m.plusThirty() })
                    .help("30 more seconds")
                    .transition(.scale.combined(with: .opacity))
            } else if m.extra {
                Text("+30").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(.red.opacity(0.9))
            }
            if m.showCount {
                Text("×\(m.count)" + (m.extras > 0 ? " · +30×\(m.extras)" : ""))
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
        .help(m.ringing ? "Click to start again, or +30 for thirty more seconds"
              : m.running ? "Click to pause" : "Click to start a \(m.minutes)-minute timer")
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
        p.orderFrontRegardless()
        panel = p
    }

    private var dark: [NSPanel] = []

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
            panel?.orderFrontRegardless()
        } else {
            let old = dark; dark = []
            for d in old {
                NSAnimationContext.runAnimationGroup({ $0.duration = 0.45; d.animator().alphaValue = 0 }) { d.orderOut(nil) }
            }
        }
    }

    private func menu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let h = NSMenuItem(title: "\(m.count) timer\(m.count == 1 ? "" : "s") finished · +30 used \(m.extras)×", action: nil, keyEquivalent: "")
        h.isEnabled = false; menu.addItem(h)
        menu.addItem(.separator())
        for n in [1, 2, 10] {
            menu.addItem(ActionItem("\(n) minute\(n == 1 ? "" : "s")", checked: m.minutes == n) { [weak self] in
                guard let self else { return }
                self.m.minutes = n
                if self.m.running || self.m.ringing { self.m.stopRinging(); self.m.reset() }
            })
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem(m.running ? "Pause" : "Start") { [weak self] in self?.m.tap() })
        menu.addItem(ActionItem("Restart from \(m.minutes):00") { [weak self] in self?.m.stopRinging(); self?.m.reset() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Show count", checked: m.showCount) { [weak self] in self?.m.showCount.toggle() })
        menu.addItem(ActionItem("Reset counts") { [weak self] in self?.m.count = 0; self?.m.extras = 0 })
        return menu
    }
}
