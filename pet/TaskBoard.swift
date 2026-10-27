// Task board: a card you talk to. Hit record, say your tasks (or anything); your words appear as you speak.
// Then tell Mercury what to do with them ("lab work at the top, personal at the bottom", "make it concise")
// and the card flips to its version. Flip back to see what you actually said and try a different prompt —
// every prompt starts from your own words, never from the last result. Each card is its own board on screen:
// + or holding ` opens another; ✕ only hides one (the pet's "Task board" menu item brings them all back);
// the trash deletes that card. Pin the pointer in the top-left corner for a quick look: every card, hidden
// ones too, laid out in a grid until you click somewhere else or leave them alone for a few seconds.
import AppKit
import SwiftUI

struct TaskView: Equatable {
    var recording = false, ready = false, started = 0.0, transcribing = false, busy = false
    var otherRecording = false                  // another card has the mic
    var live = "", original = "", ai = "", prompt = ""
}

struct ServerCard: Decodable { let id: String; let original: String; let ai: String; let prompt: String; let busy: Bool; let hidden: Bool }
struct ServerRec: Decodable { let recording: Bool; let ready: Bool; let started: Double; let live: String; let transcribing: Bool; let card: String }
struct ServerTasks: Decodable { let rec: ServerRec; let cards: [ServerCard] }

final class TaskBoardModel: ObservableObject {
    @Published var v = TaskView()
    @Published var shown = false
    @Published var flipped = false              // showing Mercury's version
    static let defaultPrompt = "organize this into what to do"
    @Published var prompt = TaskBoardModel.defaultPrompt   // ready to send, never sent on its own
    @Published var sent = false                 // a prompt is out: flip when its answer lands
    @Published var editing = ""                 // "original" / "ai" while you edit that side
    @Published var draft = ""
    var onSaveEdit: () -> Void = {}
    func edit(_ side: String) {
        if editing == side { onSaveEdit(); return }                // the checkmark: save
        draft = side == "ai" ? v.ai : v.original; editing = side
    }
    var onClose: () -> Void = {}
    var onRecord: () -> Void = {}
    var onAsk: () -> Void = {}
    var onDelete: () -> Void = {}
    var onNew: () -> Void = {}
}

