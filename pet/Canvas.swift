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
    @Published var latest: CanvasLine? = nil
    @Published var shown = false
    var seen: Set<String> = []
    var onNeeded: ((CGFloat) -> Void)?       // height the current text needs
    func add(_ l: CanvasLine) {
        guard !seen.contains(l.id) else { return }
        seen.insert(l.id)
        withAnimation(OSMotion.show) { latest = l }
    }
}

struct CanvasHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct SpeechCanvasView: View {
    @ObservedObject var m: CanvasModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "text.bubble").font(.system(size: 10, weight: .bold)).foregroundColor(.white.opacity(0.5))
                    Text(m.latest?.who ?? "Canvas").font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.55)).lineLimit(1)
                    Spacer()
                    if let at = m.latest?.at {
                        Text(at, format: .dateTime.hour().minute())
                            .font(.system(size: 9, design: .rounded)).foregroundColor(.white.opacity(0.3)).monospacedDigit()
                    }
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundColor(.white.opacity(0.55))
                            .frame(width: 16, height: 16).background(Circle().fill(Color.white.opacity(0.08)))
                    }.buttonStyle(.plain).help("Close canvas")
                }
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
                if let l = m.latest {
                    VStack(alignment: .leading, spacing: 8) {                // one sentence per line, a little air between
                        ForEach(Array(Self.sentences(l.text).enumerated()), id: \.offset) { _, s in
                            Text(s)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundColor(.white.opacity(0.95))
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.bottom, 16)
                    .id(l.id)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 6)), removal: .opacity))
                } else {
                    Text("Whatever an agent says shows up here.")
                        .font(.system(size: 12, design: .rounded)).foregroundColor(.white.opacity(0.35))
                        .padding(.horizontal, 14).padding(.bottom, 16)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { g in Color.clear.preference(key: CanvasHeightKey.self, value: g.size.height) })
            Spacer(minLength: 0)
        }
        .onPreferenceChange(CanvasHeightKey.self) { h in m.onNeeded?(h) }
        .frame(minWidth: 220, maxWidth: .infinity, minHeight: 80, maxHeight: .infinity, alignment: .top)
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

}

/// Borderless, resizable from its edges, moved by dragging anywhere that isn't text.
final class CanvasPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Your size (set by resizing it) is the default. A long reply grows the card downward to fit; the next
/// shorter one brings it back to your size.
final class Canvas: NSObject, NSWindowDelegate {
    let m = CanvasModel()
    private var panel: CanvasPanel?
    private static let enabledKey = "canvasEnabled", frameKey = "canvasBaseFrame"
    private var base = NSRect.zero                 // your size and spot (top edge stays put)
    private var programmatic = false
    private var needed: CGFloat = 0
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
            p.minSize = NSSize(width: 220, height: 80)
            p.contentView = NSHostingView(rootView: SpeechCanvasView(m: m) { [weak self] in self?.hide() })
            p.delegate = self
            if let s = UserDefaults.standard.string(forKey: Self.frameKey) { base = NSRectFromString(s) }
            if base.width < 100 {                                     // first time: top right, under the menu bar
                let s = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
                base = NSRect(x: s.maxX - 340 - 16, y: s.maxY - 160 - 12, width: 340, height: 160)
            }
            panel = p                                                 // first: set() below needs the window
            set(base, animate: false)
            m.onNeeded = { [weak self] h in self?.fit(h) }
        }
        panel?.orderFrontRegardless()
        m.shown = true
    }

    private func set(_ r: NSRect, animate: Bool) {
        guard let p = panel else { return }
        programmatic = true
        if animate {                                                 // animator: doesn't hold the main thread
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; p.animator().setFrame(r, display: true) },
                                                 completionHandler: { [weak self] in self?.programmatic = false })
        } else {
            p.setFrame(r, display: true)
            programmatic = false
        }
    }

    /// Grow to fit the text, never below your size; keep the top edge where it is.
    private func fit(_ h: CGFloat) {
        needed = h
        guard let p = panel, !p.inLiveResize else { return }        // you're resizing it: wait till you let go
        let top = p.frame.maxY
        var height = max(base.height, ceil(h) + 4)
        if let s = p.screen?.visibleFrame { height = min(height, top - s.minY - 8) }   // never past the bottom of the screen
        height = max(height, p.minSize.height)                       // …nor smaller than a card
        guard abs(height - p.frame.height) > 1 else { return }
        set(NSRect(x: p.frame.minX, y: top - height, width: p.frame.width, height: height), animate: true)
    }

    // you moved or resized it: that's the new default
    func windowDidMove(_ n: Notification) { remember() }
    func windowDidEndLiveResize(_ n: Notification) { remember(resized: true) }
    private func remember(resized: Bool = false) {
        guard !programmatic, let p = panel else { return }
        let f = p.frame
        base = resized ? f : NSRect(x: f.minX, y: f.maxY - base.height, width: f.width, height: base.height)
        UserDefaults.standard.set(NSStringFromRect(base), forKey: Self.frameKey)
        if resized { fit(needed) }
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
