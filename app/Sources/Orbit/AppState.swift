import AppKit
import AVFoundation
import NaturalLanguage
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var settings = LocalStore.read(ConnectionSettings.self, name: "settings.json") ?? ConnectionSettings()
    @Published var messages = LocalStore.read([ChatMessage].self, name: "conversation.json") ?? []
    @Published var draft = ""
    @Published var attachment: ScreenAttachment?
    @Published var isBusy = false
    @Published var isCapturing = false
    @Published var error: String?
    @Published var selectedPage = "chat"
    @Published var apiKey = ""
    @Published var connectionResults: [ProviderKind: String] = [:]
    @Published var localModels: [String] = []
    @Published var isLoadingModels = false
    let voice = VoiceInput()
    let overlay = OverlayController()
    let hotkey = PushToTalk()
    @Published var hotkeyTrusted = AXIsProcessTrusted()
    private var heard = ""
    let client = ProviderClient()
    let speaker = AVSpeechSynthesizer()
    var showWindow: (() -> Void)?
    private var task: Task<Void, Never>?

    func saveSettings() {
        do { try LocalStore.write(settings, name: "settings.json") }
        catch { self.error = error.localizedDescription }
        updateCompanion()
    }
    func saveConnection() -> Bool {
        do {
            if settings.provider == .custom { try APIKeyStore.save(apiKey, endpoint: settings.customBaseURL) }
            try LocalStore.write(settings, name: "settings.json")
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func loadKey() { apiKey = APIKeyStore.read(endpoint: settings.customBaseURL) }
    func updateCompanion() {
        if settings.showCompanion { overlay.show() } else { overlay.hide() }
        if settings.talkHotkey {
            hotkey.onPress = { [weak self] in self?.beginTalk() }
            hotkey.onRelease = { [weak self] in self?.endTalk() }
            hotkey.start()
        } else {
            hotkey.onPress = {}; hotkey.onRelease = {}
        }
        hotkeyTrusted = hotkey.isTrusted
    }
    func allowHotkey() {
        hotkey.requestPermission()
        Task { for _ in 0..<30 { try? await Task.sleep(nanoseconds: 2_000_000_000); hotkeyTrusted = hotkey.isTrusted; if hotkeyTrusted { return } } }
    }
    // Hold ⌃⌥: listen; let go: Orbit looks at the screen, answers out loud, and draws.
    func beginTalk() {
        guard !isBusy, !voice.isRecording else { return }
        speaker.stopSpeaking(at: .immediate)
        heard = ""
        overlay.model.clear(); overlay.model.mood = .listening; overlay.model.caption = nil
        Task { [self] in
            await voice.start(onText: { [weak self] text in self?.heard = text; self?.overlay.model.caption = text },
                              onError: { [weak self] error in self?.error = error; self?.overlay.model.mood = .idle })
        }
    }
    func endTalk() {
        guard overlay.model.mood == .listening else { return }
        Task { [self] in
            try? await Task.sleep(nanoseconds: 350_000_000) // let the last words land
            voice.stop()
            overlay.model.mood = .idle; overlay.model.caption = nil
            let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { send(text, spoken: true) }
        }
    }
    func selectProvider(_ provider: ProviderKind) {
        settings.provider = provider
        saveSettings()
    }
    func capture() {
        guard !isCapturing, !isBusy else { return }
        isCapturing = true; error = nil
        Task {
            defer { isCapturing = false }
            do { attachment = try await ScreenCapture.capture() }
            catch { self.error = error.localizedDescription }
        }
    }
    func send(_ spokenText: String? = nil, spoken: Bool = false) {
        let text = (spokenText ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBusy, !text.isEmpty else { return }
        voice.stop(); speaker.stopSpeaking(at: .immediate)
        let configuration = settings
        let key = configuration.provider == .custom ? APIKeyStore.read(endpoint: configuration.customBaseURL) : ""
        var image = attachment
        if spokenText == nil { draft = "" }
        attachment = nil; isBusy = true; error = nil
        overlay.model.clear(); overlay.model.say(nil); overlay.model.mood = .thinking
        task = Task {
            defer { isBusy = false; task = nil; overlay.model.mood = .idle }
            if image == nil, configuration.seesScreen {
                do { image = try await ScreenCapture.capture() }
                catch { self.error = error.localizedDescription }
            }
            messages.append(ChatMessage(role: "user", text: text, hadImage: image != nil))
            persist()
            let history = messages
            do {
                let result = try await client.reply(settings: configuration, messages: history, image: image?.data, apiKey: key)
                try Task.checkCancellation()
                let parsed = SketchScript.parse(result.text)
                messages.append(ChatMessage(role: "assistant", text: parsed.text, provider: configuration.provider.title))
                connectionResults[configuration.provider] = "Reply verified"
                persist()
                if let image, !parsed.marks.isEmpty { overlay.model.play(parsed.marks, frame: image.frame) }
                if settings.showCompanion { overlay.model.say(parsed.text) }
                if spoken || settings.speakResponses { speak(parsed.text) }
            } catch is CancellationError { self.error = "Stopped. You can send another message." }
            catch { self.error = error.localizedDescription }
        }
    }
    func stop() { task?.cancel(); client.cancel(); speaker.stopSpeaking(at: .immediate); voice.stop() }
    func testConnection() {
        guard !isBusy, saveConnection() else { return }
        let configuration = settings
        let key = configuration.provider == .custom ? apiKey : ""
        isBusy = true; error = nil
        connectionResults[configuration.provider] = "Testing…"
        task = Task {
            defer { isBusy = false; task = nil }
            do {
                let result = try await client.reply(settings: configuration, messages: [ChatMessage(role: "user", text: "Reply with exactly: Orbit connection OK.")], image: nil, apiKey: key)
                try Task.checkCancellation()
                connectionResults[configuration.provider] = "Reply received: " + String(result.text.prefix(100))
            } catch {
                connectionResults[configuration.provider] = "Not connected"
                self.error = error.localizedDescription
            }
        }
    }
    func fetchModels() {
        guard !isLoadingModels else { return }
        isLoadingModels = true; error = nil
        Task {
            defer { isLoadingModels = false }
            do {
                localModels = try await client.localModels(base: settings.ollamaBaseURL)
                if settings.ollamaModel.isEmpty, let first = localModels.first { settings.ollamaModel = first; saveSettings() }
                if localModels.isEmpty { error = "Ollama is running, but no models are installed yet." }
            } catch { self.error = error.localizedDescription }
        }
    }
    func toggleVoice() {
        if voice.isRecording { voice.stop(); return }
        let prefix = draft.isEmpty ? "" : draft + " "
        Task { [self] in await voice.start(onText: { [weak self] text in self?.draft = prefix + text }, onError: { [weak self] error in self?.error = error }) }
    }
    func speak(_ text: String) {
        speaker.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.5
        if let language = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue,
           let voice = AVSpeechSynthesisVoice(language: language) ?? AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language.hasPrefix(language) }) {
            utterance.voice = voice
        }
        speaker.speak(utterance)
    }
    func newChat() { guard !isBusy else { return }; messages = []; attachment = nil; error = nil; persist() }
    func persist() {
        if messages.count > 100 { messages = Array(messages.suffix(100)) }
        do { try LocalStore.write(messages, name: "conversation.json") }
        catch { self.error = error.localizedDescription }
    }
    func openLogin() {
        let path = settings.provider == .codex ? settings.codexPath : settings.claudePath
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { error = "Choose the CLI executable first."; return }
        let command = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "' " + (settings.provider == .codex ? "login" : "auth login")
        let alert = NSAlert()
        alert.messageText = "Sign in using the official CLI"
        alert.informativeText = "Run this in Terminal:\n\n" + command
        alert.addButton(withTitle: "Copy command & open Terminal")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        }
    }
}
