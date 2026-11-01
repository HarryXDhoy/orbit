import AppKit
import SwiftUI

struct AppView: View {
    @ObservedObject var state: AppState
    var body: some View {
        ZStack(alignment: .top) {
            DotGrid().ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                switch state.selectedPage {
                case "connections": ConnectionsView(state: state)
                case "settings": SettingsView(state: state)
                default: ChatView(state: state, voice: state.voice)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
            if let error = state.error { errorBanner(error).padding(.top, 8) }
        }
        .frame(minWidth: 980, minHeight: 630)
        .focusEffectDisabled()
        .preferredColorScheme(.light)
        .animation(.easeOut(duration: 0.18), value: state.error)
    }

    // A menu-bar style strip living inside the window's title bar.
    var topBar: some View {
        ZStack {
            HStack(spacing: 18) {
                Text("orbit").font(DS.Typography.bodyMedium).foregroundStyle(DS.Colors.ink)
                nav("chat", page: "chat")
                nav("connections", page: "connections")
                nav("settings", page: "settings")
                Spacer()
                Toggle(isOn: $state.settings.showCompanion) { Text("buddy") }
                    .toggleStyle(PillToggleStyle())
                    .onChange(of: state.settings.showCompanion) { _, _ in state.saveSettings() }
                    .help("Show Orbit on your desktop")
                StatusPill(text: state.settings.provider.title.lowercased(), live: state.connectionResults[state.settings.provider] != "Not connected")
            }
            OrbitMark(size: 22)
        }
        .padding(.leading, 82).padding(.trailing, 20).frame(height: 52)
        .background(DS.Colors.canvas.opacity(0.85))
        .overlay(alignment: .bottom) { Rectangle().fill(DS.Colors.hairline).frame(height: 1) }
    }

    func nav(_ title: String, page: String) -> some View {
        Button(title) { state.selectedPage = page }
            .buttonStyle(LinkButtonStyle(color: state.selectedPage == page ? DS.Colors.ink : DS.Colors.ink2))
    }

    func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("(・_・;)").font(DS.Typography.label)
            VStack(alignment: .leading, spacing: 8) {
                Text(error).font(DS.Typography.label).textSelection(.enabled)
                if error == OrbitError.screenPermission.message {
                    HStack(spacing: 8) {
                        Button("open settings") { PrivacyPane.screen.open() }.buttonStyle(PillButtonStyle(kind: .silver, compact: true))
                        Button("relaunch orbit") { state.relaunch() }.buttonStyle(PillButtonStyle(kind: .aqua, compact: true))
                    }.foregroundStyle(DS.Colors.ink)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { state.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle())
        }
        .foregroundStyle(DS.Colors.danger)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).strokeBorder(DS.Colors.danger.opacity(0.35), lineWidth: DS.edge))
        .dsShadow()
        .frame(maxWidth: 560)
        .padding(.horizontal, 24)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct PillToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 6) {
                Circle().fill(configuration.isOn ? DS.Colors.live : DS.Colors.ink3).frame(width: 6, height: 6)
                configuration.label
            }
        }.buttonStyle(PillButtonStyle(kind: configuration.isOn ? .aqua : .silver, compact: true))
    }
}

struct ChatView: View {
    @ObservedObject var state: AppState
    @ObservedObject var voice: VoiceInput
    @FocusState var composerFocused: Bool
    var body: some View {
        HStack(spacing: 0) {
            ChatList(state: state)
            conversation
        }
    }

