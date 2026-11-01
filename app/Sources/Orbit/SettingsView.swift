import AppKit
import AVFoundation
import ScreenCaptureKit
import Speech
import SwiftUI

enum PrivacyPane: String {
    case screen = "Privacy_ScreenCapture", microphone = "Privacy_Microphone", speech = "Privacy_SpeechRecognition", accessibility = "Privacy_Accessibility"
    func open() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)") { NSWorkspace.shared.open(url) }
    }
    /// The TCC service name `tccutil` understands.
    var service: String {
        switch self {
        case .screen: return "ScreenCapture"
        case .microphone: return "Microphone"
        case .speech: return "SpeechRecognition"
        case .accessibility: return "Accessibility"
        }
    }
    /// Forgets Orbit's saved entry for this permission and asks again. An entry saved for an older build
    /// keeps showing as on in System Settings but never matches the current app, so toggling it does nothing.
    func resetAndAsk() {
        let reset = Process()
        reset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        reset.arguments = ["reset", service, Bundle.main.bundleIdentifier ?? "local.orbit.companion"]
        try? reset.run(); reset.waitUntilExit()
        switch self {
        case .screen: _ = CGRequestScreenCaptureAccess()
        case .accessibility: _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        case .microphone: AVCaptureDevice.requestAccess(for: .audio) { _ in }
        case .speech: SFSpeechRecognizer.requestAuthorization { _ in }
        }
        open()
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var permissions: [PrivacyPane: Bool] = [:]
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("settings").font(DS.Typography.title).foregroundStyle(DS.Colors.ink)
                    Text("how orbit behaves, how you call it, and what it’s allowed to see.").font(DS.Typography.label).foregroundStyle(DS.Colors.ink2)
                }
                MacWindow(title: "buddy.prefs") {
                    VStack(spacing: 0) {
                        row("show orbit next to your cursor", note: "the little orb that follows your mouse and draws for you") {
                            toggle($state.settings.showCompanion)
                        }
                        divider
                        row("look at my screen with every message", note: "lets orbit point at and draw on what you’re looking at") {
                            toggle($state.settings.seesScreen)
                        }
                        divider
                        row("read replies aloud", note: "replies to the talk shortcut are always spoken") {
                            toggle($state.settings.speakResponses)
                        }
                        divider
                        row("drawings stay on screen", note: "or clear them anytime with the shortcut below") {
                            Picker("", selection: $state.settings.keepDrawings) {
                                Text("10 sec").tag(10.0); Text("30 sec").tag(30.0); Text("1 min").tag(60.0); Text("until cleared").tag(0.0)
                            }.labelsHidden().fixedSize().onChange(of: state.settings.keepDrawings) { _, _ in state.saveSettings() }
                        }
                    }.padding(.horizontal, 20).padding(.vertical, 6)
                }
                MacWindow(title: "dictation.prefs") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("languages you talk in").font(DS.Typography.label).foregroundStyle(DS.Colors.ink)
                        Text("tap one to use it now, or auto to let orbit tell them apart. the language button next to talk also flips between them.").font(DS.Typography.caption).foregroundStyle(DS.Colors.ink2)
                        FlowRow(spacing: 8) {
                            Button {
                                state.settings.language = Dictation.auto; state.saveSettings()
                            } label: { Label("auto", systemImage: "sparkles") }
                                .buttonStyle(PillButtonStyle(kind: state.settings.language == Dictation.auto ? .aqua : .silver, compact: true))
                                .disabled(state.settings.languages.count < 2)
                                .help(state.settings.languages.count < 2 ? "Add a second language to use auto-detect" : "Listen for your first \(Dictation.autoLimit) languages and keep whichever you speak")
                            ForEach(state.settings.languages, id: \.self) { id in
                                HStack(spacing: 2) {
                                    Button(Dictation.name(id).lowercased()) { state.settings.language = id; state.saveSettings() }
                                        .buttonStyle(PillButtonStyle(kind: state.settings.language == id ? .aqua : .silver, compact: true))
                                    if state.settings.languages.count > 1 {
                                        Button { state.settings.languages.removeAll { $0 == id }; state.saveSettings() } label: { Image(systemName: "xmark") }
                                            .buttonStyle(IconButtonStyle()).help("Remove \(Dictation.name(id))")
                                    }
                                }
                            }
                            Menu {
                                ForEach(Dictation.supported.filter { !state.settings.languages.contains($0) }, id: \.self) { id in
                                    Button(Dictation.name(id)) { state.settings.languages.append(id); state.saveSettings() }
                                }
                            } label: { Label("add language", systemImage: "plus") }
                                .menuStyle(.borderlessButton).fixedSize().font(DS.Typography.label)
                        }
                        if state.settings.language == Dictation.auto {
                            Text("auto listens in \(state.settings.listening.map { Dictation.name($0).lowercased() }.joined(separator: ", ")) at once and keeps the one that fits. \(state.settings.languages.count > Dictation.autoLimit ? "only your first \(Dictation.autoLimit) languages are used. " : "")replies come back in the language you spoke.")
                                .font(DS.Typography.caption).foregroundStyle(DS.Colors.ink3).fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(20)
                }
                MacWindow(title: "keyboard.prefs") {
                    VStack(spacing: 0) {
                        row("talk to orbit", note: "hold, speak, let go. modifiers alone work best, since other keys also reach the app in front") {
                            HStack(spacing: 10) {
                                toggle($state.settings.talkHotkey)
                                ShortcutRecorder(shortcut: $state.settings.talkShortcut, fallback: .talkDefault, allowModifiersOnly: true, hotkeys: state.hotkeys) { state.saveSettings() }
                                    .disabled(!state.settings.talkHotkey)
                            }
                        }
                        divider
                        row("type to orbit", note: "opens a box by your cursor in any app. return sends, esc closes") {
                            ShortcutRecorder(shortcut: $state.settings.typeShortcut, fallback: .typeDefault, allowModifiersOnly: false, hotkeys: state.hotkeys) { state.saveSettings() }
                        }
                        divider
                        row("clear drawings", note: nil) {
                            ShortcutRecorder(shortcut: $state.settings.clearShortcut, fallback: .clearDefault, allowModifiersOnly: false, hotkeys: state.hotkeys) { state.saveSettings() }
                        }
                        divider
                        row("open orbit", note: nil) {
                            ShortcutRecorder(shortcut: $state.settings.openShortcut, fallback: .openDefault, allowModifiersOnly: false, hotkeys: state.hotkeys) { state.saveSettings() }
                        }
                        if let clash = clash {
                            Text(clash).font(DS.Typography.caption).foregroundStyle(DS.Colors.danger).frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 10)
                        }
                    }.padding(.horizontal, 20).padding(.vertical, 6)
                }
                MacWindow(title: "permissions.prefs") {
                    VStack(spacing: 0) {
                        permission(.screen, "screen recording", note: "to see your screen. relaunch orbit after turning it on")
                        divider
                        permission(.microphone, "microphone", note: "to hear you when you talk")
                        divider
                        permission(.speech, "speech recognition", note: "to turn your voice into words")
                        divider
                        permission(.accessibility, "accessibility", note: "to notice your shortcuts while other apps are in front")
                        Text("turned it on and it still says not allowed? use reset & ask again, turn orbit on in the list that opens, then relaunch.")
                            .font(DS.Typography.caption).foregroundStyle(DS.Colors.ink3).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                        HStack {
                            Spacer()
                            Button("relaunch orbit") { state.relaunch() }.buttonStyle(PillButtonStyle(kind: .silver, compact: true))
                        }.padding(.vertical, 12)
                    }.padding(.horizontal, 20).padding(.vertical, 6)
                }
                MacWindow(title: "about.txt") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            OrbitMark(size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("orbit \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")").font(DS.Typography.bodyMedium)
                                Text("your chats stay on this mac").font(DS.Typography.caption).foregroundStyle(DS.Colors.ink2)
                            }
                            Spacer()
                        }
                        HStack(spacing: 8) {
                            Button("show chat history folder") { NSWorkspace.shared.activateFileViewerSelecting([LocalStore.directory]) }
                                .buttonStyle(PillButtonStyle(kind: .silver, compact: true))
                            Button("delete all chats") { state.deleteAllChats() }
                                .buttonStyle(PillButtonStyle(kind: .ghost, compact: true)).disabled(state.isBusy || state.conversations.isEmpty)
                        }
                    }.padding(20)
                }
            }
            .frame(maxWidth: 720).padding(.horizontal, 32).padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .onAppear(perform: check)
        .onReceive(refresh) { _ in check() }
    }

    private var clash: String? {
        let s = state.settings
        let keyed = [s.typeShortcut, s.clearShortcut, s.openShortcut]
        if Set(keyed.map(\.display)).count < keyed.count { return "two commands use the same shortcut." }
        if s.talkHotkey, keyed.contains(s.talkShortcut) { return "talk to orbit shares a shortcut with another command." }
        return nil
    }

    private func check() {
        permissions[.screen] = CGPreflightScreenCaptureAccess()
        permissions[.microphone] = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        permissions[.speech] = SFSpeechRecognizer.authorizationStatus() == .authorized
        permissions[.accessibility] = AXIsProcessTrusted()
        state.hotkeyTrusted = permissions[.accessibility] ?? false
    }

    private var divider: some View { Rectangle().fill(DS.Colors.hairline).frame(height: 1) }

    private func toggle(_ binding: Binding<Bool>) -> some View {
        Toggle("", isOn: binding).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(DS.Colors.link)
            .onChange(of: binding.wrappedValue) { _, _ in state.saveSettings() }
    }

    private func row<Trailing: View>(_ title: String, note: String?, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(DS.Typography.label).foregroundStyle(DS.Colors.ink)
                if let note { Text(note).font(DS.Typography.caption).foregroundStyle(DS.Colors.ink2).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            trailing()
        }.padding(.vertical, 12)
    }

    private func permission(_ pane: PrivacyPane, _ title: String, note: String) -> some View {
        row(title, note: note) {
            HStack(spacing: 10) {
                StatusPill(text: permissions[pane] == true ? "allowed" : "not allowed", live: permissions[pane] == true)
                if permissions[pane] != true {
                    Button("open settings") { pane == .accessibility ? state.allowHotkey() : pane.open() }.buttonStyle(LinkButtonStyle())
                    Button("reset & ask again") { pane.resetAndAsk(); if pane == .accessibility { state.allowHotkey() } }
                        .buttonStyle(LinkButtonStyle())
                        .help("Already turned on but still not allowed? This clears Orbit’s old entry so you can turn it on fresh.")
                }
            }
        }
    }
}

