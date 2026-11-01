import AppKit
import Combine
import SwiftUI

/// Transparent, click-through window covering one screen. Orbit's buddy and drawings live here.
final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        setFrame(screen.frame, display: false)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum BuddyMood: Equatable { case idle, listening, thinking }

/// Orbit's ink: the one colour every mark is drawn in, and the pastel gel its labels use.
enum Ink: String, CaseIterable, Codable {
    case blue, red, gold, green
    var hex: UInt32 {
        switch self {
        case .blue: return 0x3380FF
        case .red: return 0xFF4C4C
        case .gold: return 0xD4A017
        case .green: return 0x26C281
        }
    }
    var color: Color { Color(hex: hex) }
    var nsColor: NSColor { NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1) }
    /// Lighter at the top, a dark rim, dark words.
    var gel: (top: Color, mid: Color, low: Color, rim: Color) {
        switch self {
        case .blue: return (Color(hex: 0xEDF4FF), Color(hex: 0xA2C7FF), Color(hex: 0xA2D2F7), Color(hex: 0x221898))
        case .red: return (Color(hex: 0xFFF1EF), Color(hex: 0xFFB8B0), Color(hex: 0xFFC8C0), Color(hex: 0x7A1E1E))
        case .gold: return (Color(hex: 0xFFF8E2), Color(hex: 0xFFDF8A), Color(hex: 0xFFE9A8), Color(hex: 0x6E4E00))
        case .green: return (Color(hex: 0xEFFBF2), Color(hex: 0xC9F0CF), Color(hex: 0xB4E8C5), Color(hex: 0x17603F))
        }
    }
}

