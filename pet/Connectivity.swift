// Wi-Fi and Bluetooth for the OS mode menu bar: their state for the icons, and the menus you get
// by clicking them (turn on/off, connect/disconnect, switch network or device).
import AppKit
import CoreLocation
import CoreWLAN
import IOBluetooth

/// An NSMenuItem that runs a closure.
final class ActionItem: NSMenuItem {
    private var run: () -> Void = {}
    convenience init(_ title: String, checked: Bool = false, enabled: Bool = true, _ run: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.run = run; target = self; state = checked ? .on : .off; isEnabled = enabled
    }
    @objc private func fire() { run() }
}

private func header(_ t: String) -> NSMenuItem {
    let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; return i
}

private func openSettings(_ pane: String) {
    if let u = URL(string: "x-apple.systempreferences:com.apple.\(pane)") { NSWorkspace.shared.open(u) }
}

// MARK: - Wi-Fi

final class WiFi: NSObject, CLLocationManagerDelegate {
    static let shared = WiFi()
    private let loc = CLLocationManager()               // macOS only reveals network names with Location access
    private let q = DispatchQueue(label: "wifi")
    private(set) var networks: [CWNetwork] = []         // last scan, strongest first
    private var lastScan = Date.distantPast
    var onChange: (() -> Void)?

    override init() {
        super.init()
        loc.delegate = self
        if loc.authorizationStatus == .notDetermined { loc.requestWhenInUseAuthorization() }
    }

    var iface: CWInterface? { CWWiFiClient.shared().interface() }
    var on: Bool { iface?.powerOn() ?? false }
    var connected: Bool { (iface?.rssiValue() ?? 0) != 0 }
    var ssid: String? { iface?.ssid() }
    /// 0…1 signal strength for the icon
    var strength: Double {
        guard let r = iface?.rssiValue(), r != 0 else { return 0 }
        return min(1, max(0.1, Double(r + 90) / 40))      // -90 dBm weak … -50 dBm full
    }

    /// Scan in the background (at most every 15 s) so the menu opens instantly.
    func refresh() {
        guard on, Date().timeIntervalSince(lastScan) > 15 else { return }
        lastScan = Date()
        q.async { [weak self] in
            guard let self, let found = try? self.iface?.scanForNetworks(withName: nil) else { return }
            var best: [String: CWNetwork] = [:]
            for n in found { guard let s = n.ssid, !s.isEmpty else { continue }
                if (best[s]?.rssiValue ?? -999) < n.rssiValue { best[s] = n } }
            let list = best.values.sorted { $0.rssiValue > $1.rssiValue }
            DispatchQueue.main.async { self.networks = list; self.onChange?() }
        }
    }

    private func known() -> [String] {                    // networks this Mac has joined before
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        p.arguments = ["-listpreferredwirelessnetworks", "en0"]
        let pipe = Pipe(); p.standardOutput = pipe
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\n").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func menu() -> NSMenu {
        let m = NSMenu(); m.autoenablesItems = false
        m.addItem(header("Wi-Fi"))
        m.addItem(ActionItem(on ? "Turn Wi-Fi Off" : "Turn Wi-Fi On") { [weak self] in
            guard let self else { return }
            let want = !self.on
            self.q.async { try? self.iface?.setPower(want); DispatchQueue.main.async { self.lastScan = .distantPast; self.onChange?() } }
        })
        guard on else { m.addItem(.separator()); m.addItem(ActionItem("Wi-Fi Settings…") { openSettings("wifi-settings-extension") }); return m }
        if connected {
            m.addItem(.separator())
            m.addItem(ActionItem(ssid ?? "Connected", checked: true, enabled: false) {})
            m.addItem(ActionItem("Disconnect") { [weak self] in self?.iface?.disassociate(); self?.onChange?() })
        }
        m.addItem(.separator())
        m.addItem(header(networks.isEmpty ? "Known Networks" : "Networks"))
        let knownList = known()
        if networks.isEmpty {
            // no scan results (Location not allowed yet, or still scanning): join a network this Mac knows
            for s in knownList.prefix(12) {
                m.addItem(ActionItem(s, checked: s == ssid) { [weak self] in self?.join(name: s) })
            }
        } else {
            for n in networks.prefix(14) {
                let s = n.ssid ?? ""
                let locked = !n.supportsSecurity(.none)
                let title = s + (locked ? "  🔒" : "")
                m.addItem(ActionItem(title, checked: s == ssid) { [weak self] in
                    guard let self else { return }
                    if !locked { self.q.async { try? self.iface?.associate(to: n, password: nil); DispatchQueue.main.async { self.onChange?() } } }
                    else if knownList.contains(s) { self.join(name: s) }       // password is in the keychain
                    else { self.askPassword(n) }
                })
            }
        }
        m.addItem(.separator())
        m.addItem(ActionItem("Wi-Fi Settings…") { openSettings("wifi-settings-extension") })
        return m
    }

