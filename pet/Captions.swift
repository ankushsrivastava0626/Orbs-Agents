// Reply cards for muted orbs: the reply appears as text instead of being spoken. Same idea as the notes
// card, but made for reading: longer, unfolds line by line, stays while you hover, click to dismiss.
import AppKit
import SwiftUI

enum OSMotion {
    static let show = Animation.spring(response: 0.36, dampingFraction: 0.82)   // same as the dial and menu bar
    static let hide = Animation.easeInOut(duration: 0.55)
    static let linger = 1.0                                                   // stay a beat before fading
}

struct ReplyCard: Identifiable, Equatable {
    let id: String
    let title: String
    let text: String
    let born: Date
    var muted = true                     // false: it was spoken aloud (hover shows it again)
    var stay: Double { 10 }                                          // auto-hide after 10 s (or click outside)
}

final class CaptionsModel: ObservableObject {
    @Published var cards: [ReplyCard] = []
    @Published var hovering = false
    @Published var tailX: CGFloat? = nil       // where (in the panel) its orb is, for the bubble tail
    private var seen = Set<String>()
    private var timer: Timer?
    var onVisibility: ((Bool) -> Void)?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.expire() }
    }

    private(set) var last: ReplyCard? = nil   // most recent reply, for hover-to-peek
    private var peeking = false

    /// Hovering the orb: bring back its last reply (if it already timed out) for as long as you hover.
    func peek(_ on: Bool) {
        if on, !peeking, cards.isEmpty, let l = last {
            peeking = true; hovering = true
            onVisibility?(true)
            withAnimation(OSMotion.show) {
                cards = [ReplyCard(id: "peek-" + l.id, title: l.title, text: l.text, born: Date(), muted: l.muted)]
            }
        } else if !on, peeking {
            peeking = false
            // stay a beat after you move off, then fade (unless you come back)
            DispatchQueue.main.asyncAfter(deadline: .now() + OSMotion.linger) { [weak self] in
                guard let self, !self.peeking else { return }
                self.hovering = false
                self.cards.filter { $0.id.hasPrefix("peek-") }.forEach { self.dismiss($0.id) }
            }
        }
    }

    /// Keep a spoken reply as the orb's "last message" (not shown now; hover the orb to see it).
    func remember(_ id: String, title: String, text: String) {
        guard !text.isEmpty else { return }
        seen.insert(id)
        last = ReplyCard(id: id, title: title, text: text, born: Date(), muted: false)
    }

    func add(_ id: String, title: String, text: String) {
        guard !seen.contains(id), !text.isEmpty else { return }
        seen.insert(id)
        if peeking { peeking = false; hovering = false; cards.removeAll { $0.id.hasPrefix("peek-") } }
        last = ReplyCard(id: id, title: title, text: text, born: Date())
        withAnimation(OSMotion.show) {
            cards.append(ReplyCard(id: id, title: title, text: text, born: Date()))
            if cards.count > 3 { cards.removeFirst(cards.count - 3) }
        }
        onVisibility?(true)
    }

    /// Seed with what already happened so old replies don't pop up when the pet starts.
    func markSeen(_ ids: [String]) { ids.forEach { seen.insert($0) } }

    /// Fade every bubble of this orb (typing field opened, or a click outside).
    func dismissAll() {
        peeking = false; hovering = false
        cards.map(\.id).forEach(dismiss)
    }

    func dismiss(_ id: String) {
        withAnimation(OSMotion.hide) { cards.removeAll { $0.id == id } }
        if cards.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in   // after the fade has played
                if self?.cards.isEmpty == true { self?.onVisibility?(false) }
            }
        }
    }

    private func expire() {
        guard !hovering else { return }
        let now = Date()
        let old = cards.filter { now.timeIntervalSince($0.born) > $0.stay }.map(\.id)
        old.forEach(dismiss)
    }
}