/// Drives the buddy: follows the cursor with a little lag, flies off to point, and holds the pen while drawing.
@MainActor
final class OverlayModel: ObservableObject {
    @Published var buddy = NSEvent.mouseLocation
    @Published var mood: BuddyMood = .idle
    @Published var caption: String?
    @Published var strokes: [Stroke] = []
    /// Seconds since the drawing started; each stroke draws over its own slice of it.
    @Published var elapsed: Double = 0
    @Published var tilt: Double = 0
    @Published var ink = Ink.blue
    /// Which side of the buddy its bubble opens on, so it stays on screen and its tail points back at the buddy.
    @Published var bubbleLeft = false
    @Published var bubbleAbove = false
    /// A 3D model being built or shown, and its window in global coordinates.
    @Published var sculpture: Sculpture?
    private(set) var sculptureFrame: CGRect = .zero
    private var sculptureStarted: Date?
    private var placedParts = 0
    private(set) var starts: [Double] = []
    private var sounded = 0
    private var popped: Set<Int> = []
    private var timer: Timer?
    private var drawingStarted: Date?
    private var drawingDone: Date?
    private var captionUntil = Date.distantPast
    /// Keeps the reply bubble up while Orbit is still reading it aloud.
    var isSpeaking: () -> Bool = { false }
    /// While you hold the talk shortcut, the pointer leaves a fading line so you can circle what you mean.
    var pointing = false
    @Published var trail: [TrailPoint] = []
    /// The whole pointer path while talking, drawn onto the screenshot so the model sees what you pointed at.
    private(set) var gesture: [CGPoint] = []
    static let trailLife: TimeInterval = 1.6
    /// The sentence being read aloud, shown as a caption when captions are on.
    @Published var spokenLine: String?
    var showCaptions = false
    static let offset = CGPoint(x: 22, y: -24)
    /// A breath between strokes, like a hand lifting the pen.
    static let gap = 0.08
    var keepDrawings: TimeInterval = 30

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }

    /// Draws marks in order; `tone` says whether the screenshot is dark or light under an area (for free words).
    func play(_ marks: [SketchMark], frame: CGRect, tone: (CGRect) -> Stroke.Tone = { _ in .dark }) {
        var made = marks.map { Stroke.make($0, in: frame, tone: tone) }
        let screens = NSScreen.screens.map(\.frame)
        LabelLayout.place(&made, screens: screens.isEmpty ? [frame] : screens)
        var time = 0.0
        starts = made.map { stroke in
            defer { time += stroke.duration + Self.gap }
            return time
        }
        strokes = made
        elapsed = 0; sounded = 0; popped = []
        drawingStarted = Date(); drawingDone = nil
    }
    /// How much of stroke `i` is drawn, 0...1.
    func fraction(_ i: Int) -> CGFloat {
        guard i < strokes.count, i < starts.count else { return 0 }
        return CGFloat(max(0, min(1, (elapsed - starts[i]) / strokes[i].duration)))
    }
    var drawingLength: Double { zip(starts, strokes).map { $0 + $1.duration }.max() ?? 0 }

    /// Builds a 3D model next to the spot it names; parts pop in one by one.
    func build(_ model: Sculpture, frame: CGRect) {
        sculptureFrame = model.frame(in: frame)
        sculpture = model
        sculptureStarted = Date(); placedParts = 0
    }
    func clear() {
        strokes = []; starts = []; elapsed = 0; drawingStarted = nil; drawingDone = nil
        sculpture = nil; sculptureStarted = nil
    }
    func say(_ text: String?) {
        caption = text.map { String($0.prefix(220)) + ($0.count > 220 ? "…" : "") }
        // Time to read it twice at an easy pace; drawings on screen and speech keep it up longer (see tick).
        captionUntil = Date().addingTimeInterval(max(8, Double(text?.count ?? 0) * 0.12))
    }

    /// Flips the bubble left near the right edge and above near the bottom, with a margin so it doesn't flicker.
    private func placeBubble(around point: CGPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })?.frame else { return }
        let right = screen.maxX - point.x, below = point.y - screen.minY
        let left = bubbleLeft ? right < Self.bubbleRoom.width + 60 : right < Self.bubbleRoom.width
        let above = bubbleAbove ? below < Self.bubbleRoom.height + 60 : below < Self.bubbleRoom.height
        if left != bubbleLeft { bubbleLeft = left }
        if above != bubbleAbove { bubbleAbove = above }
    }
    /// Room the bubble needs to the right of and below the buddy.
    static let bubbleRoom = CGSize(width: 360, height: 190)

    func takeGesture() -> [CGPoint] {
        defer { gesture = [] }
        return gesture
    }

    private func sound(for stroke: Stroke) {
        switch stroke.kind {
        case .target: SoundFX.shared.play(.ping)
        case .spotlight: SoundFX.shared.play(.dim)
        case .cheer: SoundFX.shared.play(.cheer)
        case .pen, .frame: SoundFX.shared.play(.pen(stroke.duration))
        case .text: SoundFX.shared.play(.pen(stroke.duration * 0.9))
        case .marker: SoundFX.shared.play(.marker(stroke.duration))
        case .badge: SoundFX.shared.play(.badge)
        case .note: SoundFX.shared.play(.press)
        case .point: SoundFX.shared.play(.ping)
        }
    }

    private func tick() {
        let now = Date()
        var pen: CGPoint?, penEase: CGFloat = 0.45
        if let started = drawingStarted, drawingDone == nil, !strokes.isEmpty {
            elapsed = now.timeIntervalSince(started)
            while sounded < strokes.count, elapsed >= starts[sounded] { sound(for: strokes[sounded]); sounded += 1 }
            for i in 0..<sounded where strokes[i].labelBox != nil && !popped.contains(i) && fraction(i) >= 1 {
                popped.insert(i)
                SoundFX.shared.play(.pop)
            }
            if elapsed >= drawingLength {
                drawingDone = now
            } else if let i = starts.lastIndex(where: { $0 <= elapsed }) {
                // Hold the pen on the stroke being drawn; between strokes, glide to where the next one starts.
                let f = fraction(i)
                pen = f < 1 || i + 1 >= strokes.count ? strokes[i].tip(at: f) : strokes[i + 1].tip(at: 0)
                penEase = strokes[i].kind == .point ? 0.14 : 0.45
            }
        }
        if let done = drawingDone, now.timeIntervalSince(done) > keepDrawings {
            strokes = []; starts = []; elapsed = 0; drawingStarted = nil; drawingDone = nil
        }
        var building: CGPoint?
        if let started = sculptureStarted, let model = sculpture {
            let elapsed = now.timeIntervalSince(started)
            let buildTime = Double(model.parts.count) * SculptureScene.secondsPerPart
            if elapsed > buildTime + max(keepDrawings, 20) { sculpture = nil; sculptureStarted = nil }
            else if elapsed < buildTime {
                let index = min(Int(elapsed / SculptureScene.secondsPerPart), model.parts.count - 1)
                if index >= placedParts { placedParts = index + 1; SoundFX.shared.play(.pop) }
                building = Sculpture.screenPoint(of: model.parts[index], in: sculptureFrame)
            }
        }
        // Point while you talk: keep the pointer's path, and let the visible line fade from its tail.
        if pointing, mood == .listening {
            let mouse = NSEvent.mouseLocation
            if let last = trail.last?.point, hypot(mouse.x - last.x, mouse.y - last.y) < 2 {} else {
                trail.append(TrailPoint(point: mouse, time: now))
                if gesture.count < 1200 { gesture.append(mouse) }
            }
        }
        if let first = trail.first, now.timeIntervalSince(first.time) > Self.trailLife {
            trail.removeAll { now.timeIntervalSince($0.time) > Self.trailLife }
        }
        // The reply stays while its drawings are up or it's being read aloud.
        if mood == .idle, caption != nil, now > captionUntil, strokes.isEmpty, sculpture == nil, !isSpeaking() { caption = nil }

        // While drawing the buddy rides the pen tip; otherwise it trails the cursor.
        var target = NSEvent.mouseLocation
        target.x += Self.offset.x; target.y += Self.offset.y
        var ease: CGFloat = 0.28
        if let building { target = CGPoint(x: building.x + 18, y: building.y + 26); ease = 0.22 } // hover just above the piece being placed
        if let pen { target = pen; ease = penEase }
        let next = CGPoint(x: buddy.x + (target.x - buddy.x) * ease, y: buddy.y + (target.y - buddy.y) * ease)
        placeBubble(around: next)
        if hypot(next.x - buddy.x, next.y - buddy.y) > 0.05 {
            tilt = Double(max(-18, min(18, (next.x - buddy.x) * 1.4)))
            buddy = next
        } else if tilt != 0 { tilt = 0 }
    }
}