struct TaskBoardView: View {
    @ObservedObject var m: TaskBoardModel
    var measuring = false                        // laid out off-screen, unscrolled, to find the size that fits it all
    @State private var hover = false
    @State private var now = Date()
    let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        if measuring { (m.flipped ? AnyView(back) : AnyView(front)).fixedSize(horizontal: false, vertical: true) }
        else { live }
    }

    private var live: some View {
        ZStack {
            front.opacity(m.flipped ? 0 : 1)
            back.opacity(m.flipped ? 1 : 0)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))   // reads the right way round once flipped
        }
        .rotation3DEffect(.degrees(m.flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
        .animation(.spring(response: 0.55, dampingFraction: 0.86), value: m.flipped)
        .frame(minWidth: 260, maxWidth: .infinity, minHeight: 90, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottomTrailing) {                     // resize grip (the edges resize too)
            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 7, weight: .bold))
                .foregroundColor(.white.opacity(0.2)).padding(6)
        }
        .scaleEffect(m.shown ? 1 : 0.92, anchor: .topTrailing)
        .opacity(m.shown ? 1 : 0)
        .animation(m.shown ? OSMotion.show : .easeInOut(duration: 0.35), value: m.shown)
        .onReceive(tick) { now = $0 }
        .onHover { h in hover = h }
    }

    @ViewBuilder private func scroll<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        if measuring { c() } else { ScrollView { c() } }
    }

    private func card<H: View, C: View>(_ head: H, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, maxHeight: measuring ? nil : .infinity, alignment: .top)
            .overlay(alignment: .top) { if !measuring { header(head) } }
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.07).opacity(0.96))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 1)))
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var status: String {
        let v = m.v
        if v.recording && !v.ready { return "Starting mic…" }
        if v.recording {
            let s = Int(max(0, now.timeIntervalSince1970 - v.started))
            return String(format: "Recording · %d:%02d", s / 60, s % 60)
        }
        if v.transcribing { return "Writing it down…" }
        return v.original.isEmpty ? "Tasks" : "What you said"
    }

    // MARK: front — your own words

    private var front: some View {
        card(frontHeader) {
            Color.clear.frame(height: 12)                    // the header only shows on hover (over the top)

            scroll {
                VStack(alignment: .leading, spacing: 8) {
                    if m.editing == "original" { editor }
                    else if !m.v.original.isEmpty { bodyText(m.v.original, opacity: 0.92) }
                    if m.v.recording && !m.v.live.isEmpty { bodyText(m.v.live, opacity: 0.6) }   // still being said
                    if m.v.original.isEmpty && m.v.live.isEmpty {
                        Text(m.v.recording ? "Listening… your words show up in a few seconds."
                             : m.v.transcribing ? "" : "Hold ` (or hit record) and say your tasks.")
                            .font(.system(size: 12, design: .rounded)).foregroundColor(.white.opacity(0.35))
                    }
                    if m.v.transcribing { ProgressView().controlSize(.small).scaleEffect(0.7, anchor: .leading) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.horizontal, 14).padding(.bottom, 10)
                .animation(OSMotion.show, value: m.v.live)
            }

            HStack(spacing: 8) {
                Button(action: m.onRecord) {                                 // record / stop
                    Image(systemName: m.v.recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(m.v.recording ? .white : .white.opacity(0.75))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(m.v.recording && m.v.ready ? Color.red.opacity(0.85) : Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain).disabled(m.v.transcribing || m.v.otherRecording)
                .opacity(m.v.otherRecording ? 0.35 : 1)
                .help(m.v.recording ? "Stop recording" : (m.v.original.isEmpty ? "Record" : "Record more (adds to it)"))

                HStack(spacing: 6) {                                         // what Mercury should do with it
                    Image(systemName: "sparkles").font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.4))
                    TextField(m.v.ai.isEmpty ? "e.g. lab work at top, personal at bottom" : "Try a different prompt",
                              text: $m.prompt)
                        .textFieldStyle(.plain).font(.system(size: 12, design: .rounded)).foregroundColor(.white.opacity(0.9))
                        .onSubmit { m.onAsk() }
                    if m.v.busy { ProgressView().controlSize(.small).scaleEffect(0.6) }
                    else {
                        iconButton("arrow.up", "Send to Mercury", m.onAsk)
                            .opacity(canAsk ? 1 : 0.4)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.07)))
                .opacity(m.v.original.isEmpty ? 0.5 : 1)
            }
            .padding(.horizontal, 10).padding(.bottom, 10)
        }
    }

    // the card's header: hidden until you hover the card, then it slides in over the top
    private var frontHeader: some View {
        HStack(spacing: 7) {
            Circle().fill(m.v.recording && m.v.ready ? Color.red : Color.white.opacity(0.25)).frame(width: 6, height: 6)
                .opacity(m.v.recording ? (Int(now.timeIntervalSince1970) % 4 < 2 ? 0.9 : 0.45) : 1)
                .animation(.easeInOut(duration: 1.2), value: Int(now.timeIntervalSince1970))
            Text(status).font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.55)).monospacedDigit().lineLimit(1)
            Spacer()
            if !m.v.original.isEmpty && !m.v.recording && !m.v.transcribing { editButton("original") }
            if !m.v.recording && !m.v.transcribing && m.editing.isEmpty {
                iconButton("trash", "Delete this card", m.onDelete)
            }
            iconButton("plus", "New card (this one stays)", m.onNew)
            if !m.v.ai.isEmpty { iconButton("arrow.triangle.2.circlepath", "Show Mercury's version") { if !m.editing.isEmpty { m.onSaveEdit() }; m.flipped = true } }
            iconButton("xmark", "Hide (the pet's Task board menu brings it back)", m.onClose)
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
    }

    private var backHeader: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkles").font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.45))
            Text(m.v.prompt.isEmpty ? "Mercury" : m.v.prompt).font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.55)).lineLimit(1).truncationMode(.tail)
            Spacer()
            editButton("ai")
            iconButton("doc.on.doc", "Copy") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(m.v.ai, forType: .string)
            }
            iconButton("arrow.triangle.2.circlepath", "Back to what you said (write a new prompt there)") { if !m.editing.isEmpty { m.onSaveEdit() }; m.flipped = false }
            iconButton("xmark", "Hide (the pet's Task board menu brings it back)", m.onClose)
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)
    }

    private func header<H: View>(_ h: H) -> some View {
        h.background(LinearGradient(stops: [.init(color: Color(white: 0.07), location: 0),      // solid behind the icons,
                                             .init(color: Color(white: 0.07), location: 0.78),   // then a short fade
                                             .init(color: Color(white: 0.07).opacity(0), location: 1)],
                                    startPoint: .top, endPoint: .bottom).padding(.bottom, -10))
            .opacity(hover || !m.editing.isEmpty ? 1 : 0)
            .offset(y: hover || !m.editing.isEmpty ? 0 : -6)
            .animation(OSMotion.show, value: hover)
    }

    private var canAsk: Bool {
        !m.prompt.trimmingCharacters(in: .whitespaces).isEmpty && !m.v.original.isEmpty && !m.v.busy
    }

    // MARK: back — Mercury's version

    private var back: some View {
        card(backHeader) {
            Color.clear.frame(height: 12)

            scroll {
                VStack(alignment: .leading, spacing: 4) {
                    if m.editing == "ai" { editor }
                    else {
                        ForEach(Array(m.v.ai.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            aiLine(line)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
    }

    /// Mercury's plain text as a list: # topics, ## subtopics, and bullets nested by their indentation.
    @ViewBuilder private func aiLine(_ raw: String) -> some View {
        let lead = raw.prefix { $0 == " " || $0 == "\t" }
        let depth = min(4, lead.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) } / 2)
        let line = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "**", with: "")
        let number = line.range(of: #"^\d+[.)] "#, options: .regularExpression)
        if line.isEmpty {
            Color.clear.frame(height: 4)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") || number != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let n = number {
                    Text(line[n].trimmingCharacters(in: .whitespaces)).font(.system(size: depth == 0 ? 12 : 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.4)).monospacedDigit()
                } else if depth == 0 {
                    Circle().fill(Color.white.opacity(0.35)).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                } else {
                    Circle().stroke(Color.white.opacity(0.3), lineWidth: 1).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                }
                Text(number.map { String(line[$0.upperBound...]) } ?? String(line.dropFirst(2)))
                    .font(.system(size: depth == 0 ? 13 : 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(depth == 0 ? 0.92 : 0.75)).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 16)
        } else if line.hasPrefix("##") {                                    // subtopic
            Text(line.trimmingCharacters(in: CharacterSet(charactersIn: "#: ")))
                .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.7))
                .padding(.top, 4).padding(.leading, CGFloat(depth) * 16)
        } else if line.hasPrefix("#") || (line.hasSuffix(":") && line.count < 40) {   // topic
            Text(line.trimmingCharacters(in: CharacterSet(charactersIn: "#: ")))
                .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(.white.opacity(0.5))
                .textCase(.uppercase).padding(.top, 8)
        } else {
            bodyText(line, opacity: 0.92).padding(.leading, CGFloat(depth) * 16)
        }
    }

    private func bodyText(_ s: String, opacity: Double) -> some View {
        Text(s).font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundColor(.white.opacity(opacity)).lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var editor: some View {
        TextEditor(text: $m.draft)
            .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.92))
            .scrollContentBackground(.hidden).lineSpacing(2)
            .frame(minHeight: 160)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
    }

    private func editButton(_ side: String) -> some View {
        iconButton(m.editing == side ? "checkmark" : "pencil", m.editing == side ? "Save your edit" : "Edit") { m.edit(side) }
    }

    private func iconButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 8, weight: .bold)).foregroundColor(.white.opacity(0.55))
                .frame(width: 16, height: 16).background(Circle().fill(Color.white.opacity(0.08)))
        }.buttonStyle(.plain).help(help)
    }
}