    var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView {
                    if state.messages.isEmpty { welcome }
                    else {
                        LazyVStack(spacing: 18) {
                            ForEach(state.messages) { message in row(message).id(message.id) }
                            if state.isBusy && state.busyID == state.currentID { thinking.id("busy") }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .frame(maxWidth: 720).padding(.horizontal, 32).padding(.vertical, 28)
                        .frame(maxWidth: .infinity)
                    }
                }
                .onChange(of: state.messages.count) { _, _ in withAnimation { reader.scrollTo("bottom", anchor: .bottom) } }
                .onChange(of: state.currentID) { _, _ in reader.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: state.isBusy) { _, _ in withAnimation { reader.scrollTo("bottom", anchor: .bottom) } }
            }
            composer
        }
    }

    func row(_ message: ChatMessage) -> some View {
        let mine = message.role == "user"
        return VStack(alignment: mine ? .trailing : .leading, spacing: 8) {
            SpeechBubble(mine: mine) {
                VStack(alignment: .leading, spacing: 6) {
                    if message.hadImage { Label("shared my screen", systemImage: "viewfinder").font(DS.Typography.caption).foregroundStyle(DS.Colors.ink2) }
                    Text(message.text).font(DS.Typography.body).lineSpacing(4).textSelection(.enabled).foregroundStyle(DS.Colors.ink)
                }
            }
            .frame(maxWidth: 520, alignment: mine ? .trailing : .leading)
            HStack(spacing: 2) {
                Text(mine ? "you" : "orbit · \((message.provider ?? state.settings.provider.title).lowercased())")
                    .font(DS.Typography.caption).foregroundStyle(DS.Colors.ink3).padding(.trailing, 4)
                if !mine {
                    Button { state.speak(message.text) } label: { Image(systemName: "speaker.wave.2") }.buttonStyle(IconButtonStyle()).help("Read aloud")
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(IconButtonStyle()).help("Copy reply")
                }
            }.padding(.horizontal, 6)
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }

    var thinking: some View {
        HStack(spacing: 10) {
            SpeechBubble(mine: false) { Waveform(active: true, bars: 7) }
            Text("thinking with \(state.settings.provider.title.lowercased())…").font(DS.Typography.caption).foregroundStyle(DS.Colors.ink3)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    var welcome: some View {
        ZStack {
            // Little faces drifting around the canvas.
            GeometryReader { geo in
                ForEach(Array(kaomoji.enumerated()), id: \.offset) { _, item in
                    Text(item.0).font(.system(size: 15)).foregroundStyle(DS.Colors.ink2)
                        .position(x: geo.size.width * item.1, y: geo.size.height * item.2)
                }
            }
            VStack(spacing: 14) {
                OrbitMark(size: 64).padding(.bottom, 6)
                Text("orbit").font(DS.Typography.display).tracking(-1.5).foregroundStyle(DS.Colors.ink)
                Text("a little buddy that lives on your mac").font(.system(size: 17)).foregroundStyle(DS.Colors.ink)
                HStack(alignment: .top, spacing: 12) {
                    suggestion("explain my screen", icon: "viewfinder", kind: .aqua, note: "shared only when you ask") {
                        state.draft = "Explain what’s on my screen and help me with the next step."; state.capture(pickArea: false)
                    }
                    suggestion("think it through", icon: "lightbulb", kind: .silver, note: "type or talk, your call") {
                        state.draft = "Help me think through an idea. Ask me one question to get started."; composerFocused = true
                    }
                }.padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 440)
    }

    private let kaomoji: [(String, CGFloat, CGFloat)] = [("^ ω ^", 0.2, 0.18), ("{ ^-^ }", 0.82, 0.26), ("(˘▾˘)", 0.14, 0.72), ("(•‿•)", 0.86, 0.78)]

    func suggestion(_ title: String, icon: String, kind: PillKind, note: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 7) {
            Button(action: action) { Label(title, systemImage: icon) }.buttonStyle(PillButtonStyle(kind: kind))
            Text(note).font(DS.Typography.caption).foregroundStyle(DS.Colors.ink3)
        }
    }

    var composer: some View {
        VStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 12) {
                if let attachment = state.attachment {
                    HStack(spacing: 12) {
                        MacWindow(title: attachment.isArea ? "area.png" : "screen.png") {
                            Image(nsImage: attachment.image).resizable().scaledToFit().frame(width: 120, height: 66)
                        }.frame(width: 120)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(attachment.isArea ? "area ready to share · \(Int(attachment.frame.width)) × \(Int(attachment.frame.height))" : "screen ready to share").font(DS.Typography.bodyMedium)
                            Text("goes to \(state.settings.provider.title.lowercased()) with your next message").font(DS.Typography.caption).foregroundStyle(DS.Colors.ink2)
                        }
                        Spacer()
                        Button { state.attachment = nil } label: { Image(systemName: "xmark") }.buttonStyle(IconButtonStyle()).help("Remove screenshot")
                    }
                }
                HStack(alignment: .center, spacing: 10) {
                    if voice.isRecording { Waveform(active: true) }
                    TextField(voice.isRecording ? "listening…" : "what’s on your mind?", text: $state.draft, axis: .vertical)
                        .font(.system(size: 15)).textFieldStyle(.plain).lineLimit(1...5).focused($composerFocused)
                        .onSubmit { state.send() }.disabled(state.isBusy)
                        .accessibilityIdentifier("messageInput")
                }
                HStack(spacing: 8) {
                    Button { state.capture() } label: { Label(state.isCapturing ? "picking…" : "area", systemImage: "rectangle.dashed") }
                        .buttonStyle(PillButtonStyle(kind: .silver, compact: true)).disabled(state.isBusy || state.isCapturing)
                        .help("Drag over part of your screen for Orbit to look at. Click for the whole screen, Esc to cancel")
                    Button { state.toggleVoice() } label: { Label(voice.isRecording ? "done" : "talk", systemImage: voice.isRecording ? "stop.fill" : "mic") }
                        .buttonStyle(PillButtonStyle(kind: voice.isRecording ? .aqua : .silver, compact: true)).disabled(state.isBusy)
                        .help(voice.isRecording ? "Stop dictation" : "Dictate into the message box")
                    Button { state.nextLanguage() } label: { Text(languageLabel) }
                        .buttonStyle(PillButtonStyle(kind: .ghost, compact: true)).disabled(voice.isRecording)
                        .help(languageHelp)
                    modelMenu
                    Toggle(isOn: $state.settings.seesScreen) { Text("sees screen") }
                        .toggleStyle(PillToggleStyle()).help("Look at your screen with every message so Orbit can point and draw")
                        .onChange(of: state.settings.seesScreen) { _, _ in state.saveSettings() }
                    Toggle(isOn: $state.settings.speakResponses) { Text("read aloud") }
                        .toggleStyle(PillToggleStyle()).help("Read replies aloud")
                        .onChange(of: state.settings.speakResponses) { _, _ in state.saveSettings() }
                    Spacer()
                    if state.isBusy {
                        Button { state.stop() } label: { Label("stop", systemImage: "stop.fill") }.buttonStyle(PillButtonStyle(kind: .silver))
                    } else {
                        Button { state.send() } label: { Label("send", systemImage: "arrow.up") }
                            .buttonStyle(PillButtonStyle(kind: .aqua)).keyboardShortcut(.return, modifiers: .command)
                            .disabled(state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("sendMessage")
                    }
                }
            }
            .padding(16)
            .background(DS.Colors.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(.black.opacity(0.12), lineWidth: DS.edge))
            .dsShadow()
            HStack(spacing: 6) {
                Text(voice.isRecording ? "listening… tap done, then check your words before sending" : state.settings.talkHotkey ? "hold \(state.settings.talkShortcut.display) anywhere to talk  ·  \(state.settings.typeShortcut.display) to type  ·  return to send" : "\(state.settings.typeShortcut.display) to type anywhere  ·  return to send")
                if !state.hotkeyTrusted && state.settings.talkHotkey && !voice.isRecording {
                    Button("allow the hotkey") { state.allowHotkey() }.buttonStyle(LinkButtonStyle()).font(DS.Typography.caption)
                }
            }
            .font(DS.Typography.caption).foregroundStyle(DS.Colors.ink3)
        }
        .frame(maxWidth: 720).padding(.horizontal, 32).padding(.bottom, 18)
        .frame(maxWidth: .infinity)
    }
}