@MainActor
final class OverlayController {
    let model = OverlayModel()
    private var windows: [OverlayWindow] = []
    private var observer: NSObjectProtocol?
    private var sculptureWindow: SculptureWindow?
    private var sculptureWatch: AnyCancellable?

    func show() {
        if sculptureWatch == nil {
            sculptureWatch = model.$sculpture.removeDuplicates().sink { [weak self] sculpture in
                MainActor.assumeIsolated { self?.present(sculpture) }
            }
        }
        if windows.isEmpty { build() }
        windows.forEach { $0.orderFrontRegardless() }
        model.start()
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild() }
            }
        }
    }
    func hide() { windows.forEach { $0.orderOut(nil) }; model.stop(); model.clear() }
    private func present(_ sculpture: Sculpture?) {
        sculptureWindow?.orderOut(nil)
        sculptureWindow = nil
        guard let sculpture else { return }
        let window = SculptureWindow(sculpture: sculpture, frame: model.sculptureFrame)
        window.orderFrontRegardless()
        // Keep the buddy's window above the model.
        windows.forEach { $0.orderFrontRegardless() }
        sculptureWindow = window
    }
    private func build() {
        windows = NSScreen.screens.map { screen in
            let window = OverlayWindow(screen: screen)
            window.contentView = NSHostingView(rootView: OverlayView(model: model, frame: screen.frame))
            return window
        }
    }
    private func rebuild() {
        let visible = windows.first?.isVisible ?? false
        windows.forEach { $0.orderOut(nil) }
        windows = []
        if visible { show() }
    }
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    let frame: CGRect
    func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - frame.minX, y: frame.maxY - p.y) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.strokes.enumerated()), id: \.offset) { index, stroke in
                let fraction = model.fraction(index)
                if fraction > 0 { StrokeView(stroke: stroke, fraction: fraction, ink: model.ink, frame: frame) }
            }
            if !model.trail.isEmpty { TrailView(points: model.trail, ink: model.ink, frame: frame) }
            if frame.insetBy(dx: -60, dy: -60).contains(model.buddy) { buddy.position(local(model.buddy)) }
            if model.showCaptions, let line = model.spokenLine, frame.contains(model.buddy) {
                CaptionBar(text: line).frame(maxWidth: min(900, frame.width - 80))
                    .position(x: frame.width / 2, y: frame.height - 70)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.spokenLine)
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// The orb sits at the center; the bubble opens toward whichever corner has room.
    var buddy: some View {
        let left = model.bubbleLeft, above = model.bubbleAbove
        let corner: Alignment = above ? (left ? .bottomTrailing : .bottomLeading) : (left ? .topTrailing : .topLeading)
        let anchor: UnitPoint = above ? (left ? .bottomTrailing : .bottomLeading) : (left ? .topTrailing : .topLeading)
        let half = CGSize(width: 340, height: 220)
        return ZStack {
            Group {
                switch model.mood {
                case .listening:
                    HStack(spacing: 8) {
                        Waveform(active: true, bars: 9)
                        if let caption = model.caption, !caption.isEmpty { Text(caption).lineLimit(2) }
                    }
                    .bubbleChip(alignment: left ? .trailing : .leading)
                case .thinking:
                    Waveform(active: true, bars: 5).bubbleChip(alignment: left ? .trailing : .leading)
                case .idle:
                    if let caption = model.caption {
                        // The tail sits in the corner nearest the buddy and points back at it.
                        SpeechBubble(mine: false, tailOnRight: left, tailOnTop: !above) {
                            Text(caption).font(.system(size: 14)).foregroundStyle(Color(hex: 0x15171C)).lineSpacing(3)
                        }
                        .frame(maxWidth: 320, alignment: left ? .trailing : .leading).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: 13)).foregroundStyle(DS.Colors.ink)
            .padding(left ? .trailing : .leading, half.width + 14)
            .padding(above ? .bottom : .top, half.height + 22)
            .frame(width: half.width * 2, height: half.height * 2, alignment: corner)
            .transition(.scale(scale: 0.6, anchor: anchor).combined(with: .opacity))
            OrbitMark(size: 22).rotationEffect(.degrees(model.tilt)).dsShadow()
                .scaleEffect(model.mood == .listening ? 1.15 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.5), value: model.mood)
        }
        .frame(width: half.width * 2, height: half.height * 2)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: model.caption)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: left)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: above)
    }
}

