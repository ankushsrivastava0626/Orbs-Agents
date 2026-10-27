// Task board: a card you talk to. Hit record, say your tasks (or anything); your words appear as you speak.
// Then tell Mercury what to do with them ("lab work at the top, personal at the bottom", "make it concise")
// and the card flips to its version. Flip back to see what you actually said and try a different prompt —
// every prompt starts from your own words, never from the last result. Turned on from any orb's menu.
import AppKit
import SwiftUI

struct TaskView: Decodable, Equatable {
    var recording = false, ready = false, started = 0.0, transcribing = false, busy = false
    var live = "", original = "", ai = "", prompt = ""
}

final class TaskBoardModel: ObservableObject {
    @Published var v = TaskView()
    @Published var shown = false
    @Published var flipped = false              // showing Mercury's version
    @Published var prompt = ""
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
    var onClear: () -> Void = {}
}

struct TaskBoardView: View {
    @ObservedObject var m: TaskBoardModel
    @State private var now = Date()
    let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            front.opacity(m.flipped ? 0 : 1)
            back.opacity(m.flipped ? 1 : 0)
                .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))   // reads the right way round once flipped
        }
        .rotation3DEffect(.degrees(m.flipped ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
        .animation(.spring(response: 0.55, dampingFraction: 0.86), value: m.flipped)
        .frame(minWidth: 260, maxWidth: .infinity, minHeight: 160, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .bottomTrailing) {                     // resize grip (the edges resize too)
            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 7, weight: .bold))
                .foregroundColor(.white.opacity(0.2)).padding(6)
        }
        .scaleEffect(m.shown ? 1 : 0.92, anchor: .topTrailing)
        .opacity(m.shown ? 1 : 0)
        .animation(m.shown ? OSMotion.show : .easeInOut(duration: 0.35), value: m.shown)
        .onReceive(tick) { now = $0 }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
        card {
            HStack(spacing: 7) {
                Circle().fill(m.v.recording && m.v.ready ? Color.red : Color.white.opacity(0.25)).frame(width: 6, height: 6)
                    .opacity(m.v.recording ? (Int(now.timeIntervalSince1970) % 4 < 2 ? 0.9 : 0.45) : 1)
                    .animation(.easeInOut(duration: 1.2), value: Int(now.timeIntervalSince1970))
                Text(status).font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.55)).monospacedDigit().lineLimit(1)
                Spacer()
                if !m.v.original.isEmpty && !m.v.recording && !m.v.transcribing {
                    editButton("original")
                    if m.editing != "original" { iconButton("trash", "Start over", m.onClear) }
                }
                if !m.v.ai.isEmpty { iconButton("arrow.triangle.2.circlepath", "Show Mercury's version") { if !m.editing.isEmpty { m.onSaveEdit() }; m.flipped = true } }
                iconButton("xmark", "Close the task board", m.onClose)
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)

            ScrollView {
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
                .buttonStyle(.plain).disabled(m.v.transcribing)
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

    private var canAsk: Bool {
        !m.prompt.trimmingCharacters(in: .whitespaces).isEmpty && !m.v.original.isEmpty && !m.v.busy
    }

    // MARK: back — Mercury's version

    private var back: some View {
        card {
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
                iconButton("xmark", "Close the task board", m.onClose)
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 8)

            ScrollView {
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

final class TaskBoard: NSObject, NSWindowDelegate {
    let m = TaskBoardModel()
    private var panel: CanvasPanel?
    private var timer: Timer?
    private var sawBusy = false                  // the server picked up the prompt (ignores polls sent before it)
    private static let enabledKey = "taskBoardEnabled", frameKey = "taskBoardFrame"
    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    func restore() { if enabled { start() } }

    /// Hold `: the board comes up and records until you let go; it stays open with what you said.
    func hold(_ down: Bool) {
        if down {
            if !m.editing.isEmpty { m.onSaveEdit() }
            if !enabled { UserDefaults.standard.set(true, forKey: Self.enabledKey); start() } else if !m.shown { show() }
            m.flipped = false
            m.v.recording = true; m.v.ready = false; m.v.started = Date().timeIntervalSince1970
            post("/task/record", "start")
        } else {
            m.v.recording = false
            post("/task/record", "stop")
        }
    }
    func toggle() {
        if enabled { stop() } else { UserDefaults.standard.set(true, forKey: Self.enabledKey); start() }
    }

    private func stop() {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        if m.v.recording { post("/task/record", "stop") }                // closing mid-recording keeps what was said
        timer?.invalidate(); timer = nil
        m.shown = false
        let p = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            if self?.m.shown == false { p?.orderOut(nil) }
        }
    }

    private func start() {
        m.onClose = { [weak self] in self?.stop() }
        m.onRecord = { [weak self] in
            guard let self else { return }
            if !self.m.editing.isEmpty { self.m.onSaveEdit() }       // keep your edit, then record more
            self.m.flipped = false
            self.m.v.recording.toggle()                          // feels instant; the next poll confirms
            if self.m.v.recording { self.m.v.started = Date().timeIntervalSince1970 }
            self.post("/task/record", self.m.v.recording ? "start" : "stop")
        }
        m.onAsk = { [weak self] in
            guard let self else { return }
            let q = self.m.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty, !self.m.v.original.isEmpty, !self.m.v.busy else { return }
            self.m.sent = true; self.sawBusy = false; self.m.v.busy = true; self.m.prompt = ""
            self.post("/task/ask", q)
        }
        m.onSaveEdit = { [weak self] in
            guard let self else { return }
            let side = self.m.editing, text = self.m.draft
            self.m.editing = ""
            if side == "ai" { self.m.v.ai = text } else { self.m.v.original = text }   // show it now; the server confirms
            var req = URLRequest(url: URL(string: "http://127.0.0.1:5123/task/edit")!)
            req.httpMethod = "POST"; req.timeoutInterval = 3
            req.httpBody = try? JSONSerialization.data(withJSONObject: [side: text])
            URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
                DispatchQueue.main.async { self?.apply(data) }
            }.resume()
        }
        m.onClear = { [weak self] in
            self?.m.flipped = false
            self?.post("/task/clear")
        }
        show()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private func post(_ path: String, _ text: String = "") {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:5123" + path)!)
        req.httpMethod = "POST"; req.timeoutInterval = 3
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["text": text])
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
        guard let data, let v = try? JSONDecoder().decode(TaskView.self, from: data) else { return }
        if m.sent && v.busy { sawBusy = true }
        if m.sent && sawBusy && !v.busy {                            // Mercury answered: flip to its version
            m.sent = false; sawBusy = false; m.flipped = !v.ai.isEmpty
        }
        if v.ai.isEmpty && m.flipped { m.flipped = false }
        if v != m.v { m.v = v }
    }

    private func show() {
        if panel == nil {
            let p = CanvasPanel(contentRect: .zero, styleMask: [.borderless, .resizable, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            p.isMovableByWindowBackground = true
            p.minSize = NSSize(width: 260, height: 160)
            p.contentView = NSHostingView(rootView: TaskBoardView(m: m))
            p.delegate = self
            var r = UserDefaults.standard.string(forKey: Self.frameKey).map(NSRectFromString) ?? .zero
            if r.width < 100 {                                      // first time: left of where the meeting board goes
                let s = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
                r = NSRect(x: s.maxX - 380 - 16 - 400, y: s.maxY - 400 - 60, width: 360, height: 400)
            }
            p.setFrame(r, display: true)
            panel = p
        }
        panel?.orderFrontRegardless()
        m.shown = true
    }

    func windowDidMove(_ n: Notification) { remember() }
    func windowDidEndLiveResize(_ n: Notification) { remember() }
    private func remember() {
        guard let p = panel else { return }
        UserDefaults.standard.set(NSStringFromRect(p.frame), forKey: Self.frameKey)
    }
}