    /// Join a saved network; macOS fills the password from the keychain.
    private func join(name: String) {
        q.async { [weak self] in
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            p.arguments = ["-setairportnetwork", "en0", name]
            try? p.run(); p.waitUntilExit()
            DispatchQueue.main.async { self?.onChange?() }
        }
    }

    /// A new secured network: you type its password (we never see or store it beyond handing it to macOS).
    private func askPassword(_ n: CWNetwork) {
        let a = NSAlert()
        a.messageText = "Join “\(n.ssid ?? "")”"
        a.informativeText = "Enter the network password."
        let f = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        a.accessoryView = f
        a.addButton(withTitle: "Join"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let pw = f.stringValue
        q.async { [weak self] in
            try? self?.iface?.associate(to: n, password: pw)
            DispatchQueue.main.async { self?.onChange?() }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) { lastScan = .distantPast; refresh() }
}

// MARK: - Bluetooth

final class Bluetooth {
    static let shared = Bluetooth()
    private let q = DispatchQueue(label: "bluetooth")
    var onChange: (() -> Void)?

    // the same (private) calls the system's Bluetooth switch uses
    private typealias GetPower = @convention(c) () -> Int32
    private typealias SetPower = @convention(c) (Int32) -> Void
    private let getPower: GetPower? = {
        _ = IOBluetoothHostController.default()                       // make sure the framework is loaded
        guard let s = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOBluetoothPreferenceGetControllerPowerState") else { return nil }
        return unsafeBitCast(s, to: GetPower.self)
    }()
    private let setPower: SetPower? = {
        guard let s = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOBluetoothPreferenceSetControllerPowerState") else { return nil }
        return unsafeBitCast(s, to: SetPower.self)
    }()

    var on: Bool {
        if let getPower { return getPower() != 0 }
        return IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
    }
    var paired: [IOBluetoothDevice] { (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] }
    var anyConnected: Bool { paired.contains { $0.isConnected() } }

    func menu() -> NSMenu {
        let m = NSMenu(); m.autoenablesItems = false
        m.addItem(header("Bluetooth"))
        let isOn = on
        m.addItem(ActionItem(isOn ? "Turn Bluetooth Off" : "Turn Bluetooth On", enabled: setPower != nil) { [weak self] in
            guard let self, let setPower = self.setPower else { return }
            self.q.async { setPower(isOn ? 0 : 1); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.onChange?() } }
        })
        if isOn {
            let devices = paired.sorted { ($0.isConnected() ? 0 : 1, $0.name ?? "") < ($1.isConnected() ? 0 : 1, $1.name ?? "") }
            m.addItem(.separator())
            m.addItem(header(devices.isEmpty ? "No paired devices" : "Devices"))
            for d in devices {
                let up = d.isConnected()
                let item = ActionItem((d.name ?? d.addressString ?? "Device") + (up ? "  — Disconnect" : ""), checked: up) { [weak self] in
                    self?.q.async {
                        if up { d.closeConnection() } else { d.openConnection() }
                        DispatchQueue.main.async { self?.onChange?() }
                    }
                }
                m.addItem(item)
            }
        }
        m.addItem(.separator())
        m.addItem(ActionItem("Bluetooth Settings…") { openSettings("BluetoothSettings") })
        return m
    }
}