private extension View {
    func bubbleChip(alignment: Alignment = .leading) -> some View {
        padding(.horizontal, 12).frame(minHeight: 30)
            .background(DS.Colors.silver, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(DS.Colors.silverEdge.opacity(0.55), lineWidth: DS.edge))
            .dsShadow()
            .frame(maxWidth: 300, alignment: alignment)
    }
}

struct StrokeView: View {
    let stroke: Stroke
    let fraction: CGFloat
    let ink: Ink
    /// The screen this overlay window covers.
    let frame: CGRect

    func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - frame.minX, y: frame.maxY - p.y) }
    func local(_ r: CGRect) -> CGRect { CGRect(x: r.minX - frame.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            mark
            if let label = stroke.label, let box = stroke.labelBox, fraction >= 1 {
                let r = local(box)
                GelLabel(text: label, ink: ink).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
    }

    @ViewBuilder var mark: some View {
        let color = ink.color
        switch stroke.kind {
        case .pen:
            penPath.trimmedPath(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: stroke.lineWidth, lineCap: .round, lineJoin: .round))
                .shadow(color: color.opacity(0.65), radius: 6)
        case .frame:
            let r = local(stroke.box)
            let shape = RoundedRectangle(cornerRadius: stroke.radius, style: .continuous)
            shape.fill(color.opacity(0.07 * min(1, fraction * 1.5)))
                .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
            shape.trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: Stroke.pen, lineCap: .round, lineJoin: .round, dash: [8, 5]))
                .shadow(color: color.opacity(0.65), radius: 6)
                .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
        case .marker:
            let r = local(stroke.box)
            RoundedRectangle(cornerRadius: stroke.radius, style: .continuous).fill(color.opacity(0.26))
                .frame(width: max(1, r.width * fraction), height: r.height)
                .position(x: r.minX + r.width * fraction / 2, y: r.midY)
        case .text:
            let r = local(stroke.box)
            HandText(text: stroke.text ?? "", size: stroke.textSize, tone: stroke.tone, fraction: fraction)
                .fixedSize()
                .offset(x: r.minX, y: r.minY)
        case .badge:
            let r = local(stroke.box)
            GelBadge(text: stroke.text ?? "", ink: ink).position(x: r.midX, y: r.midY)
        case .note:
            let r = local(stroke.box)
            StickyNote(text: stroke.text ?? "", ink: ink)
                .frame(width: r.width, height: r.height)
                .scaleEffect(1.06 - 0.06 * fraction).opacity(min(1, fraction * 2))
                .position(x: r.midX, y: r.midY)
        case .point:
            TargetRing(ink: ink).position(local(CGPoint(x: stroke.box.midX, y: stroke.box.midY)))
        case .target:
            let r = local(stroke.box)
            ClickTarget(ink: ink, radius: stroke.radius, fraction: fraction)
                .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
        case .spotlight:
            let hole = local(stroke.box)
            Path { p in
                p.addRect(CGRect(origin: .zero, size: frame.size))
                p.addRoundedRect(in: hole, cornerSize: CGSize(width: stroke.radius, height: stroke.radius), style: .continuous)
            }
            .fill(Color.black.opacity(0.42 * fraction), style: FillStyle(eoFill: true))
        case .cheer:
            let r = local(stroke.box)
            GelLabel(text: stroke.text ?? "", ink: ink, size: 15).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
        }
    }

    var penPath: Path {
        Path { p in
            for line in stroke.paths {
                guard let first = line.first else { continue }
                p.move(to: local(first))
                for point in line.dropFirst() { p.addLine(to: local(point)) }
            }
        }
    }
}

