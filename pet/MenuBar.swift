// OS mode menu bar: a thin black bar across the top. Left of the notch: the app you're using, with its
// real menus (read through Accessibility). Right of the notch: voice/Claude status, mode toggles,
// Wi-Fi, battery, date & time, and a power menu. It sits above macOS's auto-hiding menu bar, so that
// one never shows.
import AppKit
import ApplicationServices
import CoreWLAN
import IOKit.ps
import SwiftUI

final class MenuBarModel: ObservableObject {
    @Published var appName = ""
    @Published var appIcon: NSImage? = nil
    @Published var status = ""              // voice / Claude state in a word or two
    @Published var step = ""                // what Claude is doing right now
    @Published var notes = false
    @Published var auto = false
    @Published var tunnel = false
    @Published var battery: Int? = nil
    @Published var charging = false
    @Published var wifiOn = false
    @Published var wifiConnected = false
    @Published var wifiStrength = 0.0
    @Published var btOn = false
    @Published var btConnected = false
    var onWifi: ((NSView, CGPoint) -> Void)?
    var onBluetooth: ((NSView, CGPoint) -> Void)?
    @Published var now = Date()
    @Published var shown = false            // drives the reveal animation (same spring as the dial)
    @Published var appMode = false          // the front app's box fills the screen: show that app's own bar
    @Published var appMenus: [String] = []  // its top-level menus (File, Edit, View…)
    @Published var windowTitle = ""
    var onTopMenu: ((String, NSView, CGPoint) -> Void)?
    var onBackToBox: (() -> Void)?
    var leftWidth: CGFloat = 400            // space left of the notch
    var rightWidth: CGFloat = 600           // space right of the notch
    var onAppMenu: ((NSView, CGPoint) -> Void)?
    var onPower: ((NSView, CGPoint) -> Void)?
    var onNotes: (() -> Void)?, onAuto: (() -> Void)?, onTunnel: (() -> Void)?
}

/// Lets SwiftUI buttons find their NSView and position, to pop up an NSMenu right under them.
struct AnchorReader: NSViewRepresentable {
    let onClick: (NSView, CGPoint) -> Void
    var onRightClick: ((NSView, CGPoint) -> Void)? = nil     // two-finger click / control-click
    init(onRightClick: ((NSView, CGPoint) -> Void)? = nil, _ onClick: @escaping (NSView, CGPoint) -> Void) {
        self.onClick = onClick; self.onRightClick = onRightClick
    }
    init(onClick: @escaping (NSView, CGPoint) -> Void) { self.onClick = onClick }
    func makeNSView(context: Context) -> NSView { ClickView(onClick: onClick, onRightClick: onRightClick) }
    func updateNSView(_ v: NSView, context: Context) {
        (v as? ClickView)?.onClick = onClick; (v as? ClickView)?.onRightClick = onRightClick
    }
    final class ClickView: NSView {
        var onClick: (NSView, CGPoint) -> Void
        var onRightClick: ((NSView, CGPoint) -> Void)?
        init(onClick: @escaping (NSView, CGPoint) -> Void, onRightClick: ((NSView, CGPoint) -> Void)? = nil) {
            self.onClick = onClick; self.onRightClick = onRightClick; super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with e: NSEvent) {
            if e.modifierFlags.contains(.control), let r = onRightClick { r(self, NSPoint(x: 0, y: -4)) }
            else { onClick(self, NSPoint(x: 0, y: -4)) }
        }
        override func rightMouseDown(with e: NSEvent) {
            if let r = onRightClick { r(self, NSPoint(x: 0, y: -4)) } else { super.rightMouseDown(with: e) }
        }
    }
}

