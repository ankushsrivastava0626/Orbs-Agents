// Select text anywhere, double-tap RIGHT Option: Joe (Gemini) reads exactly the selection out loud.
// Double-tap again on a new selection and it reads that instead (the newest always wins).
import AppKit
import ApplicationServices

enum SelectionReader {
    static let session = "reader"

    /// The selected text in the front app: Accessibility first, else a quiet ⌘C (your clipboard is put back).
    static func selectedText(_ done: @escaping (String?) -> Void) {
        if let t = axSelection(), !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { done(t); return }
        copySelection(done)
    }

    private static func axSelection() -> String? {
        let sys = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused else { return nil }
        var sel: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el as! AXUIElement, kAXSelectedTextAttribute as CFString, &sel) == .success else { return nil }
        return sel as? String
    }

    private static func copySelection(_ done: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let v = item.data(forType: t) { d[t] = v } }
            return d
        }
        let before = pb.changeCount
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: down)     // C
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard pb.changeCount != before else { done(nil); return }                // nothing was selected
            let text = pb.string(forType: .string)
            pb.clearContents()                                                        // put your clipboard back
            let items = saved.map { d -> NSPasteboardItem in
                let i = NSPasteboardItem(); for (t, v) in d { i.setData(v, forType: t) }; return i
            }
            if !items.isEmpty { pb.writeObjects(items) }
            done(text)
        }
    }

    /// Hand it to the voice server in paragraph-sized pieces (so long passages are read in full, in order).
    private static var generation = 0
    private static let lock = NSLock()

    static func read(_ text: String) {
        lock.lock(); generation += 1; let mine = generation; lock.unlock()
        stop()                                                                        // waits: old reading is gone first
        for chunk in chunks(text) {
            lock.lock(); let current = generation == mine; lock.unlock()
            guard current else { return }                                             // a newer selection took over
            var req = URLRequest(url: URL(string: "http://127.0.0.1:5123/say?kind=say&s=\(session)")!)
            req.httpMethod = "POST"; req.timeoutInterval = 3
            req.httpBody = chunk.data(using: .utf8)
            let sem = DispatchSemaphore(value: 0)                                     // keep the order
            URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
            _ = sem.wait(timeout: .now() + 3)
        }
    }

    /// Stop Joe and drop everything queued. Returns once the server has done it.
    static func stop() {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:5123/stop")!)
        req.httpMethod = "POST"; req.timeoutInterval = 2
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 2)
    }

    static func chunks(_ text: String, max: Int = 700) -> [String] {
        let clean = text.replacingOccurrences(of: "\r", with: "")
        var out: [String] = [], cur = ""
        for para in clean.components(separatedBy: "\n") {
            let p = para.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            var pieces = [p]
            if p.count > max {                                                        // split a long paragraph by sentence
                pieces = []
                var s = ""
                p.enumerateSubstrings(in: p.startIndex..<p.endIndex, options: .bySentences) { sub, _, _, _ in
                    guard let sub else { return }
                    if s.count + sub.count > max, !s.isEmpty { pieces.append(s); s = "" }
                    s += sub
                }
                if !s.isEmpty { pieces.append(s) }
            }
            for piece in pieces {
                if cur.count + piece.count + 1 > max, !cur.isEmpty { out.append(cur); cur = "" }
                cur += (cur.isEmpty ? "" : "\n") + piece
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}
