import AppKit
import ApplicationServices
import SwiftUI

/// The walkthrough tags a reply may carry besides its drawings: the task's short name, and a step Orbit can't
/// see finish (typing, dragging, picking a file), which goes on when the user says it's done.
enum WalkScript {
    private static let regex = try! NSRegularExpression(pattern: #"\[(TASK|WAIT):([^\]\n]{1,200})\]"#)

    static func parse(_ text: String) -> (text: String, task: String?, wait: String?) {
        let range = NSRange(text.startIndex..., in: text)
        var task: String?, wait: String?
        for match in regex.matches(in: text, range: range) {
            guard let kr = Range(match.range(at: 1), in: text), let br = Range(match.range(at: 2), in: text) else { continue }
            let words = text[br].trimmingCharacters(in: .whitespaces)
            guard !words.isEmpty else { continue }
            if text[kr] == "TASK" { task = task ?? String(words.prefix(60)) } else { wait = wait ?? String(words.prefix(120)) }
        }
        let clean = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (clean, task, wait)
    }
}

/// What one step of a walkthrough waits for before Orbit looks at the screen again.
enum WalkStep: Equatable {
    /// A click on the control Orbit ringed (global AppKit coordinates).
    case click(CGRect, String?)
    /// The pointer resting on it, for menus and previews that open on hover.
    case hover(CGRect, String?)
    /// Work Orbit can't see finish; the user says when it's done.
    case manual(String)

    /// The step a reply sets up: its last ring, else the manual step it names.
    static func from(_ strokes: [Stroke], wait: String?) -> WalkStep? {
        if let ring = strokes.last(where: { $0.kind == .target }) {
            return ring.waitsForHover ? .hover(ring.box, ring.label) : .click(ring.box, ring.label)
        }
        return wait.map { .manual($0) }
    }

    var area: CGRect? {
        switch self {
        case .click(let r, _), .hover(let r, _): return r
        case .manual: return nil
        }
    }

    /// What Orbit sends for the user once the step is done, in the conversation's language.
    func doneMessage(language: String) -> String {
        let say = WalkPhrases.for(language)
        let first: String
        switch self {
        case .click(_, let label): first = label.map { say.clicked.replacingOccurrences(of: "{}", with: $0) } ?? say.clickedIt
        case .hover(_, let label): first = label.map { say.pointing.replacingOccurrences(of: "{}", with: $0) } ?? say.pointingThere
        case .manual: first = say.done
        }
        return first + say.space + say.next
    }
}

/// The few words a walkthrough says for the user, in the languages Orbit has voices for.
struct WalkPhrases {
    var clicked: String, clickedIt: String, pointing: String, pointingThere: String, done: String, next: String
    /// Between the two sentences; Japanese and Chinese run them together.
    var space = " "

    static func `for`(_ language: String) -> WalkPhrases {
        switch Voices.code(language) {
        case "ko": return WalkPhrases(clicked: "“{}” 눌렀어요.", clickedIt: "눌렀어요.", pointing: "“{}” 위에 올렸어요.", pointingThere: "올렸어요.", done: "다 했어요.", next: "다음은 뭐예요?")
        case "ja": return WalkPhrases(clicked: "「{}」を押しました。", clickedIt: "押しました。", pointing: "「{}」にカーソルを置きました。", pointingThere: "カーソルを置きました。", done: "できました。", next: "次は？", space: "")
        case "zh": return WalkPhrases(clicked: "点了“{}”。", clickedIt: "点好了。", pointing: "鼠标放在“{}”上了。", pointingThere: "鼠标放好了。", done: "做好了。", next: "下一步呢？", space: "")
        case "es": return WalkPhrases(clicked: "Hice clic en “{}”.", clickedIt: "Hice clic.", pointing: "El puntero está sobre “{}”.", pointingThere: "El puntero está ahí.", done: "Listo.", next: "¿Qué sigue?")
        case "fr": return WalkPhrases(clicked: "J'ai cliqué sur « {} ».", clickedIt: "J'ai cliqué.", pointing: "Le pointeur est sur « {} ».", pointingThere: "Le pointeur est dessus.", done: "C'est fait.", next: "Et ensuite ?")
        case "de": return WalkPhrases(clicked: "„{}“ geklickt.", clickedIt: "Geklickt.", pointing: "Der Zeiger ist auf „{}“.", pointingThere: "Der Zeiger ist drauf.", done: "Erledigt.", next: "Was kommt jetzt?")
        default: return WalkPhrases(clicked: "Clicked “{}”.", clickedIt: "Clicked it.", pointing: "Pointer's on “{}”.", pointingThere: "Pointer's there.", done: "Done.", next: "What's next?")
        }
    }
}

/// A step being waited on.
struct WalkWait: Equatable {
    let step: WalkStep
    let since: Date
    private(set) var restingSince: Date?

