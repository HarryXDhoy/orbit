import XCTest
@testable import Orbit

final class OrbitTests: XCTestCase {
    func testSketchTagsAreParsedHiddenAndBounded() {
        let parsed = SketchScript.parse("Click Save.\n[POINT:0.25,0.75:Save]\n[BOX:0.1,0.2,0.3,0.1:toolbar]\n[CIRCLE:0.5,0.5,0.05]\n[ARROW:0.1,0.1,0.4,0.4:here]\n[PATH:0.1,0.1 0.2,0.2 0.3,0.1]\n[TEXT:0.6,0.2:hello]")
        XCTAssertEqual(parsed.text, "Click Save.")
        XCTAssertEqual(parsed.marks.count, 6)
        XCTAssertEqual(parsed.marks.first, .point(CGPoint(x: 0.25, y: 0.75), "Save"))
        XCTAssertEqual(parsed.marks.last, .text(CGPoint(x: 0.6, y: 0.2), "hello"))
        XCTAssertTrue(SketchScript.parse("[POINT:3,0.5:Outside]").marks.isEmpty)
        XCTAssertTrue(SketchScript.parse("[POINT:nan,0.5:Bad]").marks.isEmpty)
        XCTAssertTrue(SketchScript.parse("[TEXT:0.5,0.5]").marks.isEmpty)
        XCTAssertTrue(SketchScript.parse("[PATH:0.5,0.5]").marks.isEmpty)
    }