/// Free words in Orbit's handwriting, written left to right; white on dark screens, near-black on light ones.
struct HandText: View {
    let text: String
    let size: CGFloat
    let tone: Stroke.Tone
    let fraction: CGFloat

    var body: some View {
        let name = Handwriting.fontName(for: text)
        let light = tone == .light
        Text(text)
            .font(.custom(name, size: size * Handwriting.scale(for: name)))
            .foregroundStyle(light ? Color.white : Color(hex: 0x15171C))
            .shadow(color: light ? Color.black.opacity(0.5) : Color.white.opacity(0.9), radius: light ? 3 : 2)
            .mask(alignment: .leading) { GeometryReader { g in Rectangle().frame(width: g.size.width * fraction) } }
    }
}

/// The pastel gel plate labels and badges sit on: lighter at the top, a white gloss strip, a dark rim.
struct GelSurface<S: InsettableShape>: View {
    let ink: Ink
    let shape: S

    var body: some View {
        let gel = ink.gel
        GeometryReader { g in
            ZStack {
                shape.fill(Color(hex: 0x1C1E24).opacity(0.12)).offset(y: 1)
                shape.fill(LinearGradient(colors: [gel.top, gel.mid, gel.low], startPoint: .top, endPoint: .bottom))
                shape.fill(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom))
                    .frame(width: max(0, g.size.width - g.size.height * 0.5), height: g.size.height * 0.42)
                    .offset(y: -g.size.height * 0.2)
                shape.strokeBorder(gel.rim, lineWidth: 1)
            }
        }
    }
}

/// The pill that names a mark, popping in once its mark is drawn.
struct GelLabel: View {
    let text: String
    let ink: Ink
    var size: CGFloat = 12
    @State private var shown = false

    var body: some View {
        Text(text).font(.system(size: size, weight: .semibold)).foregroundStyle(Color(hex: 0x15171C)).lineLimit(1).fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(GelSurface(ink: ink, shape: Capsule()))
            .scaleEffect(shown ? 1 : 0.6).opacity(shown ? 1 : 0)
            .onAppear { withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { shown = true } }
    }
}

/// A numbered step badge.
struct GelBadge: View {
    let text: String
    let ink: Ink
    @State private var shown = false

    var body: some View {
        Text(text).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(Color(hex: 0x15171C))
            .padding(.horizontal, 6).frame(minWidth: 20, minHeight: 20)
            .background(GelSurface(ink: ink, shape: Capsule()))
            .scaleEffect(shown ? 1 : 0.3).opacity(shown ? 1 : 0)
            .onAppear { withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) { shown = true } }
    }
}

/// A ring on the spot to look at, with a slow ripple.
struct TargetRing: View {
    let ink: Ink
    @State private var ripple = false

    var body: some View {
        ZStack {
            Circle().stroke(ink.color.opacity(0.55), lineWidth: 2).frame(width: 28, height: 28)
                .scaleEffect(ripple ? 1.8 : 1).opacity(ripple ? 0 : 0.8)
            Circle().stroke(ink.color, lineWidth: Stroke.pen).frame(width: 28, height: 28)
                .shadow(color: ink.color.opacity(0.65), radius: 6)
            Circle().fill(ink.color).frame(width: 6, height: 6)
        }
        .onAppear { withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) { ripple = true } }
    }
}