/// Every card on screen: polls the voice server and keeps one window per card in step with it.
final class TaskBoard: NSObject {
    private var boards: [String: TaskCardWindow] = [:]
    private var order: [String] = []             // oldest first, as the server keeps them
    private var hiddenIDs: Set<String> = []
    private var timer: Timer?
    var enabled: Bool { boards.values.contains { $0.m.shown } }   // the menu's checkmark

    func restore() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        poll()
        startCornerWatch()
    }

    // MARK: quick look (top-left corner, like Pane's top-right one)

    private var peeking = false
    private var peekActive = Date()              // last time the pointer was on a card (or the corner)
    private var peekTimer: Timer?
    private var monitors: [Any] = []
    private static let peekLinger: TimeInterval = 6

    private func startCornerWatch() {
        guard monitors.isEmpty else { return }
        for mask in [NSEvent.EventTypeMask.mouseMoved, .leftMouseDragged] {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.mouseMoved() }) {
                monitors.append(m)
            }
        }
        // a click anywhere else ends it (our own clicks on a card never reach a global monitor)
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            guard let self, self.peeking, !self.pointerOnCard() else { return }
            self.endPeek()
        }) { monitors.append(m) }
    }

    private func mouseMoved() {
        if Self.pointerInCorner() {
            if !peeking { startPeek() }
            peekActive = Date()
        }
    }

    private static func pointerInCorner() -> Bool {
        let p = NSEvent.mouseLocation
        guard let f = (NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main)?.frame else { return false }
        return p.x <= f.minX + 1 && p.y >= f.maxY - 1              // pinned in the corner, not just near it
    }

    private func pointerOnCard() -> Bool {
        let p = NSEvent.mouseLocation
        return boards.values.contains { $0.m.shown && ($0.frame?.contains(p) ?? false) }
    }

    private func startPeek() {
        let ids = order.filter { boards[$0] != nil }
        guard !ids.isEmpty else { return }
        peeking = true; peekActive = Date()
        let p = NSEvent.mouseLocation
        let s = (NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        // each card at the size that shows all of it, laid out in rows from the top-left
        let gap: CGFloat = 12, margin: CGFloat = 16
        let maxW = min(460, s.width - 2 * margin), maxH = s.height - 2 * margin
        var x = s.minX + margin, top = s.maxY - margin, rowH: CGFloat = 0
        for id in ids {
            guard let b = boards[id] else { continue }
            let f = b.fittingSize(maxWidth: maxW)
            let w = f.width, h = min(maxH, f.height)
            if x + w > s.maxX - margin && x > s.minX + margin {      // no room left in this row: start the next
                x = s.minX + margin; top -= rowH + gap; rowH = 0
            }
            b.peek(to: NSRect(x: x, y: top - h, width: w, height: h))
            x += w + gap; rowH = max(rowH, h)
        }
        peekTimer?.invalidate()
        peekTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.pointerOnCard() || Self.pointerInCorner() { self.peekActive = Date() }
            if Date().timeIntervalSince(self.peekActive) > Self.peekLinger { self.endPeek() }
        }
    }

    private func endPeek() {
        guard peeking else { return }
        peeking = false
        peekTimer?.invalidate(); peekTimer = nil
        for (id, b) in boards { b.unpeek(hidden: hiddenIDs.contains(id)) }
    }

    /// The pet's menu: every card back on screen (a new empty one if there are none).
    func toggle() { post("/task/showall") }

    /// Hold `: a fresh card comes up and records until you let go; it stays open with what you said.
    func hold(_ down: Bool) { post("/task/record", ["text": down ? "new" : "stop"]) }

    func post(_ path: String, _ body: [String: String] = [:]) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:5123" + path)!)
        req.httpMethod = "POST"; req.timeoutInterval = 12
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            DispatchQueue.main.async { self?.apply(data) }
        }.resume()
    }

    private func poll() {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:5123/task")!)
        req.timeoutInterval = 1.5
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            DispatchQueue.main.async { self?.apply(data) }
        }.resume()
    }

    private func apply(_ data: Data?) {
        guard let data, let t = try? JSONDecoder().decode(ServerTasks.self, from: data) else { return }
        let ids = Set(t.cards.map(\.id))
        for (id, b) in boards where !ids.contains(id) { b.close(); boards[id] = nil }   // deleted
        order = t.cards.map(\.id)
        hiddenIDs = Set(t.cards.filter(\.hidden).map(\.id))
        for c in t.cards {
            let mine = t.rec.card == c.id
            var v = TaskView()
            v.original = c.original; v.ai = c.ai; v.prompt = c.prompt; v.busy = c.busy
            v.recording = mine && t.rec.recording; v.ready = mine && t.rec.ready; v.started = t.rec.started
            v.transcribing = mine && t.rec.transcribing; v.live = mine ? t.rec.live : ""
            v.otherRecording = t.rec.recording && !mine
            let b = boards[c.id] ?? {
                let b = TaskCardWindow(id: c.id, board: self, place: boards.count)
                boards[c.id] = b
                return b
            }()
            b.update(v)
            if peeking { continue }                                  // the quick look decides what's showing
            if c.hidden { b.hide() } else if !b.m.shown { b.show() }
        }
    }
}

