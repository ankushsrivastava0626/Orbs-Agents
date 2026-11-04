// "+" → Search sessions: every orb conversation (Claude and Codex). With nothing typed it's a browser —
// folders, then the models used in that folder, then that folder's conversations on that model (newest
// first); typing searches everything at once.
// Click a result (or Return for the highlighted one) and a new orb opens, resuming that conversation.
import AppKit
import Combine
import SwiftUI

struct SearchHit: Decodable, Identifiable, Equatable {
    let kind: String, id: String, cwd: String, title: String, when: Double, snippet: String
    let name: String?
    let command: String?                        // e.g. claude-openrouter: its conversations only resume with it
    let model: String?                          // the model it ran on (claude-opus-5-5, z-ai/glm-5.3-flash, gpt-…)
}

/// One row: a folder, a model inside a folder, or a conversation.
struct SearchRow: Identifiable {
    enum Kind { case folder, model, session }
    let id: String, kind: Kind, title: String, detail: String, count: Int, when: Double
    var hit: SearchHit? = nil
}

final class SessionSearchModel: ObservableObject {
    @Published var query = ""
    @Published var hits: [SearchHit] = []
    @Published var selectedId: String? = nil   // the highlighted session (by id, so a list refresh can't move it)
    @Published var shown = false
    @Published var searching = false
    @Published var stale = false                // the results shown are for an older search
    @Published var folder: String? = nil        // browsing: inside this folder
    @Published var model: String? = nil         // browsing: this model, inside the folder
    var openIds: Set<String> = []                   // conversations already showing as an orb

    /// What the list shows now: search results, or the browser's current level.
    var rows: [SearchRow] {
        func session(_ h: SearchHit) -> SearchRow {
            SearchRow(id: "s:" + h.id, kind: .session, title: h.title, detail: "", count: 0, when: h.when, hit: h)
        }
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return hits.map(session) }
        guard let folder else {
            return Dictionary(grouping: hits, by: \.cwd).map { cwd, hs in
                SearchRow(id: "f:" + cwd, kind: .folder, title: cwd.isEmpty ? "(no folder)" : URL(fileURLWithPath: cwd).lastPathComponent,
                          detail: (cwd as NSString).abbreviatingWithTildeInPath, count: hs.count, when: hs.map(\.when).max() ?? 0)
            }.sorted { $0.when > $1.when }
        }
        let inFolder = hits.filter { $0.cwd == folder }
        guard let model else {
            return Dictionary(grouping: inFolder) { $0.model ?? $0.kind }.map { md, hs in
                SearchRow(id: "m:" + md, kind: .model, title: md, detail: hs.first?.kind == "codex" ? "Codex" : "Claude",
                          count: hs.count, when: hs.map(\.when).max() ?? 0)
            }.sorted { $0.when > $1.when }
        }
        return inFolder.filter { ($0.model ?? $0.kind) == model }.sorted { $0.when > $1.when }.map(session)
    }

    /// Back one level (Esc or the back button); false when already at the top.
    func back() -> Bool {
        if !query.isEmpty { return false }
        if model != nil { model = nil; return true }
        if folder != nil { folder = nil; return true }
        return false
    }
    var onPick: ((SearchHit) -> Void)?
    var onClose: (() -> Void)?
}

