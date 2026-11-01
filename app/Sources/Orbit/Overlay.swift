import AppKit
import ApplicationServices
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

/// Drives the buddy: follows the cursor with a little lag, flies off to point, and holds the pen while drawing.
@MainActor
final class OverlayModel: ObservableObject {
    @Published var buddy = NSEvent.mouseLocation
    @Published var mood: BuddyMood = .idle
    @Published var caption: String?
    @Published var strokes: [Stroke] = []
    @Published var progress: CGFloat = 0
    @Published var tilt: Double = 0
    private var timer: Timer?
    private var drawingStarted: Date?
    private var drawingDone: Date?
    private var captionUntil = Date.distantPast
    static let offset = CGPoint(x: 22, y: -24)
    static let secondsPerStroke: CGFloat = 0.55
    static let keepDrawings: TimeInterval = 30

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }

    func play(_ marks: [SketchMark], frame: CGRect) {
        strokes = marks.map { Stroke.make($0, in: frame) }
        progress = 0
        drawingStarted = Date(); drawingDone = nil
    }
    func clear() { strokes = []; progress = 0; drawingStarted = nil; drawingDone = nil }
    func say(_ text: String?) {
        caption = text.map { String($0.prefix(220)) + ($0.count > 220 ? "…" : "") }
        captionUntil = Date().addingTimeInterval(max(4, Double(text?.count ?? 0) * 0.07))
    }

    var activeStroke: Int { min(Int(progress), max(strokes.count - 1, 0)) }

    private func tick() {
        let now = Date()
        if let started = drawingStarted, !strokes.isEmpty {
            progress = min(CGFloat(strokes.count), CGFloat(now.timeIntervalSince(started)) / Self.secondsPerStroke)
            if progress >= CGFloat(strokes.count), drawingDone == nil { drawingDone = now }
        }
        if let done = drawingDone, now.timeIntervalSince(done) > Self.keepDrawings { clear() }
        if mood == .idle, caption != nil, now > captionUntil { caption = nil }

        // While drawing the buddy rides the pen tip; otherwise it trails the cursor.
        var target = NSEvent.mouseLocation
        target.x += Self.offset.x; target.y += Self.offset.y
        var ease: CGFloat = 0.28
        if drawingDone == nil, drawingStarted != nil, !strokes.isEmpty {
            let stroke = strokes[activeStroke]
            let local = progress - CGFloat(activeStroke)
            if let tip = stroke.prefix(min(1, local)).last { target = tip }
            ease = stroke.kind == .point ? 0.12 : 0.5
        }
        let next = CGPoint(x: buddy.x + (target.x - buddy.x) * ease, y: buddy.y + (target.y - buddy.y) * ease)
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

    func show() {
        if windows.isEmpty { build() }
        windows.forEach { $0.orderFrontRegardless() }
        model.start()
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild() }
            }
        }
    }
    func hide() { windows.forEach { $0.orderOut(nil) }; model.stop() }
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
                let fraction = max(0, min(1, model.progress - CGFloat(index)))
                if fraction > 0 { StrokeView(stroke: stroke, fraction: fraction, local: local) }
            }
            if frame.insetBy(dx: -60, dy: -60).contains(model.buddy) { buddy.position(local(model.buddy)) }
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    var buddy: some View {
        ZStack(alignment: .topLeading) {
            OrbitMark(size: 22).rotationEffect(.degrees(model.tilt)).dsShadow()
                .scaleEffect(model.mood == .listening ? 1.15 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.5), value: model.mood)
            Group {
                switch model.mood {
                case .listening:
                    HStack(spacing: 8) {
                        Waveform(active: true, bars: 9)
                        if let caption = model.caption, !caption.isEmpty { Text(caption).lineLimit(2) }
                    }
                    .bubbleChip()
                case .thinking:
                    Waveform(active: true, bars: 5).bubbleChip()
                case .idle:
                    if let caption = model.caption {
                        SpeechBubble(mine: false) { Text(caption).font(.system(size: 13)).foregroundStyle(DS.Colors.ink).lineSpacing(2) }
                            .frame(maxWidth: 300, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: 13)).foregroundStyle(DS.Colors.ink)
            .offset(x: 26, y: 18)
            .transition(.scale(scale: 0.6, anchor: .topLeading).combined(with: .opacity))
        }
        .frame(width: 340, height: 160, alignment: .topLeading)
        .offset(x: 159, y: 69) // keep the orb's center on the tracked point
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: model.caption)
    }
}

