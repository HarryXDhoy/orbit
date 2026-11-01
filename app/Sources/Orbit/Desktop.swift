import AppKit
import AVFoundation
import NaturalLanguage
import ScreenCaptureKit
import Speech
import SwiftUI

@MainActor
enum ScreenCapture {
    static func capture() async throws -> ScreenAttachment {
        // Ask ScreenCaptureKit directly: CGPreflightScreenCaptureAccess caches a "no" until relaunch.
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch {
            if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
            throw OrbitError.screenPermission
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == number }) else { throw OrbitError("No screen is available.") }
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let config = SCStreamConfiguration()
        let scale = min(1, 1440.0 / Double(max(display.width, display.height)))
        config.width = Int(Double(display.width) * scale)
        config.height = Int(Double(display.height) * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { throw OrbitError("Could not encode the screenshot.") }
        return ScreenAttachment(data: jpeg, frame: screen.frame, image: NSImage(cgImage: image, size: screen.frame.size))
    }
}

/// Dictation. With several languages it listens in all of them at once and keeps the one that fits best.
@MainActor
final class VoiceInput: ObservableObject {
    @Published var isRecording = false
    /// The language auto-detect settled on last time; its words are shown first while you talk.
    @Published private(set) var detected: String?
    private let engine = AVAudioEngine()
    private var listeners: [Listener] = []
    private var installedTap = false
    private var generation = UUID()
    private var onText: (String) -> Void = { _ in }

    private final class Listener {
        let id: String
        let request = SFSpeechAudioBufferRecognitionRequest()
        var task: SFSpeechRecognitionTask?
        var heard: Heard
        var done = false
        init(id: String) { self.id = id; heard = Heard(id: id, text: "", confidence: 0, isFinal: false) }
    }

    /// One language's take on what was said.
    struct Heard: Equatable {
        var id: String
        var text: String
        var confidence: Float
        var isFinal: Bool
    }

    func start(languages: [String], onText: @escaping (String) -> Void, onError: @escaping (String) -> Void) async {
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard microphone, speech == .authorized else { onError("Enable Orbit’s Microphone and Speech Recognition permissions in System Settings."); return }
        // The language detected last time goes first, so live captions start in the likely language.
        let ordered = languages.sorted { a, _ in a == detected }
        let recognizers = ordered.compactMap { id -> (String, SFSpeechRecognizer)? in
            guard let r = SFSpeechRecognizer(locale: Locale(identifier: id)), r.isAvailable else { return nil }
            return (id, r)
        }
        guard !recognizers.isEmpty else { onError("Speech recognition for \(languages.map(Dictation.name).joined(separator: ", ")) isn’t available right now. Pick another language in Settings."); return }
        stop()
        let current = UUID(); generation = current
        self.onText = onText
        listeners = recognizers.map { id, recognizer in
            let listener = Listener(id: id)
            listener.request.shouldReportPartialResults = true
            listener.request.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition { listener.request.requiresOnDeviceRecognition = true }
            return listener
        }
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { listeners = []; onError("No microphone input is available."); return }
        let requests = listeners.map(\.request)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in requests.forEach { $0.append(buffer) } }
        installedTap = true
        for (index, (_, recognizer)) in recognizers.enumerated() {
            listeners[index].task = recognizer.recognitionTask(with: listeners[index].request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                let segments = result?.bestTranscription.segments.map(\.confidence) ?? []
                let failed = error != nil
                let message = error?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, self.generation == current, index < self.listeners.count else { return }
                    let listener = self.listeners[index]
                    if let text { listener.heard.text = text }
                    if final {
                        listener.heard.isFinal = true
                        listener.heard.confidence = segments.isEmpty ? 0 : segments.reduce(0, +) / Float(segments.count)
                    }
                    if final || failed { listener.done = true }
                    if text != nil { self.onText(self.live) }
                    if self.listeners.allSatisfy(\.done), self.isRecording {
                        // Recognition ended on its own (a long pause or an error) before you let go.
                        if self.listeners.allSatisfy({ $0.heard.text.isEmpty }), let message { self.stop(); onError(message) }
                        else { _ = await self.finish() }
                    }
                }
            }
        }
        do { engine.prepare(); try engine.start(); isRecording = true }
        catch { stop(); onError(error.localizedDescription) }
    }

    /// What to show while you're still talking.
    private var live: String {
        listeners.first(where: { !$0.heard.text.isEmpty })?.heard.text ?? ""
    }

    /// Stops listening, waits briefly for every language's final take, and returns the best one.
    @discardableResult func finish() async -> String {
        guard isRecording else { return "" }
        let current = generation
        isRecording = false
        engine.stop()
        if installedTap { engine.inputNode.removeTap(onBus: 0); installedTap = false }
        listeners.forEach { $0.request.endAudio() }
        for _ in 0..<40 where !listeners.allSatisfy(\.done) {
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard generation == current else { return "" }
        }
        let takes = listeners.map(\.heard)
        let best = Self.best(takes, preferred: detected)
        if listeners.count > 1, let best, !best.text.isEmpty { detected = best.id }
        let text = best?.text ?? ""
        onText(text)
        stop()
        return text
    }

    /// Prefers the most confident final transcript, nudged toward text that reads like its language.
    static func best(_ takes: [Heard], preferred: String?) -> Heard? {
        let spoken = takes.filter { !$0.text.isEmpty }
        guard spoken.count > 1 else { return spoken.first ?? takes.first }
        func score(_ h: Heard) -> Double {
            let language = NLLanguage(rawValue: Dictation.short(h.id))
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(h.text)
            let fit = recognizer.languageHypotheses(withMaximum: 5)[language] ?? 0
            return Double(h.isFinal ? h.confidence : 0) + 0.15 * fit + (h.id == preferred ? 0.02 : 0)
        }
        return spoken.max { score($0) < score($1) }
    }

    /// Stops and throws away whatever was heard.
    func stop() {
        generation = UUID()
        engine.stop()
        if installedTap { engine.inputNode.removeTap(onBus: 0); installedTap = false }
        listeners.forEach { $0.request.endAudio(); $0.task?.cancel() }
        listeners = []; isRecording = false
    }
}

/// Languages Orbit can take dictation in. You pick a few in Settings and flip between them, or let Orbit tell them apart.
enum Dictation {
    /// Listen in every chosen language at once and keep the one that fits.
    static let auto = "auto"
    /// Auto-detect listens in at most this many languages at a time.
    static let autoLimit = 3
    static var supported: [String] {
        SFSpeechRecognizer.supportedLocales().map(\.identifier).sorted { name($0).localizedCompare(name($1)) == .orderedAscending }
    }
    /// The system language when speech recognition supports it, else English.
    static var systemDefault: String {
        let ids = Set(SFSpeechRecognizer.supportedLocales().map(\.identifier))
        let current = Locale.autoupdatingCurrent
        let exact = current.identifier.replacingOccurrences(of: "_", with: "-")
        if ids.contains(exact) { return exact }
        if let code = current.language.languageCode?.identifier, let match = ids.sorted().first(where: { $0.hasPrefix(code + "-") }) { return match }
        return "en-US"
    }
    static func name(_ id: String) -> String { id == auto ? "Auto-detect" : Locale.autoupdatingCurrent.localizedString(forIdentifier: id) ?? id }
    static func short(_ id: String) -> String { String(id.split(separator: "-").first ?? Substring(id)) }
}