/// One card's window.
final class TaskCardWindow: NSObject, NSWindowDelegate {
    let id: String
    let m = TaskBoardModel()
    private weak var board: TaskBoard?
    private var panel: CanvasPanel?
    private var sawBusy = false                  // the server picked up the prompt (ignores polls sent before it)
    private let place: Int                       // where a brand-new card goes: stepped off the others
    private var frameKey: String { "taskCardFrame." + id }

    init(id: String, board: TaskBoard, place: Int) {
        self.id = id; self.board = board; self.place = place
        super.init()
        m.onClose = { [weak self] in
            guard let self else { return }
            if self.m.v.recording { self.post("/task/record", ["text": "stop"]) }   // keeps what was said
            self.hide(); self.post("/task/hide")
        }
        m.onDelete = { [weak self] in self?.post("/task/delete") }
        m.onNew = { [weak self] in
            if let self, !self.m.editing.isEmpty { self.m.onSaveEdit() }
            self?.post("/task/new")
        }
        m.onRecord = { [weak self] in
            guard let self else { return }
            if !self.m.editing.isEmpty { self.m.onSaveEdit() }       // keep your edit, then record more
            self.m.flipped = false
            self.m.v.recording.toggle()                          // feels instant; the next poll confirms
            if self.m.v.recording { self.m.v.started = Date().timeIntervalSince1970 }
            self.post("/task/record", ["text": self.m.v.recording ? "start" : "stop"])
        }
        m.onAsk = { [weak self] in
            guard let self else { return }
            let q = self.m.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty, !self.m.v.original.isEmpty, !self.m.v.busy else { return }
            self.m.sent = true; self.sawBusy = false; self.m.v.busy = true; self.m.prompt = ""
            self.post("/task/ask", ["text": q])
        }
        m.onSaveEdit = { [weak self] in
            guard let self else { return }
            let side = self.m.editing, text = self.m.draft
            self.m.editing = ""
            if side == "ai" { self.m.v.ai = text } else { self.m.v.original = text }   // show it now; the server confirms
            self.post("/task/edit", [side: text])
        }
    }

