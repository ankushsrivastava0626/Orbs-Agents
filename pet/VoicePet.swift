// Voice pet: an always-on-top orb in the bottom-right of every screen and Space.
// No text on screen: color + motion show the state. Hover the orb to peek at what was heard/said.
// Two-finger click the orb for options (auto mode, notes mode, tunnel vision, stop Claude). Notes mode shows each
// transcript for 1 s (click it to edit) before it's saved. Polls http://127.0.0.1:5123/status.
import AppKit
import ApplicationServices
import SwiftUI

struct SessState: Codable { var state = "idle", step = "", at = 0.0 }
struct Caption: Codable, Equatable, Identifiable { var id = "", session = "", text = "", at = 0.0 }
struct CodexPending: Codable { var method = "", detail = "", request_id = 0 }

struct PendingNote: Codable, Equatable { var id = "", text = "", at = 0.0, held = false }
struct SavedNote: Codable, Equatable { var id = "", text = "", at = 0.0 }

struct Status: Codable {
    var pending_note: PendingNote? = nil
    var saved_note: SavedNote? = nil
    var notes = false
    var auto = false
    var listening = false, level = 0.0, transcribing = false
    var heard = "", heard_at = 0.0
    var speaking = false, spoken = "", out_level = 0.0
    var claude = "idle", step = "", claude_at = 0.0
    var voice_claude = "idle", voice_claude_at = 0.0
    var problem_at = 0.0
    var codex: String? = nil, codex_at: Double? = nil   // Codex assistant's equivalent of `claude`
    var approval = false                                 // Codex is waiting for an approval
    var approvalId = 0, approvalDetail = "", approvalMethod = ""
    var target = "voice", target_kind = "claude", speaking_session = ""
    var sessions: [String: SessState] = [:]               // per voice session: working / idle
    var thread_id = ""                                    // Codex: its active session
    var muted_sessions: [String] = []                     // Claude orbs whose replies are shown as text
    var captions: [Caption] = []
    var last_said: [String: Caption] = [:]                // each orb's last reply, spoken or muted
    var muted = false, muted_text = "", muted_at = 0.0    // Codex: its own mute + last muted reply
    var meeting = false, meeting_started = 0.0, meeting_transcribing = false, meeting_done = "", meeting_done_at = 0.0

    init() {}

    private struct K: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    /// Every field optional, so either voice server's status decodes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        func g<T: Decodable>(_ k: String, _ d: T) -> T { ((try? c.decodeIfPresent(T.self, forKey: K(k))) ?? nil) ?? d }
        pending_note = g("pending_note", nil); saved_note = g("saved_note", nil)
        notes = g("notes", false); auto = g("auto", false)
        listening = g("listening", false); level = g("level", 0.0); transcribing = g("transcribing", false)
        heard = g("heard", ""); heard_at = g("heard_at", 0.0)
        speaking = g("speaking", false); spoken = g("spoken", ""); out_level = g("out_level", 0.0)
        claude = g("claude", "idle"); step = g("step", ""); claude_at = g("claude_at", 0.0)
        voice_claude = g("voice_claude", "idle"); voice_claude_at = g("voice_claude_at", 0.0)
        problem_at = g("problem_at", 0.0)
        codex = g("codex", nil); codex_at = g("codex_at", nil)
        approval = c.contains(K("pending")) && ((try? c.decodeNil(forKey: K("pending"))) == false)
        if let x = codex { claude = x; claude_at = codex_at ?? 0 }
        target = g("target", "voice"); target_kind = g("target_kind", "claude"); speaking_session = g("speaking_session", "")
        sessions = g("sessions", [:]); thread_id = g("thread_id", "")
        muted_sessions = g("muted_sessions", []); captions = g("captions", []); last_said = g("last_said", [:])
        muted = g("muted", false); muted_text = g("muted_text", ""); muted_at = g("muted_at", 0.0)
        meeting = g("meeting", false); meeting_started = g("meeting_started", 0.0)
        meeting_transcribing = g("meeting_transcribing", false)
        meeting_done = g("meeting_done", ""); meeting_done_at = g("meeting_done_at", 0.0)
        if let p: CodexPending = g("pending", nil) { approvalId = p.request_id; approvalDetail = p.detail; approvalMethod = p.method }
    }
}

enum Mode { case offline, idle, listening, sent, working, speaking }

final class Model: ObservableObject {
    let base: String                 // voice server
    let tokenPath: String?           // bearer token file, if that server needs one
    let idleColor: Color
    @Published var s = Status()
    @Published var online = false
    @Published var hovering = false
    @Published var bubblePeek = false            // hovering shows the last reply bubble instead of the info card
    var cornerSession = ""                       // the orb the corner orb stands for (your first orb)
    var orbFrames: () -> [NSRect] = { [] }
    private var timer: Timer?

