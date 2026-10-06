// OS mode: the whole screen becomes a black canvas. Push the mouse against the left edge to reveal a
// dial of apps; each app you pick opens as a box (its real window, resized and placed by Accessibility).
// Several apps tile as several boxes. Esc / the dial's exit button / the options menu leave OS mode.
import AppKit
import ApplicationServices
import SwiftUI

/// Private but long-stable: the CGWindowID behind an Accessibility window element.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: - Dial model

struct DialApp: Identifiable, Equatable {
    let id: String          // bundle path
    let name: String
    let url: URL
    let icon: NSImage
}

final class DialModel: ObservableObject {
    @Published var apps: [DialApp] = []          // what the dial shows (filtered by `query`)
    private var allApps: [DialApp] = []
    @Published var query = ""

    /// Typing filters the dial: "g" shows every app with a word starting with g, "go" narrows it, etc.
    func type(_ e: NSEvent) -> Bool {
        switch e.keyCode {
        case 51: if !query.isEmpty { query.removeLast(); refilter() }; return true        // delete
        case 53: if query.isEmpty { return false }; query = ""; refilter(); return true    // esc clears search
        case 36, 76: if let s = selected { onPick?(s) }; return true                     // return opens
        case 123, 126: step(-1); return true                                              // ← ↑
        case 124, 125: step(1); return true                                               // → ↓
        default:
            guard let c = e.charactersIgnoringModifiers, !c.isEmpty,
                  c.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == " " }) else { return false }
            query += c.lowercased(); refilter(); return true
        }
    }

    func clearQuery() { if !query.isEmpty { query = ""; refilter() } }

    /// Search never rebuilds the wheel: it turns it to the first match, dims everything else, and
    /// scrolling/arrows then step between matches only.
    @Published var matches: [Int] = []           // indices into `apps` that match (while turning to them)
    @Published var matchIds: Set<String>? = nil  // apps matching the query (nil = no search)
    private var searchGen = 0

    /// Search, in two smooth steps:
    ///  1. the wheel turns (slowly, like a dial) to the nearest match while every other app fades out;
    ///  2. once it lands, the wheel swaps to just the matching apps, which slide together around the pointer.
    private func refilter() {
        searchGen += 1
        let gen = searchGen
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {                                           // search cleared: full wheel back, in place
            spinTimer?.invalidate(); spinTimer = nil
            matches = []
            let keep = selected?.id
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) {                                 // full wheel back instantly (others still invisible)
                apps = allApps
                if let k = keep, let i = apps.firstIndex(where: { $0.id == k }) { offset = Double(i) } else { offset = 0 }
            }
            matchIds = nil
            return
        }
        func hit(_ a: DialApp) -> Bool {
            let n = a.name.lowercased()
            return n.hasPrefix(q) || n.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." }).contains { $0.hasPrefix(q) }
        }
        let ids = Set(allApps.filter(hit).map(\.id))
        matchIds = ids
        matches = apps.indices.filter { ids.contains(apps[$0].id) }
        guard let target = nearestMatch(from: selectedIndex) else { return }   // no match: everything stays dimmed
        let keep = apps[target].id
        let only = allApps.filter { ids.contains($0.id) }
        let d = Double(signedDist(selectedIndex, target))
        let start = offset, end = offset.rounded() + d             // wheel slots, in the current list
        let duration = d == 0 ? 0.35 : min(1.2, 0.55 + 0.08 * abs(d))
        // spin to the match; halfway through (fastest point) swap in only the matches, so the motion hides it
        spin(from: start, to: end, duration: duration) { [weak self] in
            guard let self, self.searchGen == gen, let t = only.firstIndex(where: { $0.id == keep }) else { return nil }
            self.apps = only
            self.matches = []
            return Double(t) - end                                 // same slots, now counted in the new list
        }
    }

    // MARK: frame-by-frame spin (so we know exactly where the wheel is when we swap the apps)

    private var spinTimer: Timer?

    private func spin(from start: Double, to end: Double, duration: Double, midway swap: @escaping () -> Double?) {
        spinTimer?.invalidate()
        var s = start, e = end, swapped = false
        let t0 = Date()
        var lastSlot = Int(start.rounded())
        func ease(_ p: Double) -> Double { p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2 }   // easeInOutCubic
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let p = min(1, Date().timeIntervalSince(t0) / max(duration, 0.01))
            if !swapped && p >= 0.45 {                             // fastest part of the spin
                swapped = true
                if let shift = swap() { s += shift; e += shift; lastSlot += Int(shift.rounded()) }
            }
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { self.offset = s + (e - s) * ease(p) }
            let slot = Int(self.offset.rounded())
            if slot != lastSlot {                                  // tick as each app passes the pointer
                lastSlot = slot
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            if p >= 1 { timer.invalidate(); if self.spinTimer === timer { self.spinTimer = nil } }
        }
        spinTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func isMatch(_ app: DialApp) -> Bool {
        if let o = openingId { return app.id == o }              // opening: only that app stays lit
        return matchIds?.isEmpty != true                         // search never fades apps; no match dims all
    }


    /// Closest match going forward round the wheel from `i` (including `i`).
    private func nearestMatch(from i: Int) -> Int? {
        guard !matches.isEmpty else { return nil }
        return matches.min { a, b in fwd(i, a) < fwd(i, b) }
    }
    private func fwd(_ from: Int, _ to: Int) -> Int { count == 0 ? 0 : ((to - from) % count + count) % count }

    var slots = 13                               // apps that fit on the half-wheel (set from the geometry)
    var wraps: Bool { count > slots }            // few apps: show each once instead of repeating them

    /// Step to the next/previous match (or app) with a rotation.
    func step(_ dir: Int) {
        guard count > 0 else { return }
        if matches.isEmpty { turnAnimated(by: Double(dir)); return }
        let cur = selectedIndex
        let next = dir > 0 ? matches.min { fwd(cur, $0 == cur ? $0 + count : $0) < fwd(cur, $1 == cur ? $1 + count : $1) }
                           : matches.min { fwd($0, cur == $0 ? cur + count : cur) < fwd($1, cur == $1 ? cur + count : cur) }
        if let n = next { select(n) }
    }

    private func turnAnimated(by d: Double) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { offset = clampOffset(offset.rounded() + d) }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func clampOffset(_ o: Double) -> Double { wraps ? o : min(max(o, 0), Double(max(count - 1, 0))) }

    /// The app icon under a point in the dial's (flipped, top-left origin) coordinates, if any.
    func index(at p: CGPoint, height: CGFloat) -> Int? {
        guard count > 0 else { return nil }
        let r = min(height * 0.36, 300.0), step = Double(70) / Double(r), cy = height / 2
        let span = Int(Double.pi / step / 2) + 2, base = Int(offset.rounded(.down))
        var best: (Int, CGFloat)? = nil
        for k in -span...span {
            guard wraps || (base + k >= 0 && base + k < count) else { continue }
            let a = (Double(base + k) - offset) * step
            guard abs(a) < .pi / 2 + 0.2 else { continue }
            let c = CGPoint(x: CGFloat(cos(a)) * r, y: cy + CGFloat(sin(a)) * r)
            let d = hypot(p.x - c.x, p.y - c.y)
            if d < 38, d < (best?.1 ?? .infinity) { best = ((((base + k) % count) + count) % count, d) }
        }
        return best?.0
    }

    @Published var opening: String? = nil {      // app being prepared behind the curtain
        didSet { if opening == nil { openingId = nil } }
    }
    @Published var openingId: String? = nil      // while opening, every other app on the dial dims
    var onLaunch: ((DialApp, Double) -> Void)?   // (app, seconds the dial takes to turn there)

    /// One click: turn the wheel to `index` like a real dial (slower the further it goes), and start
    /// opening the app right away so it's ready by the time it's revealed.
    func rotateThenOpen(_ index: Int) {
        guard count > 0, opening == nil else { return }
        let d = Double(signedDist(selectedIndex, index))
        let duration = d == 0 ? 0.0 : min(1.4, 0.5 + 0.09 * abs(d))
        let app = apps[index]
        opening = app.name
        openingId = app.id
        if d != 0 {
            withAnimation(.timingCurve(0.45, 0.05, 0.25, 1, duration: duration)) { offset = clampOffset(offset.rounded() + d) }
            // a click for each app passing the pointer, like a rotary dial
            let n = Int(abs(d))
            for i in 0..<n {
                DispatchQueue.main.asyncAfter(deadline: .now() + duration * Double(i + 1) / Double(n + 1)) {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            }
        }
        onLaunch?(app, duration)
    }
    @Published var hovered: String? = nil
    @Published var visible = false
    @Published var offset: Double = 0            // dial rotation, in app slots (fractional while turning)
    private var snapWork: DispatchWorkItem?

    var count: Int { apps.count }
    var selectedIndex: Int {
        guard count > 0 else { return 0 }
        let i = Int(offset.rounded())
        return wraps ? ((i % count) + count) % count : min(max(i, 0), count - 1)
    }
    var selected: DialApp? { count == 0 ? nil : apps[selectedIndex] }

    /// Two-finger scroll turns the dial freely; it ticks as each app passes the pointer.
    func turn(by slots: Double) {
        guard count > 0 else { return }
        spinTimer?.invalidate(); spinTimer = nil
        let before = Int(offset.rounded())
        offset = clampOffset(offset + slots)
        if Int(offset.rounded()) != before { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        // no auto-centering: the wheel stays exactly where you leave it; the app nearest the pointer is selected
    }

    /// Signed slot distance from `a` to `b` the short way round (or straight, when the wheel doesn't wrap).
    func signedDist(_ a: Int, _ b: Int) -> Int {
        var d = b - a
        if wraps { if d > count / 2 { d -= count } else if d < -count / 2 { d += count } }
        return d
    }

    /// Turn the wheel (animated, never a jump) until `index` is at the pointer.
    func select(_ index: Int) {
        guard count > 0 else { return }
        let d = Double(signedDist(selectedIndex, index))
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { offset = clampOffset(offset.rounded() + d) }
        if d != 0 { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }
    var onPick: ((DialApp) -> Void)?
    var onExit: (() -> Void)?

    /// Dial apps: Finder, then apps pinned in the Dock, then running apps, then the most recently used
    /// apps in /Applications and /System/Applications (up to 18 in all).
    func loadDockApps() {
        var urls: [URL] = [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")]
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        proc.arguments = ["export", "com.apple.dock", "-"]
        let pipe = Pipe(); proc.standardOutput = pipe
        try? proc.run(); proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let dock = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        for key in ["persistent-apps", "recent-apps"] {
            for it in (dock?[key] as? [[String: Any]]) ?? [] {
                if let tile = it["tile-data"] as? [String: Any], let file = tile["file-data"] as? [String: Any],
                   let s = file["_CFURLString"] as? String, let u = URL(string: s) { urls.append(u) }
            }
        }
        let me = ProcessInfo.processInfo.processIdentifier
        urls += NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
            .compactMap { $0.bundleURL }
        let fm = FileManager.default
        var installed: [(URL, Date)] = []
        for dir in ["/Applications", "/System/Applications"] {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".app") {
                let u = URL(fileURLWithPath: dir).appendingPathComponent(name)
                let used = (try? u.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate) ?? .distantPast
                installed.append((u, used))
            }
        }
        urls += installed.sorted { $0.1 > $1.1 }.map(\.0)
        var seen = Set<String>()
        allApps = urls.compactMap { u in
            let path = u.standardizedFileURL.path.replacingOccurrences(of: "/$", with: "", options: .regularExpression)
            guard !path.contains("VoicePet"), !seen.contains(path), fm.fileExists(atPath: path) else { return nil }
            seen.insert(path)
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 64, height: 64)
            return DialApp(id: path, name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                           url: URL(fileURLWithPath: path), icon: icon)
        }
        query = ""
        refilter()

    }
}

/// Rotary dial: a wheel of every app around the left edge. The pointer sits at 3 o'clock; scroll to
/// turn the wheel, click the app at the pointer (or any app) to open it in a box.
struct DialSlot { let key: String; let idx: Int; let angle: Double }

struct DialView: View {
    @ObservedObject var m: DialModel
    let height: CGFloat

    /// Visible icons. Each is keyed by its app (plus which lap round the wheel, when it repeats), so when
    /// the list changes the same app glides to its new spot instead of popping.
    func slots(span: Int, step: Double) -> [DialSlot] {
        guard m.count > 0 else { return [] }
        let base = Int(m.offset.rounded(.down))
        var out: [DialSlot] = []
        for k in -span...span {
            let j = base + k
            guard m.wraps || (j >= 0 && j < m.count) else { continue }
            let a = (Double(j) - m.offset) * step
            guard abs(a) < .pi / 2 + 0.2 else { continue }
            let idx = ((j % m.count) + m.count) % m.count
            let lap = Int((Double(j) / Double(m.count)).rounded(.down))   // stable while the wheel turns
            out.append(DialSlot(key: "\(m.apps[idx].id)#\(lap)", idx: idx, angle: a))
        }
        return out
    }

    var body: some View {
        let r = min(height * 0.36, 300.0)                         // wheel radius
        let step = Double(70) / Double(r)                         // angle between apps (~70 pt apart)
        let cy = height / 2
        let span = Int(Double.pi / step / 2) + 2                  // apps visible on the half-wheel
        ZStack(alignment: .topLeading) {
            // the wheel: dark disc, finger-stop rim, and tick marks that turn with it
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.16), Color(white: 0.05)],
                                     center: .center, startRadius: 20, endRadius: r + 70))
                .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
                .overlay(Circle().inset(by: 70).stroke(Color.white.opacity(0.06), lineWidth: 1))
                .frame(width: (r + 70) * 2, height: (r + 70) * 2)
                .position(x: 0, y: cy)
            ForEach(-span * 2...span * 2, id: \.self) { k in      // ticks between apps, half-slot apart
                let a = (Double(k) / 2 - (m.offset - m.offset.rounded(.down))) * step
                Capsule().fill(Color.white.opacity(k % 2 == 0 ? 0.22 : 0.10))
                    .frame(width: k % 2 == 0 ? 10 : 6, height: 2)
                    .rotationEffect(.radians(a))
                    .position(x: CGFloat(cos(a)) * (r + 58), y: cy + CGFloat(sin(a)) * (r + 58))
                    .opacity(abs(a) < .pi / 2 ? 1 : 0)
            }
            // pointer at 3 o'clock
            Triangle().fill(Color(red: 1, green: 0.82, blue: 0.2))
                .frame(width: 12, height: 14)
                .position(x: r + 78, y: cy)
            // apps on the wheel
            ForEach(slots(span: span, step: step), id: \.key) { s in
                let app = m.apps[s.idx]
                let a = s.angle                                   // 0 = at the pointer
                let near = max(0, 1 - abs(a) / (step * 1.1))      // 1 at the pointer, 0 one slot away
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 52, height: 52)
                    .scaleEffect(1 + near * 0.4)
                    .shadow(color: Color(red: 1, green: 0.82, blue: 0.2).opacity(near * 0.5), radius: 10)
                    .opacity((0.35 + 0.65 * max(0, cos(a))) * (m.isMatch(app) ? 1 : 0))
                    .saturation(m.isMatch(app) ? 1 : 0)
                    .animation(.easeInOut(duration: 0.5), value: m.isMatch(app))   // non-matches fade out/in
                    .position(x: CGFloat(cos(a)) * r, y: cy + CGFloat(sin(a)) * r)
                    .transition(.opacity)
            }
            // hub: name of the app at the pointer, open and exit
            VStack(spacing: 6) {
                if !m.query.isEmpty {
                    Text("🔍 " + m.query)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(Color(red: 1, green: 0.82, blue: 0.2))
                }
                Text(m.opening.map { "Opening \($0)…" } ?? (m.matchIds?.isEmpty == true ? "No match" : (m.selected?.name ?? "No apps")))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.white).lineLimit(1).minimumScaleFactor(0.6)
                Text(m.query.isEmpty ? "\(m.count == 0 ? 0 : m.selectedIndex + 1) of \(m.count)"
                                     : "\(m.matchIds?.count ?? 0) match\((m.matchIds?.count ?? 0) == 1 ? "" : "es")")
                    .font(.system(size: 10, design: .rounded)).foregroundColor(.white.opacity(0.45))
                HStack(spacing: 6) {
                    Button(action: { if m.count > 0 { m.rotateThenOpen(m.selectedIndex) } }) {
                        Text("Open").font(.system(size: 11, weight: .semibold, design: .rounded))
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(Capsule().fill(Color(red: 1, green: 0.82, blue: 0.2).opacity(0.9)))
                            .foregroundColor(.black)
                    }.buttonStyle(.plain)
                    Button(action: { m.onExit?() }) {
                        Text("Exit").font(.system(size: 11, weight: .medium, design: .rounded))
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.12)))
                            .foregroundColor(.white.opacity(0.8))
                    }.buttonStyle(.plain)
                }
            }
            .frame(width: r * 0.75)
            .position(x: r * 0.42, y: cy)
        }
        .frame(width: r + 110, height: height, alignment: .topLeading)
        .offset(x: m.visible ? 0 : -(r + 110))
        .opacity(m.visible ? 1 : 0)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: m.visible)
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// Hosting view for the dial: clicks on first touch, two-finger scroll turns the wheel.
final class DialHost<V: View>: NSHostingView<V> {
    var onScroll: ((Double) -> Void)?
    var iconAt: ((CGPoint) -> Int?)?
    var onIcon: ((Int) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) {
        let local = convert(e.locationInWindow, from: nil)
        let p = CGPoint(x: local.x, y: isFlipped ? local.y : bounds.height - local.y)
        if let i = iconAt?(p) { onIcon?(i); return }                // one click: rotate there, then open
        super.mouseDown(with: e)                                    // Open / Exit buttons
    }
    var onOpenSelected: (() -> Void)?
    override func rightMouseDown(with e: NSEvent) { onOpenSelected?() }   // two-finger tap: open what's at the pointer
    override func scrollWheel(with e: NSEvent) {
        let dy = e.hasPreciseScrollingDeltas ? Double(e.scrollingDeltaY) / 40 : Double(e.scrollingDeltaY) / 3
        onScroll?(-dy)
    }
}

