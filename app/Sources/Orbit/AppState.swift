import AppKit
import AVFoundation
import NaturalLanguage
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var settings = LocalStore.read(ConnectionSettings.self, name: "settings.json") ?? ConnectionSettings()
    @Published var conversations = AppState.loadConversations()
    /// The open chat; nil is a fresh chat that becomes a conversation on its first message.
    @Published var currentID: UUID?
    @Published var busyID: UUID?
    var messages: [ChatMessage] { conversations.first { $0.id == currentID }?.messages ?? [] }
    @Published var draft = ""
    @Published var attachment: ScreenAttachment?
    @Published var isBusy = false
    @Published var isCapturing = false
    @Published var error: String?
    @Published var selectedPage = "chat"
    @Published var apiKey = ""
    @Published var connectionResults: [ProviderKind: String] = [:]
    /// Models each connection said it offers, fetched when Connections opens or the provider changes.
    @Published var models: [ProviderKind: [ModelOption]] = [:]
    @Published var modelErrors: [ProviderKind: String] = [:]
    @Published var loadingModels: Set<ProviderKind> = []
    /// Connectors found in each CLI's own setup, remembered between launches.
    @Published var connectors: [ProviderKind: [Connector]] = LocalStore.read([ProviderKind: [Connector]].self, name: "connectors.json") ?? [:]
    @Published var connectorErrors: [ProviderKind: String] = [:]
    @Published var loadingConnectors: Set<ProviderKind> = []
    let voice = VoiceInput()
    let overlay = OverlayController()
    let hotkeys = Hotkeys()
    let quickType = QuickTypeController()
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
            if settings.provider == .custom { fetchModels(force: true) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func loadKey() { apiKey = APIKeyStore.read(endpoint: settings.customBaseURL) }
    func updateCompanion() {
        if settings.showCompanion { overlay.show() } else { overlay.hide() }
        overlay.model.keepDrawings = settings.keepDrawings > 0 ? settings.keepDrawings : .infinity
        hotkeys.talk = settings.talkShortcut
        hotkeys.clear = settings.clearShortcut
        hotkeys.open = settings.openShortcut
        hotkeys.type = settings.typeShortcut
        hotkeys.talkEnabled = settings.talkHotkey
        hotkeys.onTalkStart = { [weak self] in self?.beginTalk() }
        hotkeys.onTalkEnd = { [weak self] in self?.endTalk() }
        hotkeys.onTalkCancel = { [weak self] in self?.cancelTalk() }
        hotkeys.onClear = { [weak self] in self?.overlay.model.clear(); self?.overlay.model.say(nil) }
        hotkeys.onOpen = { [weak self] in self?.showWindow?() }
        hotkeys.onType = { [weak self] in self?.beginTyping() }
        quickType.onSend = { [weak self] text in self?.send(text) }
        hotkeys.start()
        hotkeyTrusted = hotkeys.isTrusted
    }
    func allowHotkey() {
        hotkeys.requestPermission()
        Task { for _ in 0..<30 { try? await Task.sleep(nanoseconds: 2_000_000_000); hotkeyTrusted = hotkeys.isTrusted; if hotkeyTrusted { return } } }
    }
    func nextLanguage() {
        let list = settings.languages.count > 1 ? settings.languages + [Dictation.auto] : settings.languages
        guard list.count > 1, let i = list.firstIndex(of: settings.language) else { return }
        settings.language = list[(i + 1) % list.count]
        saveSettings()
    }
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
    /// Type to Orbit from any app: a box opens by the cursor; the reply comes back in the buddy's bubble.
    func beginTyping() {
        guard !voice.isRecording else { return }
        if isBusy { stop() }
        quickType.toggle()
    }
    func cancelTalk() {
        guard overlay.model.mood == .listening else { return }
        voice.stop(); heard = ""
        overlay.model.mood = .idle; overlay.model.caption = nil
    }
    // Hold the talk shortcut: listen; let go: Orbit looks at the screen, answers out loud, and draws.
    func beginTalk() {
        guard !isBusy, !voice.isRecording else { return }
        speaker.stopSpeaking(at: .immediate)
        heard = ""
        overlay.model.clear(); overlay.model.mood = .listening; overlay.model.caption = nil
        Task { [self] in
            await voice.start(languages: settings.listening, onText: { [weak self] text in self?.heard = text; self?.overlay.model.caption = text },
                              onError: { [weak self] error in self?.error = error; self?.overlay.model.mood = .idle })
        }
    }
    func endTalk() {
        guard overlay.model.mood == .listening else { return }
        Task { [self] in
            try? await Task.sleep(nanoseconds: 350_000_000) // let the last words land
            let final = await voice.finish()
            overlay.model.mood = .idle; overlay.model.caption = nil
            let text = (final.isEmpty ? heard : final).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { send(text, spoken: true) }
        }
    }
    func selectProvider(_ provider: ProviderKind) {
        settings.provider = provider
        saveSettings()
        fetchModels()
        fetchConnectors()
    }
    /// Steps Orbit's window aside so you can drag over the part of the screen it should look at.
    /// `pickArea: false` takes the whole screen under the cursor right away.
    func capture(pickArea: Bool = true) {
        guard !isCapturing, !isBusy else { return }
        isCapturing = true; error = nil
        Task {
            defer { isCapturing = false }
            guard pickArea else {
                do { attachment = try await ScreenCapture.capture() } catch { self.error = error.localizedDescription }
                return
            }
            do { _ = try await ScreenCapture.shareableContent() } // ask for permission before dimming the screen
            catch { self.error = error.localizedDescription; return }
            let windows = NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }
            windows.forEach { $0.orderOut(nil) }
            defer { windows.forEach { $0.makeKeyAndOrderFront(nil) }; NSApp.activate(ignoringOtherApps: true) }
            guard let area = await AreaPicker.pick() else { return }
            try? await Task.sleep(nanoseconds: 150_000_000) // let the dimming leave the screen
            do { attachment = try await ScreenCapture.capture(area: area) }
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
        let startedIn = currentID
        if spokenText == nil { draft = "" }
        attachment = nil; isBusy = true; error = nil
        overlay.model.clear(); overlay.model.say(nil); overlay.model.mood = .thinking
        task = Task {
            defer { isBusy = false; busyID = nil; task = nil; overlay.model.mood = .idle }
            if image == nil, configuration.seesScreen {
                do { image = try await ScreenCapture.capture() }
                catch { self.error = error.localizedDescription }
            }
            let chatID = append(ChatMessage(role: "user", text: text, hadImage: image != nil), to: startedIn)
            if currentID == startedIn { currentID = chatID }
            busyID = chatID
            persist()
            let history = conversations.first { $0.id == chatID }?.messages ?? []
            do {
                let result = try await client.reply(settings: configuration, messages: history, image: image?.data, apiKey: key, connectors: connectors[configuration.provider] ?? [])
                try Task.checkCancellation()
                let built = ModelScript.parse(result.text)
                let parsed = SketchScript.parse(built.text)
                append(ChatMessage(role: "assistant", text: parsed.text, provider: configuration.provider.title), to: chatID)
                connectionResults[configuration.provider] = "Reply verified"
                persist()
                if let image, !parsed.marks.isEmpty { overlay.model.play(parsed.marks, frame: image.frame) }
                if let sculpture = built.sculpture {
                    // 3D models don't need a screenshot; without one they go on the screen under the cursor.
                    let mouse = NSEvent.mouseLocation
                    let screen = image?.frame ?? (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.frame ?? .zero
                    overlay.model.build(sculpture, frame: screen)
                }
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
                let result = try await client.reply(settings: configuration, messages: [ChatMessage(role: "user", text: "Reply with exactly: Orbit connection OK.")], image: nil, apiKey: key, connectors: connectors[configuration.provider] ?? [])
                try Task.checkCancellation()
                connectionResults[configuration.provider] = "Reply received: " + String(result.text.prefix(100))
            } catch {
                connectionResults[configuration.provider] = "Not connected"
                self.error = error.localizedDescription
            }
        }
    }
    func fetchModels(force: Bool = false) {
        let provider = settings.provider
        guard !loadingModels.contains(provider), force || models[provider] == nil else { return }
        loadingModels.insert(provider); modelErrors[provider] = nil
        let configuration = settings
        let key = provider == .custom ? (apiKey.isEmpty ? APIKeyStore.read(endpoint: settings.customBaseURL) : apiKey) : ""
        Task {
            defer { loadingModels.remove(provider) }
            do {
                let found = try await client.models(settings: configuration, apiKey: key)
                models[provider] = found
                if found.isEmpty { modelErrors[provider] = provider == .ollama ? "ollama is running, but no models are installed yet." : "no models came back. type a model id instead." }
                if provider == .ollama, settings.ollamaModel.isEmpty, let first = found.first { settings.ollamaModel = first.id; saveSettings() }
            } catch {
                models[provider] = []
                modelErrors[provider] = error.localizedDescription
            }
        }
    }
    /// The model id the current connection sends; empty means the CLI's own default.
    var currentModel: String {
        get {
            switch settings.provider {
            case .codex: return settings.codexModel
            case .claude: return settings.claudeModel
            case .custom: return settings.customModel
            case .ollama: return settings.ollamaModel
            }
        }
        set {
            switch settings.provider {
            case .codex: settings.codexModel = newValue
            case .claude: settings.claudeModel = newValue
            case .custom: settings.customModel = newValue
            case .ollama: settings.ollamaModel = newValue
            }
        }
    }
    func chooseModel(_ id: String) { currentModel = id; saveSettings() }

    func fetchConnectors(force: Bool = false) {
        let provider = settings.provider
        guard provider == .codex || provider == .claude, !loadingConnectors.contains(provider), force || connectors[provider] == nil else { return }
        loadingConnectors.insert(provider); connectorErrors[provider] = nil
        let configuration = settings
        Task {
            defer { loadingConnectors.remove(provider) }
            do {
                connectors[provider] = try await client.connectors(settings: configuration)
                try? LocalStore.write(connectors, name: "connectors.json")
            } catch { connectorErrors[provider] = error.localizedDescription }
        }
    }
    func choice(for connector: Connector) -> ConnectorChoice? {
        settings.connectors.first { $0.provider == settings.provider && $0.name == connector.name }
    }
    func setConnector(_ connector: Connector, on: Bool) {
        settings.connectors.removeAll { $0.provider == settings.provider && $0.name == connector.name }
        if on { settings.connectors.append(ConnectorChoice(provider: settings.provider, name: connector.name)) }
        saveSettings()
    }
    func setConnector(_ connector: Connector, allowChanges: Bool) {
        guard let index = settings.connectors.firstIndex(where: { $0.provider == settings.provider && $0.name == connector.name }) else { return }
        settings.connectors[index].allowChanges = allowChanges
        saveSettings()
    }
    func toggleVoice() {
        if voice.isRecording { Task { await voice.finish() }; return }
        let prefix = draft.isEmpty ? "" : draft + " "
        Task { [self] in await voice.start(languages: settings.listening, onText: { [weak self] text in self?.draft = prefix + text }, onError: { [weak self] error in self?.error = error }) }
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
    func newChat() { currentID = nil; attachment = nil; error = nil }
    func select(_ id: UUID) { currentID = id; attachment = nil; error = nil }
    func deleteChat(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if currentID == id { currentID = nil }
        persist()
    }
    func deleteAllChats() { guard !isBusy else { return }; conversations = []; currentID = nil; persist() }
    /// Adds a message to a chat (creating it when `id` is nil) and returns that chat's id.
    @discardableResult func append(_ message: ChatMessage, to id: UUID?) -> UUID {
        if let id, let index = conversations.firstIndex(where: { $0.id == id }) {
            conversations[index].messages.append(message)
            conversations[index].updated = Date()
            return id
        }
        let chat = Conversation(title: Conversation.title(for: message.text), messages: [message])
        conversations.insert(chat, at: 0)
        return chat.id
    }
    func persist() {
        for i in conversations.indices where conversations[i].messages.count > 200 {
            conversations[i].messages = Array(conversations[i].messages.suffix(200))
        }
        conversations.sort { $0.updated > $1.updated }
        if conversations.count > 200 { conversations = Array(conversations.prefix(200)) }
        do { try LocalStore.write(conversations, name: "conversations.json") }
        catch { self.error = error.localizedDescription }
    }
    static func loadConversations() -> [Conversation] {
        if let saved = LocalStore.read([Conversation].self, name: "conversations.json") { return saved }
        // Carry over the single chat kept by earlier builds.
        guard let old = LocalStore.read([ChatMessage].self, name: "conversation.json"), let first = old.first(where: { $0.role == "user" }) else { return [] }
        return [Conversation(title: Conversation.title(for: first.text), updated: old.last?.date ?? Date(), messages: old)]
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
