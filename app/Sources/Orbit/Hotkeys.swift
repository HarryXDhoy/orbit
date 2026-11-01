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
    var talkEnabled = true
    /// Set while a shortcut recorder is listening, so typing a new shortcut doesn't fire the old one.
    var paused = false
    var onTalkStart: () -> Void = {}
    var onTalkEnd: () -> Void = {}
    var onTalkCancel: () -> Void = {}
    var onClear: () -> Void = {}
    var onOpen: () -> Void = {}
    var onType: () -> Void = {}
    private(set) var isTalking = false
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
            if talkEnabled, talk.keyCode == nil {
                let held = mods == talk.flags
                if held && !isTalking { isTalking = true; onTalkStart() }
                else if !held && isTalking { isTalking = false; onTalkEnd() }
            } else if isTalking, mods != talk.flags {
                isTalking = false; onTalkEnd()
            }
            return false
        case .keyDown:
            if isTalking, talk.keyCode == nil {
                // The talk modifiers were part of some other shortcut; don't treat it as talking.
                isTalking = false; onTalkCancel()
            }
            guard !event.isARepeat else { return isTalking && event.keyCode == talk.keyCode }
            if talkEnabled, let code = talk.keyCode, event.keyCode == code, mods == talk.flags {
                isTalking = true; onTalkStart(); return true
            }
            if let code = clear.keyCode, event.keyCode == code, mods == clear.flags { onClear(); return true }
            if let code = open.keyCode, event.keyCode == code, mods == open.flags { onOpen(); return true }
            if let code = type.keyCode, event.keyCode == code, mods == type.flags { onType(); return true }
            return false
        case .keyUp:
            if isTalking, let code = talk.keyCode, event.keyCode == code { isTalking = false; onTalkEnd(); return true }
            return false
        default:
            return false
        }
    }
}