// MARK: - Canvas (black backdrop) with box frames

final class CanvasView: NSView {
    var boxes: [CGRect] = [] { didSet { needsDisplay = true } }      // in this view's coordinates
    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)
        for b in boxes {                                             // soft frame around each app box
            let path = CGPath(roundedRect: b.insetBy(dx: -6, dy: -6), cornerWidth: 14, cornerHeight: 14, transform: nil)
            ctx.addPath(path)
            ctx.setShadow(offset: .zero, blur: 18, color: NSColor(white: 1, alpha: 0.10).cgColor)
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.16).cgColor)
            ctx.setLineWidth(1.2)
            ctx.strokePath()
        }
    }
}

/// Black curtain with see-through holes over the boxes you already have.
final class CurtainView: NSView {
    var holes: [CGRect] = []
    override func draw(_ dirty: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(bounds)
        ctx.setBlendMode(.clear)
        for h in holes { ctx.fill(h.insetBy(dx: -2, dy: -2)) }
    }
}

final class FirstClickPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// The dial's panel takes the keyboard while it's open, so you can type to search.
final class DialPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with e: NSEvent) { if onKey?(e) != true { super.keyDown(with: e) } }
}

final class FirstMouseHosting<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - OS mode controller

final class OSMode {
    private(set) var on = false
    private var canvases: [(NSPanel, CanvasView, NSScreen)] = []
    fileprivate var dialPanel: NSPanel?
    fileprivate let dial = DialModel()
    private var timer: Timer?
    private var hiddenByUs: [NSRunningApplication] = []
    private var observers: [Any] = []
    private var savedDockAutohide: Bool?
    private var savedMenuAutohide: Bool?
    private var escWasDown = false
    var keyDown: ((UInt16) -> Bool)?                  // Esc polling, provided by the app delegate
    var onChange: (() -> Void)?

