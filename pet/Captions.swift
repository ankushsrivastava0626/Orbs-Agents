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
    /// Hover-revealed: 10 s. Arrived by itself (a muted reply): as long as the text takes to read.
    var stay: Double { id.hasPrefix("peek-") ? 10 : min(25, 5 + Double(text.count) * 0.06) }
}

/// What a busy orb is doing (hover a purple or coral orb): shown live, only while hovered.
struct Activity: Equatable {
    var title: String                            // "Claude · voice-2"
    var transcribing = false                     // coral: your words are being written down
    var since: Double = 0                        // when this run of work started
    var steps: [String] = []                     // oldest first; the last is what it's doing right now
}

final class CaptionsModel: ObservableObject {
    @Published var cards: [ReplyCard] = []
    @Published var hovering = false
    @Published var activity: Activity? = nil     // hovering a busy orb: what it's doing, live
    @Published var tailX: CGFloat? = nil       // where (in the panel) its orb is, for the bubble tail
    var contentHeight: CGFloat = 0             // how tall the cards are (the rest of the panel lets clicks through)
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
            // moving off the orb doesn't close it: like every bubble it stays until a click outside or 10 s
            peeking = false; hovering = false
            cards = cards.map { $0.id.hasPrefix("peek-") ? ReplyCard(id: $0.id, title: $0.title, text: $0.text,
                                                                        born: Date(), muted: $0.muted) : $0 }
        }
    }

    /// The orb moved to another conversation: its old last message isn't this one's.
    func forget() {
        last = nil
        if peeking { peeking = false; hovering = false; cards.removeAll { $0.id.hasPrefix("peek-") } }
    }

    /// Hovering a busy orb shows what it's doing and keeps it current; nil when the hover ends (only on hover).
    func showActivity(_ a: Activity?) {
        guard a != activity else { return }
        let was = activity != nil
        withAnimation(OSMotion.show) { activity = a }
        if a != nil, !was { onVisibility?(true) }
        if a == nil, cards.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in   // after the fade has played
                if self?.cards.isEmpty == true, self?.activity == nil { self?.onVisibility?(false) }
            }
        }
    }

    /// Keep a spoken reply as the orb's "last message" (not shown now; hover the orb to see it).
    func remember(_ id: String, title: String, text: String) {
        guard !text.isEmpty else { return }
        seen.insert(id)
        if last?.id == id && last?.title == title { return }
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

    /// Fade just the hover-revealed bubble (another orb's hover bubble is taking over).
    func dismissPeeks() {
        peeking = false; hovering = false
        cards.filter { $0.id.hasPrefix("peek-") }.map(\.id).forEach(dismiss)
    }

    /// Fade every bubble of this orb (typing field opened, or a click outside).
    func dismissAll() {
        peeking = false; hovering = false
        cards.map(\.id).forEach(dismiss)
    }

    func dismiss(_ id: String) {
        withAnimation(OSMotion.hide) { cards.removeAll { $0.id == id } }
        if cards.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in   // after the fade has played
                if self?.cards.isEmpty == true, self?.activity == nil { self?.onVisibility?(false) }
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
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture(perform: dismiss)                                  // click a card to put it away
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
            VStack(alignment: .center, spacing: 8) {
                ForEach(m.cards) { c in
                    ReplyCardView(card: c, tailX: m.tailX, showTail: c.id == m.cards.last?.id && m.activity == nil) { m.dismiss(c.id) }
                }
                if let a = m.activity {                                   // nearest the orb: what it's doing now
                    ActivityCard(a: a, tailX: m.tailX)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                }
            }
            .background(GeometryReader { g in Color.clear.onAppear { m.contentHeight = g.size.height }
                                                       .onChange(of: g.size.height) { m.contentHeight = $0 } })
            .onHover { m.hovering = $0 }                                   // only the cards keep it up, not the empty space
        }
        .frame(width: 440, height: 520, alignment: .bottom)
    }
}

/// A busy orb's live card: how long it's been at it, what it's doing now (slides in as each step starts) and the
/// steps just before, ticked off. Purple spinner while it works, coral while your words are transcribed.
struct ActivityCard: View {
    let a: Activity
    var tailX: CGFloat? = nil
    static let w: CGFloat = 300
    static let purple = Color(red: 0.65, green: 0.4, blue: 1.0), coral = Color(red: 1.0, green: 0.5, blue: 0.38)

    static func elapsed(_ s: Double) -> String {
        let t = Int(max(0, s)); return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                                                 : String(format: "%d:%02d", t / 60, t % 60)
    }

    var body: some View {
        let w = Self.w, orbX = tailX ?? 220
        let center = min(max(orbX, w / 2 + 4), 440 - w / 2 - 4)       // over the orb, but inside the panel
        let tailLocal = orbX - (center - w / 2)
        let accent = a.transcribing ? Self.coral : Self.purple
        let now = a.transcribing ? "Transcribing what you said" : (a.steps.last ?? "Working")
        let done = Array(a.transcribing ? [] : a.steps.dropLast().suffix(3).reversed())
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in   // a small spinner in the orb's color
                    Circle().trim(from: 0, to: 0.3)
                        .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 10, height: 10)
                        .rotationEffect(.degrees(tl.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360))
                }
                Text(a.title).font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.55)).lineLimit(1)
                Spacer(minLength: 4)
                if a.since > 0 {
                    TimelineView(.periodic(from: .now, by: 1)) { tl in
                        Text(Self.elapsed(tl.date.timeIntervalSince1970 - a.since))
                            .font(.system(size: 10, design: .rounded)).monospacedDigit().foregroundColor(.white.opacity(0.45))
                    }
                }
            }
            ZStack(alignment: .leading) {                                  // the step slides up as the next begins
                Text(now).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(.white)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .id(now)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .move(edge: .top).combined(with: .opacity)))
            }
            .clipped()
            ForEach(Array(done.enumerated()), id: \.offset) { i, st in
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundColor(.white.opacity(0.35))
                    Text(st).font(.system(size: 11, design: .rounded)).foregroundColor(.white.opacity(0.5 - Double(i) * 0.12))
                        .lineLimit(1)
                }
            }
        }
        .animation(OSMotion.show, value: now)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(width: w, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.07).opacity(0.94))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(accent.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.55), radius: 14, y: 4))
        .overlay(alignment: .bottomLeading) {
            if tailX != nil {                                              // the speech-bubble tail, at its orb
                BubbleTail().fill(Color(white: 0.07).opacity(0.94))
                    .frame(width: 22, height: 13)
                    .offset(x: min(max(tailLocal - 11, 14), w - 36), y: 12)
            }
        }
        .padding(.bottom, tailX != nil ? 12 : 0)
        .offset(x: center - 220)
    }
}
