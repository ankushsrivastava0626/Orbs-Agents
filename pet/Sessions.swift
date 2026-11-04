// Voice sessions as orbs: as many Claude or Codex sessions as you
// like, each its own orb in the dock. Click an orb to talk to it (gold ring); two-finger click for its menu
// (transcript, Terminal, stop, resume, close). The ＋ button starts a new Claude or Codex session.
// Codex sessions run on the Codex voice server (:5124); its approval prompts are shown here.
import AppKit
import SwiftUI

/// Names you give orbs, by conversation id (so the name follows the conversation: resume, search, cards…).
enum OrbNames {
    static let path = NSHomeDirectory() + "/.claude/voice/orb_names.json"
    static func all() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))) ?? [:]
    }
    static func get(_ id: String) -> String? { all()[id] }
    static func set(_ id: String, _ name: String?) {
        var a = all()
        a[id] = (name?.isEmpty ?? true) ? nil : name
        if let d = try? JSONEncoder().encode(a) { try? d.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }
}

struct OrbEntry: Codable, Equatable {
    var name: String          // Claude: tmux session name ("voice", "voice-2"…); Codex: "codex", "codex-2"…
    var kind: String          // "claude" | "codex"
    var id: String            // Claude session id / Codex thread id
    var cwd: String
    var label: String? = nil
    var hotkey: Hotkey? = nil // speak hotkey you set; nil = the default for its position
    var closed: Bool? = nil   // you closed it: don't relaunch it automatically
    var command: String? = nil // custom launch command ("claude-openrouter --model …"); kept when we rewrite the file
}

/// A hold-to-talk key. Modifiers are side-specific (left ⌥ ≠ right ⌥). code -1 = no hotkey.
struct Hotkey: Codable, Equatable {
    var code: Int
    var label: String
    static let none = Hotkey(code: -1, label: "None")
    static let leftOption = Hotkey(code: 58, label: "Left Option")
    static let leftControl = Hotkey(code: 59, label: "Left Control")

    /// Device-specific flag bit for each modifier key, so left and right can be told apart.
    static let modifierBits: [Int: UInt64] = [
        58: 0x20, 61: 0x40,          // ⌥ left / right
        59: 0x01, 62: 0x2000,        // ⌃ left / right
        56: 0x02, 60: 0x04,          // ⇧ left / right
        55: 0x08, 54: 0x10,          // ⌘ left / right
        63: 0x800000, 57: 0x10000,   // fn, caps lock
    ]
    static let names: [Int: String] = [
        58: "Left Option", 61: "Right Option", 59: "Left Control", 62: "Right Control", 56: "Left Shift",
        60: "Right Shift", 55: "Left Command", 54: "Right Command", 63: "fn", 57: "Caps Lock",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 49: "Space", 48: "Tab", 51: "Delete",
        36: "Return", 123: "←", 124: "→", 125: "↓", 126: "↑", 116: "Page Up", 121: "Page Down",
        115: "Home", 119: "End", 50: "`",
    ]
    var isModifier: Bool { Hotkey.modifierBits[code] != nil }
}

/// Live orb for one session: reads the shared voice server status (Claude) or the Codex server status.
struct SessionOrb: View {
    let entry: OrbEntry
    @ObservedObject var main: Model
    @ObservedObject var codex: Model

    var body: some View {
        let s = main.s, now = Date().timeIntervalSince1970
        let target = s.target == entry.name
        if entry.kind == "codex" {
            let live = codex.s.thread_id == entry.id
            let codexMode: Mode = !codex.online ? .offline
                : (target && s.listening) ? .listening                  // the pet is recording for this orb
                : (target && now - s.heard_at < 0.6) ? .sent
                : (live ? codex.mode : .idle)
            OrbFace(mode: codexMode,
                    level: (target && s.listening) ? s.level : (live ? codex.s.level : 0), outLevel: live ? codex.s.out_level : 0,
                    auto: live && codex.s.auto, problem: live && codex.s.approval,
                    idleColor: Color(red: 1.0, green: 0.73, blue: 0.3), selected: target, muted: live && codex.s.muted)
                .scaleEffect(0.62)
        } else {
            let st = s.sessions[entry.name]
            let working = (st?.state == "working" && now - (st?.at ?? 0) < 600)
            let speaking = s.speaking && s.speaking_session == entry.name
            let mode: Mode = !main.online ? .offline
                : (target && s.listening) ? .listening
                : (target && now - s.heard_at < 0.6) ? .sent
                : speaking ? .speaking
                : working ? .working : .idle
            OrbFace(mode: mode, level: target ? s.level : 0, outLevel: speaking ? s.out_level : 0,
                    auto: target && s.auto, notes: target && s.notes, ripple: target && main.flying != nil,
                    problem: target && main.problem,
                idleColor: (entry.command ?? "").contains("openrouter") ? Color(red: 1.0, green: 0.55, blue: 0.75)   // OpenRouter: rose
                                                                         : Color(red: 0.55, green: 0.6, blue: 0.75),
                selected: target, muted: s.muted_sessions.contains(entry.name))
                .scaleEffect(0.62)
        }
    }
}

