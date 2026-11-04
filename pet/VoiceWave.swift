// While a task card records: a soft wave at the middle of the right edge that moves with your voice.
// It reads the recorder's loudness (a tiny file it rewrites ~25 times a second) and fades away when you stop.
import AppKit
import SwiftUI

final class VoiceWaveModel: ObservableObject {
    @Published var shown = false
    @Published var level: Double = 0             // smoothed loudness, 0…1
}

struct VoiceWaveView: View {
    @ObservedObject var m: VoiceWaveModel
    static let size = CGSize(width: 120, height: 220)

    var body: some View {
        TimelineView(.animation) { tl in
            SwiftUI.Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let amp = 6 + m.level * 46                                   // quiet: a gentle ripple
                // three vertical waves, each its own speed and colour (pink, purple, mint — no yellow or blue)
                let waves: [(Color, Double, Double, Double)] = [
                    (Color(red: 1, green: 0.5, blue: 0.7), 1.0, 2.2, 0.0),
                    (Color(red: 0.75, green: 0.6, blue: 1), 0.75, 1.6, 1.3),
                    (Color(red: 0.55, green: 0.9, blue: 0.78), 0.55, 2.9, 2.6)]
                for (color, scale, speed, phase) in waves {
                    var p = Path()
                    let midX = size.width / 2
                    for i in 0...60 {
                        let y = size.height * Double(i) / 60
                        let u = Double(i) / 60
                        let taper = sin(.pi * u)                                 // pinched at both ends
                        let x = midX + amp * scale * taper * sin(u * .pi * 3 + t * speed * 2 + phase)
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    ctx.stroke(p, with: .color(color.opacity(0.85)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .shadow(color: Color(red: 1, green: 0.5, blue: 0.7).opacity(0.25 + m.level * 0.4), radius: 12)
        .scaleEffect(m.shown ? 1 : 0.6)
        .opacity(m.shown ? 1 : 0)
        .animation(m.shown ? OSMotion.show : .easeInOut(duration: 0.35), value: m.shown)
    }
}

final class VoiceWave {
    let m = VoiceWaveModel()
    private var panel: NSPanel?
    private var timer: Timer?
    private var file = ""

    /// Called with each task-board poll: the recorder's loudness file while one records, "" when none does.
    func sync(levelFile: String) {
        if !levelFile.isEmpty, file.isEmpty { start(levelFile) }
        else if levelFile.isEmpty, !file.isEmpty { stop() }
        else if !levelFile.isEmpty { file = levelFile }
    }

    private func start(_ f: String) {
        file = f
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.level = .statusBar; p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.contentView = NSHostingView(rootView: VoiceWaveView(m: m))
            panel = p
        }
        let s = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame, z = VoiceWaveView.size
        panel?.setFrame(NSRect(x: s.maxX - z.width - 8, y: s.midY - z.height / 2, width: z.width, height: z.height), display: true)
        panel?.orderFrontRegardless()
        m.level = 0; m.shown = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.read() }
    }

    private func read() {
        guard let s = try? String(contentsOfFile: file, encoding: .utf8), let rms = Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        else { m.level *= 0.9; return }
        let target = min(1, rms * 9)                                       // speech is ~0.02–0.1 rms
        m.level += (target - m.level) * (target > m.level ? 0.45 : 0.12)   // quick to rise, slow to settle
    }

    private func stop() {
        file = ""
        timer?.invalidate(); timer = nil
        m.shown = false
        let p = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in if self?.m.shown == false { p?.orderOut(nil) } }
    }
}