    init() {
        dial.onPick = { [weak self] app in self?.open(app) }
        dial.onLaunch = { [weak self] app, t in self?.launchBehindCurtain(app, turn: t) }
        dial.onExit = { [weak self] in self?.stop() }
    }

    func toggle() { on ? stop() : start() }

    // MARK: dock (always visible, bottom center)

    static let dockReserve: CGFloat = 70             // space kept free above the bottom edge for the dock
    static var barReserve: CGFloat = 38              // space kept free under our menu bar (set from the notch)

    // MARK: menu bar (top; covers macOS's auto-hiding one so it never shows)

    let bar = MenuBarModel()
    private var barPanel: NSPanel?
    private let axMenus = AXMenuBridge()
    var voiceStatus: (() -> (String, String))?      // provided by the app: (state, current step)
    var modeStates: (() -> (Bool, Bool, Bool))?     // (notes, auto, tunnel)
    var toggleNotes: (() -> Void)?, toggleAuto: (() -> Void)?, toggleTunnel: (() -> Void)?
    private var barTick = 0
    private var barShown = false
    private var barMenuOpen = false
    private var barHeight: CGFloat = 30

    /// Auto-hide: the bar appears only when the mouse touches the absolute top edge, and slides away when
    /// the mouse leaves it (unless one of its menus is open).
    private func autoHideBar() {
        guard let p = barPanel else { return }
        let screen = NSScreen.screens[0].frame
        let m = NSEvent.mouseLocation
        let onScreen = m.x >= screen.minX && m.x <= screen.maxX
        let pinned = bar.appMode                                  // a full-screen box: its bar stays
        if !barShown, pinned || (onScreen && m.y >= screen.maxY - 0.5) { setBar(shown: true, p, screen) }
        else if barShown, !pinned, !barMenuOpen, !(onScreen && m.y >= screen.maxY - barHeight - 6) { setBar(shown: false, p, screen) }
    }

    private func setBar(shown: Bool, _ p: NSPanel, _ screen: CGRect) {
        barShown = shown
        p.ignoresMouseEvents = !shown                             // hidden: clicks reach the boxes underneath
        bar.shown = shown                                         // SwiftUI plays the spring + stagger
    }

    private func showMenuBar() {
        let screen = NSScreen.screens[0]
        // cover macOS's own menu bar completely: as tall as the notch or the real menu bar, whichever is taller
        let realBar = max(NSStatusBar.system.thickness, NSApp.mainMenu?.menuBarHeight ?? 0, 24)
        let h = max(screen.safeAreaInsets.top, realBar, 30) + 8                    // generous: no silver edge
        barHeight = h
        Self.barReserve = 10                                    // auto-hides, so boxes may use the top too
        bar.leftWidth = screen.auxiliaryTopLeftArea?.width ?? screen.frame.width / 2 - 110
        bar.rightWidth = screen.auxiliaryTopRightArea?.width ?? screen.frame.width / 2 - 110
        let p = FirstClickPanel(contentRect: NSRect(x: screen.frame.minX, y: screen.frame.maxY - h,
                                                    width: screen.frame.width, height: h),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)   // above the real menu bar
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = MenuBarHost(rootView: MenuBarView(m: bar, height: h))
        barPanel = p
        p.ignoresMouseEvents = true                              // starts hidden; reveal at the top edge
        p.orderFrontRegardless()
        barShown = false; bar.shown = false
        bar.onAppMenu = { [weak self] v, pt in
            guard let self, let app = self.frontApp() else { return }
            self.barMenuOpen = true
            self.axMenus.menu(for: app.processIdentifier).popUp(positioning: nil, at: pt, in: v)   // returns when closed
            self.barMenuOpen = false
        }
        bar.onPower = { [weak self] v, pt in
            guard let self else { return }
            self.barMenuOpen = true
            self.powerMenu().popUp(positioning: nil, at: pt, in: v)
            self.barMenuOpen = false
        }
        bar.onWifi = { [weak self] v, pt in
            guard let self else { return }
            self.barMenuOpen = true
            WiFi.shared.menu().popUp(positioning: nil, at: pt, in: v)
            self.barMenuOpen = false
        }
        bar.onBluetooth = { [weak self] v, pt in
            guard let self else { return }
            self.barMenuOpen = true
            Bluetooth.shared.menu().popUp(positioning: nil, at: pt, in: v)
            self.barMenuOpen = false
        }
        WiFi.shared.onChange = { [weak self] in self?.readRadios() }
        Bluetooth.shared.onChange = { [weak self] in self?.readRadios() }
        WiFi.shared.refresh()
        bar.onNotes = { [weak self] in self?.toggleNotes?() }
        bar.onAuto = { [weak self] in self?.toggleAuto?() }
        bar.onTunnel = { [weak self] in self?.toggleTunnel?() }
        bar.onTopMenu = { [weak self] title, v, pt in
            guard let self, let app = self.frontApp() else { return }
            self.barMenuOpen = true
            self.axMenus.menu(for: app.processIdentifier, title: title).popUp(positioning: nil, at: pt, in: v)
            self.barMenuOpen = false
        }
        bar.onBackToBox = { [weak self] in
            guard let self, let app = self.frontApp(),
                  let b = self.boxes.last(where: { $0.pid == app.processIdentifier && $0.restoreFrame != nil }) else { return }
            self.toggleFill(b)
        }
        refreshMenuBar()
    }

    private func hideMenuBar() {
        barPanel?.orderOut(nil); barPanel = nil; barShown = false; barMenuOpen = false
        pillPanel?.orderOut(nil); pillPanel = nil; pillShown = false
    }

    // status pill beside the notch: only while Claude/voice is doing something and the bar is hidden
    private var pillPanel: NSPanel?
    private var pillShown = false