    /// A click this close to the ring still counts.
    static let slop: CGFloat = 4
    /// How long the pointer rests on a hover target before it counts.
    static let dwell: TimeInterval = 0.6
    /// A step nobody finishes in this long ends the walkthrough.
    static let patience: TimeInterval = 300

    init(_ step: WalkStep, since: Date = Date()) { self.step = step; self.since = since }

    func finishes(clickAt point: CGPoint) -> Bool {
        guard case .click(let area, _) = step else { return false }
        return area.insetBy(dx: -Self.slop, dy: -Self.slop).contains(point)
    }
    /// Follows the pointer; true once it has rested on a hover target long enough.
    mutating func rests(at point: CGPoint, now: Date) -> Bool {
        guard case .hover(let area, _) = step, area.insetBy(dx: -Self.slop, dy: -Self.slop).contains(point) else { restingSince = nil; return false }
        let start = restingSince ?? now
        restingSince = start
        return now.timeIntervalSince(start) >= Self.dwell
    }
    func expired(at now: Date) -> Bool { now.timeIntervalSince(since) > Self.patience }
}

/// What the walkthrough bar shows.
struct WalkStatus: Equatable {
    enum State: Equatable { case waiting(WalkStep), looking, done }
    var task: String?
    var count: Int
    var state: State
}

/// Runs a walkthrough. A ring waits for its click or a resting pointer, a manual step waits for the user, and
/// each finished step asks for the next one with a fresh look at the screen.
@MainActor
final class Walkthrough {
    enum Phase: Equatable { case off, waiting(WalkWait), looking }

    private(set) var phase = Phase.off
    private(set) var task: String?
    private(set) var count = 0
    private var chat: UUID?
    private var spoken = false
    private var language = "en"
    private var monitors: [Any] = []
    private var timer: Timer?
    /// Bumped whenever the walkthrough moves on, so a next-step request that was waiting for the app to settle
    /// doesn't go out after the user stopped it or started talking.
    private var generation = 0
    /// Takes the finished step's marks off the screen.
    var clearMarks: () -> Void = {}
    /// Asks for the next step, as the user, in the walkthrough's chat.
    var onNext: (_ message: String, _ chat: UUID?, _ spoken: Bool) -> Void = { _, _, _ in }
    /// The bar follows this; nil hides it.
    var onChange: (WalkStatus?) -> Void = { _ in }
    /// Seconds for the app to react to the click before Orbit looks again.
    var settle: Double = 0.7

    static let maxSteps = 15

    var isActive: Bool { phase != .off }
    var isWaiting: Bool { if case .waiting = phase { return true } else { return false } }

    /// After each reply: wait for the step it sets up, or end the walkthrough when it sets none.
    func follow(_ strokes: [Stroke], wait: String?, task: String?, chat: UUID?, spoken: Bool, language: String) {
        let continuing = isActive
        unwatch()
        guard let step = WalkStep.from(strokes, wait: wait) else {
            guard continuing else { return }
            // A cheer is a walkthrough's last line: say it's done before the bar goes.
            if strokes.contains(where: { $0.kind == .cheer }) { finish() } else { stop() }
            return
        }
        count = continuing ? count + 1 : 1
        if !continuing { self.task = nil }
        if let task { self.task = task }
        guard count <= Self.maxSteps else { stop(); return }
        self.chat = chat; self.spoken = spoken; self.language = language
        generation += 1
        phase = .waiting(WalkWait(step))
        watch(step)
        report()
    }

