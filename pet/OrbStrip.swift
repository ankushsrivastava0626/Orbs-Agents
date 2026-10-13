// Outside OS mode: every orb sits in a small strip at the bottom right, working exactly as in the dock
// (click to type, hold its number to talk, two-finger click for its menu, drag to reorder, ＋ for new).
import AppKit
import Combine
import SwiftUI

struct OrbStripView: View {
    @ObservedObject var m: DockModel
    var body: some View {
        HStack(spacing: 6) {
            ForEach(m.orbIds, id: \.self) { id in
                (m.orbView?(id) ?? AnyView(EmptyView()))
                    .frame(width: 36, height: 36)
                    .scaleEffect(m.draggingId == id ? 1.18 : 1)
                    .shadow(color: .white.opacity(m.draggingId == id ? 0.25 : 0), radius: 8)
                    .animation(.spring(response: 0.3, dampingFraction: 0.75), value: m.draggingId)
                    .overlay(RightClickReader(onClick: { v, p in m.onOrbMenuFor?(id, v, p) },
                                              onLeftClick: { m.onOrbClick?(id) },
                                              onDrag: { phase, p in m.onOrbDrag?(id, phase, p) }))
                    .background(OrbAnchor(id: id))
                    .onHover { m.onOrbHover?(id, $0) }
                    .transition(.scale.combined(with: .opacity))
            }
            Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.75))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.10)))
                .overlay(AnchorReader { v, p in m.onPlus?(v, p) })
                .help("New voice session (Claude or Codex)")
        }
        .animation(OSMotion.show, value: m.orbIds)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            Capsule().fill(Color(white: 0.09).opacity(0.92))
                .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 2))
        .fixedSize()
        .padding(8)
    }
}

final class OrbStrip {
    private var panel: NSPanel?
    private var host: DockHost<OrbStripView>?
    private var watch: AnyCancellable?
    private let m: DockModel

    init(_ m: DockModel) { self.m = m }

    func show() {
        if panel == nil {
            let p = FirstClickPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let h = DockHost(rootView: OrbStripView(m: m))
            p.contentView = h
            panel = p; host = h
            watch = m.$orbIds.receive(on: DispatchQueue.main).sink { [weak self] _ in
                DispatchQueue.main.async { self?.layout() }          // after SwiftUI has the new orbs
            }
        }
        layout()
        guard let p = panel, !p.isVisible || p.alphaValue < 1 else { return }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.3; p.animator().alphaValue = 1 }
    }

    func hide() {
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
    }

    /// Bottom right, just above the macOS Dock; grows to the left as orbs are added.
    func layout() {
        guard let p = panel, let h = host else { return }
        let size = h.fittingSize
        let s = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let r = NSRect(x: s.maxX - size.width - 2, y: s.minY + 2, width: size.width, height: size.height)
        if p.frame != r { p.setFrame(r, display: true) }
    }
}