/// Click, then press the new shortcut. Esc cancels; the ↺ button restores the default.
struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    let fallback: Shortcut
    let allowModifiersOnly: Bool
    let hotkeys: Hotkeys
    var onChange: () -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var peak: NSEvent.ModifierFlags = []
    @State private var live: NSEvent.ModifierFlags = []

    var body: some View {
        HStack(spacing: 4) {
            Button { recording ? finish(nil) : begin() } label: {
                Text(recording ? (live.isEmpty ? "press keys…" : Shortcut(keyCode: nil, key: nil, flags: live).display + "…") : shortcut.display)
                    .font(.system(size: 13, weight: .medium, design: .rounded)).frame(minWidth: 70)
            }
            .buttonStyle(PillButtonStyle(kind: recording ? .aqua : .silver, compact: true))
            .help(recording ? "Press the new shortcut, or Esc to cancel" : "Click to change")
            if shortcut != fallback && !recording {
                Button { shortcut = fallback; onChange() } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(IconButtonStyle()).help("Restore \(fallback.display)")
            }
        }
        .onDisappear { finish(nil) }
    }

    private func begin() {
        recording = true; peak = []; live = []
        hotkeys.paused = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            MainActor.assumeIsolated { handle(event) }
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let mods = event.modifierFlags.intersection(Shortcut.relevant)
        if event.type == .flagsChanged {
            live = mods
            if Shortcut(keyCode: nil, key: nil, flags: mods).modifierCount > Shortcut(keyCode: nil, key: nil, flags: peak).modifierCount { peak = mods }
            // Releasing every modifier without a key records a modifiers-only shortcut.
            if allowModifiersOnly, mods.isEmpty, !peak.isEmpty { finish(Shortcut(keyCode: nil, key: nil, flags: peak)) }
            return event
        }
        if event.keyCode == 53, mods.isEmpty { finish(nil); return nil }
        guard !mods.isEmpty else { NSSound.beep(); return nil }
        finish(Shortcut(keyCode: event.keyCode, key: Shortcut.keyName(event), flags: mods))
        return nil
    }

    private func finish(_ result: Shortcut?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { hotkeys.paused = false }
        recording = false; live = []
        if let result { shortcut = result; onChange() }
    }
}
