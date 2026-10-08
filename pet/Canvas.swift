// Canvas: a small always-on card (top right by default) that prints whatever any agent says, newest first.
// Turned on from any orb's menu. Drag it anywhere, resize it from its edges; it remembers both.
import AppKit
import NaturalLanguage
import SwiftUI

struct CanvasLine: Identifiable, Equatable {
    let id: String
    let who: String          // orb display name: "Claude · Inbox"
    let kind: String         // "claude" | "codex"
    let text: String
    let at: Date
}

final class CanvasModel: ObservableObject {
    @Published var lines: [CanvasLine] = []
    @Published var shown = false
    func add(_ l: CanvasLine) {
        guard !lines.contains(where: { $0.id == l.id }) else { return }
        withAnimation(OSMotion.show) {
            lines.insert(l, at: 0)
            if lines.count > 30 { lines.removeLast(lines.count - 30) }
        }
    }
}

struct SpeechCanvasView: View {
    @ObservedObject var m: CanvasModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble").font(.system(size: 10, weight: .bold)).foregroundColor(.white.opacity(0.5))
                Text("Canvas").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.5))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundColor(.white.opacity(0.55))
                        .frame(width: 16, height: 16).background(Circle().fill(Color.white.opacity(0.08)))
                }.buttonStyle(.plain).help("Close canvas")
            }
            .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 6)
            if m.lines.isEmpty {
                Text("Whatever an agent says shows up here.")
                    .font(.system(size: 12, design: .rounded)).foregroundColor(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(m.lines.enumerated()), id: \.element.id) { i, l in
                            line(l, latest: i == 0)
                                .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                        removal: .opacity))
                        }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 12)
                }
            }
        }
        .frame(minWidth: 220, maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
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
    }

    /// Split into sentences (Apple's sentence tokenizer: "e.g.", "Dr.", "3.5" don't break), and lines the agent
    /// already broke stay broken.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        for para in text.components(separatedBy: .newlines) {
            let p = para.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            let tok = NLTokenizer(unit: .sentence)
            tok.string = p
            tok.enumerateTokens(in: p.startIndex..<p.endIndex) { r, _ in
                let s = p[r].trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { out.append(s) }
                return true
            }
        }
        return out.isEmpty ? [text] : out
    }

    func line(_ l: CanvasLine, latest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(Color.white.opacity(latest ? 0.9 : 0.3)).frame(width: 5, height: 5)
                Text(l.who).font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(latest ? 0.7 : 0.4)).lineLimit(1)
                Spacer(minLength: 4)
                Text(l.at, format: .dateTime.hour().minute())
                    .font(.system(size: 9, design: .rounded)).foregroundColor(.white.opacity(0.3)).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: latest ? 7 : 4) {      // one sentence per line, a little air between
                ForEach(Array(Self.sentences(l.text).enumerated()), id: \.offset) { _, s in
                    Text(s)
                        .font(.system(size: latest ? 14 : 12, weight: latest ? .medium : .regular, design: .rounded))
                        .foregroundColor(.white.opacity(latest ? 0.95 : 0.5))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
        }
    }
}

/// Borderless, resizable from its edges, moved by dragging anywhere that isn't text.
final class CanvasPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class Canvas {
    let m = CanvasModel()
    private var panel: CanvasPanel?
    private static let enabledKey = "canvasEnabled"
    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    func restore() { if enabled { show() } }

    func toggle() { enabled ? hide() : show() }

    func show() {
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        if panel == nil {
            let p = CanvasPanel(contentRect: .zero, styleMask: [.borderless, .resizable, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.isMovableByWindowBackground = true
            p.minSize = NSSize(width: 220, height: 120)
            let host = NSHostingView(rootView: SpeechCanvasView(m: m) { [weak self] in self?.hide() })
            p.contentView = host
            if !p.setFrameUsingName("VoicePetCanvas") {             // first time: top right, under the menu bar
                let s = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
                p.setFrame(NSRect(x: s.maxX - 340 - 16, y: s.maxY - 240 - 12, width: 340, height: 240), display: true)
            }
            p.setFrameAutosaveName("VoicePetCanvas")
            panel = p
        }
        panel?.orderFrontRegardless()
        m.shown = true
    }

    func hide() {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        m.shown = false
        let p = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            if self?.m.shown == false { p?.orderOut(nil) }
        }
    }
}
