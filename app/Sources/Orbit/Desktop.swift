import AppKit
import AVFoundation
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

@MainActor
final class VoiceInput: ObservableObject {
    @Published var isRecording = false
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var installedTap = false
    private var generation = UUID()

    func start(locale: Locale, onText: @escaping (String) -> Void, onError: @escaping (String) -> Void) async {
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard microphone, speech == .authorized else { onError("Enable Orbit’s Microphone and Speech Recognition permissions in System Settings."); return }
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else { onError("Speech recognition for \(Dictation.name(locale.identifier)) isn’t available right now. Pick another language in Settings."); return }
        stop()
        let current = UUID(); generation = current
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { onError("No microphone input is available."); return }
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        installedTap = true
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                if let text { onText(text) }
                if final { self.stop() }
                else if let error, self.isRecording { self.stop(); onError(error.localizedDescription) }
            }
        }
        do { engine.prepare(); try engine.start(); isRecording = true }
        catch { stop(); onError(error.localizedDescription) }
    }
    func stop() {
        generation = UUID()
        engine.stop()
        if installedTap { engine.inputNode.removeTap(onBus: 0); installedTap = false }
        request?.endAudio(); recognitionTask?.cancel()
        request = nil; recognitionTask = nil; isRecording = false
    }
}

/// Languages Orbit can take dictation in. You pick a few in Settings and flip between them.
enum Dictation {
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
    static func name(_ id: String) -> String { Locale.autoupdatingCurrent.localizedString(forIdentifier: id) ?? id }
    static func short(_ id: String) -> String { String(id.split(separator: "-").first ?? Substring(id)) }
}