struct MenuBarView: View {
    @ObservedObject var m: MenuBarModel
    let height: CGFloat
    let gold = Color(red: 1, green: 0.82, blue: 0.2)

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if m.appMode { appBar } else { systemBar }
            }
            .frame(height: height)
            .background(Color.black)
            .offset(y: m.shown ? 0 : -height - 4)                 // drops in from the top edge
            .animation(.spring(response: 0.36, dampingFraction: 0.82), value: m.shown)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
    }

    /// Contents fade in left → right after the bar lands, like the dial's icons.
    func stagger(_ i: Int) -> some ViewModifier { Stagger(on: m.shown, delay: 0.06 + Double(i) * 0.035) }

    // the app's own menu bar, while its box fills the screen
    var appBar: some View {
        HStack(spacing: 0) {
            HStack(spacing: 2) {
                HStack(spacing: 7) {
                    if let icon = m.appIcon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                    Text(m.appName).font(.system(size: 13, weight: .bold, design: .rounded))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .modifier(stagger(0))
                ForEach(Array(m.appMenus.enumerated()), id: \.offset) { i, title in
                    Text(title).font(.system(size: 13, weight: .medium, design: .rounded))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.001)))
                        .overlay(AnchorReader { v, p in m.onTopMenu?(title, v, p) })
                        .modifier(stagger(i + 1))
                }
            }
            .foregroundColor(.white)
            .padding(.leading, 10)
            .frame(width: m.leftWidth, alignment: .leading)
            .clipped()
            Spacer(minLength: 0)                                   // the notch
            HStack(spacing: 12) {
                Text(m.windowTitle).font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.65)).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: m.rightWidth - 260, alignment: .trailing)
                    .modifier(stagger(1))
                connectivity.modifier(stagger(2))
                TimerChip().overlay(AnchorReader(onRightClick: { v, p in TaskTimer.shared.historyMenu(v, p) }) { v, p in TaskTimer.shared.click(v, p) }).modifier(stagger(2))
                Text(m.now, format: .dateTime.weekday(.abbreviated).hour().minute())
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(.white).monospacedDigit()
                    .modifier(stagger(2))
                Button(action: { m.onBackToBox?() }) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 22, height: 22)
                }.buttonStyle(.plain).help("Back to box").modifier(stagger(2))
            }
            .padding(.trailing, 14)
            .frame(width: m.rightWidth, alignment: .trailing)
        }
    }

    var systemBar: some View {
        HStack(spacing: 0) {
            // left of the notch: the app you're using and its menus
            HStack(spacing: 8) {
                if let icon = m.appIcon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                Text(m.appName.isEmpty ? "OS mode" : m.appName)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.6)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
            .overlay(AnchorReader { v, p in m.onAppMenu?(v, p) })
            .help("This app's menus")
            .padding(.leading, 12)
            .modifier(stagger(0))
            .frame(width: m.leftWidth, alignment: .leading)
            Spacer(minLength: 0)                                   // the notch
            // right of the notch
            HStack(spacing: 12) {
                if !m.status.isEmpty {
                    HStack(spacing: 5) {
                        Circle().fill(gold).frame(width: 6, height: 6)
                        Text(m.status).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(.white)
                        if !m.step.isEmpty {
                            Text(m.step).font(.system(size: 11, design: .rounded)).foregroundColor(.white.opacity(0.5))
                                .lineLimit(1).frame(maxWidth: 220, alignment: .leading)
                        }
                    }
                }
                toggle("note.text", on: m.notes, help: "Notes mode") { m.onNotes?() }
                toggle("waveform", on: m.auto, help: "Auto mode (hands-free)") { m.onAuto?() }
                toggle("flashlight.on.fill", on: m.tunnel, help: "Tunnel vision") { m.onTunnel?() }
                connectivity
                TimerChip().overlay(AnchorReader(onRightClick: { v, p in TaskTimer.shared.historyMenu(v, p) }) { v, p in TaskTimer.shared.click(v, p) })
                Text(m.now, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(.white).monospacedDigit()
                Image(systemName: "power").font(.system(size: 12, weight: .bold)).foregroundColor(.white.opacity(0.85))
                    .frame(width: 22, height: 22)
                    .overlay(AnchorReader { v, p in m.onPower?(v, p) })
                    .help("Exit OS mode, lock, sleep")
            }
            .padding(.trailing, 14)
            .modifier(stagger(2))
            .frame(width: m.rightWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Wi-Fi and Bluetooth (click for their menus), then battery. Shown in both bars.
    var connectivity: some View {
        HStack(spacing: 12) {
            Image(systemName: !m.wifiOn ? "wifi.slash" : (m.wifiConnected ? "wifi" : "wifi.exclamationmark"),
                  variableValue: m.wifiConnected ? m.wifiStrength : nil)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(m.wifiOn ? 0.9 : 0.5))
                .frame(width: 22, height: 22).contentShape(Rectangle())
                .overlay(AnchorReader { v, p in m.onWifi?(v, p) })
                .help("Wi-Fi")
            BluetoothGlyph()
                .stroke(Color.white.opacity(m.btOn ? (m.btConnected ? 1 : 0.85) : 0.4),
                        style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                .frame(width: 7, height: 13)
                .overlay(alignment: .bottomTrailing) {
                    if !m.btOn { Rectangle().fill(Color.white.opacity(0.6)).frame(width: 14, height: 1.3).rotationEffect(.degrees(-55)).offset(x: 3.5, y: -6) }
                }
                .frame(width: 22, height: 22).contentShape(Rectangle())
                .overlay(AnchorReader { v, p in m.onBluetooth?(v, p) })
                .help("Bluetooth")
            if let b = m.battery {
                HStack(spacing: 3) {
                    Text("\(b)%").font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                    Image(systemName: m.charging ? "battery.100.bolt" : batterySymbol(b)).font(.system(size: 13))
                }.foregroundColor(b <= 15 && !m.charging ? .red : .white.opacity(0.85))
            }
        }
    }

    func toggle(_ symbol: String, on: Bool, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundColor(on ? .black : .white.opacity(0.7))
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(on ? gold : Color.white.opacity(0.06)))
        }.buttonStyle(.plain).help(help)
    }

    func batterySymbol(_ b: Int) -> String {
        b > 87 ? "battery.100" : b > 62 ? "battery.75" : b > 37 ? "battery.50" : b > 12 ? "battery.25" : "battery.0"
    }
}

struct Stagger: ViewModifier {
    let on: Bool, delay: Double
    func body(content: Content) -> some View {
        content.opacity(on ? 1 : 0).offset(y: on ? 0 : -4)
            .animation(on ? .easeOut(duration: 0.22).delay(delay) : .easeIn(duration: 0.12), value: on)
    }
}

/// The Bluetooth rune.
struct BluetoothGlyph: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height
        p.move(to: CGPoint(x: r.minX, y: r.minY + h * 0.27))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + h * 0.73))
        p.addLine(to: CGPoint(x: r.minX + w * 0.5, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + w * 0.5, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + h * 0.27))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + h * 0.73))
        return p
    }
}