extension ChatView {
    var languageLabel: String {
        guard state.settings.language == Dictation.auto else { return Dictation.short(state.settings.language) }
        return voice.detected.map { "auto · " + Dictation.short($0) } ?? "auto"
    }
    var languageHelp: String {
        if state.settings.language == Dictation.auto { return "Orbit listens for \(state.settings.listening.map(Dictation.name).joined(separator: ", ")) and keeps whichever you speak · click to switch" }
        return state.settings.languages.count > 1 ? "Dictating in \(Dictation.name(state.settings.language)) · click to switch" : "Dictating in \(Dictation.name(state.settings.language)) · add languages in Settings"
    }
    /// Switch models without leaving the chat.
    var modelMenu: some View {
        let provider = state.settings.provider
        let found = state.models[provider] ?? []
        let current = found.first { $0.id == state.currentModel }?.name ?? (state.currentModel.isEmpty ? "default model" : state.currentModel)
        return Menu {
            if provider == .codex || provider == .claude { Button("CLI default") { state.chooseModel("") } }
            ForEach(found) { option in
                Button { state.chooseModel(option.id) } label: {
                    if option.id == state.currentModel { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
                }
            }
            if found.isEmpty { Text(state.loadingModels.contains(provider) ? "Looking for models…" : (state.modelErrors[provider] ?? "No models found")) }
            Divider()
            Button("Refresh List") { state.fetchModels(force: true) }
            Button("Connections…") { state.selectedPage = "connections" }
        } label: {
            Text(current.lowercased()).font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Colors.ink2)
        }
        .menuStyle(.borderlessButton).fixedSize().disabled(state.isBusy)
        .help("Model for \(provider.title)")
        .onAppear { state.fetchModels() }
    }
}