    init(base: String = "http://127.0.0.1:5123", tokenPath: String? = nil,
         idleColor: Color = Color(red: 0.55, green: 0.6, blue: 0.75)) {
        self.base = base; self.tokenPath = tokenPath; self.idleColor = idleColor
        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.poll()
            self?.checkHover()
        }
    }

    func authorize(_ req: inout URLRequest) {
        if let p = tokenPath, let t = try? String(contentsOfFile: p, encoding: .utf8) {
            req.setValue("Bearer " + t.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "Authorization")
        }
    }

    func toggleAuto() {
        var req = URLRequest(url: URL(string: base + "/auto")!)
        authorize(&req)
        req.httpMethod = "POST"
        req.timeoutInterval = 1
        URLSession.shared.dataTask(with: req).resume()
        s.auto.toggle()                    // instant feedback; next poll confirms
    }

    func post(_ path: String) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:5123" + path)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 1
        URLSession.shared.dataTask(with: req).resume()
    }

    // Notes card: shown while a transcript waits (1 s), while you edit it, and during the save animation
    @Published var editing: PendingNote? = nil
    @Published var draft = ""
    @Published var flying: SavedNote? = nil          // note currently animating into the orb
    var onCardActive: ((Bool, Bool) -> Void)?       // (card visible, wants keyboard)
    private var lastSavedId = ""

    func postJSON(_ path: String, _ obj: [String: String]) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:5123" + path)!)
        req.httpMethod = "POST"
        req.timeoutInterval = 1
        req.httpBody = try? JSONSerialization.data(withJSONObject: obj)
        URLSession.shared.dataTask(with: req).resume()
    }

    func startEditing() {
        guard editing == nil, let n = s.pending_note else { return }
        postJSON("/note/hold", ["id": n.id])
        draft = n.text
        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { editing = n }
        onCardActive?(true, true)
    }

    func commitEdit() {
        guard let n = editing else { return }
        postJSON("/note/commit", ["id": n.id, "text": draft])
        withAnimation(.easeOut(duration: 0.2)) { editing = nil }
        onCardActive?(cardVisible, false)
    }

    func discardEdit() {
        guard let n = editing else { return }
        postJSON("/note/discard", ["id": n.id])
        withAnimation(.easeIn(duration: 0.25)) { editing = nil }
        onCardActive?(cardVisible, false)
    }

    var cardVisible: Bool { editing != nil || s.pending_note != nil || flying != nil }

    private func noteChanged() {
        if let sv = s.saved_note, sv.id != lastSavedId {
            let fresh = !lastSavedId.isEmpty || now - sv.at < 2
            lastSavedId = sv.id
            if fresh {
                flying = sv                               // play the "fly into the orb" animation
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                    if self?.flying?.id == sv.id { self?.flying = nil }
                    self?.onCardActive?(self?.cardVisible ?? false, self?.editing != nil)
                }
            }
        }
        onCardActive?(cardVisible, editing != nil)
    }

    func toggleNotes() {
        post("/notes")
        s.notes.toggle()
    }

    func openNotes() {
        let path = "/Users/kush/Githubs/persistent agent/notes/notes.md"
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        NSWorkspace.shared.open(url)
    }

    private func checkHover() {
        let p = NSEvent.mouseLocation
        let h = orbFrames().contains { $0.insetBy(dx: -4, dy: -4).contains(p) }
        if h != hovering { hovering = h }
    }

    private func poll() {
        var req = URLRequest(url: URL(string: base + "/status")!)
        authorize(&req)
        req.timeoutInterval = 0.5
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let st = data.flatMap { try? JSONDecoder().decode(Status.self, from: $0) }
            DispatchQueue.main.async {
                self.online = st != nil
                if let st { self.s = st; self.noteChanged() }
            }
        }.resume()
    }

    var now: Double { Date().timeIntervalSince1970 }

    var mode: Mode {
        if !online { return .offline }
        if s.listening { return .listening }
        if now - s.heard_at < 0.6 { return .sent }                 // one quick green pulse
        if s.speaking { return .speaking }
        let busy = { (state: String, at: Double) in state == "working" && self.now - at < 600 }
        if s.transcribing || busy(s.voice_claude, s.voice_claude_at) || busy(s.claude, s.claude_at) { return .working }
        return .idle
    }

    var problem: Bool { !online || now - s.problem_at < 120 }

    var peek: String {
        var lines: [String] = []
        if !online { lines.append("Voice server offline") }
        if !s.heard.isEmpty { lines.append("You: " + s.heard) }
        if !s.spoken.isEmpty { lines.append("Joe: " + s.spoken) }
        if mode == .working, !s.step.isEmpty { lines.append("Now: " + s.step) }
        if online, now - s.problem_at < 120 { lines.append("⚠︎ Gemini had a hiccup; used a fallback voice") }
        if s.notes { lines.append("📝 Notes mode: speech is saved to notes, not sent to Claude") }
        if s.auto { lines.append("Auto mode on") }
        lines.append("Two-finger click for options")
        return lines.joined(separator: "\n")
    }
}

struct Orb: View {
    @ObservedObject var m: Model
    var body: some View {
        OrbFace(mode: m.mode, level: m.s.level, outLevel: m.s.out_level, auto: m.s.auto, notes: m.s.notes,
                ripple: m.flying != nil, problem: m.problem, idleColor: m.idleColor,
                muted: m.s.muted_sessions.contains(m.cornerSession))
    }
}

/// The orb's look for any session: colour = state, motion = voice level, rings = modes.
struct OrbFace: View {
    var mode: Mode
    var level = 0.0, outLevel = 0.0
    var auto = false, notes = false, ripple = false, problem = false
    var idleColor = Color(red: 0.55, green: 0.6, blue: 0.75)
    var selected = false                                   // the session your voice goes to (no longer drawn)
    var muted = false                                      // replies shown as text: small speaker-slash badge
    @State private var spin = false
    @State private var breathe = false

    var color: Color {
        switch mode {
        case .offline: return .gray
        case .idle: return idleColor
        case .listening: return Color(red: 1.0, green: 0.27, blue: 0.3)
        case .sent: return Color(red: 0.2, green: 0.85, blue: 0.45)
        case .working: return Color(red: 0.65, green: 0.4, blue: 1.0)
        case .speaking: return Color(red: 0.25, green: 0.6, blue: 1.0)
        }
    }

    var scale: Double {
        switch mode {
        case .listening: return 1 + level * 0.55        // grows with your voice
        case .speaking: return 1 + outLevel * 0.45     // pulses with Joe's voice
        case .sent: return 1.25
        default: return breathe ? 1.05 : 0.95
        }
    }

