import AppKit

/// Drag over part of the screen for Orbit to look at, like ⌘⇧4. A click takes the whole screen; Esc cancels.
@MainActor
enum AreaPicker {
    private static var session: AreaPickerSession?

    /// The picked area in global AppKit coordinates, or nil when cancelled.
    static func pick() async -> CGRect? {
        session?.finish(nil)
        return await withCheckedContinuation { continuation in
            let picker = AreaPickerSession { rect in
                session = nil
                continuation.resume(returning: rect)
            }
            session = picker
            picker.begin()
        }
    }

    /// The rectangle between two points, kept inside one screen and snapped to whole points.
    static func area(from a: CGPoint, to b: CGPoint, within screen: CGRect) -> CGRect {
        let p = CGPoint(x: min(max(a.x, screen.minX), screen.maxX), y: min(max(a.y, screen.minY), screen.maxY))
        let q = CGPoint(x: min(max(b.x, screen.minX), screen.maxX), y: min(max(b.y, screen.minY), screen.maxY))
        return CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(p.x - q.x), height: abs(p.y - q.y)).integral
    }
    /// Drags smaller than this count as a click.
    static let minimumSide: CGFloat = 8
}

@MainActor
final class AreaPickerSession {
    private var windows: [AreaPickerWindow] = []
    private let done: (CGRect?) -> Void
    private var finished = false
    private var resignObserver: NSObjectProtocol?
    var start: CGPoint?
    var startScreen: CGRect = .zero
    var selection: CGRect?

    init(done: @escaping (CGRect?) -> Void) { self.done = done }

    func begin() {
        windows = NSScreen.screens.map { AreaPickerWindow(screen: $0, session: self) }
        NSApp.activate(ignoringOtherApps: true)
        windows.forEach { $0.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        (windows.first { $0.frame.contains(mouse) } ?? windows.first)?.makeKey()
        NSCursor.crosshair.push()
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(nil) }
        }
    }

    func finish(_ rect: CGRect?) {
        guard !finished else { return }
        finished = true
        NSCursor.pop()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        windows.forEach { $0.orderOut(nil) }
        windows = []
        done(rect)
    }

    func press(at point: CGPoint) {
        start = point
        startScreen = NSScreen.screens.first { $0.frame.contains(point) }?.frame ?? .zero
        selection = nil
        redraw()
    }
    func drag(to point: CGPoint) {
        guard let start else { return }
        selection = AreaPicker.area(from: start, to: point, within: startScreen)
        redraw()
    }
    func release(at point: CGPoint) {
        drag(to: point)
        if let selection, selection.width >= AreaPicker.minimumSide, selection.height >= AreaPicker.minimumSide { finish(selection) }
        else { finish(startScreen.isEmpty ? nil : startScreen) }
    }
    private func redraw() { windows.forEach { $0.contentView?.needsDisplay = true } }
}

final class AreaPickerWindow: NSWindow {
    private weak var session: AreaPickerSession?

    init(screen: NSScreen, session: AreaPickerSession) {
        self.session = session
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        contentView = AreaPickerView(session: session)
        setFrame(screen.frame, display: false)
    }
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { MainActor.assumeIsolated { session?.finish(nil) } } else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { MainActor.assumeIsolated { session?.finish(nil) } }
}

final class AreaPickerView: NSView {
    private weak var session: AreaPickerSession?
    init(session: AreaPickerSession) { self.session = session; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) { MainActor.assumeIsolated { session?.press(at: NSEvent.mouseLocation) } }
    override func mouseDragged(with event: NSEvent) { MainActor.assumeIsolated { session?.drag(to: NSEvent.mouseLocation) } }
    override func mouseUp(with event: NSEvent) { MainActor.assumeIsolated { session?.release(at: NSEvent.mouseLocation) } }
    override func rightMouseDown(with event: NSEvent) { MainActor.assumeIsolated { session?.finish(nil) } }

    override func draw(_ dirtyRect: NSRect) {
        guard let window else { return }
        let selection = MainActor.assumeIsolated { session?.selection }
        NSColor.black.withAlphaComponent(0.28).setFill()
        bounds.fill()
        guard let selection, selection.intersects(window.frame) else {
            hint("drag over what orbit should look at  ·  click for the whole screen  ·  esc to cancel")
            return
        }
        let local = selection.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        NSColor.clear.setFill()
        local.fill(using: .copy)
        let border = NSBezierPath(rect: local.insetBy(dx: -1, dy: -1))
        border.lineWidth = 2
        NSColor(DS.Colors.link).setStroke()
        border.stroke()
        label("\(Int(selection.width)) × \(Int(selection.height))", below: local)
    }

    private func hint(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor(DS.Colors.ink)]
        let size = (text as NSString).size(withAttributes: attributes)
        let pill = CGRect(x: bounds.midX - size.width / 2 - 18, y: bounds.maxY - 120, width: size.width + 36, height: size.height + 16)
        NSColor(white: 0.97, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        (text as NSString).draw(at: CGPoint(x: pill.minX + 18, y: pill.minY + 8), withAttributes: attributes)
    }

    private func label(_ text: String, below rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        var origin = CGPoint(x: rect.maxX - size.width - 10, y: rect.minY - size.height - 12)
        if origin.y < bounds.minY + 4 { origin.y = rect.minY + 8 }
        let pill = CGRect(x: origin.x - 8, y: origin.y - 4, width: size.width + 16, height: size.height + 8)
        NSColor(DS.Colors.link).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}
