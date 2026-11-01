import AppKit
import ApplicationServices
import AVFoundation
import NaturalLanguage

extension ScreenAttachment {
    /// The screenshot with the pointer's path drawn on it, so the model can see what you circled while talking.
    func marked(with path: [CGPoint], ink: NSColor) -> ScreenAttachment {
        guard path.count > 1, Stroke.length(of: path) > 40,
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return self }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        // Both the bitmap and global screen coordinates grow upward, so the path maps across without a flip.
        let sx = CGFloat(cg.width) / max(frame.width, 1), sy = CGFloat(cg.height) / max(frame.height, 1)
        context.setStrokeColor(ink.withAlphaComponent(0.8).cgColor)
        context.setLineWidth(6 * sx)
        context.setLineCap(.round); context.setLineJoin(.round)
        for (i, p) in path.enumerated() {
            let q = CGPoint(x: (p.x - frame.minX) * sx, y: (p.y - frame.minY) * sy)
            if i == 0 { context.move(to: q) } else { context.addLine(to: q) }
        }
        context.strokePath()
        guard let out = context.makeImage(),
              let jpeg = NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return self }
        return ScreenAttachment(data: jpeg, frame: frame, image: NSImage(cgImage: out, size: frame.size), isArea: isArea)
    }
}

/// Puts dictated words where the text cursor is in the app in front, by pasting, then puts the clipboard back.
@MainActor
enum TextInserter {
    static func insert(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let board = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (board.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        board.clearContents()
        board.setString(text, forType: .string)
        let ours = board.changeCount
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down) // V
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            // Leave the clipboard alone if something else was copied meanwhile.
            guard board.changeCount == ours else { return }
            board.clearContents()
            board.writeObjects(saved.map { types in
                let item = NSPasteboardItem()
                for (type, data) in types { item.setData(data, forType: type) }
                return item
            })
        }
        return true
    }
}

/// The voices Orbit can speak with, best quality first.
enum Voices {
    /// "ko", "en"… from an identifier like "ko-KR".
    static func code(_ language: String) -> String { String(language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(language)).lowercased() }

    static func options(for language: String) -> [AVSpeechSynthesisVoice] {
        let code = code(language)
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { Voices.code($0.language) == code }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
    }

    /// The chosen voice for a language, or its best installed one.
    static func voice(for language: String, chosen: [String: String]) -> AVSpeechSynthesisVoice? {
        if let id = chosen[code(language)], let voice = AVSpeechSynthesisVoice(identifier: id) { return voice }
        return options(for: language).first
    }

    static func quality(_ voice: AVSpeechSynthesisVoice) -> String? {
        switch voice.quality {
        case .premium: return "premium"
        case .enhanced: return "enhanced"
        default: return nil
        }
    }

    static func sample(for language: String) -> String {
        switch code(language) {
        case "ko": return "안녕하세요, 저는 오빗이에요. 화면을 같이 보면서 도와드릴게요."
        case "ja": return "こんにちは、オービットです。画面を一緒に見ながらお手伝いします。"
        case "zh": return "你好，我是 Orbit。我会看着你的屏幕帮你。"
        case "es": return "Hola, soy Orbit. Miro tu pantalla contigo y te ayudo."
        case "fr": return "Salut, je suis Orbit. Je regarde ton écran avec toi pour t'aider."
        case "de": return "Hallo, ich bin Orbit. Ich schaue mit dir auf den Bildschirm und helfe dir."
        default: return "Hi, I'm Orbit. I look at your screen with you and help out."
        }
    }

    /// Opens the system list where more voices can be downloaded.
    static func openVoiceSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpeakableItems") { NSWorkspace.shared.open(url) }
    }
}

/// Follows what the synthesizer is saying and reports the sentence being spoken, for captions.
final class SpeechFeed: NSObject, AVSpeechSynthesizerDelegate {
    var onLine: @MainActor (String?) -> Void = { _ in }
    private var sentences: [(NSRange, String)] = []
    private var speaking: String = ""

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        if text != speaking {
            speaking = text
            sentences = SpeechFeed.sentences(in: text)
        }
        let line = sentences.first { NSLocationInRange(characterRange.location, $0.0) }?.1
        Task { @MainActor [onLine] in onLine(line) }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [onLine] in onLine(nil) }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [onLine] in onLine(nil) }
    }

    static func sentences(in text: String) -> [(NSRange, String)] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).map { range in
            (NSRange(range, in: text), text[range].trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