    /// The user talks or types to Orbit mid-walkthrough: stop waiting, but keep the task and its count for the reply.
    func pause() {
        guard isActive else { return }
        unwatch()
        generation += 1
        phase = .looking
        report()
    }

    /// The user says the manual step is done.
    func proceed() {
        guard case .waiting(let wait) = phase, case .manual = wait.step else { return }
        advance(wait.step)
    }

    func stop() {
        unwatch()
        generation += 1
        phase = .off; task = nil; count = 0; chat = nil
        onChange(nil)
    }

    /// A click anywhere; only one on the ringed control finishes the step.
    func clicked(at point: CGPoint) {
        guard case .waiting(let wait) = phase, wait.finishes(clickAt: point) else { return }
        advance(wait.step)
    }

    private func advance(_ step: WalkStep) {
        unwatch()
        generation += 1
        phase = .looking
        SoundFX.shared.play(.tick)
        clearMarks()
        report()
        let message = step.doneMessage(language: language), chat = chat, spoken = spoken, mine = generation
        Task { [weak self, settle] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, settle) * 1_000_000_000))
            guard let self, self.generation == mine else { return }
            self.onNext(message, chat, spoken)
        }
    }

    private func finish() {
        let status = WalkStatus(task: task, count: count, state: .done)
        unwatch()
        generation += 1
        phase = .off; task = nil; count = 0; chat = nil
        onChange(status)
        let mine = generation
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard let self, self.generation == mine else { return }
            self.onChange(nil)
        }
    }

    private func report() {
        switch phase {
        case .off: onChange(nil)
        case .waiting(let wait): onChange(WalkStatus(task: task, count: count, state: .waiting(wait.step)))
        case .looking: onChange(WalkStatus(task: task, count: count, state: .looking))
        }
    }

    private func watch(_ step: WalkStep) {
        if case .click = step {
            let handler: (NSEvent) -> Void = { [weak self] _ in
                MainActor.assumeIsolated { self?.clicked(at: NSEvent.mouseLocation) }
            }
            if let global = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: handler) { monitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { event in handler(event); return event }) { monitors.append(local) }
        }
        // Watches the pointer on a hover step, and how long every step has waited.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard case .waiting(var wait) = phase else { return }
        let now = Date()
        if wait.expired(at: now) { clearMarks(); stop(); return }
        if wait.rests(at: NSEvent.mouseLocation, now: now) { advance(wait.step); return }
        phase = .waiting(wait)
    }

    private func unwatch() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        timer?.invalidate(); timer = nil
    }
}

/// Finds the real control under a spot with Accessibility, so a ring hugs the button the user will click
/// instead of the model's estimate of where it is.
@MainActor
enum ControlFinder {
    static let pressable: Set<String> = ["AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
                                          "AXMenuItem", "AXMenuBarItem", "AXTextField", "AXTextArea", "AXComboBox", "AXSlider",
                                          "AXIncrementor", "AXDisclosureTriangle", "AXDockItem", "AXColorWell", "AXCell", "AXRow"]