    private func post(_ path: String, _ body: [String: String] = [:]) {
        board?.post(path, body.merging(["id": id]) { a, _ in a })
    }

    func update(_ v: TaskView) {
        if m.sent && v.busy { sawBusy = true }
        if m.sent && sawBusy && !v.busy {                            // Mercury answered: flip to its version
            m.sent = false; sawBusy = false; m.flipped = !v.ai.isEmpty
        }
        if v.ai.isEmpty && m.flipped { m.flipped = false }
        if v.recording && m.flipped { m.flipped = false }            // recording shows your words
        if v != m.v { m.v = v }
    }

    func show() {
        if panel == nil {
            let p = CanvasPanel(contentRect: .zero, styleMask: [.borderless, .resizable, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.isMovableByWindowBackground = true
            p.minSize = NSSize(width: 260, height: 90)
            p.contentView = NSHostingView(rootView: TaskBoardView(m: m))
            p.delegate = self
            var r = UserDefaults.standard.string(forKey: frameKey).map(NSRectFromString) ?? .zero
            if r.width < 100 {                                      // a new card: stepped down-left of the others
                let s = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
                let step = CGFloat(place % 8) * 28
                r = NSRect(x: s.maxX - 380 - 16 - 400 - step, y: s.maxY - 400 - 60 - step, width: 360, height: 400)
            }
            p.setFrame(r, display: true)
            panel = p
            remember()
        }
        panel?.orderFrontRegardless()
        m.shown = true
    }

    func hide() {
        guard m.shown else { return }
        m.shown = false
        let p = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            if self?.m.shown == false { p?.orderOut(nil) }
        }
    }

    func close() {
        hide()
        UserDefaults.standard.removeObject(forKey: frameKey)
        let p = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { p?.close() }
    }

    var frame: NSRect? { panel?.frame }

    /// The size that shows everything on the side it's showing: the narrowest width (from 260 up to `maxWidth`)
    /// that doesn't add lines, and the height it then needs. Measured from the card's real layout, off-screen.
    func fittingSize(maxWidth: CGFloat) -> NSSize {
        let host = NSHostingController(rootView: TaskBoardView(m: m, measuring: true))
        func h(_ w: CGFloat) -> CGFloat { ceil(host.sizeThatFits(in: CGSize(width: w, height: 100_000)).height) }
        let full = h(maxWidth)
        var lo: CGFloat = 260, hi = maxWidth                     // narrowest width still at the full-width height
        if h(lo) <= full { return NSSize(width: lo, height: full) }
        while hi - lo > 8 { let mid = (lo + hi) / 2; if h(mid) <= full { hi = mid } else { lo = mid } }
        return NSSize(width: ceil(hi), height: full)
    }

    private var peeked = false                   // laid out by the quick look: don't remember that spot

    func peek(to r: NSRect) {
        let fresh = panel == nil || !m.shown
        show()
        peeked = true
        guard let p = panel else { return }
        if fresh { p.setFrame(r, display: true) }
        else { NSAnimationContext.runAnimationGroup { $0.duration = 0.3; p.animator().setFrame(r, display: true) } }
    }

    func unpeek(hidden: Bool) {
        guard peeked, let p = panel else { return }
        if hidden { hide() }
        let back = UserDefaults.standard.string(forKey: frameKey).map(NSRectFromString) ?? p.frame
        DispatchQueue.main.asyncAfter(deadline: .now() + (hidden ? 0.36 : 0)) { [weak self] in
            if hidden { p.setFrame(back, display: false) }
            else { NSAnimationContext.runAnimationGroup { $0.duration = 0.3; p.animator().setFrame(back, display: true) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.peeked = false }
        }
    }

    func windowDidMove(_ n: Notification) { remember() }
    func windowDidEndLiveResize(_ n: Notification) { remember() }
    private func remember() {
        guard let p = panel, !peeked else { return }
        UserDefaults.standard.set(NSStringFromRect(p.frame), forKey: frameKey)
    }
}