struct ConnectionsView: View {
    @ObservedObject var state: AppState
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("choose what powers orbit").font(DS.Typography.title).foregroundStyle(DS.Colors.ink)
                    Text("bring your subscription, an api, or a model on this mac.").font(DS.Typography.label).foregroundStyle(DS.Colors.ink2)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    ForEach(ProviderKind.allCases) { provider in card(provider) }
                }
                MacWindow(title: "\(state.settings.provider.title.lowercased()) — connection") { form.padding(20) }
                    .disabled(state.isBusy && state.connectionResults[state.settings.provider] != "Testing…")
                MacWindow(title: "connectors") { connectorsPanel.padding(20) }
                HStack(alignment: .top, spacing: 10) {
                    Text("( ˘ ³˘)").font(DS.Typography.label)
                    Text("orbit keeps your chat on this mac. messages and any screenshot you attach go only to the connection you pick. subscription sign-in stays with the official cli.")
                        .font(DS.Typography.caption).lineSpacing(4)
                }.foregroundStyle(DS.Colors.ink3)
            }
            .frame(maxWidth: 720).padding(.horizontal, 32).padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }.onAppear { if state.settings.provider == .custom { state.loadKey() }; state.fetchModels(); state.fetchConnectors() }
    }

    /// Apps Orbit may use through the CLI's own connectors, off until you turn them on.
    @ViewBuilder var connectorsPanel: some View {
        let provider = state.settings.provider
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("let orbit use your apps").font(DS.Typography.bodyMedium).foregroundStyle(DS.Colors.ink)
                    Text("connectors you already set up in \(provider == .codex ? "codex" : "claude code"), like mail or calendar. off until you turn them on.")
                        .font(DS.Typography.caption).foregroundStyle(DS.Colors.ink2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if provider == .codex || provider == .claude {
                    Button(state.loadingConnectors.contains(provider) ? "looking…" : "refresh") { state.fetchConnectors(force: true) }
                        .buttonStyle(LinkButtonStyle()).disabled(state.loadingConnectors.contains(provider))
                }
            }
            if provider == .custom || provider == .ollama {
                note("connectors work with the chatgpt and claude connections for now.")
            } else {
                let list = state.connectors[provider] ?? []
                if let message = state.connectorErrors[provider] {
                    Text(message.lowercased()).font(DS.Typography.caption).foregroundStyle(DS.Colors.danger)
                }
                if list.isEmpty, !state.loadingConnectors.contains(provider), state.connectorErrors[provider] == nil {
                    note(provider == .claude ? "no connectors yet. add them on claude.ai under settings → connectors, or with `claude mcp add`." : "no connectors yet. add one with `codex mcp add`.")
                }
                VStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, connector in
                        if index > 0 { Rectangle().fill(DS.Colors.hairline).frame(height: 1) }
                        connectorRow(connector, provider: provider)
                    }
                }
                if provider == .claude {
                    Button("add connectors on claude.ai…") { if let url = URL(string: "https://claude.ai/settings/connectors") { NSWorkspace.shared.open(url) } }
                        .buttonStyle(LinkButtonStyle())
                }
                note(provider == .claude
                     ? "orbit loads only the connectors you turn on, without your claude code hooks. look-only connectors can’t send, create or delete anything."
                     : "look-only connectors run only the tools the app marks as read-only; some apps mark none, so turn on changes if a connector can’t do anything.")
            }
        }
    }

    func connectorRow(_ connector: Connector, provider: ProviderKind) -> some View {
        let choice = state.choice(for: connector)
        let on = Binding(get: { choice != nil }, set: { state.setConnector(connector, on: $0) })
        let changes = Binding(get: { choice?.allowChanges ?? false }, set: { state.setConnector(connector, allowChanges: $0) })
        let status: String = {
            switch connector.status {
            case "connected", "enabled": return provider == .claude ? "\(connector.readTools.count) look-up · \(connector.changeTools.count) change tools" : "ready"
            case "needs-auth": return provider == .claude ? "needs sign-in · run /mcp in claude code" : "needs sign-in · run codex mcp login \(connector.name)"
            case "disabled": return "turned off in codex"
            case "pending": return "still connecting · refresh in a moment"
            default: return connector.status
            }
        }()
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "puzzlepiece.extension").font(.system(size: 14)).foregroundStyle(DS.Colors.ink)
                .frame(width: 30, height: 30)
                .background(on.wrappedValue ? AnyShapeStyle(DS.Colors.aqua) : AnyShapeStyle(DS.Colors.silver), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on.wrappedValue ? DS.Colors.aquaEdge.opacity(0.7) : DS.Colors.silverEdge.opacity(0.4), lineWidth: DS.edge))
            VStack(alignment: .leading, spacing: 2) {
                Text(connector.displayName.lowercased()).font(DS.Typography.label).foregroundStyle(DS.Colors.ink)
                Text(status).font(DS.Typography.caption).foregroundStyle(connector.isReady ? DS.Colors.ink2 : DS.Colors.ink3)
            }
            Spacer()
            if on.wrappedValue {
                Toggle(isOn: changes) { Text("can make changes") }
                    .toggleStyle(PillToggleStyle())
                    .help("Let Orbit send, create, change or delete with \(connector.displayName) when you ask it to")
            }
            Toggle("", isOn: on).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(DS.Colors.link)
        }
        .padding(.vertical, 10)
    }

    /// The models this connection offers, fetched automatically; you can still type any id.
    func models(placeholder: String, allowsDefault: Bool) -> some View {
        let provider = state.settings.provider
        let found = state.models[provider] ?? []
        let loading = state.loadingModels.contains(provider)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(allowsDefault ? "model (optional)" : "model").font(DS.Typography.caption).foregroundStyle(DS.Colors.ink2)
                Spacer()
                Button(loading ? "looking…" : "refresh list") { state.fetchModels(force: true) }
                    .buttonStyle(LinkButtonStyle()).disabled(loading)
            }
            if !found.isEmpty || allowsDefault {
                FlowRow(spacing: 8) {
                    if allowsDefault {
                        Button("cli default") { state.chooseModel("") }
                            .buttonStyle(PillButtonStyle(kind: state.currentModel.isEmpty ? .aqua : .silver, compact: true))
                            .help("Use whatever model the CLI picks")
                    }
                    ForEach(found) { option in
                        Button(option.name.lowercased()) { state.chooseModel(option.id) }
                            .buttonStyle(PillButtonStyle(kind: state.currentModel == option.id ? .aqua : .silver, compact: true))
                            .help([option.id, option.note].compactMap { $0 }.joined(separator: " · "))
                    }
                }
            }
            DSField(title: "or type a model id", text: Binding(get: { state.currentModel }, set: { state.currentModel = $0 }), placeholder: placeholder)
            if let message = state.modelErrors[provider] {
                Text(message.lowercased()).font(DS.Typography.caption).foregroundStyle(DS.Colors.ink3).fixedSize(horizontal: false, vertical: true)
            } else if provider == .claude {
                Text("claude code doesn’t list models, so these are its aliases. each one always means the newest model in that family.")
                    .font(DS.Typography.caption).foregroundStyle(DS.Colors.ink3).fixedSize(horizontal: false, vertical: true)
            } else if !found.isEmpty {
                Text("\(found.count) models available on this connection.").font(DS.Typography.caption).foregroundStyle(DS.Colors.ink3)
            }
        }
    }

    func card(_ provider: ProviderKind) -> some View {
        let selected = state.settings.provider == provider
        return Button { state.selectProvider(provider) } label: {
            MacWindow(title: provider.fileName, highlighted: selected) {
                HStack(spacing: 12) {
                    Image(systemName: provider.symbol).font(.system(size: 18)).foregroundStyle(DS.Colors.ink)
                        .frame(width: 38, height: 38)
                        .background(selected ? AnyShapeStyle(DS.Colors.aqua) : AnyShapeStyle(DS.Colors.silver), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? DS.Colors.aquaEdge.opacity(0.7) : DS.Colors.silverEdge.opacity(0.4), lineWidth: DS.edge))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(provider.title.lowercased()).font(DS.Typography.bodyMedium).foregroundStyle(DS.Colors.ink)
                        Text(provider.subtitle.lowercased()).font(DS.Typography.caption).foregroundStyle(DS.Colors.ink2)
                    }
                    Spacer()
                    if selected { StatusPill(text: "in use") }
                }.padding(14)
            }
        }.buttonStyle(.plain).disabled(state.isBusy)
    }

    @ViewBuilder var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch state.settings.provider {
            case .codex:
                DSField(title: "Codex executable", text: $state.settings.codexPath, placeholder: "/absolute/path/to/codex")
                models(placeholder: "use the cli’s default model", allowsDefault: true)
                subscriptionHelp("Codex")
            case .claude:
                DSField(title: "Claude Code executable", text: $state.settings.claudePath, placeholder: "/absolute/path/to/claude")
                models(placeholder: "use the cli’s default model", allowsDefault: true)
                subscriptionHelp("Claude Code")
            case .custom:
                DSField(title: "API base URL", text: $state.settings.customBaseURL, placeholder: "https://your-provider.example/v1")
                    .onChange(of: state.settings.customBaseURL) { _, _ in state.apiKey = "" }
                DSField(title: "API key (optional for local servers)", text: $state.apiKey, placeholder: "stored in macOS keychain", secure: true)
                models(placeholder: "your provider’s model id", allowsDefault: false)
                Button("load saved key for this endpoint") { state.loadKey() }.buttonStyle(LinkButtonStyle())
                note("uses chat completions. screen sharing needs a vision model. api billing is separate from cli subscriptions.")
            case .ollama:
                DSField(title: "Ollama server", text: $state.settings.ollamaBaseURL, placeholder: "http://localhost:11434")
                models(placeholder: "choose an installed model", allowsDefault: false)
                note("start ollama first. use a vision model for screenshots. nothing downloads automatically.")
            }
            Rectangle().fill(DS.Colors.hairline).frame(height: 1).padding(.vertical, 2)
            HStack(spacing: 10) {
                Button("save") { if state.saveConnection() { state.connectionResults[state.settings.provider] = "Saved · test to verify" } }
                    .buttonStyle(PillButtonStyle(kind: .silver))
                Button(state.isBusy ? "testing…" : "test connection") { state.testConnection() }
                    .buttonStyle(PillButtonStyle(kind: .aqua)).disabled(state.isBusy)
                if state.isBusy { Button("stop") { state.stop() }.buttonStyle(LinkButtonStyle()) }
                Spacer()
                let result = state.connectionResults[state.settings.provider]
                StatusPill(text: (result ?? "not tested yet").lowercased(), live: result != nil && result != "Not connected")
                    .textSelection(.enabled).lineLimit(2)
            }
        }
    }

    func note(_ text: String) -> some View {
        Text(text).font(DS.Typography.caption).foregroundStyle(DS.Colors.ink2)
    }

    func subscriptionHelp(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            note("uses your existing \(name.lowercased()) login and its plan limits. the connection test sends one short request.")
            Button("sign in with \(name.lowercased())…") { state.openLogin() }.buttonStyle(PillButtonStyle(kind: .silver, compact: true))
        }
    }
}

