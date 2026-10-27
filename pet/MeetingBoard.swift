// Meeting board: a card that shows the meeting being transcribed while you record — who spoke and when —
// then the final transcript once you stop. Turned on from any orb's menu. Drag it anywhere, resize it from
// its edges; it remembers both. Hidden from screen sharing and recordings, like the rest of meeting mode.
import AppKit
import SwiftUI

struct LiveSeg: Decodable, Equatable {
    let start: Double
    let end: Double
    let speaker: String
    let text: String
}

struct LiveView: Decodable {
    var recording = false, started = 0.0, transcribing = false, final = false
    var folder = ""
    var segments: [LiveSeg] = []
}

final class MeetingBoardModel: ObservableObject {
    @Published var v = LiveView()
    @Published var shown = false
    var onClose: () -> Void = {}
    var onOpenFolder: () -> Void = {}

    /// Consecutive lines from the same speaker read as one paragraph.
    struct Block: Identifiable { let id: Int; let start: Double; let speaker: String; var text: String }
    var blocks: [Block] {
        var out: [Block] = []
        for (i, s) in v.segments.enumerated() {
            if let last = out.last, last.speaker == s.speaker { out[out.count - 1].text += " " + s.text }
            else { out.append(Block(id: i, start: s.start, speaker: s.speaker, text: s.text)) }
        }
        return out
    }
}

struct MeetingBoardView: View {
    @ObservedObject var m: MeetingBoardModel
    @State private var now = Date()
    let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // no yellow or blue: speakers get soft pink, green, purple, coral, mint
    static let palette: [Color] = [Color(red: 1, green: 0.5, blue: 0.65), Color(red: 0.5, green: 0.85, blue: 0.55),
                                   Color(red: 0.75, green: 0.6, blue: 1), Color(red: 1, green: 0.55, blue: 0.45),
                                   Color(red: 0.55, green: 0.9, blue: 0.78)]
    static func color(_ speaker: String) -> Color {
        let n = Int(speaker.filter(\.isNumber)) ?? 1
        return palette[(max(n, 1) - 1) % palette.count]
    }
    static func ts(_ ms: Double) -> String {
        let s = Int(ms / 1000), h = s / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    var status: (String, Color) {
        let v = m.v
        if v.recording {
            let s = Int(max(0, now.timeIntervalSince1970 - v.started))
            return (String(format: "Recording · %d:%02d", s / 60, s % 60), .red)
        }
        if v.transcribing { return ("Finishing transcript…", .white.opacity(0.5)) }
        if v.final { return ("Transcript", .white.opacity(0.35)) }
        return ("Starts with your next meeting", .white.opacity(0.25))
    }

    var body: some View {
        let (label, dot) = status
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(dot).frame(width: 6, height: 6)
                    .opacity(m.v.recording ? (Int(now.timeIntervalSince1970) % 4 < 2 ? 0.9 : 0.45) : 1)
                    .animation(.easeInOut(duration: 1.2), value: Int(now.timeIntervalSince1970))
                Text(label).font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.55)).monospacedDigit().lineLimit(1)
                Spacer()
                if !m.v.folder.isEmpty {
                    iconButton("folder", "Open this meeting's folder", m.onOpenFolder)
                }
                iconButton("xmark", "Hide until the next meeting", m.onClose)
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(m.blocks) { b in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(Self.ts(b.start)).font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.3))
                                    Text(b.speaker).font(.system(size: 10, weight: .semibold, design: .rounded))
                                        .foregroundColor(Self.color(b.speaker).opacity(0.85))
                                }
                                Text(b.text).font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundColor(.white.opacity(0.92)).lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(b.id)
                            .transition(.opacity.combined(with: .offset(y: 6)))
                        }
                        if m.v.segments.isEmpty {
                            Text(m.v.recording ? "Listening… the first lines appear in about half a minute."
                                               : "Double-tap right Option to record a meeting.")
                                .font(.system(size: 12, design: .rounded)).foregroundColor(.white.opacity(0.35))
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.bottom, 12)
                    .animation(OSMotion.show, value: m.v.segments.count)
                }
                .onChange(of: m.v.segments.count) { _ in
                    withAnimation(OSMotion.show) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .frame(minWidth: 260, maxWidth: .infinity, minHeight: 120, maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.07).opacity(0.96))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 1)))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .bottomTrailing) {                     // resize grip (the edges resize too)
            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 7, weight: .bold))
                .foregroundColor(.white.opacity(0.2)).padding(6)
        }
        .scaleEffect(m.shown ? 1 : 0.92, anchor: .topTrailing)
        .opacity(m.shown ? 1 : 0)
        .animation(m.shown ? OSMotion.show : .easeInOut(duration: 0.35), value: m.shown)
        .onReceive(tick) { now = $0 }
    }

    private func iconButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold)).foregroundColor(.white.opacity(0.55))
                .frame(width: 16, height: 16).background(Circle().fill(Color.white.opacity(0.08)))
        }.buttonStyle(.plain).help(help)
    }
}

