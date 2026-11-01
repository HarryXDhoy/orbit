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