    var body: some View {
        let teal = Color(red: 0.2, green: 0.9, blue: 0.85), gold = Color(red: 1.0, green: 0.82, blue: 0.2)
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [color.opacity(0.95), color.opacity(0.35)],
                                     center: .center, startRadius: 1, endRadius: 18))
                .frame(width: 30, height: 30)
                .shadow(color: color.opacity(0.8), radius: mode == .idle ? 3 : 9)
                .scaleEffect(scale)
                .animation(.easeOut(duration: 0.09), value: scale)
            if auto {
                Circle().stroke(teal, lineWidth: 2)
                    .frame(width: 44, height: 44)
                    .shadow(color: teal.opacity(0.8), radius: 4)
            }
            if notes {
                Circle().stroke(gold, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                    .frame(width: 38, height: 38)
            }
            if ripple {
                Circle().stroke(gold, lineWidth: 3)
                    .frame(width: 30, height: 30)
                    .modifier(Ripple())
            }
            if mode == .working {
                Circle().trim(from: 0, to: 0.3)
                    .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: 38, height: 38)
                    .rotationEffect(.degrees(spin ? 360 : 0))
            }
            if muted {
                Image(systemName: "speaker.slash.fill").font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Color.black.opacity(0.85)))
                    .offset(x: 13, y: 13)
            }
            if problem {
                Circle().fill(Color.orange)
                    .frame(width: 8, height: 8)
                    .offset(x: 13, y: -13)
            }
        }
        .opacity((mode == .idle && !auto) || mode == .offline ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.25), value: mode)
        .frame(width: 56, height: 64)
        .onAppear {
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { spin = true }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

/// Expanding ring that fades out: plays once when a note is saved.
struct Ripple: ViewModifier {
    @State private var go = false
    func body(content: Content) -> some View {
        content.scaleEffect(go ? 2.0 : 0.9).opacity(go ? 0 : 1)
            .onAppear { withAnimation(.easeOut(duration: 0.7)) { go = true } }
    }
}

/// Reveals text word by word.
struct Typewriter: View {
    let text: String
    @State private var shown = 0
    var body: some View {
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        Text(words.prefix(shown).joined(separator: " "))
            .onAppear { reveal(words.count) }
            .onChange(of: text) { _ in shown = 0; reveal(text.split(separator: " ").count) }
    }
    func reveal(_ n: Int) {
        let step = min(0.045, 0.45 / Double(max(n, 1)))   // whole note in ≤0.45 s
        for i in 0...n {
            DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(i)) {
                withAnimation(.easeOut(duration: 0.12)) { shown = i }
            }
        }
    }
}

struct NoteCard: View {
    @ObservedObject var m: Model
    @FocusState private var focused: Bool
    let gold = Color(red: 1.0, green: 0.82, blue: 0.2)

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Spacer(minLength: 0)
            ZStack(alignment: .bottomTrailing) {
                if let e = m.editing {
                    editor(e).transition(.asymmetric(
                        insertion: .scale(scale: 0.96, anchor: .bottomTrailing).combined(with: .opacity),
                        removal: .scale(scale: 0.2, anchor: .bottomTrailing).combined(with: .opacity)))
                } else if let n = m.s.pending_note {
                    pending(n).id(n.id).transition(.asymmetric(
                        insertion: .scale(scale: 0.3, anchor: .bottomTrailing).combined(with: .opacity)
                            .combined(with: .offset(y: 24)),
                        removal: .identity))
                } else if let f = m.flying {
                    card(Text(f.text).lineLimit(3), glow: 1)
                        .id("fly" + f.id)
                        .modifier(FlyIntoOrb())
                }
            }
        }
        .frame(width: 380, height: 220, alignment: .bottomTrailing)
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: m.s.pending_note?.id)
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: m.editing?.id)
    }

    func card<V: View>(_ content: V, glow: Double) -> some View {
        content
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundColor(.white)
            .frame(maxWidth: 320, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black.opacity(0.84))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(gold.opacity(0.35 + 0.5 * glow), lineWidth: 1.2))
                    .shadow(color: gold.opacity(0.35 * glow), radius: 10))
    }

    func pending(_ n: PendingNote) -> some View {
        card(VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "note.text").foregroundColor(gold)
                Text("Note").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(gold)
                Spacer()
                Text("click to edit").font(.system(size: 10, design: .rounded)).foregroundColor(.white.opacity(0.5))
            }
            Typewriter(text: n.text).lineLimit(4)
            TimelineView(.animation) { tl in                 // 1.5 s countdown bar
                let left = max(0, 1 - (tl.date.timeIntervalSince1970 - n.at) / 1.5)
                GeometryReader { g in
                    Capsule().fill(gold.opacity(0.85)).frame(width: g.size.width * left, height: 3)
                }.frame(height: 3)
            }
        }, glow: 0.4)
        .contentShape(Rectangle())
        .onTapGesture { m.startEditing() }
    }

    func editor(_ n: PendingNote) -> some View {
        card(VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "pencil").foregroundColor(gold)
                Text("Editing note").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(gold)
            }
            TextField("", text: $m.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focused)
                .onSubmit { m.commitEdit() }
            HStack {
                Text("⏎ save · esc discard").font(.system(size: 10, design: .rounded)).foregroundColor(.white.opacity(0.5))
                Spacer()
                Button("Discard") { m.discardEdit() }.buttonStyle(.plain).foregroundColor(.white.opacity(0.7))
                Button("Save") { m.commitEdit() }.buttonStyle(.plain).foregroundColor(gold)
            }.font(.system(size: 11, weight: .semibold, design: .rounded))
        }, glow: 1)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } }
        .onExitCommand { m.discardEdit() }
    }
}

/// Saved note shrinks and slides down-right into the orb.
struct FlyIntoOrb: ViewModifier {
    @State private var go = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(go ? 0.08 : 1, anchor: .bottomTrailing)
            .offset(x: go ? 40 : 0, y: go ? 30 : 0)
            .opacity(go ? 0 : 1)
            .blur(radius: go ? 2 : 0)
            .onAppear { withAnimation(.easeIn(duration: 0.45).delay(0.1)) { go = true } }
    }
}

struct PeekView: View {
    @ObservedObject var m: Model
    var body: some View {
        HStack {
            Spacer(minLength: 0)
            if m.hovering && !m.cardVisible && !m.bubblePeek {
                Text(m.peek)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(8)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.82)))
                    .transition(.opacity)
            }
        }
        .frame(width: 380, height: 160, alignment: .bottomTrailing)
        .animation(.easeInOut(duration: 0.15), value: m.hovering)
    }
}

/// Hosting view that takes the whole click itself (works in a non-activating panel without stealing focus).
final class ClickHost<V: View>: NSHostingView<V> {
    var onClick: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onMenu?(event) } else { onClick?() }   // ctrl-click = right-click
    }
    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }               // two-finger click
}

/// Hosting view for the notes card: clicks work on first touch.
final class FirstMouseHost<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Tunnel vision: the whole screen is black except a warm lantern-like pool of light around the cursor.
final class TunnelView: NSView {
    var radius: CGFloat = 170
    var rectangle = false            // false: circle · true: wide reading rectangle
    private var light = NSPoint(x: -9999, y: -9999)
    override var isFlipped: Bool { false }