/// A short explanation on butter-yellow paper, tilted a little, with a strip of tape in Orbit's ink.
struct StickyNote: View {
    let text: String
    let ink: Ink
    static let paper = Color(hex: 0xFFE27A)
    static let fold: CGFloat = 24

    var body: some View {
        let name = Handwriting.fontName(for: text)
        ZStack(alignment: .topLeading) {
            NotePaper(fold: Self.fold).fill(Self.paper).shadow(color: Color(hex: 0x1C1E24).opacity(0.22), radius: 8, y: 4)
            NoteFold(fold: Self.fold).fill(Color.black.opacity(0.12))
            Text(text)
                .font(.custom(name, size: 19 * Handwriting.scale(for: name)))
                .foregroundStyle(Color(hex: 0x15171C)).lineSpacing(1).minimumScaleFactor(0.6)
                .padding(.horizontal, 16).padding(.top, 22).padding(.bottom, Self.fold)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            GeometryReader { g in
                Tape().fill(ink.gel.top.opacity(0.92))
                    .overlay(Tape().stroke(ink.gel.mid.opacity(0.7), lineWidth: 0.6))
                    .frame(width: g.size.width * 0.4, height: 20)
                    .position(x: g.size.width / 2, y: 1)
            }
        }
        .rotationEffect(.degrees(-2))
    }
}

struct NotePaper: Shape {
    var fold: CGFloat
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: r.origin)
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - fold))
            p.addLine(to: CGPoint(x: r.maxX - fold, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

/// The turned-up corner.
struct NoteFold: Shape {
    var fold: CGFloat
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.maxX, y: r.maxY - fold))
            p.addLine(to: CGPoint(x: r.maxX - fold, y: r.maxY))
            p.addLine(to: CGPoint(x: r.maxX - fold + 3, y: r.maxY - fold + 3))
            p.closeSubpath()
        }
    }
}

/// A strip of tape with torn ends.
struct Tape: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            let teeth = 4, step = r.height / CGFloat(teeth)
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            for i in 1...teeth { p.addLine(to: CGPoint(x: r.maxX - (i % 2 == 1 ? 3 : 0), y: r.minY + step * CGFloat(i))) }
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            for i in stride(from: teeth - 1, through: 0, by: -1) { p.addLine(to: CGPoint(x: r.minX + (i % 2 == 1 ? 3 : 0), y: r.minY + step * CGFloat(i))) }
            p.closeSubpath()
        }
    }
}

struct TrailPoint: Equatable {
    var point: CGPoint
    var time: Date
}

/// The pointer's path while you talk, fading from its oldest end.
struct TrailView: View {
    let points: [TrailPoint]
    let ink: Ink
    let frame: CGRect

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, _ in
                let now = timeline.date
                for (a, b) in zip(points, points.dropFirst()) {
                    let age = now.timeIntervalSince(a.time)
                    let alpha = max(0, 1 - age / OverlayModel.trailLife)
                    guard alpha > 0 else { continue }
                    var segment = Path()
                    segment.move(to: CGPoint(x: a.point.x - frame.minX, y: frame.maxY - a.point.y))
                    segment.addLine(to: CGPoint(x: b.point.x - frame.minX, y: frame.maxY - b.point.y))
                    context.stroke(segment, with: .color(ink.color.opacity(0.55 * alpha)), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(width: frame.width, height: frame.height)
        .allowsHitTesting(false)
    }
}

/// A control Orbit is waiting for you to click: a solid ring with a slow pulse.
struct ClickTarget: View {
    let ink: Ink
    let radius: CGFloat
    let fraction: CGFloat
    @State private var pulse = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.stroke(ink.color.opacity(0.5), lineWidth: 2)
                .scaleEffect(pulse ? 1.12 : 1).opacity(pulse ? 0 : 0.9)
            shape.trim(from: 0, to: fraction)
                .stroke(ink.color, style: StrokeStyle(lineWidth: Stroke.pen, lineCap: .round, lineJoin: .round))
                .shadow(color: ink.color.opacity(0.65), radius: 6)
        }
        .onAppear { withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) { pulse = true } }
    }
}

/// What Orbit is saying right now, at the bottom of the screen.
struct CaptionBar: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 17, weight: .medium)).foregroundStyle(.white)
            .multilineTextAlignment(.center).lineSpacing(3)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(Color(hex: 0x15171C).opacity(0.82), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .fixedSize(horizontal: false, vertical: true)
    }
}
