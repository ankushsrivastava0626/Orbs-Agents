// Meeting recording, kept quiet: a tiny dot at the top-right corner of the screen. Red (slowly pulsing)
// while recording, grey while it transcribes, nothing otherwise. Hover it for the time.
import AppKit
import SwiftUI

struct MeetingBadgeView: View {
    @ObservedObject var m: Model
    @State private var now = Date()
    let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        let on = m.s.meeting, busy = m.s.meeting_transcribing
        let s = Int(max(0, now.timeIntervalSince1970 - m.s.meeting_started))
        Circle()
            .fill(on ? Color.red : Color.white.opacity(0.5))
            .frame(width: 5, height: 5)
            .opacity(on || busy ? (on ? (s % 4 < 2 ? 0.85 : 0.45) : 0.6) : 0)
            .animation(.easeInOut(duration: 1.2), value: s)
            .animation(.easeInOut(duration: 0.4), value: on || busy)
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
            .help(on ? String(format: "Recording %d:%02d — double-tap right Option to stop", s / 60, s % 60)
                     : busy ? "Transcribing the meeting" : "")
            .onReceive(tick) { if m.s.meeting { now = $0 } }     // only a recording needs the second hand
    }
}

final class MeetingBadge {
    private var panel: NSPanel?
    private let m: Model
    init(_ m: Model) { self.m = m }

    func show() {
        guard panel == nil else { return }
        let p = FirstClickPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.contentView = DockHost(rootView: MeetingBadgeView(m: m))
        let s = (NSScreen.main ?? NSScreen.screens[0]).frame
        p.setFrame(NSRect(x: s.maxX - 16, y: s.maxY - 16, width: 14, height: 14), display: true)
        p.orderFrontRegardless()
        panel = p
    }
}