final class SessionsController: NSObject {
    let main: Model, codex: Model
    weak var app: AppDelegate?
    private(set) var entries: [OrbEntry] = []
    private weak var dock: DockModel?
    private var timer: Timer?
    private let orbsPath = NSHomeDirectory() + "/.claude/voice/orbs.json"
    private let launcher = NSHomeDirectory() + "/.claude/voice/start-voice-session.sh"
    private let codexRoot = "/Users/kush/Documents/Codex/2026-10-04/can-x20/outputs/codex-voice-assistant"
    private var promptedApproval = -1
    private var approvalOpen = false

    init(main: Model, codex: Model, app: AppDelegate) {
        self.main = main; self.codex = codex; self.app = app
        super.init()
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.load() }
        retireCodexPet()
        installKeyTap()
        reviveTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.revive() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.revive() }   // soon after login
    }

    // MARK: orbs file (written by the launcher for Claude sessions, by us for Codex sessions)

    func load() {
        var list = (try? JSONDecoder().decode([OrbEntry].self, from: Data(contentsOf: URL(fileURLWithPath: orbsPath)))) ?? []
        list.removeAll { $0.closed == true || ($0.kind == "claude" && $0.id.isEmpty) }   // no permanent default orb
        if list != entries {
            entries = list
            dock?.orbIds = list.map(\.name)
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(entries) { try? d.write(to: URL(fileURLWithPath: orbsPath)) }
        dock?.orbIds = entries.map(\.name)
    }

    func attach(to dock: DockModel) {
        self.dock = dock
        dock.orbIds = entries.map(\.name)
        dock.orbView = { [weak self] name in
            guard let self, let e = self.entries.first(where: { $0.name == name }) else { return AnyView(EmptyView()) }
            return AnyView(SessionOrb(entry: e, main: self.main, codex: self.codex).help(self.displayName(name)))
        }
        dock.onOrbClick = { [weak self] name in self?.openTyping(name) }
        dock.onOrbDrag = { [weak self] name, phase, p in self?.drag(name, phase, p) }
        dock.onOrbMenuFor = { [weak self] name, v, p in self?.orbMenu(name).popUp(positioning: nil, at: p, in: v) }
        dock.onPlus = { [weak self] v, p in self?.plusMenu().popUp(positioning: nil, at: p, in: v) }
    }

    // MARK: keep every orb's session alive (after a crash, an error, or a restart of the Mac)

    private var reviveTimer: Timer?
    private var reviveBackoff: [String: (next: Date, wait: Double)] = [:]

    private func runStatus(_ path: String, _ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit(); return p.terminationStatus
    }

    /// Relaunch any Claude orb whose session isn't running, resuming its own conversation.
    func revive() {
        for e in entries where e.kind == "claude" && e.closed != true && !e.id.isEmpty {
            guard runStatus("/opt/homebrew/bin/tmux", ["has-session", "-t", e.name]) != 0 else {
                reviveBackoff[e.name] = nil; continue                    // running fine
            }
            if let b = reviveBackoff[e.name], Date() < b.next { continue }    // failed recently: wait
            let wait = min((reviveBackoff[e.name]?.wait ?? 15) * 2, 600)  // 30 s, 1, 2, 4, 8, 10 min
            reviveBackoff[e.name] = (Date().addingTimeInterval(wait), wait)
            FileHandle.standardError.write("revive: relaunching orb \(e.name)\n".data(using: .utf8)!)
            DispatchQueue.global().async { _ = self.app?.run(self.launcher, ["--name", e.name]) }
        }
    }

    // MARK: speak hotkeys (1st orb: left Control, 2nd: left Option, 3rd+: none unless you set one)

    /// Hotkeys follow the dock: 1st orb holds 1, 2nd holds 2 … 10th holds 0 (drag to reorder = new keys).
    static let numberKeys: [(Int, String)] = [(18, "1"), (19, "2"), (20, "3"), (21, "4"), (23, "5"),
                                              (22, "6"), (26, "7"), (28, "8"), (25, "9"), (29, "0")]
    static let notesKey = 58                          // left Option: hold to take a note, any time

    func hotkey(for e: OrbEntry) -> Hotkey? {
        guard let i = entries.firstIndex(where: { $0.name == e.name }), i < Self.numberKeys.count else { return nil }
        return Hotkey(code: Self.numberKeys[i].0, label: Self.numberKeys[i].1)
    }

    private var capturing: String? = nil            // orb waiting for "press the key you want"
    private var capturePanel: NSPanel?
    private var held: (code: Int, name: String, downEvent: CGEvent?, live: Bool)? = nil
    private var keyTap: CFMachPort?

    @objc func setHotkey(_ s: NSMenuItem) {
        guard let n = s.representedObject as? String else { return }
        capturing = n
        showCapture("Press the key to hold for “\(entries.first { $0.name == n }.map { $0.label ?? $0.name } ?? n)”",
                    "Any key works: a single modifier (right ⌘, fn…) or a key like F5. Esc cancels.")
    }

    @objc func clearHotkey(_ s: NSMenuItem) {
        guard let n = s.representedObject as? String, let i = entries.firstIndex(where: { $0.name == n }) else { return }
        entries[i].hotkey = Hotkey.none
        save()
    }

    private func finishCapture(_ key: Hotkey?) {
        defer { capturing = nil; capturePanel?.orderOut(nil); capturePanel = nil }
        guard let n = capturing, let key, let i = entries.firstIndex(where: { $0.name == n }) else { return }
        for j in entries.indices where j != i && hotkey(for: entries[j])?.code == key.code {
            entries[j].hotkey = Hotkey.none                         // a key belongs to one orb only
        }
        entries[i].hotkey = key
        save()
    }

    private func showCapture(_ title: String, _ detail: String) {
        capturePanel?.orderOut(nil)
        let screen = NSScreen.main?.frame ?? .zero
        let w: CGFloat = 420, h: CGFloat = 110
        let p = NSPanel(contentRect: NSRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.level = .popUpMenu; p.hasShadow = true
        p.contentView = NSHostingView(rootView:
            VStack(spacing: 8) {
                Image(systemName: "keyboard").font(.system(size: 22)).foregroundColor(Color(red: 1, green: 0.82, blue: 0.2))
                Text(title).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundColor(.white)
                Text(detail).font(.system(size: 11, design: .rounded)).foregroundColor(.white.opacity(0.6))
            }
            .frame(width: w, height: h)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.08).opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12)))))
        p.orderFrontRegardless()
        capturePanel = p
    }

    /// One event tap watches every orb's hotkey (and captures new ones). Needs Accessibility, which the pet has.
    func installKeyTap() {
        guard keyTap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.keyUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let c = Unmanaged<SessionsController>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = c.keyTap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            return c.handleKey(type, event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: cb, userInfo: me) else {
            FileHandle.standardError.write("hotkeys: event tap unavailable (Accessibility?)\n".data(using: .utf8)!)
            return
        }
        keyTap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Returns true to swallow the event (a bound normal key shouldn't also type).
    private func handleKey(_ type: CGEventType, _ e: CGEvent) -> Bool {
        let code = Int(e.getIntegerValueField(.keyboardEventKeycode))
        let flags = e.flags.rawValue
        if capturing == nil, e.getIntegerValueField(.eventSourceUserData) != Self.replayMark {
            if code == Self.taskKey, type != .flagsChanged { return taskKey(type, e) }
            if type == .keyDown, let d = taskDown, !taskLive {          // typing fast after a `: it was just a `
                taskDown = nil; replay(d)
            }
        }
        var down: Bool
        if type == .flagsChanged {
            guard let bit = Hotkey.modifierBits[code] else { return false }
            down = flags & bit != 0
        } else {
            down = type == .keyDown
            if type == .keyDown && e.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return held?.code == code && held?.downEvent != nil     // swallow key-repeat of a held normal hotkey
            }
        }
        if capturing != nil {                                           // assigning a new hotkey
            guard down else { return true }
            if code == 53 { DispatchQueue.main.async { self.finishCapture(nil) }; return true }   // Esc cancels
            var label = Hotkey.names[code]
            if label == nil, let ns = NSEvent(cgEvent: e), let ch = ns.charactersIgnoringModifiers, !ch.isEmpty {
                label = ch.uppercased()
            }
            let key = Hotkey(code: code, label: label ?? "Key \(code)")
            DispatchQueue.main.async { self.finishCapture(key) }
            return true
        }
        if e.getIntegerValueField(.eventSourceUserData) == Self.replayMark { return false }   // our own replayed key
        // Another key while a hotkey is down: it's a shortcut (Ctrl-C) or typing, not talking.
        if type == .keyDown, let h = held, h.code != code, !h.live || h.downEvent == nil {   // (a held modifier + key is always a shortcut)
            held = nil
            SpeakerMute.end()
            post5123("/ptt", ["cancel": "1"])
            if let d = h.downEvent {                                     // a normal key we held back: type it, then this one
                replay(d); replay(e); return true
            }
            return false
        }
        let who: (name: String, kind: String)? = code == Self.notesKey ? ("__notes__", "notes")
            : entries.first(where: { hotkey(for: $0)?.code == code }).map { ($0.name, $0.kind) }
        if down, held == nil, let e2 = who {
            if type == .flagsChanged, flags & 0x1E0000 & ~Self.ownMask(code) != 0 { return false }  // part of a chord
            let modifier = type == .flagsChanged
            held = (code, e2.name, modifier ? nil : e.copy(), false)
            // start the mic now (so the first word isn't clipped); it only counts as talking once held a moment
            post5123("/ptt", ["name": e2.name, "kind": e2.kind, "down": "1"])
            let stamp = code
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay) { [weak self] in
                if let self, let h = self.held, h.code == stamp { self.held?.live = true; SpeakerMute.begin() }
            }
            return !modifier                                            // a normal key is held back until we know
        }
        if !down, let h = held, h.code == code {
            held = nil
            SpeakerMute.end()
            if h.live {
                post5123("/ptt", ["name": h.name, "down": ""])
            } else {                                                    // a tap: the key keeps its normal job
                post5123("/ptt", ["cancel": "1"])
                if let d = h.downEvent { replay(d); replay(e) }
            }
            return type != .flagsChanged
        }
        return type != .flagsChanged && held?.code == code              // swallow repeats of a held normal key
    }

    private static let holdDelay = 0.3

    // MARK: hold ` : task board (opens it and records while held; a quick tap still types `)
    static let taskKey = 50
    private var taskDown: CGEvent? = nil, taskLive = false

    private func taskKey(_ type: CGEventType, _ e: CGEvent) -> Bool {
        if type == .keyDown {
            if e.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return taskDown != nil || taskLive }
            if e.flags.rawValue & 0x1E0000 != 0 { return false }       // ⌘` (switch windows), ~ and the like
            taskDown = e.copy(); taskLive = false
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay) { [weak self] in
                guard let self, self.taskDown != nil else { return }
                self.taskDown = nil; self.taskLive = true
                self.app?.taskBoard.hold(true)
            }
            return true
        }
        if taskLive { taskLive = false; DispatchQueue.main.async { self.app?.taskBoard.hold(false) }; return true }
        if let d = taskDown { taskDown = nil; replay(d); replay(e); return true }   // a tap: type it
        return false
    }
    private static let replayMark: Int64 = 0x564F4943                   // "VOIC"

    /// Re-send a key event we held back, marked so our own tap lets it through.
    private func replay(_ ev: CGEvent) {
        guard let c = ev.copy() else { return }
        c.setIntegerValueField(.eventSourceUserData, value: Self.replayMark)
        c.post(tap: .cgSessionEventTap)
    }

    /// The generic modifier mask a modifier key itself sets (so we only treat *other* modifiers as a chord).
    private static func ownMask(_ code: Int) -> UInt64 {
        switch code {
        case 58, 61: return 0x80000     // ⌥
        case 59, 62: return 0x40000     // ⌃
        case 56, 60: return 0x20000     // ⇧
        case 55, 54: return 0x100000    // ⌘
        default: return 0
        }
    }

    // MARK: talking to a session

    /// Your voice now goes to this session.
    func select(_ name: String) {
        guard let e = entries.first(where: { $0.name == name }) else { return }
        if e.kind == "codex", codex.s.thread_id != e.id { codexPost("/sessions/resume", ["session": e.id]) }
        post5123("/target", ["name": e.name, "kind": e.kind])
    }

    // MARK: menus

    private func item(_ title: String, _ action: Selector?, _ rep: Any? = nil, enabled: Bool = true) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self; i.representedObject = rep; i.isEnabled = enabled && action != nil
        return i
    }

    func plusMenu() -> NSMenu {
        let m = NSMenu(); m.autoenablesItems = false
        m.addItem(item("Search sessions…", #selector(openSearch)))
        m.addItem(.separator())
        m.addItem(item("New Claude session", #selector(newClaude)))
        m.addItem(item("New Claude session in folder…", #selector(newClaudeInFolder)))
        m.addItem(item("New orb with custom command…", #selector(newCustom)))
        m.addItem(.separator())
        m.addItem(item("New Codex session", #selector(newCodex), enabled: codex.online))
        m.addItem(item("New Codex session in folder…", #selector(newCodexInFolder), enabled: codex.online))
        if !codex.online { m.addItem(item("Codex voice server isn't running", nil, enabled: false)) }
        return m
    }

    func orbMenu(_ name: String) -> NSMenu {
        let m = NSMenu(); m.autoenablesItems = false
        guard let e = entries.first(where: { $0.name == name }), let app else { return m }
        // header: whose menu this is, and how to talk to it
        let h = item((e.kind == "codex" ? "Codex · " : "Claude · ") + (OrbNames.get(e.id) ?? e.label ?? sessionName(e)), nil, enabled: false)
        let folder = URL(fileURLWithPath: e.cwd).lastPathComponent
        h.subtitle = ([folder, lastModel(e)].filter { !$0.isEmpty }.joined(separator: " · "))
            + " · " + (hotkey(for: e).map { "hold \($0.label) to talk" } ?? "no hotkey") + " · hold left ⌥ for a note"
        h.toolTip = e.cwd
        m.addItem(h)
        m.addItem(.separator())
        app.addNotesItems(to: m)
        m.addItem(.separator())

        // this orb
        m.addItem(app.menuItem("Stop current task", "stop", #selector(stopTask(_:)), target: self).with(name))
        let muted = e.kind == "codex" ? (codex.s.thread_id == e.id && codex.s.muted) : main.s.muted_sessions.contains(name)
        m.addItem(app.menuItem("Mute replies", "speaker.slash", #selector(toggleMute(_:)), on: muted,
                               tip: "Show this orb's replies as text instead of speaking them", target: self).with(name))
        m.addItem(app.canvasItem())
        m.addItem(app.menuItem("Rename…", "pencil", #selector(rename(_:)), target: self).with(name))
        let more = NSMenu(); more.autoenablesItems = false
        more.addItem(app.menuItem("Open transcript", "doc.text", #selector(transcript(_:)), target: self).with(name))
        if e.kind == "claude" {
            more.addItem(app.menuItem("Show in Terminal", "terminal", #selector(showTerminal(_:)), target: self).with(name))
        }
        if e.kind == "codex", codex.s.thread_id == e.id {
            more.addItem(app.menuItem("Codex auto mode", "bolt", #selector(codexAuto), on: codex.s.auto, target: self))
        }
        let mo = app.menuItem("More", "ellipsis.circle", nil, target: self); mo.submenu = more
        m.addItem(mo)
        m.addItem(app.menuItem("Close session", "xmark", #selector(close(_:)), target: self).with(name))
        m.addItem(.separator())

        app.addGeneralItems(to: m)                                  // meetings, task boards, voice, screen, quit
        return m
    }

    /// The model this orb's conversation last ran on, from the end of its transcript (cheap: last 64 KB).
    private func lastModel(_ e: OrbEntry) -> String {
        guard e.kind == "claude", !e.id.isEmpty else { return "" }
        let root = NSHomeDirectory()
        let dirs = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).filter { $0.hasPrefix(".claude") }
        for d in dirs {
            let projects = root + "/" + d + "/projects"
            for p in (try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? [] {
                let f = projects + "/" + p + "/" + e.id + ".jsonl"
                guard let h = FileHandle(forReadingAtPath: f) else { continue }
                defer { try? h.close() }
                let end = (try? h.seekToEnd()) ?? 0
                try? h.seek(toOffset: end > 65536 ? end - 65536 : 0)
                let tail = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
                let models = tail.components(separatedBy: "\"model\":\"").dropFirst()
                    .compactMap { $0.split(separator: "\"").first.map(String.init) }.filter { $0 != "<synthetic>" }
                return models.last.map { $0.components(separatedBy: "/").last ?? $0 } ?? ""
            }
        }
        return ""
    }

    private func sessionName(_ e: OrbEntry) -> String {
        app?.voiceSessions()?.sessions.first { $0.id == e.id }?.name ?? URL(fileURLWithPath: e.cwd).lastPathComponent
    }

    // MARK: actions

    // MARK: drag an orb along the dock to reorder (saved; hotkey defaults follow the position)

    private var dragFrames: [String: NSRect] = [:]

    func drag(_ name: String, _ phase: Int, _ p: NSPoint) {
        guard let dock else { return }
        switch phase {
        case 0:
            dock.draggingId = name
            dragFrames = Dictionary(uniqueKeysWithValues: entries.compactMap { e in
                OrbAnchors.shared.screenRect(e.name).map { (e.name, $0) } })      // slots as they were
        case 1:
            let others = entries.map(\.name).filter { $0 != name }
            let slots = entries.compactMap { dragFrames[$0.name]?.midX }.sorted()
            guard !slots.isEmpty else { return }
            let target = slots.filter { $0 < p.x }.count                          // which slot the cursor is over
            var order = others
            order.insert(name, at: min(max(target, 0), order.count))
            if order != entries.map(\.name) {
                let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                    entries = order.compactMap { byName[$0] }
                    dock.orbIds = order
                }
            }
        default:
            dock.draggingId = nil
            dragFrames = [:]
            save()
        }
    }

    let typeBox = TypeBox()
    lazy var search: SessionSearch = {
        let s = SessionSearch()
        s.runSearch = { [weak self] q in
            guard let self, let app = self.app else { return [] }
            let out = app.run("/usr/bin/python3", [app.voiceDir + "/orb_search.py", q])
            return (try? JSONDecoder().decode([SearchHit].self, from: Data(out.utf8))) ?? []
        }
        s.m.onPick = { [weak self] h in self?.resumeFromSearch(h) }
        return s
    }()

    @objc func openSearch() { search.open(openIds: Set(entries.map(\.id))) }

    /// A search result: bring its orb forward if it's already open, else open a new orb resuming it.
    private func resumeFromSearch(_ h: SearchHit) {
        search.close()
        if let e = entries.first(where: { $0.id == h.id }) { select(e.name); return }
        if h.kind == "claude" {
            let cmd = (h.command ?? "").isEmpty ? [] : ["--cmd", h.command!]   // its own command (e.g. OpenRouter)
            startClaude(newClaudeName(), ["--resume", h.id, "--cwd", h.cwd] + cmd)
        } else {
            let name = entries.contains(where: { $0.name == "codex" }) ? nextName("codex") : "codex"
            entries.append(OrbEntry(name: name, kind: "codex", id: h.id, cwd: h.cwd, label: h.name ?? h.title))
            save()
            select(name)                                               // switches the Codex server to it
        }
    }

    /// The first orb in the dock: the corner orb acts for it outside OS mode.
    var firstName: String? { entries.first?.name }

    /// Click an orb: a small field opens above it to type a message to that session.
    func openTyping(_ name: String) {
        guard let e = entries.first(where: { $0.name == name }) else { return }
        if e.kind == "codex", codex.s.thread_id != e.id { codexPost("/sessions/resume", ["session": e.id]) }
        app?.bubbles[e.name]?.0.dismissAll()                          // the field takes the bubble's place
        // anchor above the orb itself: its dock spot in OS mode, else the corner orb (fall back to the mouse)
        let orb = OrbAnchors.shared.screenRect(e.name) ?? app?.orbPanels.first.map { $0.frame }
        let anchor = orb.map { NSPoint(x: $0.midX, y: $0.maxY) } ?? NSEvent.mouseLocation
        typeBox.open(above: anchor, name: e.name, kind: e.kind, title: "To " + displayName(e.name))
    }


    private func nextName(_ base: String) -> String {
        var i = 2
        while entries.contains(where: { $0.name == "\(base)-\(i)" }) { i += 1 }
        return "\(base)-\(i)"
    }

    private func newClaudeName() -> String { entries.contains { $0.name == "voice" } ? nextName("voice") : "voice" }
    @objc func newClaude() { startClaude(newClaudeName(), ["--fresh"]) }
    @objc func newClaudeInFolder() { if let f = pickFolder("New Claude voice session in folder") { startClaude(newClaudeName(), ["--fresh", "--cwd", f]) } }

    /// Your own terminal command instead of `claude` (claude-openrouter, claude --model …, an alias…).
    @objc func newCustom() {
        let a = NSAlert()
        a.messageText = "New orb with a custom command"
        a.informativeText = "The command you'd type in Terminal to start the agent, e.g. claude-openrouter or claude --model opus. "
            + "The orb adds its voice options to it, and keeps using it when it relaunches or resumes."
        let box = NSStackView(frame: NSRect(x: 0, y: 0, width: 320, height: 58))
        box.orientation = .vertical; box.alignment = .leading; box.spacing = 8
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        f.placeholderString = "claude-openrouter"
        f.stringValue = UserDefaults.standard.string(forKey: "lastCustomCommand") ?? ""
        let folder = NSButton(checkboxWithTitle: "Choose a folder for it", target: nil, action: nil)
        box.addArrangedSubview(f); box.addArrangedSubview(folder)
        a.accessoryView = box
        a.addButton(withTitle: "Start"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let cmd = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        UserDefaults.standard.set(cmd, forKey: "lastCustomCommand")
        var args = ["--fresh", "--cmd", cmd]
        if folder.state == .on {
            guard let dir = pickFolder("Folder for “\(cmd)”") else { return }
            args += ["--cwd", dir]
        }
        startClaude(newClaudeName(), args)
    }

    private func startClaude(_ name: String, _ args: [String]) {
        DispatchQueue.global().async {
            _ = self.app?.run(self.launcher, ["--name", name] + args)
            DispatchQueue.main.async { self.load(); self.select(name) }
        }
    }

    @objc func newCodex() { startCodex(nil) }
    @objc func newCodexInFolder() { if let f = pickFolder("New Codex voice session in folder") { startCodex(f) } }

    private func startCodex(_ cwd: String?) {
        var body: [String: String] = [:]
        if let cwd { body["cwd"] = cwd }
        codexPost("/sessions/new", body) { [weak self] result in
            guard let self, let id = result?["id"] as? String else { return }
            let name = self.entries.contains(where: { $0.name == "codex" }) ? self.nextName("codex") : "codex"
            self.entries.append(OrbEntry(name: name, kind: "codex", id: id, cwd: result?["cwd"] as? String ?? cwd ?? "",
                                         label: result?["name"] as? String))
            self.save()
            self.post5123("/target", ["name": name, "kind": "codex"])
        }
    }

    @objc func transcript(_ s: NSMenuItem) {
        guard let n = s.representedObject as? String, let e = entries.first(where: { $0.name == n }) else { return }
        if let app {
            let path = app.run("/usr/bin/python3", [app.voiceDir + "/voice_sessions.py", "transcript", e.id, e.kind])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        }
    }

    @objc func rename(_ s: NSMenuItem) {
        guard let n = s.representedObject as? String, let e = entries.first(where: { $0.name == n }) else { return }
        let a = NSAlert()
        a.messageText = "Name this orb"
        a.informativeText = "Shown in its menu, reply cards, Resume and Search, instead of its first message. Leave empty to clear."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        f.stringValue = OrbNames.get(e.id) ?? ""
        f.placeholderString = sessionName(e)
        a.accessoryView = f
        a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        OrbNames.set(e.id, f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        if let dock { let ids = dock.orbIds; dock.orbIds = []; dock.orbIds = ids }   // redraw with the new name
    }

    @objc func showTerminal(_ s: NSMenuItem) {
        if let n = s.representedObject as? String { post5123("/claude/show?s=\(n)", [:]) }
    }

    @objc func stopTask(_ s: NSMenuItem) {
        guard let n = s.representedObject as? String, let e = entries.first(where: { $0.name == n }) else { return }
        if e.kind == "codex" { codexPost("/stop", [:]) } else { post5123("/claude/stop?s=\(n)", [:]) }
    }

    @objc func codexAuto() { codex.toggleAuto() }

    @objc func toggleMute(_ s: NSMenuItem) {
        guard let n = s.representedObject as? String, let e = entries.first(where: { $0.name == n }) else { return }
        if e.kind == "codex" {
            codexPostAny("/mute", ["on": !codex.s.muted])
        } else {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:5123/mute")!)
            req.httpMethod = "POST"; req.timeoutInterval = 2
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["session": n, "on": !main.s.muted_sessions.contains(n)])
            URLSession.shared.dataTask(with: req).resume()
        }
    }

    /// Display name for a session's reply card header.
    func displayName(_ session: String) -> String {
        if session == SelectionReader.session { return "Reading selection" }
        guard let e = entries.first(where: { $0.name == session }) else { return session }
        return (e.kind == "codex" ? "Codex · " : "Claude · ") + (OrbNames.get(e.id) ?? e.label ?? URL(fileURLWithPath: e.cwd).lastPathComponent)
    }

    /// Close: ends the session and removes its orb (the default Claude orb restarts fresh instead).
    @objc func close(_ s: NSMenuItem) {
        guard let n = s.representedObject as? String, let e = entries.first(where: { $0.name == n }) else { return }
        if e.kind == "claude" { post5123("/claude/quit?s=\(n)", [:]) }
        if e.kind == "codex", codex.s.thread_id == e.id { codexPost("/stop", [:]) }
        entries.removeAll { $0.name == n }                            // every orb is removable
        save()
        if main.s.target == n, let first = entries.first { select(first.name) }
    }

    private func pickFolder(_ title: String) -> String? {
        let p = NSOpenPanel()
        p.title = title; p.prompt = "Start session"
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        return p.runModal() == .OK ? p.url?.path : nil
    }

    // MARK: Codex approvals (shown here, so Codex's own pet isn't needed)

    func checkApproval() {
        let s = codex.s
        guard s.approval, s.approvalMethod != "item/tool/requestUserInput", s.approvalId != promptedApproval, !approvalOpen else { return }
        promptedApproval = s.approvalId
        approvalOpen = true
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Codex needs your approval"
            alert.informativeText = s.approvalDetail
            alert.addButton(withTitle: "Approve"); alert.addButton(withTitle: "Deny"); alert.addButton(withTitle: "Close")
            NSApp.activate(ignoringOtherApps: true)
            let r = alert.runModal()
            self.approvalOpen = false
            if r == .alertFirstButtonReturn { self.codexPostAny("/approval", ["request_id": s.approvalId, "decision": "approve"]) }
            else if r == .alertSecondButtonReturn { self.codexPostAny("/approval", ["request_id": s.approvalId, "decision": "deny"]) }
        }
    }

    /// Codex's separate orb isn't needed any more: switch its launch agent off (reversible with launchctl enable).
    private func retireCodexPet() {
        DispatchQueue.global().async {
            let uid = getuid()
            _ = self.app?.run("/bin/launchctl", ["bootout", "gui/\(uid)/com.kush.codex-voice-pet"])
            _ = self.app?.run("/bin/launchctl", ["disable", "gui/\(uid)/com.kush.codex-voice-pet"])
        }
        UserDefaults.standard.removeObject(forKey: "osPausedOtherPet")   // OS mode must not bring it back
    }

    // MARK: HTTP helpers

    struct CodexSession: Decodable { let id: String; let name: String; let cwd: String }
    struct CodexSessionList: Decodable { let active: String?; let sessions: [CodexSession] }

    private func codexSessions() -> [CodexSession] {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:5124/sessions")!)
        codex.authorize(&req); req.timeoutInterval = 1.5
        var out: [CodexSession] = []
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, _, _ in
            out = d.flatMap { try? JSONDecoder().decode(CodexSessionList.self, from: $0) }?.sessions ?? []
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 2)
        return out
    }

    private func post5123(_ path: String, _ body: [String: String]) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:5123" + path)!)
        req.httpMethod = "POST"; req.timeoutInterval = 2
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
    }

    private func codexPost(_ path: String, _ body: [String: String], done: (([String: Any]?) -> Void)? = nil) {
        codexPostAny(path, body, done: done)
    }

    private func codexPostAny(_ path: String, _ body: [String: Any], done: (([String: Any]?) -> Void)? = nil) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:5124" + path)!)
        codex.authorize(&req)
        req.httpMethod = "POST"; req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { d, _, _ in
            let r = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async { done?(r) }
        }.resume()
    }
}

extension NSMenuItem {
    /// Attach the orb this item acts on.
    func with(_ rep: Any?) -> NSMenuItem { representedObject = rep; return self }
}
