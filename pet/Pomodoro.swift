// A 10-minute timer that's always on screen. Click: start / pause. Done: it glows and shakes (no sound).
// Two-finger click: restart, show/hide how many you've finished, reset that count. Drag it anywhere.
import AppKit
import SwiftUI

final class PomodoroModel: ObservableObject {
    static let length: Double = 10 * 60
    @Published var left: Double = PomodoroModel.length
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
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func tap() {
        if ringing { stopRinging(); reset(); return }
        if running { left = max(0, (endsAt ?? Date()).timeIntervalSinceNow); running = false; endsAt = nil }
        else { endsAt = Date().addingTimeInterval(left); running = true }
    }

    func reset() { running = false; endsAt = nil; left = Self.length }

    private func tick() {
        guard running, let e = endsAt else { return }
        left = max(0, e.timeIntervalSinceNow)
        if left <= 0 {
            running = false; endsAt = nil
            count += 1
            ring()
        }
    }

    private func ring() {
        ringing = true
        shaker?.invalidate()
        var n = 0
        shaker = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: true) { [weak self] t in
            guard let self, self.ringing else { t.invalidate(); return }
            self.shake.toggle()
            n += 1
            if n > 40 { self.stopRinging() }                          // keeps going ~35 s, or until you click
        }
    }

    func stopRinging() { ringing = false; shaker?.invalidate(); shaker = nil }

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
                Circle().trim(from: 0, to: m.left / PomodoroModel.length)
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
            if m.showCount {
                Text("×\(m.count)")
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
        .help(m.running ? "Click to pause" : "Click to start a 10-minute timer")
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
        let size = NSSize(width: 200, height: 64)
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

    private func menu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let h = NSMenuItem(title: "\(m.count) ten-minute timer\(m.count == 1 ? "" : "s") finished", action: nil, keyEquivalent: "")
        h.isEnabled = false; menu.addItem(h)
        menu.addItem(.separator())
        menu.addItem(ActionItem(m.running ? "Pause" : "Start") { [weak self] in self?.m.tap() })
        menu.addItem(ActionItem("Restart from 10:00") { [weak self] in self?.m.stopRinging(); self?.m.reset() })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Show count", checked: m.showCount) { [weak self] in self?.m.showCount.toggle() })
        menu.addItem(ActionItem("Reset count") { [weak self] in self?.m.count = 0 })
        return menu
    }
}