    func testStrokesMapToSecondaryDisplayAndDrawByLength() {
        let frame = CGRect(x: -1440, y: 100, width: 1440, height: 900)
        let point = Stroke.make(.point(CGPoint(x: 0.25, y: 0.75), "Button"), in: frame)
        XCTAssertEqual(point.points.first, CGPoint(x: -1080, y: 325))
        let line = Stroke.make(.line(CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)), in: frame)
        XCTAssertEqual(line.length, 1440, accuracy: 0.001)
        XCTAssertEqual(line.prefix(0.5).last!.x, -720, accuracy: 0.001)
    }

    func testNewMarkTagsParseAndResolve() {
        let parsed = SketchScript.parse("[UNDERLINE:0.1,0.2,0.3][HIGHLIGHT:0.1,0.3,0.4,0.05][NUM:0.2,0.2:1][CHECK:0.5,0.5][CROSS:0.6,0.5][NOTE:0.7,0.1:Save first, then export.][NUM:0.3,0.3]")
        XCTAssertEqual(parsed.marks, [.underline(CGPoint(x: 0.1, y: 0.2), 0.3), .highlight(CGRect(x: 0.1, y: 0.3, width: 0.4, height: 0.05)),
                                      .number(CGPoint(x: 0.2, y: 0.2), "1"), .check(CGPoint(x: 0.5, y: 0.5)), .cross(CGPoint(x: 0.6, y: 0.5)),
                                      .note(CGPoint(x: 0.7, y: 0.1), "Save first, then export.")]) // a NUM without a number is dropped
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let cross = Stroke.make(.cross(CGPoint(x: 0.5, y: 0.5)), in: frame)
        XCTAssertEqual(cross.paths.count, 2)
        let note = Stroke.make(.note(CGPoint(x: 0.95, y: 0.95), "hi"), in: frame)
        XCTAssertTrue(frame.contains(note.box), "notes stay inside the screenshot")
        let underline = Stroke.make(.underline(CGPoint(x: 0.1, y: 0.5), 0.2), in: frame)
        XCTAssertEqual(underline.points.first!.y, 397, accuracy: 0.001) // just below the baseline
        XCTAssertGreaterThan(Stroke.make(.path((0...20).map { CGPoint(x: CGFloat($0) / 20, y: 0.5) }), in: frame).duration,
                             Stroke.make(.check(CGPoint(x: 0.5, y: 0.5)), in: frame).duration) // long strokes take longer
    }

    func testLabelsSitBesideTheirMarksWithoutOverlapping() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        var strokes = [Stroke.make(.box(CGRect(x: 0.4, y: 0.4, width: 0.1, height: 0.05), "search"), in: screen),
                       Stroke.make(.point(CGPoint(x: 0.42, y: 0.38), "filters"), in: screen),
                       Stroke.make(.box(CGRect(x: 0.0, y: 0.0, width: 0.05, height: 0.04), "menu"), in: screen)]
        LabelLayout.place(&strokes, screens: [screen])
        let boxes = strokes.compactMap(\.labelBox)
        XCTAssertEqual(boxes.count, 3)
        for (i, a) in boxes.enumerated() {
            XCTAssertTrue(screen.contains(a), "label \(i) stays on screen")
            for b in boxes[(i + 1)...] { XCTAssertFalse(a.intersects(b)) }
            XCTAssertFalse(a.intersects(strokes[i].bounds), "label \(i) doesn't cover its own mark")
        }
    }

    func testToneSamplerReadsTheImageRightSideUp() throws {
        let image = NSImage(size: NSSize(width: 100, height: 100), flipped: false) { _ in
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 100, height: 50).fill()   // bottom half white
            NSColor.black.setFill(); NSRect(x: 0, y: 50, width: 100, height: 50).fill()  // top half black
            return true
        }
        let sampler = try XCTUnwrap(ToneSampler(image))
        XCTAssertLessThan(sampler.brightness(in: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.2)), 0.2) // top (origin top-left)
        XCTAssertGreaterThan(sampler.brightness(in: CGRect(x: 0.1, y: 0.7, width: 0.8, height: 0.2)), 0.8)
        XCTAssertEqual(sampler.tone(in: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)), .light)
    }

    @MainActor func testSoundEffectsSynthesizeQuietBoundedAudio() throws {
        for buffer in [SoundFX.blip(from: 880, to: 520, seconds: 0.08, level: 0.22), SoundFX.thump(), SoundFX.ping(), SoundFX.whoosh(),
                       SoundFX.scratch(seconds: 0.5, low: 2200, high: 5200, level: 0.07)] {
            let b = try XCTUnwrap(buffer)
            XCTAssertGreaterThan(b.frameLength, 100)
            let samples = UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength))
            XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) <= 1 })
            XCTAssertGreaterThan(samples.map { abs($0) }.max()!, 0.005, "audible")
        }
    }

    func testBundledHandwritingFontLoadsForLatinText() {
        let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Fonts")
        FontRegistry.register(folder: fonts)
        XCTAssertNotNil(NSFont(name: "PatrickHand-Regular", size: 20))
        XCTAssertEqual(Handwriting.fontName(for: "Save first"), "PatrickHand-Regular")
        XCTAssertNotEqual(Handwriting.fontName(for: "먼저 저장"), "PatrickHand-Regular", "Patrick Hand has no Hangul")
    }

    @MainActor func testEndpointValidation() throws {
        XCTAssertEqual(try ProviderClient.endpoint(base: "https://example.com/v1/", suffix: "chat/completions").absoluteString, "https://example.com/v1/chat/completions")
        XCTAssertEqual(try ProviderClient.endpoint(base: "http://127.0.0.1:11434", suffix: "api/chat").path, "/api/chat")
        XCTAssertThrowsError(try ProviderClient.endpoint(base: "http://remote.example/v1", suffix: "chat/completions"))
        XCTAssertThrowsError(try ProviderClient.endpoint(base: "https://secret@example.com/v1", suffix: "chat/completions"))
        XCTAssertThrowsError(try ProviderClient.endpoint(base: "https://example.com/v1?key=secret", suffix: "chat/completions"))
    }

    @MainActor func testCodexDoesNotDisplayToolOutputAsReply() throws {
        let data = Data("""
        {"type":"item.completed","item":{"type":"command_execution","aggregated_output":"not a reply"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"Hello Orbit"}}
        {"type":"turn.completed"}
        """.utf8)
        XCTAssertEqual(try ProviderClient.parseCodex(data), "Hello Orbit")
        XCTAssertThrowsError(try ProviderClient.parseCodex(Data(#"{"type":"turn.failed","error":{"message":"Login expired"}}"#.utf8)))
    }

    @MainActor func testClaudeErrorAndResultParsing() throws {
        XCTAssertEqual(try ProviderClient.parseClaude(Data(#"{"type":"result","is_error":false,"result":"Hello"}"#.utf8)), "Hello")
        XCTAssertEqual(try ProviderClient.parseClaude(Data("{\"type\":\"system\"}\n{\"type\":\"result\",\"result\":\"Streamed\"}\n".utf8)), "Streamed")
        XCTAssertThrowsError(try ProviderClient.parseClaude(Data(#"{"type":"result","is_error":true,"result":"Rate limited"}"#.utf8)))
    }

    @MainActor func testCustomRequestCarriesImageAndKey() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        FixtureProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-key")
            let body = try Self.body(request)
            XCTAssertEqual(body["model"] as? String, "test-model")
            let messages = body["messages"] as! [[String: Any]]
            XCTAssertEqual(messages.count, 2)
            let parts = messages.last?["content"] as! [[String: Any]]
            XCTAssertEqual((parts[1]["image_url"] as! [String: Any])["url"] as? String, "data:image/jpeg;base64,AQID")
            return (200, #"{"choices":[{"message":{"content":"A picture"}}]}"#)
        }
        var settings = ConnectionSettings(); settings.provider = .custom; settings.customBaseURL = "https://fixture.example/v1"; settings.customModel = "test-model"
        let reply = try await ProviderClient(configuration: configuration).reply(settings: settings, messages: [ChatMessage(role: "user", text: "What is this?")], image: Data([1, 2, 3]), apiKey: "test-only-key")
        XCTAssertEqual(reply.text, "A picture")
    }

    @MainActor func testOllamaUsesNativeImageFormatWithoutAPIKey() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixtureProtocol.self]
        FixtureProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/chat")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let body = try Self.body(request)
            let messages = body["messages"] as! [[String: Any]]
            XCTAssertEqual(messages.last?["images"] as? [String], ["AQID"])
            XCTAssertEqual(body["stream"] as? Bool, false)
            return (200, #"{"message":{"content":"Local response"},"done":true}"#)
        }
        var settings = ConnectionSettings(); settings.provider = .ollama; settings.ollamaModel = "fixture"
        let reply = try await ProviderClient(configuration: configuration).reply(settings: settings, messages: [ChatMessage(role: "user", text: "Describe")], image: Data([1, 2, 3]), apiKey: "must-not-send")
        XCTAssertEqual(reply.text, "Local response")
    }

    @MainActor func testHTTPFailureIsNotShownAsSuccessfulReply() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [FixtureProtocol.self]
        FixtureProtocol.handler = { _ in (401, #"{"error":"unauthorized"}"#) }
        var settings = ConnectionSettings(); settings.provider = .custom; settings.customModel = "fixture"
        do {
            _ = try await ProviderClient(configuration: configuration).reply(settings: settings, messages: [], image: nil)
            XCTFail("Expected authentication error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("401")) }
    }

    static func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func testShortcutDisplay() {
        XCTAssertEqual(Shortcut.talkDefault.display, "⌃⌥")
        XCTAssertEqual(Shortcut.clearDefault.display, "⌃⌘K")
        XCTAssertEqual(Shortcut.talkDefault.spoken, "⌃ control + ⌥ option")
    }

    @MainActor func testHotkeysHoldToTalkClearAndCancel() throws {
        let hotkeys = Hotkeys()
        var log: [String] = []
        hotkeys.onTalkStart = { log.append("start") }
        hotkeys.onTalkEnd = { log.append("end") }
        hotkeys.onTalkCancel = { log.append("cancel") }
        hotkeys.onClear = { log.append("clear") }
        func flags(_ f: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: f, timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 59)!
        }
        func key(_ code: UInt16, _ f: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: f, timestamp: 0, windowNumber: 0, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: code)!
        }
        hotkeys.handle(flags([.control]))
        hotkeys.handle(flags([.control, .option]))
        hotkeys.handle(flags([]))
        XCTAssertEqual(log, ["start", "end"])
        log = []
        hotkeys.handle(flags([.control, .option]))
        hotkeys.handle(key(40, [.control, .option]))  // ⌃⌥K is someone else's shortcut
        hotkeys.handle(flags([]))
        XCTAssertEqual(log, ["start", "cancel"])
        log = []
        XCTAssertTrue(hotkeys.handle(key(40, [.control, .command])))
        XCTAssertEqual(log, ["clear"])
        log = []
        hotkeys.paused = true
        hotkeys.handle(flags([.control, .option]))
        XCTAssertEqual(log, [])
    }

    func testConversationTitleUsesFirstLine() {
        XCTAssertEqual(Conversation.title(for: "fix my code\nsecond line"), "fix my code")
        XCTAssertEqual(Conversation.title(for: String(repeating: "a", count: 60)).count, 49)
    }

    func testAutoLanguageNeedsTwoLanguagesAndListensToFirstThree() {
        var settings = ConnectionSettings()
        settings.languages = ["ko-KR"]
        settings.language = Dictation.auto
        XCTAssertEqual(settings.language, "ko-KR")
        XCTAssertEqual(settings.listening, ["ko-KR"])
        settings.languages = ["ko-KR", "en-US", "ja-JP", "fr-FR"]
        XCTAssertEqual(settings.language, Dictation.auto)
        XCTAssertEqual(settings.listening, ["ko-KR", "en-US", "ja-JP"])
        settings.language = "en-US"
        XCTAssertEqual(settings.listening, ["en-US"])
    }

    @MainActor func testAutoDetectKeepsTheMostConfidentTake() {
        typealias H = VoiceInput.Heard
        let korean = H(id: "ko-KR", text: "헬로 하우 아 유", confidence: 0.31, isFinal: true)
        let english = H(id: "en-US", text: "Hello, how are you?", confidence: 0.92, isFinal: true)
        XCTAssertEqual(VoiceInput.best([korean, english], preferred: "ko-KR")?.id, "en-US")
        let realKorean = H(id: "ko-KR", text: "오늘 날씨 어때?", confidence: 0.9, isFinal: true)
        let garbled = H(id: "en-US", text: "Oneul nalssi", confidence: 0.4, isFinal: true)
        XCTAssertEqual(VoiceInput.best([garbled, realKorean], preferred: "en-US")?.id, "ko-KR")
        // A language that heard nothing never wins.
        XCTAssertEqual(VoiceInput.best([H(id: "ja-JP", text: "", confidence: 0, isFinal: true), english], preferred: "ja-JP")?.id, "en-US")
    }

    @MainActor func testModelListsParseCodexAndOpenAIStyle() throws {
        let codex = #"{"models":[{"slug":"gpt-a","display_name":"GPT-A","visibility":"list"},{"slug":"internal","visibility":"hide"},{"slug":"gpt-b"}]}"#
        XCTAssertEqual(try ProviderClient.parseCodexModels(Data(codex.utf8)).map(\.id), ["gpt-a", "gpt-b"])
        XCTAssertEqual(try ProviderClient.parseCodexModels(Data(codex.utf8)).first?.name, "GPT-A")
        let openAI = #"{"object":"list","data":[{"id":"model-z"},{"id":"model-a"},{"id":"model-a"}]}"#
        XCTAssertEqual(try ProviderClient.parseModelList(Data(openAI.utf8)).map(\.id), ["model-a", "model-z"])
        let ollama = #"{"models":[{"name":"llava:7b"}]}"#
        XCTAssertEqual(try ProviderClient.parseModelList(Data(ollama.utf8)).map(\.id), ["llava:7b"])
        XCTAssertThrowsError(try ProviderClient.parseCodexModels(Data("nope".utf8)))
    }

    @MainActor func testModelTagsBuildABoundedSculpture() {
        let reply = """
        here's a little house.
        [MODEL:0.7,0.4,0.3:tiny house]
        [PART:box:0,-0.3,0:1.2,0.8,1:#F5F5F5]
        [PART:pyramid:0,0.4,0:1.4,0.6,1.2:red]
        [PART:cylinder:0.4,0.5,0:0.15,0.5:brown]
        [PART:blob:0,0,0:1,1,1:red]
        [PART:box:0,0,0:9,1,1:red]
        """
        let parsed = ModelScript.parse(reply)
        XCTAssertEqual(parsed.text, "here's a little house.")
        let model = try! XCTUnwrap(parsed.sculpture)
        XCTAssertEqual(model.parts.map(\.shape), [.box, .pyramid, .cylinder]) // unknown shape and oversize part dropped
        XCTAssertEqual(model.title, "tiny house")
        XCTAssertEqual(model.parts[2].size, SIMD3(0.15, 0.5, 0.15)) // two sizes: depth follows width
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let frame = model.frame(in: screen)
        XCTAssertEqual(frame.width, 300)
        XCTAssertTrue(screen.contains(frame))
        XCTAssertEqual(SculptureScene.make(model, animated: false).rootNode.childNode(withName: "model", recursively: false)?.childNodes.count, 3)
        let many = (0..<80).map { _ in "[PART:sphere:0,0,0:0.1:blue]" }.joined()
        XCTAssertEqual(ModelScript.parse(many).sculpture?.parts.count, ModelScript.maxParts)
        XCTAssertNil(ModelScript.parse("no model here").sculpture)
    }

    @MainActor func testModifierOnlyTypeShortcutFiresOnATap() throws {
        let hotkeys = Hotkeys()
        hotkeys.type = Shortcut(keyCode: nil, key: nil, flags: [.control, .command])
        var typed = 0, cleared = 0
        hotkeys.onType = { typed += 1 }
        hotkeys.onClear = { cleared += 1 }
        func flags(_ f: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: f, timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 59)!
        }
        func key(_ code: UInt16, _ f: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: f, timestamp: 0, windowNumber: 0, context: nil, characters: "k", charactersIgnoringModifiers: "k", isARepeat: false, keyCode: code)!
        }
        // Tap ⌃⌘: opens the box once, on release.
        hotkeys.handle(flags([.control])); hotkeys.handle(flags([.control, .command]))
        XCTAssertEqual(typed, 0)
        hotkeys.handle(flags([.control])); hotkeys.handle(flags([]))
        XCTAssertEqual(typed, 1)
        // ⌃⌘K clears drawings and doesn't open the box.
        hotkeys.handle(flags([.control, .command])); hotkeys.handle(key(40, [.control, .command])); hotkeys.handle(flags([]))
        XCTAssertEqual(cleared, 1); XCTAssertEqual(typed, 1)
        // Adding another modifier turns it into something else.
        hotkeys.handle(flags([.control, .command])); hotkeys.handle(flags([.control, .command, .option])); hotkeys.handle(flags([]))
        XCTAssertEqual(typed, 1)
    }

    func testConnectorToolNamesAndLookOnlyFilter() {
        XCTAssertEqual(Connectors.normalized("claude.ai Google Calendar"), "claude_ai_Google_Calendar")
        XCTAssertEqual(Connectors.normalized("motion-plus"), "motion-plus")
        for change in ["mcp__x__create_event", "mcp__x__delete_event", "mcp__x__send_message", "mcp__x__trash_thread", "mcp__x__update_draft"] {
            XCTAssertTrue(Connectors.looksLikeChange(change), change)
        }
        for read in ["mcp__x__list_events", "mcp__x__search_threads", "mcp__x__list_labels", "mcp__x__get_posts", "mcp__x__read_file_content"] {
            XCTAssertFalse(Connectors.looksLikeChange(read), read)
        }
    }

    func testClaudeConnectorArgumentsAllowOnlyChosenLookUpTools() {
        XCTAssertEqual(Connectors.claudeArguments(choices: [], known: []), ["--safe-mode", "--strict-mcp-config"])
        let line = #"{"type":"system","subtype":"init","mcp_servers":[{"name":"claude.ai Google Calendar","status":"connected"},{"name":"claude.ai Gmail","status":"connected"}],"tools":["mcp__claude_ai_Google_Calendar__list_events","mcp__claude_ai_Google_Calendar__create_event","mcp__claude_ai_Gmail__search_threads"]}"#
        let known = try! XCTUnwrap(Connectors.parseClaudeInit(Data(line.utf8)))
        XCTAssertEqual(known.map(\.displayName), ["Google Calendar", "Gmail"])
        XCTAssertEqual(known[0].tools.count, 2)
        let lookOnly = Connectors.claudeArguments(choices: [ConnectorChoice(provider: .claude, name: "claude.ai Google Calendar")], known: known)
        XCTAssertFalse(lookOnly.contains("--safe-mode"))
        XCTAssertTrue(lookOnly.contains(#"{"disableAllHooks":true}"#))
        XCTAssertEqual(lookOnly[lookOnly.firstIndex(of: "--allowedTools")! + 1], "mcp__claude_ai_Google_Calendar__list_events")
        XCTAssertEqual(lookOnly[lookOnly.firstIndex(of: "--disallowedTools")! + 1], "mcp__claude_ai_Google_Calendar__create_event,mcp__claude_ai_Gmail")
        let changes = Connectors.claudeArguments(choices: [ConnectorChoice(provider: .claude, name: "claude.ai Google Calendar", allowChanges: true)], known: known)
        XCTAssertEqual(changes[changes.firstIndex(of: "--allowedTools")! + 1], "mcp__claude_ai_Google_Calendar")
        // Codex choices don't affect Claude.
        XCTAssertEqual(Connectors.claudeArguments(choices: [ConnectorChoice(provider: .codex, name: "motion")], known: known), ["--safe-mode", "--strict-mcp-config"])
    }

    func testCodexConnectorsAreAddedBackWithApprovalMode() throws {
        let list = #"[{"name":"motion","enabled":true,"auth_status":"o_auth","transport":{"type":"streamable_http","url":"https://mcp.motion.dev","bearer_token_env_var":null}},{"name":"tool.x","enabled":true,"transport":{"type":"stdio","command":"./run","args":["a b"],"env":{"K":"v\"q"},"cwd":"/tmp"}}]"#
        let known = try Connectors.parseCodexList(Data(list.utf8))
        XCTAssertEqual(known[0].codexTable, #"{url = "https://mcp.motion.dev"}"#)
        XCTAssertEqual(known[1].codexTable, #"{command = "./run", args = ["a b"], cwd = "/tmp", env = {"K" = "v\"q"}}"#)
        let args = Connectors.codexArguments(choices: [ConnectorChoice(provider: .codex, name: "motion"), ConnectorChoice(provider: .codex, name: "tool.x")], known: known)
        XCTAssertEqual(args, ["-c", #"mcp_servers.motion={url = "https://mcp.motion.dev", default_tools_approval_mode = "writes"}"#]) // dotted names are skipped
        let approve = Connectors.codexArguments(choices: [ConnectorChoice(provider: .codex, name: "motion", allowChanges: true)], known: known)
        XCTAssertTrue(approve[1].hasSuffix(#"default_tools_approval_mode = "approve"}"#))
    }

    @MainActor func testTypeShortcutOpensTheTypingBox() throws {
        let hotkeys = Hotkeys()
        var typed = 0
        hotkeys.onType = { typed += 1 }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .command], timestamp: 0, windowNumber: 0, context: nil, characters: "t", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17))
        XCTAssertTrue(hotkeys.handle(event))
        XCTAssertEqual(typed, 1)
        XCTAssertEqual(Shortcut.typeDefault.display, "⌃⌘T")
    }
}

final class FixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
