// OS mode dock: a small, always-visible bar at the bottom of the canvas showing what's open.
// Click = bring that box forward (repeat to cycle an app's windows); two-finger click = actions;
// right side: clock and Exit OS mode.
import AppKit
import SwiftUI

struct DockItem: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let icon: NSImage
    let windows: Int
    let active: Bool
    static func == (a: DockItem, b: DockItem) -> Bool {
        a.id == b.id && a.windows == b.windows && a.active == b.active && a.name == b.name
    }
}

final class DockModel: ObservableObject {
    @Published var items: [DockItem] = []
    @Published var now = Date()
    @Published var hovered: pid_t? = nil
    var onFocus: ((pid_t) -> Void)?
    var onClose: ((pid_t) -> Void)?
    var onQuit: ((pid_t) -> Void)?
    var onFill: ((pid_t) -> Void)?
    var onReset: ((pid_t) -> Void)?
    var onExit: (() -> Void)?
    var isFilled: ((pid_t) -> Bool)?
    var orb: AnyView? = nil                          // the voice orb lives here in OS mode
    var onOrbMenu: ((NSView, CGPoint) -> Void)?
    @Published var orbIds: [String] = []             // one orb per voice session
    var orbView: ((String) -> AnyView)?
    var onOrbClick: ((String) -> Void)?
    var onOrbHover: ((String, Bool) -> Void)?
    var onOrbMenuFor: ((String, NSView, CGPoint) -> Void)?
    var onPlus: ((NSView, CGPoint) -> Void)?
}

/// Remembers where each orb is on screen, so a speech bubble can point at it.
final class OrbAnchors {
    static let shared = OrbAnchors()
    private var views: [String: WeakView] = [:]
    final class WeakView { weak var v: NSView?; init(_ v: NSView) { self.v = v } }
    func set(_ id: String, _ v: NSView) { views[id] = WeakView(v) }
    func screenRect(_ id: String) -> NSRect? {
        guard let v = views[id]?.v, let w = v.window, w.isVisible, w.alphaValue > 0.01 else { return nil }
        return w.convertToScreen(v.convert(v.bounds, to: nil))
    }
}

struct OrbAnchor: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> NSView { let v = NSView(); OrbAnchors.shared.set(id, v); return v }
    func updateNSView(_ v: NSView, context: Context) { OrbAnchors.shared.set(id, v) }
}

/// Right-click / two-finger click catcher that knows its NSView (for popping up an NSMenu).
struct RightClickReader: NSViewRepresentable {
    let onClick: (NSView, CGPoint) -> Void
    var onLeftClick: (() -> Void)? = nil                 // plain click (this view sits on top, so it must handle it)
    func makeNSView(context: Context) -> NSView { V(onClick: onClick, onLeft: onLeftClick) }
    func updateNSView(_ v: NSView, context: Context) { (v as? V)?.onClick = onClick; (v as? V)?.onLeft = onLeftClick }
    final class V: NSView {
        var onClick: (NSView, CGPoint) -> Void
        var onLeft: (() -> Void)?
        init(onClick: @escaping (NSView, CGPoint) -> Void, onLeft: (() -> Void)?) {
            self.onClick = onClick; self.onLeft = onLeft; super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func rightMouseDown(with e: NSEvent) { onClick(self, convert(e.locationInWindow, from: nil)) }
        override func mouseDown(with e: NSEvent) {
            if e.modifierFlags.contains(.control) { onClick(self, convert(e.locationInWindow, from: nil)) }
            else { onLeft?() }
        }
    }
}

struct DockView: View {
    @ObservedObject var m: DockModel
    let gold = Color(red: 1, green: 0.82, blue: 0.2)

    var body: some View {
        HStack(spacing: 6) {
            if m.items.isEmpty {
                Text("Push the mouse to the left edge for apps")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.45))
                    .padding(.horizontal, 8)
            }
            ForEach(m.items) { item in
                Button(action: { m.onFocus?(item.id) }) {
                    VStack(spacing: 3) {
                        Image(nsImage: item.icon).resizable().frame(width: 32, height: 32)
                            .opacity(item.windows == 0 ? 0.55 : 1)
                            .scaleEffect(m.hovered == item.id ? 1.12 : 1)
                            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: m.hovered == item.id)
                        HStack(spacing: 2) {                              // one dot per box (max 3)
                            if item.windows == 0 {                        // running, but not on the canvas
                                Circle().fill(Color.white.opacity(0.22)).frame(width: 3, height: 3)
                            }
                            ForEach(0..<min(item.windows, 3), id: \.self) { _ in
                                Circle().fill(item.active ? gold : Color.white.opacity(0.5)).frame(width: 3, height: 3)
                            }
                        }.frame(height: 3)
                    }
                }
                .buttonStyle(.plain)
                .help(item.name)
                .onHover { m.hovered = $0 ? item.id : (m.hovered == item.id ? nil : m.hovered) }
                .contextMenu {
                    Button(m.isFilled?(item.id) == true ? "Back to box" : "Fill screen") { m.onFill?(item.id) }
                    Button("Reset box size") { m.onReset?(item.id) }
                    Divider()
                    Button("Close window") { m.onClose?(item.id) }
                    Button("Quit \(item.name)") { m.onQuit?(item.id) }
                }
            }
            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 26).padding(.horizontal, 4)
            ForEach(m.orbIds, id: \.self) { id in                  // session orbs: click = talk to it
                (m.orbView?(id) ?? AnyView(EmptyView()))
                    .frame(width: 36, height: 36)
                    .overlay(RightClickReader(onClick: { v, p in m.onOrbMenuFor?(id, v, p) },
                                              onLeftClick: { m.onOrbClick?(id) }))
                    .background(OrbAnchor(id: id))                       // speech bubbles point here
                    .onHover { m.onOrbHover?(id, $0) }
            }
            Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.75))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.10)))
                .overlay(AnchorReader { v, p in m.onPlus?(v, p) })
                .help("New voice session (Claude or Codex)")
            Button(action: { m.onExit?() }) {
                Image(systemName: "power").font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.75))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.10)))
            }.buttonStyle(.plain).help("Exit OS mode")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(
            Capsule().fill(Color(white: 0.09).opacity(0.92))
                .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 10, y: 2))
        .fixedSize()
        .padding(10)
    }
}

final class DockHost<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
