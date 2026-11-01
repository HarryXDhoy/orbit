import AppKit
import ApplicationServices

/// A keyboard shortcut: modifiers alone (for hold-to-talk) or modifiers plus one key.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt16?
    var key: String?
    var modifiers: UInt

    static let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command, .function]
    static let talkDefault = Shortcut(keyCode: nil, key: nil, flags: [.control, .option])
    static let clearDefault = Shortcut(keyCode: 40, key: "K", flags: [.control, .command])
    static let openDefault = Shortcut(keyCode: 31, key: "O", flags: [.control, .command])
    static let typeDefault = Shortcut(keyCode: 17, key: "T", flags: [.control, .command])
    static let dictateDefault = Shortcut(keyCode: nil, key: nil, flags: [.control, .shift])

    init(keyCode: UInt16?, key: String?, flags: NSEvent.ModifierFlags) {
        self.keyCode = keyCode; self.key = key; modifiers = flags.intersection(Self.relevant).rawValue
    }
    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.relevant) }
    var modifierCount: Int { [NSEvent.ModifierFlags.control, .option, .shift, .command, .function].filter { flags.contains($0) }.count }

    var display: String {
        var out = ""
        if flags.contains(.function) { out += "fn " }
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        return out + (key ?? "")
    }
    /// Spelled out for sentences, e.g. "⌃ control + ⌥ option".
    var spoken: String {
        var parts: [String] = []
        if flags.contains(.function) { parts.append("fn") }
        if flags.contains(.control) { parts.append("⌃ control") }
        if flags.contains(.option) { parts.append("⌥ option") }
        if flags.contains(.shift) { parts.append("⇧ shift") }
        if flags.contains(.command) { parts.append("⌘ command") }
        if let key { parts.append(key) }
        return parts.joined(separator: " + ")
    }

    static func keyName(_ event: NSEvent) -> String {
        let named: [UInt16: String] = [49: "Space", 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                       122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        if let name = named[event.keyCode] { return name }
        let chars = event.charactersIgnoringModifiers?.uppercased() ?? ""
        return chars.isEmpty || chars.unicodeScalars.contains(where: { $0.value < 32 }) ? "key \(event.keyCode)" : chars
    }
}

/// Global keyboard commands. Seeing keys while another app is in front needs Accessibility permission.
@MainActor
final class Hotkeys {
    var talk = Shortcut.talkDefault
    var clear = Shortcut.clearDefault
    var open = Shortcut.openDefault
    var type = Shortcut.typeDefault
    var dictate = Shortcut.dictateDefault
    var talkEnabled = true
    var dictateEnabled = true
    /// Tap control twice to open the typing box.
    var doubleControl = true
    /// Set while a shortcut recorder is listening, so typing a new shortcut doesn't fire the old one.
    var paused = false
    var onTalkStart: () -> Void = {}
    var onTalkEnd: () -> Void = {}
    var onTalkCancel: () -> Void = {}
    var onClear: () -> Void = {}
    var onOpen: () -> Void = {}
    var onType: () -> Void = {}
    var onDictateStart: () -> Void = {}
    var onDictateEnd: () -> Void = {}
    var onDictateCancel: () -> Void = {}
    /// Escape with nothing else held; never swallowed, so the app in front still gets it.
    var onEscape: () -> Void = {}
    private(set) var isTalking = false
    private(set) var isDictating = false
    private var lastMods: NSEvent.ModifierFlags = []
    private var controlDownAt: Date?
    private var lastControlTap: Date?
    /// When the type modifiers went down alone; letting go soon after with no key in between opens the box.
    private var typeArmed: Date?
    static let tapLimit: TimeInterval = 0.8
    private var monitors: [Any] = []
    private var globalInstalled = false
    private var retry: Timer?

    var isTrusted: Bool { AXIsProcessTrusted() }