private extension View {
    func bubbleChip() -> some View {
        padding(.horizontal, 12).frame(minHeight: 30)
            .background(DS.Colors.silver, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(DS.Colors.silverEdge.opacity(0.55), lineWidth: DS.edge))
            .dsShadow()
            .frame(maxWidth: 300, alignment: .leading)
    }
}

struct StrokeView: View {
    let stroke: Stroke
    let fraction: CGFloat
    let local: (CGPoint) -> CGPoint
    static let ink = DS.Colors.link

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch stroke.kind {
            case .point:
                PointPulse().position(local(stroke.points[0]))
            case .text:
                Text(String((stroke.label ?? "").prefix(Int(CGFloat(stroke.label?.count ?? 0) * fraction))))
                    .font(.custom("Marker Felt", size: 24)).foregroundStyle(Self.ink)
                    .shadow(color: .white, radius: 2)
                    .fixedSize()
                    .position(x: local(stroke.labelAt).x, y: local(stroke.labelAt).y)
            case .highlight, .pen:
                let pts = stroke.prefix(fraction).map(local)
                if stroke.kind == .highlight, fraction >= 1, stroke.points.count > 3 {
                    polyline(stroke.points.map(local)).fill(Self.ink.opacity(0.08))
                }
                polyline(pts).stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                polyline(pts).stroke(Self.ink, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            if let label = stroke.label, stroke.kind != .text, fraction >= 1 {
                SpeechBubble(mine: true) { Text(label.lowercased()).font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Colors.ink).lineLimit(1) }
                    .fixedSize()
                    .position(x: local(stroke.labelAt).x + 10, y: local(stroke.labelAt).y + 30)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    func polyline(_ pts: [CGPoint]) -> Path {
        Path { p in
            guard let first = pts.first else { return }
            p.move(to: first)
            pts.dropFirst().forEach { p.addLine(to: $0) }
        }
    }
}

struct PointPulse: View {
    @State private var on = false
    var body: some View {
        ZStack {
            Circle().fill(DS.Colors.aqua).frame(width: 44, height: 44).scaleEffect(on ? 1.5 : 0.7).opacity(on ? 0 : 0.7)
            Circle().strokeBorder(DS.Colors.link, lineWidth: 3).frame(width: 30, height: 30)
            Circle().fill(DS.Colors.link).frame(width: 7, height: 7)
        }
        .onAppear { withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { on = true } }
    }
}

/// Hold ⌃ control + ⌥ option anywhere to talk to Orbit. Needs Accessibility permission to see global keys.
@MainActor
final class PushToTalk {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    private(set) var isHeld = false
    private var monitors: [Any] = []
    private var retry: Timer?
    static let combo: NSEvent.ModifierFlags = [.control, .option]

    var isTrusted: Bool { AXIsProcessTrusted() }

    func start() {
        guard monitors.isEmpty else { return }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event.modifierFlags) }
            return event
        }) { monitors.append(local) }
        if isTrusted { installGlobal() }
        else {
            // Accessibility may be granted later in System Settings; pick it up without a relaunch.
            retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isTrusted else { return }
                    self.retry?.invalidate(); self.retry = nil
                    self.installGlobal()
                }
            }
        }
    }
    func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
    private func installGlobal() {
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event.modifierFlags) }
        }) { monitors.append(global) }
    }
    private func handle(_ flags: NSEvent.ModifierFlags) {
        let held = flags.intersection([.control, .option, .command, .shift]) == Self.combo
        guard held != isHeld else { return }
        isHeld = held
        held ? onPress() : onRelease()
    }
}