extension ProviderKind {
    var fileName: String {
        switch self {
        case .codex: return "chatgpt.app"
        case .claude: return "claude.app"
        case .custom: return "custom-api.json"
        case .ollama: return "ollama.local"
        }
    }
}

/// The list of past chats down the left side, newest first.
struct ChatList: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { state.newChat() } label: { Label("new chat", systemImage: "square.and.pencil").frame(maxWidth: .infinity) }
                .buttonStyle(PillButtonStyle(kind: state.currentID == nil ? .aqua : .silver, compact: true))
            if state.conversations.isEmpty {
                Text("your chats will show up here (˘▾˘)").font(DS.Typography.caption).foregroundStyle(DS.Colors.ink3).padding(.horizontal, 6)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(groups, id: \.0) { group in
                        Text(group.0).font(DS.Typography.caption).foregroundStyle(DS.Colors.ink3).padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 2)
                        ForEach(group.1) { chat in ChatRow(chat: chat, state: state) }
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 16)
        .frame(width: 236)
        .background(Color.white.opacity(0.45), ignoresSafeAreaEdges: [])
        .overlay(alignment: .trailing) { Rectangle().fill(DS.Colors.hairline).frame(width: 1) }
    }

    private var groups: [(String, [Conversation])] {
        let calendar = Calendar.current
        var buckets: [(String, [Conversation])] = [("today", []), ("yesterday", []), ("this week", []), ("earlier", [])]
        for chat in state.conversations.sorted(by: { $0.updated > $1.updated }) {
            let i = calendar.isDateInToday(chat.updated) ? 0 : calendar.isDateInYesterday(chat.updated) ? 1
                : (calendar.dateComponents([.day], from: chat.updated, to: Date()).day ?? 99) < 7 ? 2 : 3
            buckets[i].1.append(chat)
        }
        return buckets.filter { !$0.1.isEmpty }
    }
}

struct ChatRow: View {
    let chat: Conversation
    @ObservedObject var state: AppState
    @State private var hovering = false
    var body: some View {
        let selected = state.currentID == chat.id
        Button { state.select(chat.id) } label: {
            HStack(spacing: 6) {
                if state.busyID == chat.id { Waveform(active: true, bars: 3).frame(width: 14) }
                Text(chat.title.lowercased()).font(DS.Typography.label).foregroundStyle(selected ? DS.Colors.ink : DS.Colors.ink2).lineLimit(1)
                Spacer(minLength: 0)
                if hovering && state.busyID != chat.id {
                    Button { state.deleteChat(chat.id) } label: { Image(systemName: "trash") }.buttonStyle(IconButtonStyle()).help("Delete chat")
                }
            }
            .padding(.horizontal, 8).frame(height: 32)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.Colors.silver)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.Colors.silverEdge.opacity(0.35), lineWidth: DS.edge))
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.04))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Delete Chat", role: .destructive) { state.deleteChat(chat.id) }.disabled(state.busyID == chat.id)
        }
    }
}