final class MenuBarHost<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - reading system state

enum SystemInfo {
    static func battery() -> (Int, Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  let cap = d[kIOPSCurrentCapacityKey] as? Int else { continue }
            let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            let onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (cap, charging || (onAC && cap >= 100))
        }
        return nil
    }

    static func wifiOn() -> Bool { WiFi.shared.on }
}

// MARK: - the frontmost app's real menus, rebuilt as an NSMenu from Accessibility

final class AXMenuBridge: NSObject {
    private var keep: [AXUIElement] = []

    func menu(for pid: pid_t) -> NSMenu {
        let menu = NSMenu()
        let app = AXUIElementCreateApplication(pid)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let bar else {
            menu.addItem(withTitle: "No menus", action: nil, keyEquivalent: ""); return menu
        }
        for (i, top) in children(bar as! AXUIElement).enumerated() where i > 0 {     // skip the Apple menu
            let title = (attr(top, kAXTitleAttribute) as? String) ?? ""
            guard !title.isEmpty else { continue }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if let sub = children(top).first { item.submenu = build(sub, depth: 0) }
            menu.addItem(item)
        }
        return menu
    }

    /// The app's top-level menu titles (without the Apple menu and the app-name menu).
    func topTitles(for pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let bar else { return [] }
        return children(bar as! AXUIElement).enumerated().compactMap { i, top in
            i < 2 ? nil : (attr(top, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// One top-level menu (e.g. "File") as an NSMenu.
    func menu(for pid: pid_t, title: String) -> NSMenu {
        let app = AXUIElementCreateApplication(pid)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success, let bar,
              let top = children(bar as! AXUIElement).first(where: { (attr($0, kAXTitleAttribute) as? String) == title }),
              let sub = children(top).first else { return NSMenu() }
        return build(sub, depth: 0)
    }

    private func build(_ axMenu: AXUIElement, depth: Int) -> NSMenu {
        let m = NSMenu(); m.autoenablesItems = false
        for el in children(axMenu) {
            let title = (attr(el, kAXTitleAttribute) as? String) ?? ""
            if title.isEmpty { m.addItem(.separator()); continue }
            let item = NSMenuItem(title: title, action: #selector(press(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = (attr(el, kAXEnabledAttribute) as? Bool) ?? true
            if (attr(el, "AXMenuItemMarkChar") as? String)?.isEmpty == false { item.state = .on }
            if depth < 2, let sub = children(el).first, (attr(sub, kAXRoleAttribute) as? String) == "AXMenu" {
                item.submenu = build(sub, depth: depth + 1); item.action = nil
            } else {
                keep.append(el); item.tag = keep.count - 1
            }
            m.addItem(item)
        }
        return m
    }

    @objc private func press(_ sender: NSMenuItem) {
        guard keep.indices.contains(sender.tag) else { return }
        AXUIElementPerformAction(keep[sender.tag], kAXPressAction as CFString)
    }

    private func children(_ e: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v) == .success ? (v as? [AXUIElement]) ?? [] : []
    }
    private func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
    }
}

/// Shown beside the notch only while something is happening (bar hidden): gold dot, state, current step.
struct StatusPill: View {
    @ObservedObject var m: MenuBarModel
    let height: CGFloat
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color(red: 1, green: 0.82, blue: 0.2)).frame(width: 6, height: 6)
            Text(m.status).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(.white)
            if !m.step.isEmpty {
                Text(m.step).font(.system(size: 11, design: .rounded)).foregroundColor(.white.opacity(0.5))
                    .lineLimit(1).frame(maxWidth: 240, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: height)
        .background(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).fill(Color.black))
        .fixedSize()
    }
}