    func start() {
        guard monitors.isEmpty else { return }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp], handler: { [weak self] event in
            MainActor.assumeIsolated { (self?.handle(event) ?? false) ? nil : event }
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
        guard !globalInstalled else { return }
        globalInstalled = true
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp], handler: { [weak self] event in
            MainActor.assumeIsolated { _ = self?.handle(event) }
        }) { monitors.append(global) }
    }

    /// Returns true when the event was one of Orbit's commands.
    @discardableResult func handle(_ event: NSEvent) -> Bool {
        guard !paused else { return false }
        let mods = event.modifierFlags.intersection(Shortcut.relevant)
        switch event.type {
        case .flagsChanged:
            defer { lastMods = mods }
            if talkEnabled, talk.keyCode == nil {
                let held = mods == talk.flags
                if held && !isTalking { isTalking = true; onTalkStart() }
                else if !held && isTalking { isTalking = false; onTalkEnd() }
            } else if isTalking, mods != talk.flags {
                isTalking = false; onTalkEnd()
            }
            if dictateEnabled, dictate.keyCode == nil {
                let held = mods == dictate.flags
                if held && !isDictating { isDictating = true; onDictateStart() }
                else if !held && isDictating { isDictating = false; onDictateEnd() }
            } else if isDictating, mods != dictate.flags {
                isDictating = false; onDictateEnd()
            }
            // A modifiers-only type shortcut fires on a tap: press them together and let go.
            if type.keyCode == nil, !type.flags.isEmpty {
                if mods == type.flags { if typeArmed == nil { typeArmed = Date() } }
                else if let armed = typeArmed {
                    typeArmed = nil
                    if mods.isSubset(of: type.flags), Date().timeIntervalSince(armed) < Self.tapLimit { onType() }
                }
            }
            // Two quick taps of control alone open the typing box too.
            if doubleControl {
                let now = Date()
                if mods == [.control], lastMods.isEmpty { controlDownAt = now }
                else if mods.isEmpty, lastMods == [.control], let down = controlDownAt, now.timeIntervalSince(down) < 0.3 {
                    controlDownAt = nil
                    if let tap = lastControlTap, now.timeIntervalSince(tap) < 0.45 { lastControlTap = nil; onType() }
                    else { lastControlTap = now }
                } else if !mods.isEmpty, mods != [.control] {
                    controlDownAt = nil; lastControlTap = nil
                }
            }
            return false
        case .keyDown:
            typeArmed = nil // the modifiers were part of another shortcut, like ⌃⌘K
            controlDownAt = nil; lastControlTap = nil
            if isTalking, talk.keyCode == nil {
                // The talk modifiers were part of some other shortcut; don't treat it as talking.
                isTalking = false; onTalkCancel()
            }
            if isDictating, dictate.keyCode == nil { isDictating = false; onDictateCancel() }
            if event.keyCode == 53, mods.isEmpty, !event.isARepeat { onEscape() }
            guard !event.isARepeat else { return (isTalking && event.keyCode == talk.keyCode) || (isDictating && event.keyCode == dictate.keyCode) }
            if talkEnabled, let code = talk.keyCode, event.keyCode == code, mods == talk.flags {
                isTalking = true; onTalkStart(); return true
            }
            if dictateEnabled, let code = dictate.keyCode, event.keyCode == code, mods == dictate.flags {
                isDictating = true; onDictateStart(); return true
            }
            if let code = clear.keyCode, event.keyCode == code, mods == clear.flags { onClear(); return true }
            if let code = open.keyCode, event.keyCode == code, mods == open.flags { onOpen(); return true }
            if let code = type.keyCode, event.keyCode == code, mods == type.flags { onType(); return true }
            return false
        case .keyUp:
            if isTalking, let code = talk.keyCode, event.keyCode == code { isTalking = false; onTalkEnd(); return true }
            if isDictating, let code = dictate.keyCode, event.keyCode == code { isDictating = false; onDictateEnd(); return true }
            return false
        default:
            return false
        }
    }
}