struct SessionSearchView: View {
    @ObservedObject var m: SessionSearchModel
    @FocusState private var focused: Bool
    static let width: CGFloat = 560, height: CGFloat = 440

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .semibold)).foregroundColor(.white.opacity(0.5))
                TextField("Search titles, folders and everything said…", text: $m.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundColor(.white)
                    .focused($focused)
                    .onSubmit { let rs = m.rows; pick(rs.first { $0.id == m.selectedId } ?? rs.first) }
                if m.searching { ProgressView().controlSize(.small).colorScheme(.dark) }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            if m.query.isEmpty, let f = m.folder {                       // where you are, and the way back
                HStack(spacing: 6) {
                    Button { _ = m.back() } label: {
                        Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.6))
                            .frame(width: 20, height: 20).background(Circle().fill(Color.white.opacity(0.08)))
                    }.buttonStyle(.plain).help("Back")
                    Text(URL(fileURLWithPath: f).lastPathComponent + (m.model.map { "  ›  " + $0 } ?? ""))
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.6)).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            }
            if m.searching && m.hits.isEmpty || m.searching && m.hits.isEmpty == false && m.stale {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).colorScheme(.dark)
                    Text("Searching…").font(.system(size: 12, design: .rounded)).foregroundColor(.white.opacity(0.5))
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if m.hits.isEmpty {
                Text(m.query.isEmpty ? "No conversations yet" : "Nothing matches")
                    .font(.system(size: 12, design: .rounded)).foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(m.rows) { r in row(r).id(r.id) }   // each row is itself, never a position
                        }.padding(6)
                    }
                    .onChange(of: m.selectedId) { id in if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } } }
                }
            }
        }
        .frame(width: Self.width, height: Self.height)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.07).opacity(0.97))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.12), lineWidth: 1))
            .shadow(color: .black.opacity(0.55), radius: 18, y: 4))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .scaleEffect(m.shown ? 1 : 0.94, anchor: .bottom)
        .offset(y: m.shown ? 0 : 10)
        .opacity(m.shown ? 1 : 0)
        .animation(m.shown ? OSMotion.show : .easeInOut(duration: 0.3), value: m.shown)
        .onExitCommand { if !m.back() { m.onClose?() } }               // Esc: up a level, then close
        .onMoveCommand { d in
            let rs = m.rows
            guard !rs.isEmpty else { return }
            let i = rs.firstIndex { $0.id == m.selectedId } ?? 0
            if d == .down { m.selectedId = rs[min(i + 1, rs.count - 1)].id }
            if d == .up { m.selectedId = rs[max(i - 1, 0)].id }
        }
        .onChange(of: m.folder) { _ in m.selectedId = m.rows.first?.id }
        .onChange(of: m.model) { _ in m.selectedId = m.rows.first?.id }
        .onChange(of: m.shown) { on in if on { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } } }
    }

    /// A real button: a click opens that row whether or not it's the highlighted one.
    func row(_ r: SearchRow) -> some View {
        Button { pick(r) } label: {                                  // acts on the row you clicked, itself
            if let h = r.hit { rowBody(h, r.id) } else { groupBody(r) }
        }
            .buttonStyle(.plain)
            .onHover { if $0 { m.selectedId = r.id } }
    }

    /// A folder or a model: its name, how many conversations, when it was last used.
    func groupBody(_ r: SearchRow) -> some View {
        HStack(spacing: 10) {
            Image(systemName: r.kind == .folder ? "folder" : (r.detail == "Codex" ? "chevron.left.forwardslash.chevron.right" : "sparkle"))
                .font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.7))
                .frame(width: 24, height: 24).background(Circle().fill(Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 3) {
                Text(r.title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(.white).lineLimit(1)
                Text(r.detail + " · " + (r.count == 1 ? "1 conversation" : "\(r.count) conversations"))
                    .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.45)).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(Date(timeIntervalSince1970: r.when), format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.system(size: 10, design: .rounded)).foregroundColor(.white.opacity(0.4)).monospacedDigit()
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.3))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(r.id == m.selectedId ? 0.12 : 0.001)))
        .contentShape(Rectangle())
    }

    func rowBody(_ h: SearchHit, _ rowId: String) -> some View {
        let sel = rowId == m.selectedId
        let folder = URL(fileURLWithPath: h.cwd).lastPathComponent
        let when = Date(timeIntervalSince1970: h.when)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: h.kind == "codex" ? "chevron.left.forwardslash.chevron.right" : "sparkle")
                .font(.system(size: 11, weight: .bold)).foregroundColor(.white.opacity(0.7))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(h.title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(.white).lineLimit(1)
                    if m.openIds.contains(h.id) {
                        Text("open").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(.black)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.white.opacity(0.8)))
                    }
                    Spacer(minLength: 4)
                    Text(when, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.system(size: 10, design: .rounded)).foregroundColor(.white.opacity(0.4)).monospacedDigit()
                }
                Text((h.kind == "codex" ? "Codex · " : "Claude · ") + folder + (h.model.map { " · " + $0 } ?? ""))
                    .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.45))
                if !h.snippet.isEmpty {
                    Text(h.snippet).font(.system(size: 11, design: .rounded)).foregroundColor(.white.opacity(0.65)).lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(sel ? 0.12 : 0.001)))
        .contentShape(Rectangle())
    }

    func pick(_ r: SearchRow?) {
        guard let r else { return }
        switch r.kind {
        case .folder: m.folder = String(r.id.dropFirst(2))
        case .model: m.model = String(r.id.dropFirst(2))
        case .session: if let h = r.hit { m.onPick?(h) }
        }
    }
}

final class SessionSearch {
    let m = SessionSearchModel()
    private var panel: TypePanel?
    private var watch: Any?
    private var monitors: [Any] = []
    private var pending: DispatchWorkItem?
    private var seq = 0
    var runSearch: ((String) -> [SearchHit])?

    func open(openIds: Set<String>) {
        m.openIds = openIds
        if m.query.isEmpty { m.folder = nil; m.model = nil }           // start at the folders
        if panel == nil { build() }
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let w = SessionSearchView.width + 40, h = SessionSearchView.height + 40
        panel.setFrame(NSRect(x: screen.frame.midX - w / 2, y: screen.frame.minY + 110, width: w, height: h), display: true)
        panel.alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        m.shown = true
        search(m.query)
        let mon = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.close() }
        if let mon { monitors.append(mon) }
    }

    private func build() {
        let p = TypePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: SessionSearchView(m: m).padding(20))
        p.onResign = { [weak self] in self?.close() }
        panel = p
        m.onClose = { [weak self] in self?.close() }
        watch = m.$query.dropFirst().sink { [weak self] q in self?.search(q) }
    }

    /// Debounced: the script runs off the main thread; only the newest answer is shown.
    private func search(_ q: String) {
        pending?.cancel()
        m.searching = true; m.stale = true               // say so right away, not after the pause
        seq += 1
        let mine = seq
        let w = DispatchWorkItem { [weak self] in
            guard let self, let run = self.runSearch else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let hits = run(q)
                DispatchQueue.main.async {
                    guard mine == self.seq else { return }
                    self.m.searching = false; self.m.stale = false
                    self.m.hits = hits
                    let rs = self.m.rows
                    if !rs.contains(where: { $0.id == self.m.selectedId }) { self.m.selectedId = rs.first?.id }
                }
            }
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
    }

    func close() {
        guard m.shown else { return }
        m.shown = false
        for mon in monitors { NSEvent.removeMonitor(mon) }
        monitors = []
        let p = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            if self?.m.shown == false { p?.orderOut(nil) }
        }
    }
}