    /// The frame of the control at the middle of `box` (global AppKit coordinates), or nil when nothing there fits.
    static func control(near box: CGRect) -> CGRect? {
        guard AXIsProcessTrusted(), let main = NSScreen.screens.first?.frame else { return nil }
        // Accessibility measures down from the top of the main screen; AppKit measures up from its bottom.
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(box.midX), Float(main.maxY - box.midY), &hit) == .success,
              var element = hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != getpid() else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25) // a busy app shouldn't hold up the drawing
        // The spot is often a label or an icon inside the control; climb to the part that takes the click.
        for _ in 0..<5 {
            if let role = attribute(element, kAXRoleAttribute) as? String, pressable.contains(role) {
                guard let frame = frame(of: element) else { return nil }
                let control = CGRect(x: frame.minX, y: main.maxY - frame.maxY, width: frame.width, height: frame.height)
                return plausible(control, for: box) ? control : nil
            }
            guard let parent = attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
            element = parent as! AXUIElement
        }
        return nil
    }

    /// A control about the size of the box the model drew: not a whole pane, not a speck inside it.
    nonisolated static func plausible(_ control: CGRect, for box: CGRect) -> Bool {
        guard control.width >= 6, control.height >= 6, control.width <= 900, control.height <= 320 else { return false }
        let ratio = (control.width * control.height) / max(1, box.width * box.height)
        return (0.12...8).contains(ratio)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}

// MARK: - The bar

/// Floats above the overlay (and its spotlight) without taking focus from the app being walked through.
final class WalkthroughPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 72), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
    }
}

/// Takes the first click although the bar is never the key window, so its buttons work from any app.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The walkthrough's bar at the top of the screen: which step this is, the task, what Orbit is waiting for, a
/// button for steps Orbit can't see finish, and a way out.
@MainActor
final class WalkthroughBar {
    private let panel = WalkthroughPanel()
    private let hosting = FirstClickHostingView(rootView: WalkthroughBarView(status: WalkStatus(task: nil, count: 1, state: .looking), ink: .blue, next: {}, stop: {}))
    private var screen: CGRect?
    private var avoid: CGRect?
    var onNext: () -> Void = {}
    var onStop: () -> Void = {}

    init() { panel.contentView = hosting }

    func show(_ status: WalkStatus?, ink: Ink) {
        guard let status else { panel.orderOut(nil); return }
        if case .waiting(let step) = status.state {
            let spot = step.area.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
            screen = (NSScreen.screens.first { $0.frame.contains(spot) } ?? NSScreen.main)?.visibleFrame
            avoid = step.area
        }
        hosting.rootView = WalkthroughBarView(status: status, ink: ink, next: { [weak self] in self?.onNext() }, stop: { [weak self] in self?.onStop() })
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let bounds = screen ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height, width: size.width, height: size.height)
        // Never on top of the control it's waiting for: the bottom of the screen when the top would cover it.
        if let avoid, frame.intersects(avoid.insetBy(dx: -12, dy: -12)) { frame.origin.y = bounds.minY }
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }
}

struct WalkthroughBarView: View {
    let status: WalkStatus
    let ink: Ink
    var next: () -> Void
    var stop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            GelBadge(text: status.state == .done ? "✓" : "\(status.count)", ink: ink)
            VStack(alignment: .leading, spacing: 1) {
                Text(status.task ?? "walkthrough").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Colors.ink)
                Text(line).font(DS.Typography.caption).foregroundStyle(DS.Colors.ink2)
            }
            .lineLimit(1).frame(maxWidth: 320, alignment: .leading).fixedSize()
            if case .waiting(.manual(_)) = status.state {
                Button("next step", action: next).buttonStyle(PillButtonStyle(kind: .aqua, compact: true))
            }
            if status.state != .done {
                Button(action: stop) { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).help("stop the walkthrough (esc)")
            }
        }
        .padding(.leading, 10).padding(.trailing, 8).frame(height: 44)
        .background(DS.Colors.silver, in: Capsule())
        .overlay(Capsule().strokeBorder(DS.Colors.silverEdge.opacity(0.55), lineWidth: DS.edge))
        .dsShadow()
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 24) // room for the shadow
        .fixedSize()
    }

    var line: String {
        switch status.state {
        case .waiting(.click(_, let label)): return label.map { "click “\($0)”" } ?? "click the ringed control"
        case .waiting(.hover(_, let label)): return label.map { "point at “\($0)”" } ?? "point at the ringed spot"
        case .waiting(.manual(let what)): return what
        case .looking: return "looking at the screen…"
        case .done: return "all done"
        }
    }
}