    /// Called every frame with the cursor in screen coordinates.
    func step(cursor: NSPoint) {
        guard let w = window else { return }
        let local = NSPoint(x: cursor.x - w.frame.minX, y: cursor.y - w.frame.minY)
        if local != light { light = local; needsDisplay = true }    // the circle sits exactly on the cursor
    }

    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)
        ctx.setBlendMode(.clear)                                     // plain, hard-edged see-through window
        if rectangle {
            let w = radius * 3.2, h = radius * 1.1                   // wide band, good for reading lines
            ctx.fill(CGRect(x: light.x - w / 2, y: light.y - h / 2, width: w, height: h))
        } else {
            ctx.fillEllipse(in: CGRect(x: light.x - radius, y: light.y - radius, width: radius * 2, height: radius * 2))
        }
    }
}

/// Full-screen tunnel overlay. It can take the keyboard so Esc exits; mouse clicks pass through.
final class TunnelPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// Panel that can take keyboard focus (for editing a note) without activating the app.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Model()
    var panels: [NSPanel] = []
    var orbPanels: [NSPanel] = []
    var cardPanels: [KeyPanel] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in self?.canvas.restore(); TaskTimer.shared.installStatusItem(); self?.pomodoro.show(); self?.meetingBadge.show() }
        NSApp.setActivationPolicy(.accessory)   // no Dock icon, never steals focus
        model.orbFrames = { [weak self] in self?.orbPanels.map(\.frame) ?? [] }
        model.onCardActive = { [weak self] visible, wantsKeys in
            guard let self else { return }
            for p in self.cardPanels {
                p.ignoresMouseEvents = !visible               // only clickable while a note is showing
                if wantsKeys, p.screen == NSScreen.main ?? NSScreen.screens.first {
                    p.makeKeyAndOrderFront(nil)               // keyboard goes to the note editor
                } else if !wantsKeys, p.isKeyWindow {
                    p.orderOut(nil); p.orderFrontRegardless() // hand the keyboard back to your app
                }
            }
        }
        build()
        _ = osMode                                         // create it now so a leftover hidden Dock gets restored
        startDoubleOptionWatch()
        _ = sessions                                       // hotkeys work even outside OS mode
        setupCaptions()
        DistributedNotificationCenter.default().addObserver(forName: .init("com.claude.voicepet.osmode"),
                                                            object: nil, queue: .main) { [weak self] n in
            guard let self else { return }
            let want = (n.object as? String).map { $0 == "on" } ?? !self.osMode.on
            if want { self.osMode.start() } else { self.osMode.stop() }
        }
        // open an orb's typing field from scripts (also used to test it):  object = session name
        DistributedNotificationCenter.default().addObserver(forName: .init("com.claude.voicepet.type"),
                                                            object: nil, queue: .main) { [weak self] n in
            guard let self else { return }
            if let n = (n.object as? String) ?? self.sessions.firstName { self.sessions.openTyping(n) }
        }
        // toggle tunnel vision from scripts/hotkeys:  ~/.claude/voice/tunnel [on|off]
        DistributedNotificationCenter.default().addObserver(forName: .init("com.claude.voicepet.tunnel"),
                                                            object: nil, queue: .main) { [weak self] n in
            guard let self else { return }
            let want = (n.object as? String).map { $0 == "on" } ?? self.tunnelPanels.isEmpty
            self.setTunnel(want)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.build() }
    }

    @objc func menuAuto() { model.toggleAuto() }
    @objc func menuNotes() { model.toggleNotes() }
    @objc func menuOpenNotes() { model.openNotes() }
    @objc func menuStopClaude() { model.post("/claude/stop") }
    @objc func menuShowClaude() { model.post("/claude/show") }
    @objc func menuQuitClaude() { model.post("/claude/quit") }
    @objc func menuTunnel() { setTunnel(tunnelPanels.isEmpty) }
    @objc func menuOSMode() { osMode.toggle() }

    // MARK: reply cards for muted orbs: a speech bubble above the orb that's "talking"
    var bubbles: [String: (CaptionsModel, NSPanel)] = [:]
    var captionsSeeded = false
    var seenCaptions = Set<String>()
    var lastCodexMuted = 0.0
    var lastCodexSpoken = ""

    func setupCaptions() {
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.feedCaptions() }
        // a click anywhere outside the bubbles closes them (clicking a bubble closes that one)
        let outside: (NSEvent) -> Void = { [weak self] _ in
            guard let self else { return }
            let p = NSEvent.mouseLocation
            for (_, (m, panel)) in self.bubbles where !m.cards.isEmpty {
                if !panel.frame.contains(p) { m.dismissAll() }
            }
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: outside)
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { outside($0); return $0 }
        osMode.dock.onOrbHover = { [weak self] name, on in self?.peekBubble(name, on) }
    }

    private var cornerHover = false

    private var hoverWork: [String: DispatchWorkItem] = [:]

    /// Show an orb's last reply only once the cursor has rested on it (not while just passing over).
    func peekBubble(_ session: String, _ on: Bool) {
        hoverWork[session]?.cancel()
        guard let (m, _) = bubbles[session] else { return }
        if on {
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                for (other, (om, _)) in self.bubbles where other != session { om.dismissPeeks() }   // one hover bubble at a time
                self.placeBubble(session); m.peek(true)
            }
            hoverWork[session] = w
            DispatchQueue.main.async(execute: w)                                    // reveal on hover right away
        } else {
            m.peek(false)
        }
    }

    func bubble(for session: String) -> (CaptionsModel, NSPanel) {
        if let b = bubbles[session] { return b }
        let m = CaptionsModel()
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.ignoresMouseEvents = true
        p.contentView = FirstMouseHost(rootView: CaptionsView(m: m))
        m.onVisibility = { [weak self, weak p] on in
            guard let self, let p else { return }
            self.placeBubble(session)
            p.ignoresMouseEvents = !on
            if on { p.orderFrontRegardless() }
        }
        bubbles[session] = (m, p)
        return (m, p)
    }

    /// Above its orb in the dock (OS mode), or above the corner orb otherwise; the tail points at the orb.
    func placeBubble(_ session: String) {
        guard let (m, p) = bubbles[session] else { return }
        let orb = (osMode.on ? OrbAnchors.shared.screenRect(session) : nil)
            ?? orbPanels.first?.frame
            ?? NSRect(x: NSScreen.screens[0].frame.maxX - 60, y: 20, width: 40, height: 40)
        let screen = NSScreen.screens.first { $0.frame.intersects(orb) }?.frame ?? NSScreen.screens[0].frame
        let w: CGFloat = 440, h: CGFloat = 520
        let x = min(max(orb.midX - w / 2, screen.minX + 8), screen.maxX - w - 8)
        let r = NSRect(x: x, y: orb.maxY + 4, width: w, height: h)
        if p.frame != r { p.setFrame(r, display: true) }
        let tail = orb.midX - x                                       // orb's x inside the panel
        if m.tailX != tail { m.tailX = tail }
    }

    func feedCaptions() {
        let list = model.s.captions
        if !captionsSeeded {                              // don't replay old replies on launch
            captionsSeeded = true
            list.forEach { seenCaptions.insert($0.id) }; lastCodexMuted = codexModel.s.muted_at
            for (session, c) in model.s.last_said {
                seenCaptions.insert(c.id)
                bubble(for: session).0.remember(c.id, title: sessions.displayName(session), text: c.text)
            }
            return
        }
        for c in list where !seenCaptions.contains(c.id) {
            seenCaptions.insert(c.id)
            if canvas.enabled {                                   // the canvas shows it instead of a popping bubble
                toCanvas(c.id, c.session, c.text)
                bubble(for: c.session).0.remember(c.id, title: sessions.displayName(c.session), text: c.text)
            } else {
                bubble(for: c.session).0.add(c.id, title: sessions.displayName(c.session), text: c.text)
            }
        }
        // spoken replies (not muted): kept as each orb's last message, shown when you hover the orb
        for (session, c) in model.s.last_said where !seenCaptions.contains(c.id) {
            seenCaptions.insert(c.id)
            toCanvas(c.id, session, c.text)
            bubble(for: session).0.remember(c.id, title: sessions.displayName(session), text: c.text)
        }
        let cm = codexModel.s
        if !cm.muted, cm.speaking, !cm.spoken.isEmpty, cm.spoken != lastCodexSpoken {
            lastCodexSpoken = cm.spoken
            let name = sessions.entries.first { $0.kind == "codex" && $0.id == cm.thread_id }?.name ?? "codex"
            bubble(for: name).0.remember("codexs-\(cm.spoken.hashValue)", title: sessions.displayName(name), text: cm.spoken)
            toCanvas("codexs-\(cm.spoken.hashValue)", name, cm.spoken)
        }
        if cm.muted, cm.muted_at > lastCodexMuted, !cm.muted_text.isEmpty {
            lastCodexMuted = cm.muted_at
            let name = sessions.entries.first { $0.kind == "codex" && $0.id == cm.thread_id }?.name ?? "codex"
            if canvas.enabled {
                toCanvas("codex-\(cm.muted_at)", name, cm.muted_text)
                bubble(for: name).0.remember("codex-\(cm.muted_at)", title: sessions.displayName(name), text: cm.muted_text)
            } else {
                bubble(for: name).0.add("codex-\(cm.muted_at)", title: sessions.displayName(name), text: cm.muted_text)
            }
        }
        for s in bubbles.keys where !(bubbles[s]?.0.cards.isEmpty ?? true) { placeBubble(s) }   // follow the dock
        model.cornerSession = sessions.firstName ?? ""
        let h = model.hovering && !osMode.on
        if h != cornerHover {
            cornerHover = h
            let first = sessions.firstName ?? ""
            model.bubblePeek = h && bubbles[first]?.0.last != nil
            peekBubble(first, h)
        }
    }

    /// In OS mode the corner orb (and its hover card) is invisible and click-through — the dock has the orbs.
    /// Alpha instead of hiding, so other code bringing windows forward can't make it reappear.
    lazy var orbStrip = OrbStrip(osMode.dock)

    /// The single corner orb is replaced by the strip of every orb (bottom right) outside OS mode,
    /// and by the dock inside it.
    func applyCornerOrbVisibility() {
        for p in panels where !(cardPanels.contains { $0 === p }) {   // the notes card stays available
            p.alphaValue = 0
            if orbPanels.contains(where: { $0 === p }) { p.ignoresMouseEvents = true }
        }
        if osMode.on { orbStrip.hide() } else { orbStrip.show() }
    }
    @objc func codexAuto() { codexModel.toggleAuto() }
    lazy var sessions = SessionsController(main: model, codex: codexModel, app: self)
    let canvas = Canvas()
    let pomodoro = Pomodoro()
    @objc func menuCanvas() { canvas.toggle() }
    @objc func menuPomodoro() { pomodoro.toggleHidden() }
    @objc func menuMeeting() { toggleMeeting() }
    @objc func menuOpenMeetings() {
        let d = voiceDir + "/meetings"
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: d))
    }

    /// Quit completely: put the Mac's Dock and menu bar back, then unload the pet so it doesn't restart.
    @objc func menuQuitPet() {
        if osMode.on { osMode.toggle() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["bootout", "gui/\(getuid())/com.claude.voice-pet"]
            try? p.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }   // if not run by launchd
        }
    }

    /// Something an agent said: onto the canvas (if it's on).
    func toCanvas(_ id: String, _ session: String, _ text: String) {
        guard canvas.enabled, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let kind = sessions.entries.first { $0.name == session }?.kind ?? "claude"
        canvas.m.add(CanvasLine(id: id, who: sessions.displayName(session), kind: kind, text: text, at: Date()))
    }

    /// The Codex assistant's orb (its own voice server on :5124, token in its runtime folder).
    lazy var codexModel = Model(
        base: "http://127.0.0.1:5124",
        tokenPath: "/Users/kush/Documents/Codex/2026-10-04/can-x20/outputs/codex-voice-assistant/runtime/token",
        idleColor: Color(red: 1.0, green: 0.73, blue: 0.3))
    func watchCodexApproval() { sessions.checkApproval() }

    // Double-tap LEFT Option: toggle OS mode. (Holding left Option is still push-to-talk.)
    private var optTimer: Timer?
    private var optDownAt: Date?
    private var lastTapAt: Date?

    func startDoubleOptionWatch() {
        optTimer = Timer.scheduledTimer(withTimeInterval: 1 / 120, repeats: true) { [weak self] _ in self?.watchOption() }
        RunLoop.main.add(optTimer!, forMode: .common)
    }

    private func watchOption() {
        let f = CGEventSource.flagsState(.hidSystemState).rawValue
        let leftOpt = f & 0x00080000 != 0 && f & 0x20 != 0          // Option mask + left-Alt device bit
        let others = f & (0x00100000 | 0x00040000 | 0x00020000) != 0 // ⌘ ⌃ ⇧ held: not a plain tap
        let now = Date()
        watchCodexApproval()
        // RIGHT Option double-tap: start / stop recording a meeting
        let rightOpt = f & 0x00080000 != 0 && f & 0x40 != 0
        if rightOpt, rOptDownAt == nil { rOptDownAt = now }
        if !rightOpt, let down = rOptDownAt {
            rOptDownAt = nil
            if now.timeIntervalSince(down) < 0.28, !others {
                if let last = rLastTapAt, now.timeIntervalSince(last) < 0.4 { rLastTapAt = nil; toggleMeeting() }
                else { rLastTapAt = now }
            } else { rLastTapAt = nil }
        }
        // RIGHT Command double-tap: read the selected text aloud
        let rightCmd = f & 0x00100000 != 0 && f & 0x10 != 0
        let notCmd = f & (0x00080000 | 0x00040000 | 0x00020000) != 0
        if rightCmd, rCmdDownAt == nil { rCmdDownAt = now }
        if !rightCmd, let down = rCmdDownAt {
            rCmdDownAt = nil
            if now.timeIntervalSince(down) < 0.28, !notCmd {
                if let last = rCmdLastTapAt, now.timeIntervalSince(last) < 0.4 { rCmdLastTapAt = nil; readSelection() }
                else { rCmdLastTapAt = now }
            } else { rCmdLastTapAt = nil }
        }
        if leftOpt, optDownAt == nil { optDownAt = now; return }
        if !leftOpt, let down = optDownAt {
            optDownAt = nil
            let quick = now.timeIntervalSince(down) < 0.28           // a tap, not a push-to-talk hold
            guard quick, !others else { lastTapAt = nil; return }
            if let last = lastTapAt, now.timeIntervalSince(last) < 0.4 {
                lastTapAt = nil
                osMode.toggle()
            } else {
                lastTapAt = now
            }
        }
    }
    private var rOptDownAt: Date?
    private var rLastTapAt: Date?
    private var rCmdDownAt: Date?
    private var rCmdLastTapAt: Date?
    lazy var meetingBadge = MeetingBadge(model)

    func toggleMeeting() {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:5123/meeting")!)
        req.httpMethod = "POST"; req.timeoutInterval = 3; req.httpBody = Data("{}".utf8)
        URLSession.shared.dataTask(with: req).resume()
        meetingBadge.show()
    }

    /// Double-tap right Command: read the selection aloud (replacing anything still being read).
    private func readSelection() {
        // the newest double-tap always wins: whatever was being read stops, and the current selection is read
        let reading = model.s.speaking_session == SelectionReader.session && model.s.speaking
        SelectionReader.selectedText { text in
            if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                DispatchQueue.global().async { SelectionReader.read(t) }
            } else if reading {
                DispatchQueue.global().async { SelectionReader.stop() }   // nothing selected: just stop
            }
        }
    }

    lazy var osMode: OSMode = {
        let o = OSMode()
        o.keyDown = { Self.cg.keyDown($0) }
        o.restoreBars()                                    // if the pet quit mid OS mode, undo its hiding
        o.voiceStatus = { [weak self] in
            guard let self else { return ("", "") }
            let m = self.model
            switch m.mode {
            case .listening: return ("Listening", "")
            case .sent: return ("Got it", "")
            case .speaking: return ("Speaking", "")
            case .working: return ("Working", m.s.step)
            case .offline: return ("Voice offline", "")
            case .idle: return ("", "")
            }
        }
        o.modeStates = { [weak self] in
            guard let self else { return (false, false, false) }
            return (self.model.s.notes, self.model.s.auto, !self.tunnelPanels.isEmpty)
        }
        // in OS mode the orb moves from the bottom-right corner into the dock
        sessions.attach(to: o.dock)                        // one orb per voice session, plus the ＋ button
        o.onChange = { [weak self] in self?.applyCornerOrbVisibility() }
        o.toggleNotes = { [weak self] in self?.model.toggleNotes() }
        o.toggleAuto = { [weak self] in self?.model.toggleAuto() }
        o.toggleTunnel = { [weak self] in guard let self else { return }; self.setTunnel(self.tunnelPanels.isEmpty) }
        if !AXIsProcessTrusted() {
            FileHandle.standardError.write("os mode: Accessibility not granted, boxes can't be resized\n".data(using: .utf8)!)
        }
        return o
    }()
    @objc func menuShapeCircle() { setShape(false) }
    @objc func menuShapeRect() { setShape(true) }

    func setShape(_ rect: Bool) {
        tunnelRect = rect
        UserDefaults.standard.set(rect, forKey: "tunnelRect")
        for tp in tunnelPanels {
            (tp.contentView as? TunnelView)?.rectangle = rect
            tp.contentView?.needsDisplay = true
        }
    }

    // MARK: tunnel vision
    var tunnelPanels: [TunnelPanel] = []
    var tunnelTimer: Timer?
    var pinchMonitors: [Any] = []
    var tunnelRadius: CGFloat = {
        let r = UserDefaults.standard.double(forKey: "tunnelRadius")
        return r > 0 ? CGFloat(r) : 170
    }()

    var tunnelRect = UserDefaults.standard.bool(forKey: "tunnelRect")
    var pinchTap: CFMachPort?
    var pinchSource: CFRunLoopSource?

    /// Trackpad pinch: pinch in (fingers together) = bigger light, pinch out (spread) = smaller light.
    func pinched(_ e: NSEvent) { pinched(magnification: e.magnification) }

    func pinched(magnification: CGFloat) {
        tunnelRadius = min(700, max(50, tunnelRadius * (1 - magnification * 1.2)))
        UserDefaults.standard.set(Double(tunnelRadius), forKey: "tunnelRadius")
        for tp in tunnelPanels {
            (tp.contentView as? TunnelView)?.radius = tunnelRadius
            tp.contentView?.needsDisplay = true
        }
    }
    var escWasDown = false

    func setTunnel(_ on: Bool) {
        tunnelTimer?.invalidate(); tunnelTimer = nil
        pinchMonitors.forEach { NSEvent.removeMonitor($0) }; pinchMonitors = []
        if let t = pinchTap { CGEvent.tapEnable(tap: t, enable: false) }
        if let src = pinchSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        pinchTap = nil; pinchSource = nil
        tunnelPanels.forEach { $0.orderOut(nil); $0.close() }
        tunnelPanels = []
        let top = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        for p in panels { p.level = on ? top : .statusBar }          // keep the orb visible above the dark
        guard on else { return }
        let q = Self.cg
        if !q.preflight() { _ = q.request() }                          // Esc from any app needs Input Monitoring
        for screen in NSScreen.screens {
            let tp = TunnelPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
            tp.isOpaque = false; tp.backgroundColor = .clear; tp.hasShadow = false
            tp.level = .screenSaver                                    // above menu bar and Dock
            tp.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            tp.ignoresMouseEvents = true                               // you can still click and scroll underneath
            let tv = TunnelView(frame: NSRect(origin: .zero, size: screen.frame.size))
            tv.radius = tunnelRadius
            tv.rectangle = tunnelRect
            tp.contentView = tv
            tp.onEscape = { [weak self] in self?.setTunnel(false) }
            tp.orderFrontRegardless()
            tunnelPanels.append(tp)
        }
        (tunnelPanels.first { $0.screen == NSScreen.main } ?? tunnelPanels.first)?.makeKey()   // Esc works right away
        for p in panels { p.orderFrontRegardless() }
        escWasDown = false
        installPinchTap()
        if pinchTap == nil, let g = NSEvent.addGlobalMonitorForEvents(matching: .magnify, handler: { [weak self] e in self?.pinched(e) }) {
            pinchMonitors.append(g)                                   // pinches over other apps
        }
        if pinchTap == nil, let l = NSEvent.addLocalMonitorForEvents(matching: .magnify, handler: { [weak self] e in self?.pinched(e); return e }) {
            pinchMonitors.append(l)                                   // pinches while the pet has focus
        }
        tunnelTimer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let c = NSEvent.mouseLocation
            for tp in self.tunnelPanels { (tp.contentView as? TunnelView)?.step(cursor: c) }
            if let t = self.pinchTap, !CGEvent.tapIsEnabled(tap: t) {
                CGEvent.tapEnable(tap: t, enable: true)               // macOS can switch taps off; switch it back on
            }
            let esc = q.keyDown(53)                                    // Esc pressed while another app has focus
            if esc && !self.escWasDown { self.setTunnel(false) }
            self.escWasDown = esc
        }
        RunLoop.main.add(tunnelTimer!, forMode: .common)
    }

    /// Event tap for trackpad pinches anywhere on screen. With Accessibility it also swallows the pinch,
    /// so the app under the darkness doesn't zoom. Asks for Accessibility the first time.
    var askedForAccessibility = false

    func installPinchTap() {
        var trusted = AXIsProcessTrusted()
        if !trusted && !askedForAccessibility {          // ask once per launch, never again after that
            askedForAccessibility = true
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(opts)
        }
        let mask: CGEventMask = (1 << 29) | (1 << 30)                 // gesture + magnify
        let me = Unmanaged.passUnretained(self).toOpaque()
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let d = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = d.pinchTap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if let ns = NSEvent(cgEvent: event), ns.type == .magnify {
                DispatchQueue.main.async { d.pinched(magnification: ns.magnification) }
                return nil                                            // swallow: page underneath doesn't zoom
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: trusted ? .defaultTap : .listenOnly,
                                          eventsOfInterest: mask, callback: cb, userInfo: me) else {
            FileHandle.standardError.write("pinch tap unavailable (trusted=\(trusted))\n".data(using: .utf8)!)
            return
        }
        pinchTap = tap
        pinchSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), pinchSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        FileHandle.standardError.write("pinch tap installed (trusted=\(trusted))\n".data(using: .utf8)!)
    }

    /// Minimal CoreGraphics key-state access (no event tap).
    struct CG {
        let lib = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
        func preflight() -> Bool {
            typealias F = @convention(c) () -> Bool
            guard let sym = dlsym(lib, "CGPreflightListenEventAccess") else { return false }
            return unsafeBitCast(sym, to: F.self)()
        }
        func request() -> Bool {
            typealias F = @convention(c) () -> Bool
            guard let sym = dlsym(lib, "CGRequestListenEventAccess") else { return false }
            return unsafeBitCast(sym, to: F.self)()
        }
        func keyDown(_ code: UInt16) -> Bool {
            typealias F = @convention(c) (Int32, UInt16) -> Bool
            guard let sym = dlsym(lib, "CGEventSourceKeyState") else { return false }
            return unsafeBitCast(sym, to: F.self)(1, code)
        }
    }
    static let cg = CG()

    func showMenu(in view: NSView, event: NSEvent) {
        showMenu(in: view, at: NSPoint(x: 0, y: view.bounds.maxY))
    }

    // MARK: voice sessions (like the Codex orb): new, new in folder, resume, open transcript

    struct VoiceSessionInfo: Decodable { let id: String; let cwd: String; let name: String; let started: Double }
    struct VoiceSessionList: Decodable { let current: String?; let sessions: [VoiceSessionInfo] }

    func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    var voiceDir: String { NSHomeDirectory() + "/.claude/voice" }

    func voiceSessions() -> VoiceSessionList? {
        try? JSONDecoder().decode(VoiceSessionList.self,
                                  from: Data(run("/usr/bin/python3", [voiceDir + "/voice_sessions.py", "list"]).utf8))
    }

    @objc func sessionNew() { startVoice(["--fresh"]) }
    @objc func sessionNewInFolder() {
        let picker = NSOpenPanel()
        picker.title = "New Claude voice session in folder"
        picker.prompt = "Start session"
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        if picker.runModal() == .OK, let url = picker.url { startVoice(["--fresh", "--cwd", url.path]) }
    }
    @objc func sessionResume(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { startVoice(["--resume", id]) }
    }
    @objc func sessionTranscript() {
        let path = run("/usr/bin/python3", [voiceDir + "/voice_sessions.py", "transcript"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }

    func startVoice(_ args: [String]) {
        DispatchQueue.global().async {
            _ = self.run(self.voiceDir + "/start-voice-session.sh", args)
        }
    }

    func addSessionItems(to menu: NSMenu) {
        let list = voiceSessions()
        let cur = list?.sessions.first { $0.id == list?.current }
        let header = NSMenuItem(title: "Session: " + (cur?.name ?? "none yet"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.toolTip = cur?.cwd
        menu.addItem(header)
        for (t, s) in [("New session", #selector(sessionNew)), ("New session in folder…", #selector(sessionNewInFolder))] {
            let i = NSMenuItem(title: t, action: s, keyEquivalent: ""); i.target = self; menu.addItem(i)
        }
        let resume = NSMenuItem(title: "Resume session", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Voice sessions")
        let fmt = DateFormatter(); fmt.dateFormat = "MMM d, h:mm a"
        for s in list?.sessions ?? [] {
            let folder = URL(fileURLWithPath: s.cwd).lastPathComponent
            let i = NSMenuItem(title: "\(s.name)  ·  \(folder) · \(fmt.string(from: Date(timeIntervalSince1970: s.started)))",
                               action: #selector(sessionResume(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = s.id; i.toolTip = s.cwd
            i.state = s.id == list?.current ? .on : .off
            sub.addItem(i)
        }
        if sub.items.isEmpty {
            let i = NSMenuItem(title: "No voice sessions yet", action: nil, keyEquivalent: ""); i.isEnabled = false; sub.addItem(i)
        }
        resume.submenu = sub
        menu.addItem(resume)
        let tr = NSMenuItem(title: "Open transcript", action: #selector(sessionTranscript), keyEquivalent: "")
        tr.target = self; tr.isEnabled = cur != nil
        menu.addItem(tr)
        menu.addItem(.separator())
    }

    func showMenu(in view: NSView, at point: NSPoint) {
        // the corner orb's menu is your first orb's menu (plus ＋ to start one when there are none)
        if let first = sessions.firstName {
            sessions.orbMenu(first).popUp(positioning: nil, at: point, in: view)
        } else {
            let menu = sessions.plusMenu()
            menu.addItem(.separator())
            addGeneralItems(to: menu)
            menu.popUp(positioning: nil, at: point, in: view)
        }
    }

    /// The pet's own options (stop, OS mode, tunnel vision, auto, notes…), shown on every orb's menu.
    func addGeneralItems(to menu: NSMenu) {
        func item(_ title: String, _ sel: Selector, on: Bool? = nil) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            if let on { i.state = on ? .on : .off }
            menu.addItem(i)
        }
        item("Stop Claude (interrupt current task)", #selector(menuStopClaude))
        item("OS mode (double-tap left Option)", #selector(menuOSMode), on: osMode.on)
        item("Canvas (show what agents say)", #selector(menuCanvas), on: canvas.enabled)
        item("Focus timer", #selector(menuPomodoro), on: !pomodoro.hidden)
        item(model.s.meeting ? "Stop recording meeting (right Option ×2)" : "Record meeting (right Option ×2)", #selector(menuMeeting))
        item("Open meetings folder", #selector(menuOpenMeetings))
        item("Tunnel vision (Esc to exit)", #selector(menuTunnel), on: !tunnelPanels.isEmpty)
        let shape = NSMenuItem(title: "Tunnel shape", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, sel, on) in [("Circle", #selector(menuShapeCircle), !tunnelRect),
                                 ("Rectangle", #selector(menuShapeRect), tunnelRect)] {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self; i.state = on ? .on : .off
            sub.addItem(i)
        }
        shape.submenu = sub
        menu.addItem(shape)
        menu.addItem(.separator())
        item("Auto mode (hands-free)", #selector(menuAuto), on: model.s.auto)
        item("Notes mode (save speech as notes)", #selector(menuNotes), on: model.s.notes)
        menu.addItem(.separator())
        item("Open notes file", #selector(menuOpenNotes))
        menu.addItem(.separator())
        item("Show Claude session (Terminal)", #selector(menuShowClaude))
        item("Quit Claude session", #selector(menuQuitClaude))
        menu.addItem(.separator())
        item("Quit VoicePet", #selector(menuQuitPet))
    }

    func panel(_ rect: NSRect) -> NSPanel {
        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return p
    }

    func build() {
        panels.forEach { $0.close() }
        panels = []; orbPanels = []; cardPanels = []
        for screen in NSScreen.screens {
            let f = screen.visibleFrame, orbW: CGFloat = 56, h: CGFloat = 64
            let orbX = f.maxX - orbW - 6, y = f.minY + 10
            let peek = panel(NSRect(x: orbX - 380, y: y, width: 380, height: 160))
            peek.ignoresMouseEvents = true                     // peek bubble is click-through
            peek.contentView = NSHostingView(rootView: PeekView(m: model))
            let orb = panel(NSRect(x: orbX, y: y, width: orbW, height: h))
            let host = ClickHost(rootView: Orb(m: model))
            host.onClick = { [weak self] in
                guard let self else { return }
                if !self.tunnelPanels.isEmpty { self.setTunnel(false); return }   // in tunnel vision a click exits it
                if let first = self.sessions.firstName { self.sessions.openTyping(first) }   // type to your first orb
            }
            host.onMenu = { [weak self, weak host] event in
                guard let self, let host else { return }
                self.showMenu(in: host, event: event)
            }
            orb.contentView = host
            let card = KeyPanel(contentRect: NSRect(x: orbX - 380, y: y + 50, width: 380, height: 220),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            card.isOpaque = false; card.backgroundColor = .clear; card.hasShadow = false
            card.level = .statusBar
            card.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            card.ignoresMouseEvents = true
            card.contentView = FirstMouseHost(rootView: NoteCard(m: model))
            peek.orderFrontRegardless(); card.orderFrontRegardless(); orb.orderFrontRegardless()
            panels += [peek, card, orb]; orbPanels.append(orb); cardPanels.append(card)
        }
        applyCornerOrbVisibility()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
