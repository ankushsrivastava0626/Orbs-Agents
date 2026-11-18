// Click an orb: a small input field opens above it. Type, press Return, and it goes to that orb's session
// (just like speaking to it). Esc or clicking elsewhere closes it.
import AppKit
import Combine
import SwiftUI

final class TypeBoxModel: ObservableObject {
    @Published var text = ""
    @Published var title = ""
    @Published var shown = false
    var onSend: ((String) -> Void)?
    var onClose: (() -> Void)?
}

struct TypeBoxView: View {
    @ObservedObject var m: TypeBoxModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(m.title).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.5))
            HStack(spacing: 8) {
                TextField("Type to send…", text: $m.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundColor(.white)
                    .focused($focused)
                    .onSubmit { send() }
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                        .foregroundColor(m.text.isEmpty ? .white.opacity(0.3) : .black)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(m.text.isEmpty ? Color.white.opacity(0.1) : .white))
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.08).opacity(0.96))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 12, y: 3))
        .scaleEffect(m.shown ? 1 : 0.9, anchor: .bottom)
        .offset(y: m.shown ? 0 : 8)
        .opacity(m.shown ? 1 : 0)
        .animation(m.shown ? OSMotion.show : .easeInOut(duration: 0.35), value: m.shown)
        .onExitCommand { m.onClose?() }
        .onChange(of: m.shown) { on in if on { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } } }
    }
    func send() {
        let t = m.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        m.onSend?(t)
    }
}

/// A panel that can take typing without activating the app; resigning key closes it.
final class TypePanel: NSPanel {
    var onResign: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func resignKey() { super.resignKey(); onResign?() }
}

final class TypeBox {
    let m = TypeBoxModel()
    private var panel: TypePanel?
    private var target: (name: String, kind: String)?
    private var monitors: [Any] = []
    private var idleWork: DispatchWorkItem?
    private var textWatch: Any?
    private var drafts: [String: String] = [:]       // unsent text per orb: never thrown away
    static let idleSeconds = 6.0                    // empty and untouched this long: fade away (like a bubble)

    /// Restart the idle countdown; it only closes the field while it's empty.
    private func armIdle() {
        idleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.m.shown else { return }
            if self.m.text.trimmingCharacters(in: .whitespaces).isEmpty { self.close() } else { self.armIdle() }
        }
        idleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleSeconds, execute: w)
    }

    /// Any click outside the field closes it (works over the canvas, dock, and other apps).
    private func watchClicks() {
        stopWatching()
        let handler: (NSEvent) -> Void = { [weak self] _ in
            guard let self, let p = self.panel, self.m.shown else { return }
            if !p.frame.contains(NSEvent.mouseLocation) { self.close() }   // hides; a draft is saved for next time
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { handler($0); return $0 }) {
            monitors.append(l)
        }
    }

    private func stopWatching() { monitors.forEach { NSEvent.removeMonitor($0) }; monitors = [] }

    init() {
        m.onSend = { [weak self] t in self?.send(t) }
        m.onClose = { [weak self] in self?.close() }
    }

    /// Open the field above a point on screen (the orb), for this session.
    func open(above anchor: NSPoint, name: String, kind: String, title: String) {
        if let t = target, t.name != name { drafts[t.name] = m.text }   // keep the other orb's draft
        target = (name, kind)
        m.title = title; m.text = drafts[name] ?? ""
        if panel == nil {
            let p = TypePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.level = .popUpMenu
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.contentView = NSHostingView(rootView: TypeBoxView(m: m))
            p.onResign = { [weak self] in self?.close() }        // clicked elsewhere: hide (draft is kept)
            panel = p
        }
        guard let p = panel else { return }
        let size = NSSize(width: 340, height: 74)
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) }?.frame ?? NSScreen.screens[0].frame
        var x = anchor.x - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        p.setFrame(NSRect(x: x, y: anchor.y + 6, width: size.width, height: size.height), display: true)
        m.shown = false                                          // start from hidden so the entrance plays
        p.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { self.m.shown = true }
        armIdle()
        watchClicks()
        textWatch = m.$text.sink { [weak self] _ in self?.armIdle() }   // typing keeps it open
    }

    func close() {
        guard m.shown else { return }
        if let t = target { drafts[t.name] = m.text }                   // Esc etc.: the draft is kept
        idleWork?.cancel(); stopWatching(); textWatch = nil
        m.shown = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in   // after the fade has played
            guard let self, !self.m.shown else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func send(_ text: String) {
        guard let t = target else { return }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:5123/type")!)
        req.httpMethod = "POST"; req.timeoutInterval = 3
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": t.name, "kind": t.kind, "text": text])
        drafts[t.name] = text                                         // kept until the server has it
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, err in
            let ok = err == nil && (resp as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                guard let self else { return }
                if ok { if self.drafts[t.name] == text { self.drafts[t.name] = nil } }
                else { NSSound.beep() }                                  // not sent (server restarting): the draft stays
            }
        }.resume()
        m.text = ""
        close()
    }
}