/// The little triangle under a speech bubble.
struct BubbleTail: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.maxY), control: CGPoint(x: r.midX - r.width * 0.1, y: r.minY + r.height * 0.4))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX + r.width * 0.1, y: r.minY + r.height * 0.4))
        p.closeSubpath()
        return p
    }
}

struct ReplyCardView: View {
    let card: ReplyCard
    var tailX: CGFloat? = nil            // x (in the panel) of the orb it belongs to
    var showTail = true                  // only the bubble nearest the orb has a tail
    let dismiss: () -> Void
    @State private var unfolded = false
    @State private var lines = 0
    let blue = Color(red: 0.25, green: 0.6, blue: 1.0)

    /// Width that fits the longest line and the header (capped, so long replies wrap).
    static func width(for card: ReplyCard, sentences: [String]) -> CGFloat {
        let body = NSFont.systemFont(ofSize: 13), head = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let longest = sentences.map { ($0 + ".").size(withAttributes: [.font: body]).width }.max() ?? 0
        let header = card.title.size(withAttributes: [.font: head]).width + 18
        return min(420, max(longest, header, 60) + 24 + 8)            // paddings + a little air
    }

    var body: some View {
        let parts = card.text.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let w = Self.width(for: card, sentences: parts)
        let orbX = tailX ?? 220
        let center = min(max(orbX, w / 2 + 4), 440 - w / 2 - 4)       // over the orb, but inside the panel
        let tailLocal = orbX - (center - w / 2)
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: card.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")   // muted vs spoken
                        .font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.45))
                    Text(card.title).font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.55)).lineLimit(1)
                }
                // sentences fade in one after another as the card unfolds
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { i, sentence in
                        Text(sentence + (i < parts.count - 1 || card.text.hasSuffix(".") ? "." : ""))
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundColor(.white)
                            .fixedSize(horizontal: false, vertical: true)
                            .opacity(i < lines ? 1 : 0)
                            .offset(y: i < lines ? 0 : 6)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .frame(width: w, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)                 // only as tall (and wide) as its text
        .background(
            RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.07).opacity(0.94))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.55), radius: 14, y: 4))
        .overlay(alignment: .bottomLeading) {
            if showTail, tailX != nil {                                // speech-bubble tail pointing at its orb
                let x = tailLocal
                BubbleTail().fill(Color(white: 0.07).opacity(0.94))
                    .overlay(BubbleTail().stroke(Color.white.opacity(0.10), lineWidth: 1).mask(
                        Rectangle().padding(.top, 1)))
                    .frame(width: 22, height: 13)
                    .offset(x: min(max(x - 11, 14), w - 36), y: 12)
            }
        }
        .padding(.bottom, showTail && tailX != nil ? 12 : 0)
        .offset(x: center - 220)                                        // slide toward the orb
        .scaleEffect(x: 1, y: unfolded ? 1 : 0.15, anchor: .bottom)   // unfolds upward from one line
        .opacity(unfolded ? 1 : 0)
        .onTapGesture { dismiss() }
        .onAppear {
            withAnimation(OSMotion.show) { unfolded = true }
            for i in 0...parts.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18 + Double(i) * 0.12) {
                    withAnimation(.easeOut(duration: 0.28)) { lines = i + 1 }
                }
            }
        }
        .transition(.asymmetric(insertion: .identity,                     // the unfold above is the entrance
                                removal: .opacity.combined(with: .offset(y: 10)).combined(with: .scale(scale: 0.97, anchor: .bottom))))
    }
}

struct CaptionsView: View {
    @ObservedObject var m: CaptionsModel
    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            Spacer(minLength: 0)
            ForEach(m.cards) { c in
                ReplyCardView(card: c, tailX: m.tailX, showTail: c.id == m.cards.last?.id) { m.dismiss(c.id) }
            }
        }
        .frame(width: 440, height: 520, alignment: .bottom)
        .onHover { m.hovering = $0 }
    }
}