/// On: polls the voice server (which only transcribes live while the board is polling), shows itself when
/// a meeting starts, and stays up with the final transcript after it ends until you close it.
final class MeetingBoard: NSObject, NSWindowDelegate {
    let m = MeetingBoardModel()
    private var panel: CanvasPanel?
    private var timer: Timer?
    private var dismissedFolder = ""             // closed during/after this meeting: stay hidden until the next
    private static let enabledKey = "meetingBoardEnabled", frameKey = "meetingBoardFrame"
    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    func restore() { if enabled { start(showNow: false) } }
    func toggle() {
        if enabled {
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            timer?.invalidate(); timer = nil
            hide()
        } else {
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
            start(showNow: true)
        }
    }

    private func start(showNow: Bool) {
        m.onClose = { [weak self] in guard let self else { return }; self.dismissedFolder = self.m.v.folder; self.hide() }
        m.onOpenFolder = { [weak self] in
            guard let f = self?.m.v.folder, !f.isEmpty else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: f))
        }
        dismissedFolder = ""
        if showNow { show() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private func poll() {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:5123/meeting/live")!)
        req.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data, let v = try? JSONDecoder().decode(LiveView.self, from: data) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                let startedNew = v.recording && v.folder != self.m.v.folder
                if v.segments != self.m.v.segments || v.recording != self.m.v.recording
                    || v.transcribing != self.m.v.transcribing || v.final != self.m.v.final || v.folder != self.m.v.folder {
                    self.m.v = v
                }
                if startedNew { self.dismissedFolder = "" }
                if v.recording && v.folder != self.dismissedFolder && !self.m.shown { self.show() }
            }
        }.resume()
    }

    private func show() {
        if panel == nil {
            let p = CanvasPanel(contentRect: .zero, styleMask: [.borderless, .resizable, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.isMovableByWindowBackground = true
            p.sharingType = .none                                   // not in screen shares or recordings
            p.minSize = NSSize(width: 260, height: 120)
            p.contentView = NSHostingView(rootView: MeetingBoardView(m: m))
            p.delegate = self
            var r = UserDefaults.standard.string(forKey: Self.frameKey).map(NSRectFromString) ?? .zero
            if r.width < 100 {                                      // first time: right side, under the menu bar
                let s = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
                r = NSRect(x: s.maxX - 380 - 16, y: s.maxY - 420 - 60, width: 380, height: 420)
            }
            p.setFrame(r, display: true)
            panel = p
        }
        panel?.orderFrontRegardless()
        m.shown = true
    }

    private func hide() {
        m.shown = false
        let p = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            if self?.m.shown == false { p?.orderOut(nil) }
        }
    }

    func windowDidMove(_ n: Notification) { remember() }
    func windowDidEndLiveResize(_ n: Notification) { remember() }
    private func remember() {
        guard let p = panel else { return }
        UserDefaults.standard.set(NSStringFromRect(p.frame), forKey: Self.frameKey)
    }
}