    private func updatePill() {
        let screen = NSScreen.screens[0].frame
        let want = false                       // status shows only inside the menu bar (you asked to hide the pill)
        if pillPanel == nil {
            let p = FirstClickPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: StatusPill(m: bar, height: barHeight))
            p.alphaValue = 0
            pillPanel = p
        }
        guard let p = pillPanel, let host = p.contentView else { return }
        if want {
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            let x = screen.maxX - bar.rightWidth + 4                  // just right of the notch
            let r = NSRect(x: x, y: screen.maxY - size.height, width: size.width, height: size.height)
            if p.frame != r { p.setFrame(r, display: true) }
            if !pillShown {
                pillShown = true
                p.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { $0.duration = 0.25; p.animator().alphaValue = 1 }
            }
        } else if pillShown {
            pillShown = false
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 }) {
                if !self.pillShown { p.orderOut(nil) }
            }
        }
    }

    private func frontApp() -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != me, f.bundleIdentifier != "com.apple.finder" { return f }
        return dockOrder.last.flatMap { NSRunningApplication(processIdentifier: $0) }
    }

    private func refreshMenuBar() {
        bar.now = Date()
        let app = frontApp()
        let name = app?.localizedName ?? ""
        if bar.appName != name { bar.appName = name; bar.appIcon = app?.icon }
        if let (state, step) = voiceStatus?() { if bar.status != state { bar.status = state }; if bar.step != step { bar.step = step } }
        if let (n, a, t) = modeStates?() { bar.notes = n; bar.auto = a; bar.tunnel = t }
        let filled = app.flatMap { a in boxes.last { $0.pid == a.processIdentifier && $0.restoreFrame != nil } }
        if (filled != nil) != bar.appMode { bar.appMode = filled != nil }
        if let f = filled, let a = app {
            if barTick % 10 == 0 || bar.appMenus.isEmpty {         // menus/title change rarely: ~2×/s
                let titles = axMenus.topTitles(for: a.processIdentifier)
                if titles != bar.appMenus { bar.appMenus = titles }
                let t = (attr(f.win, kAXTitleAttribute) as? String) ?? ""
                if t != bar.windowTitle { bar.windowTitle = t }
            }
        }
        updatePill()
        barTick += 1
        if barTick % 25 == 1 {                                  // every ~5 s: battery and Wi-Fi
            if let (b, c) = SystemInfo.battery() { bar.battery = b; bar.charging = c }
            readRadios()
        }
    }

    @objc private func powerExit() { stop() }
    @objc private func powerLock() { _ = shell("/usr/bin/pmset", "displaysleepnow") }
    @objc private func powerSleep() { _ = shell("/usr/bin/pmset", "sleepnow") }

    private func readRadios() {
        let w = WiFi.shared, b = Bluetooth.shared
        bar.wifiOn = w.on; bar.wifiConnected = w.connected; bar.wifiStrength = w.strength
        let btOn = b.on
        bar.btOn = btOn; bar.btConnected = btOn && b.anyConnected
        w.refresh()
    }

    private func powerMenu() -> NSMenu {
        let m = NSMenu()
        for (t, s) in [("Exit OS mode", #selector(powerExit)), ("Lock screen", #selector(powerLock)), ("Sleep", #selector(powerSleep))] {
            let i = NSMenuItem(title: t, action: s, keyEquivalent: ""); i.target = self; m.addItem(i)
        }
        return m
    }
    let dock = DockModel()
    private var dockPanel: NSPanel?
    private var focusCycle: [pid_t: Int] = [:]
    private var dockOrder: [pid_t] = []             // apps on the dock, in opening order, until they quit

    private func showDock() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let p = FirstClickPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .floating                                   // above the boxes, below the dial and curtain
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = DockHost(rootView: DockView(m: dock))
        dockPanel = p
        layoutDock(on: NSScreen.screens[0])
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.3; p.animator().alphaValue = 1 }
        dock.onFocus = { [weak self] pid in self?.focus(pid) }
        dock.onClose = { [weak self] pid in self?.closeFront(pid) }
        dock.onQuit = { pid in NSRunningApplication(processIdentifier: pid)?.terminate() }
        dock.onFill = { [weak self] pid in self?.toggleFill(pid) }
        dock.onReset = { [weak self] pid in self?.resetBox(pid) }
        dock.onExit = { [weak self] in self?.stop() }
        dock.isFilled = { [weak self] pid in self?.boxes.contains { $0.pid == pid && $0.restoreFrame != nil } ?? false }
    }

    private func layoutDock(on screen: NSScreen) {
        guard let p = dockPanel, let host = p.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let r = NSRect(x: (screen.frame.midX - size.width / 2).rounded(), y: screen.frame.minY,
                       width: size.width, height: size.height)
        if p.frame != r { p.setFrame(r, display: true) }
    }

    private func hideDock() {
        dockPanel?.orderOut(nil); dockPanel = nil
        dock.items = []
        dockOrder = []
    }

    /// Rebuild the dock's icons from the boxes on the canvas (one per app, in opening order).
    private func refreshDock() {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for b in boxes where !dockOrder.contains(b.pid) { dockOrder.append(b.pid) }
        let me = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications                         // already-open apps too
        where app.activationPolicy == .regular && app.processIdentifier != me && !dockOrder.contains(app.processIdentifier) {
            dockOrder.append(app.processIdentifier)
        }
        dockOrder.removeAll { NSRunningApplication(processIdentifier: $0)?.isTerminated != false }   // gone when quit
        let seen = dockOrder
        let items: [DockItem] = seen.compactMap { pid in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
            let icon = app.icon ?? NSWorkspace.shared.icon(forFile: app.bundleURL?.path ?? "")
            return DockItem(id: pid, name: app.localizedName ?? "App", icon: icon,
                            windows: boxes.filter { $0.pid == pid }.count, active: pid == front)
        }
        dock.now = Date()
        if items != dock.items { dock.items = items }
        DispatchQueue.main.async { [weak self] in self?.layoutDock(on: NSScreen.screens[0]) }  // always centred
    }

    /// Bring an app's box forward; clicking again cycles through its windows. Its outline pulses gold.
    private func focus(_ pid: pid_t) {
        let mine = boxes.filter { $0.pid == pid }
        guard !mine.isEmpty else {
            if !watching.contains(pid), !windows(pid).isEmpty {      // open but hidden: its windows become boxes
                addBox(pid)
                NSRunningApplication(processIdentifier: pid)?.activate()
                return
            }
            // no window open: ask the app for a new one
            if let app = NSRunningApplication(processIdentifier: pid), let url = app.bundleURL {
                let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
                watching.insert(pid)
            }
            return
        }
        let i = (focusCycle[pid] ?? -1) + 1
        focusCycle[pid] = i
        let box = mine[i % mine.count]
        AXUIElementSetAttributeValue(box.win, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(box.win, kAXRaiseAction as CFString)
        NSRunningApplication(processIdentifier: pid)?.activate()
        if let f = box.frame { pulse(f) }
    }

    private func closeFront(_ pid: pid_t) {
        guard let box = boxes.first(where: { $0.pid == pid }), let close = attr(box.win, kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString)
    }

    private func resetBox(_ pid: pid_t) {
        if let k = boxKey(pid) { UserDefaults.standard.removeObject(forKey: k) }
        guard let box = boxes.first(where: { $0.pid == pid }) else { return }
        let f = (NSScreen.main ?? NSScreen.screens[0]).frame
        setFrame(box.win, CGRect(x: f.midX, y: f.midY, width: 60, height: 40))   // as small as the app allows
        if let r = frameOf(box.win) {
            let t = CGRect(x: f.midX - r.width / 2, y: f.midY - r.height / 2, width: r.width, height: r.height)
            setFrame(box.win, t); box.target = t; box.restoreFrame = nil
        }
    }

    /// A gold outline that flashes around a box, so you see which one came forward.
    private func pulse(_ f: CGRect) {
        let p = FirstClickPanel(contentRect: f.insetBy(dx: -8, dy: -8), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .floating; p.ignoresMouseEvents = true
        p.contentView = NSHostingView(rootView:
            RoundedRectangle(cornerRadius: 14).stroke(Color(red: 1, green: 0.82, blue: 0.2), lineWidth: 2.5)
                .shadow(color: Color(red: 1, green: 0.82, blue: 0.2).opacity(0.7), radius: 8))
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 1 }) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.55; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
        }
    }

    func start() {
        guard !on else { return }
        on = true
        dial.loadDockApps()
        // remember your real Dock/menu bar settings once (persisted, so a restart or a double start can't
        // overwrite them with the already-hidden state)
        let ud = UserDefaults.standard
        if ud.object(forKey: "osSavedDock") == nil {
            ud.set(systemEvents("get autohide of dock preferences")?.booleanValue ?? false, forKey: "osSavedDock")
            ud.set(systemEvents("get autohide menu bar of dock preferences")?.booleanValue ?? false, forKey: "osSavedMenu")
        }
        savedDockAutohide = ud.bool(forKey: "osSavedDock")
        savedMenuAutohide = ud.bool(forKey: "osSavedMenu")
        _ = systemEvents("set autohide of dock preferences to true")
        _ = systemEvents("set autohide menu bar of dock preferences to true")
        if ud.object(forKey: "osSavedDockDelay") == nil {
            ud.set(shell("/usr/bin/defaults", "read", "com.apple.dock", "autohide-delay") ?? "none", forKey: "osSavedDockDelay")
        }
        _ = shell("/usr/bin/defaults", "write", "com.apple.dock", "autohide-delay", "-float", "1000")   // never reveals
        _ = shell("/usr/bin/killall", "Dock")
        pauseOtherPet()

        // black canvas on every screen: above the desktop, below all app windows
        let level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)   // above desktop + widgets, below apps
        for screen in NSScreen.screens {
            let p = FirstClickPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
            p.isOpaque = true; p.backgroundColor = .black; p.hasShadow = false
            p.level = level
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            let v = CanvasView(frame: NSRect(origin: .zero, size: screen.frame.size))
            p.contentView = v
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.35; p.animator().alphaValue = 1 }
            canvases.append((p, v, screen))
        }

        // hide everything else: OS mode starts empty
        let me = ProcessInfo.processInfo.processIdentifier
        hiddenByUs = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isHidden
        }
        NSApp.activate(ignoringOtherApps: true)           // hide() can't hide the frontmost app from outside;
        NSApp.hideOtherApplications(nil)                  // "hide others" from the active app always works
        hiddenByUs.forEach { $0.hide() }
        boxes = []; watching = []
        log("on; hid \(hiddenByUs.count) apps")

        // dial panel (left edge of the main screen; moved to the screen the mouse is on)
        let dp = DialPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        dp.isOpaque = false; dp.backgroundColor = .clear; dp.hasShadow = false
        dp.level = .popUpMenu
        dp.acceptsMouseMovedEvents = true
        dp.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        dp.onKey = { [weak self] e in
            guard let self else { return false }
            if e.keyCode == 53 && self.dial.query.isEmpty { self.hideDial(); return true }   // esc with no search: close dial
            return self.dial.type(e)
        }
        dialPanel = dp
        showDock()
        showMenuBar()
        placeDial(on: NSScreen.main ?? NSScreen.screens[0])
        dp.orderFrontRegardless()

        // any app you switch to (Cmd-Tab, Spotlight, links) also becomes a box; quitting removes it
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular, app.processIdentifier != me,
                  app.bundleIdentifier != "com.apple.finder" else { return }
            if !self.watching.contains(app.processIdentifier) { self.addBox(app.processIdentifier) }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.boxes.removeAll { $0.pid == app.processIdentifier }
            self.watching.remove(app.processIdentifier)
            self.refreshCanvas()
        })

        escWasDown = false
        installClickTap()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        onChange?()
    }

    func stop() {
        guard on else { return }
        on = false
        timer?.invalidate(); timer = nil
        removeClickTap()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers = []
        dial.visible = false
        dialPanel?.orderOut(nil); dialPanel = nil
        hideDock()
        hideMenuBar()
        for (p, _, _) in canvases {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 },
                                                 completionHandler: { p.orderOut(nil) })
        }
        canvases = []
        hideCurtain(); pending = nil; dial.opening = nil
        hiddenByUs.forEach { $0.unhide() }; hiddenByUs = []
        boxes = []; watching = []
        log("off")
        restoreBars()
        undoDeclutter()
        onChange?()
    }

    // MARK: dial

    private func placeDial(on screen: NSScreen) {
        guard let dp = dialPanel else { return }
        let h = screen.frame.height
        let r = min(h * 0.36, 300.0)
        dial.slots = Int(Double.pi / (70.0 / r)) + 1                 // apps that fit on the half-wheel
        let host = DialHost(rootView: DialView(m: dial, height: h))
        host.onScroll = { [weak self] d in self?.dial.turn(by: d) }
        host.iconAt = { [weak self] p in self?.dial.index(at: p, height: h) }
        host.onIcon = { [weak self] i in self?.dial.rotateThenOpen(i) }
        host.onOpenSelected = { [weak self] in
            guard let self, self.dial.count > 0 else { return }
            self.dial.rotateThenOpen(self.dial.selectedIndex)
        }
        let w = min(h * 0.36, 300) + 110
        dp.setFrame(NSRect(x: screen.frame.minX, y: screen.frame.minY, width: w, height: h), display: true)
        dp.contentView = host
    }

    private func tick() {
        trackTick += 1
        autoHideBar()
        if trackTick % 6 != 0 { updatePill() }                   // refreshMenuBar covers the other ticks
        checkReveal()
        if trackTick % 6 == 0 { trackBoxes() }                       // ~5×/s: frames follow your drags
        // (Esc no longer exits OS mode: use double-tap left Option, the power menu or the dock's power button)
        let p = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) else { return }
        if !dial.visible, p.x <= screen.frame.minX + 0.5 {           // only at the absolute left edge (x = 0)
            if dialPanel?.frame.minX != screen.frame.minX { placeDial(on: screen) }
            dial.clearQuery()
            dial.visible = true
            dialPanel?.ignoresMouseEvents = false
            dialPanel?.makeKey()                                     // typing now searches the dial
        } else if dial.visible, pending == nil, p.x > screen.frame.minX + screen.frame.width * 0.5 {
            hideDial()                                               // moved past half the screen: slide it back in
        }
    }

    // MARK: apps as boxes

    // MARK: open behind a curtain: the app launches and gets its size/bars/zoom while hidden

    private var curtains: [(NSPanel, CurtainView, NSScreen)] = []
    fileprivate var pending: (bundle: String?, start: Date, revealAfter: Date, boxesBefore: Int)?

    private func launchBehindCurtain(_ app: DialApp, turn: Double) {
        showCurtain()
        CATransaction.flush()                                        // curtain is on screen before the app launches
        pending = (Bundle(url: app.url)?.bundleIdentifier, Date(), Date().addingTimeInterval(turn), boxes.count)
        DispatchQueue.main.async { [weak self] in self?.open(app, keepDial: true) }
    }

    /// Reveal when the dial has finished turning and the new box has settled (or after 4 s at most).
    private func checkReveal() {
        guard let p = pending, Date() >= p.revealAfter else { return }
        let box = boxes.last { NSRunningApplication(processIdentifier: $0.pid)?.bundleIdentifier == p.bundle }
        let ready = boxes.count > p.boxesBefore && box.map { Date() >= $0.settleUntil.addingTimeInterval(0.25) } == true
        if ready || Date().timeIntervalSince(p.start) > 4 {
            pending = nil
            dial.opening = nil
            hideDial()
            if let box { NSRunningApplication(processIdentifier: box.pid)?.activate() }
            hideCurtain()
        }
    }

    private func showCurtain() {
        guard curtains.isEmpty else { return }
        let level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)   // above apps, below the dial
        for screen in NSScreen.screens {
            let c = FirstClickPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
            c.isOpaque = false; c.backgroundColor = .clear; c.hasShadow = false
            c.level = level
            c.ignoresMouseEvents = true
            c.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            let v = CurtainView(frame: NSRect(origin: .zero, size: screen.frame.size))
            c.contentView = v                                        // solid black: nothing of the launch shows through
            c.alphaValue = 1                                         // instantly, before the app starts launching
            c.orderFrontRegardless()
            c.display()
            curtains.append((c, v, screen))
        }
        dialPanel?.orderFrontRegardless()
    }

    private func hideCurtain() {
        let cs = curtains; curtains = []
        for (c, _, _) in cs {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.45; c.animator().alphaValue = 0 },
                                                 completionHandler: { c.orderOut(nil) })
        }
    }

    /// Is a screen point on the dial's wheel (not just inside its rectangular panel)?
    fileprivate func dialHit(_ p: CGPoint, in f: CGRect) -> Bool {
        guard f.contains(p) else { return false }
        let r = min(f.height * 0.36, 300) + 70                       // the wheel's outer radius
        return hypot(p.x - f.minX, p.y - f.midY) <= r + 10
    }

    fileprivate func hideDial() {
        dial.visible = false
        dial.hovered = nil
        dialPanel?.ignoresMouseEvents = true
        if dialPanel?.isKeyWindow == true { dialPanel?.orderOut(nil); dialPanel?.orderFrontRegardless() }  // give the keyboard back
    }

    private func open(_ app: DialApp, keepDial: Bool = false) {
        if !keepDial { hideDial() }
        if Bundle(url: app.url)?.bundleIdentifier == "com.google.Chrome" {
            // Chrome opens as a normal tabbed window; double-click its top bar to switch to tablet mode
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-na", app.url.path, "--args", "--new-window"]   // normal tabbed window by default
            if let c = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first {
                pendingTablet[c.processIdentifier] = false
            }
            try? p.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first else { return }
                chrome.unhide()
                let pid = chrome.processIdentifier
                if self.pendingTablet[pid] == nil { self.pendingTablet[pid] = false }  // Chrome wasn't running before
                if self.watching.contains(pid) { self.adoptNewWindows(pid, attempt: 0) } else { self.addBox(pid) }
            }
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = !keepDial                     // behind the curtain: don't bring it forward yet
        NSWorkspace.shared.openApplication(at: app.url, configuration: cfg) { [weak self] running, _ in
            guard let pid = running?.processIdentifier else { return }
            DispatchQueue.main.async {
                running?.unhide()
                self?.addBox(pid)
            }
        }
    }

    /// One box = one window. An app can have several boxes (e.g. two Chrome windows).
    final class Box {
        let pid: pid_t
        let win: AXUIElement
        var frame: CGRect?
        var settleUntil: Date          // while the app is still opening, keep forcing our frame and don't save
        var lastTitle = ""             // browsers: page we last reset to 100% zoom
        var tablet: Bool? = nil        // Chrome: true = app window (no tabs), false = tabbed, nil = unknown
        var chromeProfile: String? = nil // Chrome profile directory ("Default", "Profile 2"…) this window belongs to
        var restoreFrame: CGRect? = nil // set while the box fills the screen (green button); toggles back
        var busyUntil = Date.distantPast // ignore fullscreen state while we're switching it
        var armed = true                  // react to the green button only after seeing it out of fullscreen
        var lastToggle = Date.distantPast
        var target: CGRect
        init(pid: pid_t, win: AXUIElement, target: CGRect) {
            self.pid = pid; self.win = win; self.target = target
            self.settleUntil = Date().addingTimeInterval(1.8)
        }
    }
    private var boxes: [Box] = []
    private var pendingFrame: [pid_t: CGRect] = [:]
    private var pendingTablet: [pid_t: Bool] = [:]       // mode of the next Chrome window we open
    private var pendingProfile: [pid_t: String?] = [:]   // and its Chrome profile
    private var trackTick = 0
    private var watching = Set<pid_t>()                 // apps whose new windows become boxes

    /// Start boxing an app: its current window(s) now, and any window it opens later.
    private func addBox(_ pid: pid_t) {
        guard on else { return }
        watching.insert(pid)
        NSRunningApplication(processIdentifier: pid)?.unhide()
        hiddenByUs.removeAll { $0.processIdentifier == pid }
        adoptNewWindows(pid, attempt: 0)
    }

    /// Box every window of `pid` that isn't boxed yet (retries while a just-launched app has no window).
    private func adoptNewWindows(_ pid: pid_t, attempt: Int) {
        guard on else { return }
        let fresh = windows(pid).filter { w in !boxes.contains { CFEqual($0.win, w) } }
        if fresh.isEmpty {
            if attempt < 15, !boxes.contains(where: { $0.pid == pid }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.adoptNewWindows(pid, attempt: attempt + 1) }
            }
            return
        }
        for w in fresh { place(pid, w) }
    }

    /// Size: the app's last box size (or as small as the app allows the first time).
    /// Position: its last spot; extra windows of the same app are offset so none hides another.
    private func place(_ pid: pid_t, _ win: AXUIElement) {
        let f = (NSScreen.main ?? NSScreen.screens[0]).frame
        var siblings = boxes.filter { $0.pid == pid }.count
        var target: CGRect
        if let pf = pendingFrame.removeValue(forKey: pid) {          // replacing a window: same spot, same size
            target = pf; siblings = 0
        } else if let saved = savedBox(pid), saved.intersects(f) {
            target = saved
        } else {
            setFrame(win, CGRect(x: f.midX, y: f.midY, width: 60, height: 40))   // the app clamps to its minimum
            let size = frameOf(win)?.size ?? CGSize(width: 340, height: 240)
            target = freeSpot(size, in: f)
        }
        if siblings > 0 {                                            // cascade: 36 pt right and down per window
            let step = CGFloat(36 * siblings)
            target = target.offsetBy(dx: step, dy: -step)
            if target.maxX > f.maxX || target.minY < f.minY { target = target.offsetBy(dx: -step * 2, dy: step * 2) }
        }
        let box = Box(pid: pid, win: win, target: target)
        box.tablet = pendingTablet.removeValue(forKey: pid)
        if let p = pendingProfile.removeValue(forKey: pid) { box.chromeProfile = p }
        if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.google.Chrome" {
            // build Chrome's accessibility tree now, so the page address is readable when you switch modes
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        boxes.append(box)
        setFrame(win, target)
        for d in [0.3, 0.7, 1.2, 1.7] {                              // apps restore their own size while launching
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self, weak box] in
                guard let self, let box, Date() < box.settleUntil.addingTimeInterval(0.2) else { return }
                self.setFrame(win, box.target)
            }
        }
        box.frame = target
        log("box for pid \(pid): \(Int(target.width))x\(Int(target.height)) (window \(siblings + 1) of this app)")
        if siblings == 0 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.declutter(pid) } }
        refreshCanvas()
    }

    private func freeSpot(_ size: CGSize, in full: CGRect) -> CGRect {
        var f = full; f.origin.y += Self.dockReserve; f.size.height -= Self.dockReserve + Self.barReserve   // dock & bar clear
        let others = boxes.compactMap(\.frame)
        let pad: CGFloat = 40
        let xs = [f.midX - size.width / 2, f.minX + pad, f.maxX - pad - size.width]
        let ys = [f.midY - size.height / 2, f.maxY - pad - size.height, f.minY + pad]
        var best = CGRect(origin: CGPoint(x: xs[0], y: ys[0]), size: size), bestOverlap = CGFloat.infinity
        for y in ys { for x in xs {
            let r = CGRect(origin: CGPoint(x: x, y: y), size: size)
            let overlap = others.reduce(CGFloat(0)) { acc, o in
                let i = r.intersection(o); return acc + (i.isNull ? 0 : i.width * i.height)
            }
            if overlap < bestOverlap - 1 { best = r; bestOverlap = overlap }
        } }
        return best
    }

    /// Follow the real windows (you may have dragged or resized them), pick up new windows, drop closed ones.
    private func trackBoxes() {
        for pid in watching { adoptNewWindows(pid, attempt: 99) }    // e.g. Cmd-N or Chrome opened again
        boxes.removeAll { box in                                     // window closed or app quit: no box, no trail
            NSRunningApplication(processIdentifier: box.pid)?.isTerminated != false || frameOf(box.win) == nil
        }
        for box in boxes {
            let app = NSRunningApplication(processIdentifier: box.pid)
            guard app?.isHidden == false, !isMinimized(box.win) else { box.frame = nil; continue }
            let fs = isFullScreen(box.win)
            if !fs, Date() > box.busyUntil { box.armed = true }            // seen out of fullscreen: next press counts
            if fs, Date() > box.busyUntil, box.armed, Date().timeIntervalSince(box.lastToggle) > 2 {
                box.armed = false; box.lastToggle = Date()
                // green button: don't leave the canvas for a fullscreen Space; make the box fill the screen
                // instead (still a window). Pressing it again puts the box back to its size.
                AXUIElementSetAttributeValue(box.win, "AXFullScreen" as CFString, kCFBooleanFalse)
                toggleFill(box)
                continue
            }
            if Date() < box.busyUntil { continue }
            guard let r = frameOf(box.win) else { continue }
            box.frame = r
            resetPageZoom(box)
            if Date() > box.settleUntil, box.restoreFrame == nil, boxes.first(where: { $0.pid == box.pid }) === box {
                saveBox(box.pid, r)                                  // the app's first window sets its size
            }
        }
        refreshCanvas()
    }

    // MARK: Chrome: double-click the top bar to switch tablet (app window) <-> tabs (normal window)

    private var clickTap: CFMachPort?
    private var clickSource: CFRunLoopSource?
    private var swallowNextUp = false

    private func installClickTap() {
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
                              | (1 << CGEventType.scrollWheel.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let os = Unmanaged<OSMode>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = os.clickTap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if type == .scrollWheel { os.swipe(event); return Unmanaged.passUnretained(event) }   // never blocks scrolling
            if type == .leftMouseDown, os.dial.visible, os.pending == nil {          // click outside the dial closes it
                let loc = event.location
                let p = CGPoint(x: loc.x, y: (NSScreen.screens.first?.frame.height ?? 0) - loc.y)
                if let f = os.dialPanel?.frame, !os.dialHit(p, in: f) { DispatchQueue.main.async { os.hideDial() } }
            }
            if type == .leftMouseUp, os.swallowNextUp { os.swallowNextUp = false; return nil }
            if type == .leftMouseDown, let box = os.boxGreenButton(at: event.location) {
                // green button: fill the screen ourselves (no native fullscreen, so nothing to fight)
                os.swallowNextUp = true
                DispatchQueue.main.async { box.lastToggle = Date(); os.toggleFill(box) }
                return nil
            }
            guard type == .leftMouseDown, event.getIntegerValueField(.mouseEventClickState) == 2 else {
                return Unmanaged.passUnretained(event)
            }
            let loc = event.location                                 // top-left origin
            let p = CGPoint(x: loc.x, y: (NSScreen.screens.first?.frame.height ?? 0) - loc.y)
            guard let box = os.chromeBoxTitleBar(at: p) else { return Unmanaged.passUnretained(event) }
            os.swallowNextUp = true
            DispatchQueue.main.async { box.lastToggle = Date(); os.toggleFill(box) }   // fill the screen (boxed, bars showing) / back
            return nil                                               // don't let macOS zoom/minimize it
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: cb, userInfo: me) else {
            log("double-click tap unavailable (Accessibility not granted?)"); return
        }
        clickTap = tap
        clickSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), clickSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// The box whose green (fullscreen) title-bar button is under this point (top-left coords), if any.
    func boxGreenButton(at loc: CGPoint) -> Box? {
        let h = NSScreen.screens.first?.frame.height ?? 0
        let p = CGPoint(x: loc.x, y: h - loc.y)
        for box in boxes.reversed() {
            guard let f = box.frame, f.contains(p), p.y > f.maxY - 44 else { continue }   // only near the top edge
            for attr in [kAXFullScreenButtonAttribute, kAXZoomButtonAttribute] {
                var ref: CFTypeRef?
                guard AXUIElementCopyAttributeValue(box.win, attr as CFString, &ref) == .success, let ref else { continue }
                let btn = ref as! AXUIElement
                var pv: CFTypeRef?, sv: CFTypeRef?
                guard AXUIElementCopyAttributeValue(btn, kAXPositionAttribute as CFString, &pv) == .success,
                      AXUIElementCopyAttributeValue(btn, kAXSizeAttribute as CFString, &sv) == .success else { continue }
                var pos = CGPoint.zero, size = CGSize.zero
                AXValueGetValue(pv as! AXValue, .cgPoint, &pos); AXValueGetValue(sv as! AXValue, .cgSize, &size)
                if CGRect(origin: pos, size: size).insetBy(dx: -2, dy: -2).contains(loc) { return box }
            }
        }
        return nil
    }

    private func removeClickTap() {
        if let t = clickTap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = clickSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        clickTap = nil; clickSource = nil; swallowNextUp = false
    }

    // two-finger horizontal swipe over a tablet-mode Chrome box: back / forward
    private var swipeDX = 0.0, swipeDY = 0.0
    private var swipeBox: Box?

    private func swipe(_ e: CGEvent) {
        let phase = e.getIntegerValueField(.scrollWheelEventScrollPhase)        // 1 began, 2 changed, 4 ended, 8 cancelled
        let momentum = e.getIntegerValueField(.scrollWheelEventMomentumPhase)
        guard momentum == 0 else { return }                                    // ignore the coasting after the fingers lift
        if phase == 1 {
            let loc = e.location
            let p = CGPoint(x: loc.x, y: (NSScreen.screens.first?.frame.height ?? 0) - loc.y)
            swipeBox = boxes.last { b in
                guard b.tablet == true, let f = b.frame, f.contains(p) else { return false }
                return NSRunningApplication(processIdentifier: b.pid)?.bundleIdentifier == "com.google.Chrome"
            }
            swipeDX = 0; swipeDY = 0
        }
        guard swipeBox != nil else { return }
        swipeDX += Double(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        swipeDY += Double(e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        if phase == 4 || phase == 8 {
            if phase == 4, let box = swipeBox, abs(swipeDX) > 140, abs(swipeDX) > 2.5 * abs(swipeDY) {
                let back = swipeDX > 0                                         // fingers moved right = back
                DispatchQueue.main.async { [weak self] in self?.navigate(box, back: back) }
            }
            swipeBox = nil
        }
    }

    private func navigate(_ box: Box, back: Bool) {
        AXUIElementSetAttributeValue(box.win, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(box.win, kAXRaiseAction as CFString)
        let key: CGKeyCode = back ? 33 : 30                                     // ⌘[  /  ⌘]
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            if let ev = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) {
                ev.flags = .maskCommand
                ev.postToPid(box.pid)
            }
        }
        if let f = box.frame { flashArrow(back ? "chevron.left" : "chevron.right", in: f, left: back) }
        log("swipe: \(back ? "back" : "forward")")
    }

    /// A small arrow that pops at the box's edge and fades, so you see the swipe registered.
    private func flashArrow(_ symbol: String, in f: CGRect, left: Bool) {
        let size: CGFloat = 54
        let x = left ? f.minX + 16 : f.maxX - 16 - size
        let panel = FirstClickPanel(contentRect: NSRect(x: x, y: f.midY - size / 2, width: size, height: size),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .popUpMenu; panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView:
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.black.opacity(0.55)))
        )
        panel.contentView = host
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 1 }) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.45; panel.animator().alphaValue = 0 }) {
                panel.orderOut(nil)
            }
        }
    }

    /// A Chrome box whose top bar (title bar / tab strip, top 38 pt) is under `p` (Cocoa coords).
    private func chromeBoxTitleBar(at p: CGPoint) -> Box? {
        boxes.last { box in
            guard let f = box.frame, f.contains(p), p.y >= f.maxY - 38 else { return false }
            return NSRunningApplication(processIdentifier: box.pid)?.bundleIdentifier == "com.google.Chrome"
        }
    }

    private func toggleChromeMode(_ box: Box) {
        guard on, let frame = box.frame ?? frameOf(box.win) else { return }
        let app = AXUIElementCreateApplication(box.pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)  // expose page info
        let tabbed: Bool
        if let t = box.tablet { tabbed = !t }
        else { tabbed = find(box.win, role: "AXTabGroup", depth: 18) != nil || hasAddressBar(box.win) }
        let url = pageURL(box.win) ?? (tabbed ? activeTabURL() : nil) ?? "https://www.google.com"
        pendingTablet[box.pid] = tabbed                              // the new window is the other mode
        log("switching Chrome window to \(tabbed ? "tablet" : "tabs") mode: \(url.prefix(60))")
        pendingFrame[box.pid] = frame
        if let close = attr(box.win, kAXCloseButtonAttribute) {
            AXUIElementPerformAction(close as! AXUIElement, kAXPressAction as CFString)
        }
        boxes.removeAll { $0 === box }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        let profile = box.chromeProfile ?? chromeProfile(of: box.win)
        pendingProfile[box.pid] = profile
        p.arguments = ["-na", "Google Chrome", "--args"] + (profile.map { ["--profile-directory=\($0)"] } ?? [])
            + (tabbed ? ["--app=\(url)"] : ["--new-window", url])
        try? p.run()
        // the new window is picked up by trackBoxes (watching Chrome) and takes `pendingFrame`
    }

    private func hasAddressBar(_ win: AXUIElement) -> Bool {
        find(win, role: "AXToolbar", depth: 10) != nil
    }

    /// Chrome's active tab URL via AppleScript (works for tabbed windows; asks for permission once).
    private func activeTabURL() -> String? {
        var err: NSDictionary?
        let r = NSAppleScript(source: "tell application \"Google Chrome\" to get URL of active tab of front window")?
            .executeAndReturnError(&err)
        return r?.stringValue
    }

    /// Which Chrome profile a window belongs to. With several profiles, Chrome ends normal window titles with
    /// " - <profile name>"; map that name to its directory through Chrome's Local State file.
    func chromeProfile(of win: AXUIElement) -> String? {
        let title = (attr(win, kAXTitleAttribute) as? String) ?? ""
        let path = NSHomeDirectory() + "/Library/Application Support/Google/Chrome/Local State"
        guard let d = FileManager.default.contents(atPath: path),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let cache = (j["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]] else { return nil }
        if cache.count == 1 { return cache.keys.first }
        for (dir, info) in cache {
            if let name = info["name"] as? String, !name.isEmpty, title.hasSuffix(" - " + name) { return dir }
        }
        return nil
    }

    private func pageURL(_ win: AXUIElement) -> String? {
        for _ in 0..<3 {                                             // Chrome builds its tree on first ask
            if let web = find(win, role: "AXWebArea", depth: 25) {
                if let u = attr(web, kAXURLAttribute) {
                    if let url = u as? URL { return url.absoluteString }
                    if let s = u as? String { return s }
                    return (u as! NSURL).absoluteString
                }
            }
            usleep(150_000)
        }
        return nil
    }

    private func find(_ e: AXUIElement, role: String, depth: Int) -> AXUIElement? {
        if (attr(e, kAXRoleAttribute) as? String) == role { return e }
        guard depth > 0 else { return nil }
        for c in children(e) { if let f = find(c, role: role, depth: depth - 1) { return f } }
        return nil
    }

    private static let browsers: Set<String> = ["com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser",
                                                "com.microsoft.edgemac", "company.thebrowser.Browser"]

    /// Chrome remembers zoom per site; pages the old auto zoom-out shrank would still render their desktop
    /// layout in a small box. On each new page, set zoom back to 100% so the site picks its own layout.
    private func resetPageZoom(_ box: Box) {
        guard Date() > box.settleUntil,
              let bid = NSRunningApplication(processIdentifier: box.pid)?.bundleIdentifier, Self.browsers.contains(bid) else { return }
        let title = (attr(box.win, kAXTitleAttribute) as? String) ?? ""
        guard title != box.lastTitle else { return }
        box.lastTitle = title
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in   // after the page has loaded
            guard let self, self.on else { return }
            AXUIElementSetAttributeValue(box.win, kAXMainAttribute as CFString, kCFBooleanTrue)
            if let item = self.menuItems(AXUIElementCreateApplication(box.pid))
                .first(where: { (self.attr($0, kAXTitleAttribute) as? String) == "Actual Size" }),
               (self.attr(item, kAXEnabledAttribute) as? Bool) == true {   // enabled only when zoom isn't 100%
                AXUIElementPerformAction(item, kAXPressAction as CFString)
                self.log("reset page zoom to 100% for \(title.prefix(40))")
            }
        }
    }

    private func windows(_ pid: pid_t) -> [AXUIElement] {
        let ax = AXUIElementCreateApplication(pid)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &v) == .success,
              let ws = v as? [AXUIElement] else { return [] }
        return ws.filter { w in                                      // real windows only (no sheets/panels/popups)
            var role: CFTypeRef?, sub: CFTypeRef?
            AXUIElementCopyAttributeValue(w, kAXRoleAttribute as CFString, &role)
            AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &sub)
            return (role as? String) == "AXWindow" && ((sub as? String) ?? "AXStandardWindow") == "AXStandardWindow"
        }
    }

    private func boxKey(_ pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier.map { "box." + $0 }
    }

    private func saveBox(_ pid: pid_t, _ r: CGRect) {
        guard let k = boxKey(pid) else { return }
        UserDefaults.standard.set([r.minX, r.minY, r.width, r.height].map(Double.init), forKey: k)
    }

    private func savedBox(_ pid: pid_t) -> CGRect? {
        guard let k = boxKey(pid), let a = UserDefaults.standard.array(forKey: k) as? [Double], a.count == 4 else { return nil }
        return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
    }

    /// Fill the screen (above the dock) as a window, or put it back in its box.
    func toggleFill(_ box: Box) {
        box.busyUntil = Date().addingTimeInterval(5)            // until the switch below finishes
        let base = box.frame ?? box.target
        var screen = (NSScreen.screens.first { $0.frame.contains(CGPoint(x: base.midX, y: base.midY)) }
                      ?? NSScreen.main ?? NSScreen.screens[0]).frame
        screen.origin.y += Self.dockReserve; screen.size.height -= Self.dockReserve + barHeight   // below the pinned bar
        let target: CGRect
        if let back = box.restoreFrame { target = back; box.restoreFrame = nil }
        else { box.restoreFrame = base; target = screen }
        log("pid \(box.pid): \(box.restoreFrame == nil ? "back to its box" : "box fills the screen")")
        applyAfterFullscreenExit(box, target, tries: 0, stableSince: nil)
    }

    private func toggleFill(_ pid: pid_t) {
        if let box = boxes.first(where: { $0.pid == pid }) { toggleFill(box) }
    }

    /// macOS animates out of fullscreen and then restores the old frame itself; wait until that's over,
    /// then keep applying our frame until it sticks.
    private func applyAfterFullscreenExit(_ box: Box, _ target: CGRect, tries: Int, stableSince: Date?, last: CGRect? = nil) {
        guard on, tries < 40 else { box.busyUntil = Date().addingTimeInterval(1); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            if self.isFullScreen(box.win) {                        // still animating out
                AXUIElementSetAttributeValue(box.win, "AXFullScreen" as CFString, kCFBooleanFalse)
                self.applyAfterFullscreenExit(box, target, tries: tries + 1, stableSince: nil)
                return
            }
            let since = stableSince ?? Date()
            let r = self.frameOf(box.win)
            let close = r.map { abs($0.width - target.width) < 4 && abs($0.height - target.height) < 4
                                && abs($0.minX - target.minX) < 4 && abs($0.minY - target.minY) < 4 } ?? false
            let still = r != nil && last != nil && r == last                    // the window has stopped moving
            if (close && Date().timeIntervalSince(since) > 0.6) || (tries >= 6 && still) {
                if let r { box.frame = r }
                box.busyUntil = Date().addingTimeInterval(0.8)      // done; settle before watching again
                return
            }
            if tries < 6 { self.setFrame(box.win, target) }        // a few firm tries, then let it settle
            self.applyAfterFullscreenExit(box, target, tries: tries + 1, stableSince: since, last: r)
        }
    }

    private func isMinimized(_ win: AXUIElement) -> Bool {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &v) == .success && (v as? Bool) == true
    }

    private func isFullScreen(_ win: AXUIElement) -> Bool {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &v) == .success && (v as? Bool) == true
    }

    /// Window numbers on the desktop you're looking at (windows on other Spaces aren't listed).
    private func onScreenWindowIDs() -> Set<CGWindowID> {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    private func refreshCanvas() {
        refreshDock()
        refreshMenuBar()
        let visible = onScreenWindowIDs()
        for (_, canvas, screen) in canvases {
            canvas.boxes = boxes.filter { b in
                var wid: CGWindowID = 0
                return _AXUIElementGetWindow(b.win, &wid) != .success || visible.contains(wid)   // this desktop only
            }.compactMap(\.frame)
                .filter { $0.intersects(screen.frame) }
                .map { $0.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }
        }
    }

    private func mainWindow(_ pid: pid_t) -> AXUIElement? {
        let ax = AXUIElementCreateApplication(pid)
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(ax, kAXMainWindowAttribute as CFString, &v) == .success, let v {
            return (v as! AXUIElement)
        }
        if AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &v) == .success,
           let ws = v as? [AXUIElement], let w = ws.first { return w }
        return nil
    }

    private var primaryH: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    private func setFrame(_ win: AXUIElement, _ r: CGRect) {
        var pos = CGPoint(x: r.minX, y: primaryH - r.maxY)                // AX: top-left origin
        var size = r.size
        if let pv = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv) }
        if let sv = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv) }
        if let pv = AXValueCreate(.cgPoint, &pos) { AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv) }
    }

    private func frameOf(_ win: AXUIElement) -> CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sv) == .success,
              let pv, let sv else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(x: p.x, y: primaryH - p.y - s.height, width: s.width, height: s.height)
    }

    private func log(_ s: String) { FileHandle.standardError.write("os mode: \(s)\n".data(using: .utf8)!) }

    // MARK: declutter (tablet-like): switch off each app's bars via its own View menu, undo on exit

    private static let hideTitles = ["Hide Toolbar", "Hide Sidebar", "Hide Tab Bar", "Hide Status Bar",
                                     "Hide Path Bar", "Hide Bookmarks Bar", "Hide Favorites Bar", "Hide Ruler",
                                     "Hide Format Bar", "Hide Navigator", "Hide Inspector", "Hide Library"]
    private var decluttered: [(pid_t, String)] = []

    private func declutter(_ pid: pid_t) {
        guard on else { return }
        let app = AXUIElementCreateApplication(pid)
        var n = 0
        for item in menuItems(app) {
            guard let title = attr(item, kAXTitleAttribute) as? String, Self.hideTitles.contains(title),
                  (attr(item, kAXEnabledAttribute) as? Bool) == true,
                  !decluttered.contains(where: { $0.0 == pid && $0.1 == title }) else { continue }
            if AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
                decluttered.append((pid, title)); n += 1
            }
        }
        let titles = menuItems(app).compactMap { attr($0, kAXTitleAttribute) as? String }.filter { $0.hasPrefix("Hide") || $0.hasPrefix("Show") }
        log("declutter pid \(pid): hid \(n); hide/show items seen: \(titles.prefix(12))")
    }

    private func undoDeclutter() {
        for (pid, title) in decluttered {
            guard NSRunningApplication(processIdentifier: pid)?.isTerminated == false else { continue }
            let show = title.replacingOccurrences(of: "Hide ", with: "Show ")
            for item in menuItems(AXUIElementCreateApplication(pid)) where (attr(item, kAXTitleAttribute) as? String) == show {
                AXUIElementPerformAction(item, kAXPressAction as CFString)
                break
            }
        }
        decluttered = []
    }

    /// All items in an app's menu bar (one level of submenus deep is enough for View menus).
    private func menuItems(_ app: AXUIElement) -> [AXUIElement] {
        guard let bar = attr(app, kAXMenuBarAttribute) else { return [] }
        var out: [AXUIElement] = []
        for top in children(bar as! AXUIElement) {
            for menu in children(top) {
                for item in children(menu) {
                    out.append(item)
                    for sub in children(item) { out += children(sub) }
                }
            }
        }
        return out
    }

    private func children(_ e: AXUIElement) -> [AXUIElement] {
        (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    /// Put the Dock and menu bar back the way you had them. Also called when the pet starts, in case it
    /// quit or crashed while OS mode was on.
    @discardableResult
    private func shell(_ args: String...) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0]); p.arguments = Array(args.dropFirst())
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // the separate CodexVoicePet orb (its own launch agent) is paused while OS mode is on
    private static let otherPet = "com.kush.codex-voice-pet"
    private var uidDomain: String { "gui/\(getuid())" }

    func pauseOtherPet() {
        guard shell("/bin/launchctl", "print", "\(uidDomain)/\(Self.otherPet)") != nil else { return }   // not running
        UserDefaults.standard.set(true, forKey: "osPausedOtherPet")
        _ = shell("/bin/launchctl", "bootout", "\(uidDomain)/\(Self.otherPet)")
        log("paused \(Self.otherPet)")
    }

    func resumeOtherPet() {
        guard UserDefaults.standard.bool(forKey: "osPausedOtherPet") else { return }
        UserDefaults.standard.removeObject(forKey: "osPausedOtherPet")
        let plist = NSHomeDirectory() + "/Library/LaunchAgents/\(Self.otherPet).plist"
        _ = shell("/bin/launchctl", "bootstrap", uidDomain, plist)
        log("resumed \(Self.otherPet)")
    }

    func restoreBars() {
        resumeOtherPet()
        let ud = UserDefaults.standard
        guard ud.object(forKey: "osSavedDock") != nil else { return }
        _ = systemEvents("set autohide of dock preferences to \(ud.bool(forKey: "osSavedDock"))")
        _ = systemEvents("set autohide menu bar of dock preferences to \(ud.bool(forKey: "osSavedMenu"))")
        ud.removeObject(forKey: "osSavedDock"); ud.removeObject(forKey: "osSavedMenu")
        if let delay = ud.string(forKey: "osSavedDockDelay") {
            if delay == "none" { _ = shell("/usr/bin/defaults", "delete", "com.apple.dock", "autohide-delay") }
            else { _ = shell("/usr/bin/defaults", "write", "com.apple.dock", "autohide-delay", "-float", delay) }
            ud.removeObject(forKey: "osSavedDockDelay")
            _ = shell("/usr/bin/killall", "Dock")
        }
        log("restored Dock and menu bar")
    }

    // MARK: helpers

    @discardableResult
    private func systemEvents(_ cmd: String) -> NSAppleEventDescriptor? {
        var err: NSDictionary?
        let r = NSAppleScript(source: "tell application \"System Events\" to \(cmd)")?.executeAndReturnError(&err)
        if let err { FileHandle.standardError.write("os mode: System Events error \(err)\n".data(using: .utf8)!) }
        return r
    }
}
