import AppKit
import CoreGraphics
import Foundation

/// One thing Orbit draws on screen. Coordinates are normalized to the screenshot, origin top-left.
enum SketchMark: Equatable {
    case point(CGPoint, String)
    case box(CGRect, String?)
    case circle(CGPoint, CGFloat, String?)
    case arrow(CGPoint, CGPoint, String?)
    case line(CGPoint, CGPoint)
    case path([CGPoint])
    case text(CGPoint, String)
    case underline(CGPoint, CGFloat)
    case highlight(CGRect)
    case number(CGPoint, String)
    case check(CGPoint)
    case cross(CGPoint)
    case note(CGPoint, String)
    /// A control to click; Orbit waits for the click before the next step of a walkthrough.
    case target(CGRect, String?)
    /// Something to point at (a menu that opens on hover); Orbit waits for the pointer to rest on it.
    case hover(CGRect, String?)
    /// Dims everything except this area.
    case spotlight(CGRect)
    /// A little face when something worked.
    case cheer(CGPoint, String)

    var label: String? {
        switch self {
        case .point(_, let l): return l
        case .box(_, let l), .circle(_, _, let l), .arrow(_, _, let l), .target(_, let l), .hover(_, let l): return l
        default: return nil
        }
    }
}

/// Parses the drawing tags a reply may end with and returns the reply without them.
enum SketchScript {
    static let maxMarks = 40
    static let maxPathPoints = 160
    private static let regex = try! NSRegularExpression(pattern: #"\[(POINT|BOX|CIRCLE|ARROW|LINE|PATH|TEXT|UNDERLINE|HIGHLIGHT|NUM|CHECK|CROSS|NOTE|TARGET|HOVER|SPOT|CHEER):([^\]\n]{1,4000})\]"#)

    static func parse(_ text: String) -> (text: String, marks: [SketchMark]) {
        let range = NSRange(text.startIndex..., in: text)
        var marks: [SketchMark] = []
        for match in regex.matches(in: text, range: range) {
            guard marks.count < maxMarks,
                  let kr = Range(match.range(at: 1), in: text), let br = Range(match.range(at: 2), in: text),
                  let mark = mark(kind: String(text[kr]), body: String(text[br])) else { continue }
            marks.append(mark)
        }
        let clean = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (clean, marks)
    }

    private static func mark(kind: String, body: String) -> SketchMark? {
        if kind == "PATH" {
            let points = body.split(whereSeparator: { $0 == " " || $0 == ";" }).prefix(maxPathPoints).compactMap { pair -> CGPoint? in
                let n = numbers(String(pair))
                return n?.count == 2 ? CGPoint(x: n![0], y: n![1]) : nil
            }
            return points.count >= 2 ? .path(points) : nil
        }
        let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
        guard let n = numbers(parts[0]) else { return nil }
        let words = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        let tag = words.isEmpty ? nil : String(words.prefix(80))
        let p = n.count >= 2 ? CGPoint(x: n[0], y: n[1]) : .zero
        switch (kind, n.count) {
        case ("POINT", 2): return .point(p, tag ?? "here")
        case ("BOX", 4): return n[2] > 0 && n[3] > 0 ? .box(CGRect(x: n[0], y: n[1], width: n[2], height: n[3]), tag) : nil
        case ("CIRCLE", 3): return n[2] > 0 ? .circle(p, n[2], tag) : nil
        case ("ARROW", 4): return .arrow(p, CGPoint(x: n[2], y: n[3]), tag)
        case ("LINE", 4): return .line(p, CGPoint(x: n[2], y: n[3]))
        case ("TEXT", 2): return tag.map { .text(p, $0) }
        case ("UNDERLINE", 3): return n[2] > 0 ? .underline(p, n[2]) : nil
        case ("HIGHLIGHT", 4): return n[2] > 0 && n[3] > 0 ? .highlight(CGRect(x: n[0], y: n[1], width: n[2], height: n[3])) : nil
        case ("NUM", 2): return tag.map { .number(p, String($0.prefix(3))) }
        case ("CHECK", 2): return .check(p)
        case ("CROSS", 2): return .cross(p)
        case ("NOTE", 2): return words.isEmpty ? nil : .note(p, String(words.prefix(160)))
        case ("TARGET", 4): return n[2] > 0 && n[3] > 0 ? .target(CGRect(x: n[0], y: n[1], width: n[2], height: n[3]), tag) : nil
        case ("HOVER", 4): return n[2] > 0 && n[3] > 0 ? .hover(CGRect(x: n[0], y: n[1], width: n[2], height: n[3]), tag) : nil
        case ("SPOT", 4): return n[2] > 0 && n[3] > 0 ? .spotlight(CGRect(x: n[0], y: n[1], width: n[2], height: n[3])) : nil
        case ("CHEER", 2): return .cheer(p, words.isEmpty ? "(^▽^)" : String(words.prefix(16)))
        default: return nil
        }
    }

    /// Comma-separated numbers, all finite and within 0...1.
    private static func numbers(_ s: String) -> [CGFloat]? {
        let values = s.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !values.isEmpty, values.allSatisfy({ $0 != nil && $0!.isFinite && (0...1).contains($0!) }) else { return nil }
        return values.map { CGFloat($0!) }
    }
}

/// A sketch mark resolved to global screen points (AppKit coordinates, origin bottom-left).
struct Stroke {
    enum Kind { case point, frame, pen, text, badge, marker, note, target, spotlight, cheer }
    /// Free words read white on dark screens and near-black on light ones.
    enum Tone { case light, dark }

    var kind: Kind
    /// Pen lines; a cross or an arrowhead has more than one.
    var paths: [[CGPoint]] = []
    /// What a frame, highlighter, text, badge or note covers.
    var box: CGRect = .zero
    var radius: CGFloat = 0
    var lineWidth: CGFloat = Self.pen
    var text: String?
    var label: String?
    /// Where the label goes; placed by `LabelLayout` so labels never sit on each other.
    var labelBox: CGRect?
    /// What the label names, when that isn't the whole mark (an arrow is named at its tail).
    var anchor: CGRect?
    var tone: Tone = .dark
    var textSize: CGFloat = 26
    /// A ring that waits for the pointer to rest on it rather than for a click.
    var waitsForHover = false

    static let pen: CGFloat = 3.5
    static let noteSide: CGFloat = 170

    var points: [CGPoint] { paths.flatMap { $0 } }
    var length: CGFloat { paths.reduce(0) { $0 + Self.length(of: $1) } }

    /// Seconds the pen spends on this mark, so long strokes take longer than ticks.
    var duration: Double {
        switch kind {
        case .pen: return min(0.9, max(0.22, 0.16 + Double(length) / 1500))
        case .frame: return 0.5
        case .marker: return 0.38
        case .text: return min(1.6, max(0.35, 0.2 + Double(text?.count ?? 0) * 0.055))
        case .badge: return 0.16
        case .note: return 0.42
        case .point: return 0.28
        case .target: return 0.45
        case .spotlight: return 0.35
        case .cheer: return 0.25
        }
    }

    /// Everything the mark covers, used to keep labels off it.
    var bounds: CGRect {
        switch kind {
        case .pen:
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return .zero }
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).insetBy(dx: -lineWidth, dy: -lineWidth)
        case .spotlight:
            return .null // it lights a spot rather than covering it, so a label can sit right by the thing it lights
        default:
            return box
        }
    }

    /// Where the pen is at `fraction` of this mark, so the buddy can hold it.
    func tip(at fraction: CGFloat) -> CGPoint {
        let f = max(0, min(1, fraction))
        switch kind {
        case .pen: return prefix(f).last ?? box.origin
        case .frame, .target:
            // Round the frame from its top-left corner, clockwise.
            let w = box.width, h = box.height, d = (2 * (w + h)) * f
            if d <= w { return CGPoint(x: box.minX + d, y: box.maxY) }
            if d <= w + h { return CGPoint(x: box.maxX, y: box.maxY - (d - w)) }
            if d <= 2 * w + h { return CGPoint(x: box.maxX - (d - w - h), y: box.minY) }
            return CGPoint(x: box.minX, y: box.minY + (d - 2 * w - h))
        case .marker, .text: return CGPoint(x: box.minX + box.width * f, y: box.midY)
        case .badge, .note, .point, .spotlight, .cheer: return CGPoint(x: box.midX, y: box.midY)
        }
    }

    /// The first `fraction` of all the pen lines by length, so they can be drawn as if by hand.
    func prefix(_ fraction: CGFloat) -> [CGPoint] {
        let all = points
        guard fraction < 1, all.count > 1 else { return all }
        var remaining = length * max(0, fraction)
        var out: [CGPoint] = []
        for path in paths {
            guard let first = path.first else { continue }
            out.append(first)
            for (a, b) in zip(path, path.dropFirst()) {
                let d = hypot(b.x - a.x, b.y - a.y)
                if remaining >= d { out.append(b); remaining -= d; continue }
                let t = d > 0 ? remaining / d : 0
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                return out
            }
        }
        return out
    }

    static func length(of path: [CGPoint]) -> CGFloat {
        zip(path, path.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// Wide, short things (a field, a button, a bar) get a pill; anything else rounded corners.
    static func cornerRadius(of b: CGRect, max corner: CGFloat) -> CGFloat {
        b.width > 2.5 * b.height && b.height < 60 ? b.height / 2 : min(corner, b.height / 2)
    }

    /// The same ring around the real control, once Accessibility has found it.
    func snapped(to control: CGRect) -> Stroke {
        var ring = self
        ring.box = control.insetBy(dx: -4, dy: -4)
        ring.radius = Self.cornerRadius(of: ring.box, max: 10)
        return ring
    }

    /// Resolves a mark in the screenshot's frame. `tone` reads the screenshot under a normalized rect.
    static func make(_ mark: SketchMark, in frame: CGRect, tone: (CGRect) -> Tone = { _ in .dark }) -> Stroke {
        func g(_ p: CGPoint) -> CGPoint { CGPoint(x: frame.minX + p.x * frame.width, y: frame.maxY - p.y * frame.height) }
        func rect(_ r: CGRect) -> CGRect {
            let a = g(CGPoint(x: r.minX, y: r.minY)), b = g(CGPoint(x: r.maxX, y: r.maxY))
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        }
        func around(_ c: CGPoint, _ side: CGFloat) -> CGRect { CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side) }

        switch mark {
        case .point(let p, let label):
            let c = g(p)
            return Stroke(kind: .point, paths: [[c]], box: around(c, 36), label: label)

        case .box(let r, let label):
            let b = rect(r).insetBy(dx: -3, dy: -3)
            return Stroke(kind: .frame, box: b, radius: cornerRadius(of: b, max: 8), label: label)

        case .circle(let c, let r, let label):
            let center = g(c), radius = max(10, r * frame.width) + 4
            // A pen going round once and a little past where it started, slightly uneven like a hand.
            let pts = (0...64).map { i -> CGPoint in
                let t = -CGFloat.pi * 0.62 + CGFloat(i) / 64 * 2 * .pi * 1.07
                let rr = radius * (1 + 0.025 * sin(t * 2 + 0.9))
                return CGPoint(x: center.x + cos(t) * rr * 1.03, y: center.y + sin(t) * rr * 0.97)
            }
            return Stroke(kind: .pen, paths: [pts], box: around(center, radius * 2), label: label)

        case .arrow(let from, let to, let label):
            let a = g(from), b = g(to)
            let dx = b.x - a.x, dy = b.y - a.y, len = max(1, hypot(dx, dy))
            // Bend the shaft a little to one side, like a quick hand-drawn arrow.
            let bend = len * 0.18
            let mid = CGPoint(x: (a.x + b.x) / 2 - dy / len * bend, y: (a.y + b.y) / 2 + dx / len * bend)
            let shaft = (0...20).map { i -> CGPoint in
                let t = CGFloat(i) / 20, u = 1 - t
                return CGPoint(x: u * u * a.x + 2 * u * t * mid.x + t * t * b.x, y: u * u * a.y + 2 * u * t * mid.y + t * t * b.y)
            }
            let end = shaft[18], angle = atan2(b.y - end.y, b.x - end.x), head = min(16, len * 0.3)
            let left = CGPoint(x: b.x - head * cos(angle - 0.5), y: b.y - head * sin(angle - 0.5))
            let right = CGPoint(x: b.x - head * cos(angle + 0.5), y: b.y - head * sin(angle + 0.5))
            return Stroke(kind: .pen, paths: [shaft, [left, b, right]], label: label, anchor: around(a, 10))

        case .line(let from, let to):
            return Stroke(kind: .pen, paths: [[g(from), g(to)]])

        case .path(let pts):
            return Stroke(kind: .pen, paths: [pts.map(g)])

        case .text(let p, let words):
            let start = g(p), size: CGFloat = 26
            let width = Handwriting.width(of: words, size: size)
            let box = CGRect(x: start.x, y: start.y - size * 0.6, width: width, height: size * 1.2)
            let normalized = CGRect(x: p.x, y: p.y - size * 0.6 / max(frame.height, 1), width: width / max(frame.width, 1), height: size * 1.2 / max(frame.height, 1))
            return Stroke(kind: .text, box: box, text: words, tone: tone(normalized), textSize: size)

        case .underline(let p, let w):
            // A little below the letters so it never runs through them.
            let a = g(p), y = a.y - 3
            return Stroke(kind: .pen, paths: [[CGPoint(x: a.x, y: y), CGPoint(x: a.x + w * frame.width, y: y)]], lineWidth: 3)

        case .highlight(let r):
            return Stroke(kind: .marker, box: rect(r), radius: 3)

        case .number(let p, let n):
            return Stroke(kind: .badge, box: around(g(p), 20), text: n)

        case .check(let p):
            let c = g(p), s: CGFloat = 12
            return Stroke(kind: .pen, paths: [[CGPoint(x: c.x - s * 0.6, y: c.y), CGPoint(x: c.x - s * 0.15, y: c.y - s * 0.5), CGPoint(x: c.x + s * 0.7, y: c.y + s * 0.6)]])

        case .cross(let p):
            let c = g(p), s: CGFloat = 10
            return Stroke(kind: .pen, paths: [[CGPoint(x: c.x - s / 2, y: c.y + s / 2), CGPoint(x: c.x + s / 2, y: c.y - s / 2)],
                                              [CGPoint(x: c.x + s / 2, y: c.y + s / 2), CGPoint(x: c.x - s / 2, y: c.y - s / 2)]])

        case .target(let r, let label), .hover(let r, let label):
            let b = rect(r).insetBy(dx: -4, dy: -4)
            var ring = Stroke(kind: .target, box: b, radius: cornerRadius(of: b, max: 10), label: label)
            if case .hover = mark { ring.waitsForHover = true }
            return ring

        case .spotlight(let r):
            return Stroke(kind: .spotlight, box: rect(r).insetBy(dx: -10, dy: -10), radius: 14)

        case .cheer(let p, let face):
            let c = g(p), width = LabelLayout.size(face, fontSize: 15).width + 8
            return Stroke(kind: .cheer, box: CGRect(x: c.x - width / 2, y: c.y - 15, width: width, height: 30), text: face)

        case .note(let p, let words):
            // Top-left at the point, kept inside the screenshot.
            let tl = g(p), side = noteSide
            let x = min(max(tl.x, frame.minX + 8), frame.maxX - side - 8)
            let y = min(max(tl.y - side, frame.minY + 8), frame.maxY - side - 8)
            return Stroke(kind: .note, box: CGRect(x: x, y: y, width: side, height: side), text: words)
        }
    }
}

/// Puts each label beside what it names, on the first free spot (above, below, right, left, then corners and
/// further out), never on another label or another mark, and always on screen.
enum LabelLayout {
    static let height: CGFloat = 23
    static let gap: CGFloat = 5

    static func size(_ text: String, fontSize: CGFloat = 12) -> CGSize {
        let width = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)]).width
        return CGSize(width: ceil(width) + 20, height: height)
    }

    static func place(_ strokes: inout [Stroke], screens: [CGRect]) {
        let marks = strokes.map(\.bounds)
        var taken: [CGRect] = []
        for i in strokes.indices {
            guard let text = strokes[i].label, !text.isEmpty else { continue }
            let anchor = strokes[i].anchor ?? strokes[i].bounds
            let center = CGPoint(x: anchor.midX, y: anchor.midY)
            let screen = (screens.first { $0.contains(center) } ?? screens.first ?? anchor.insetBy(dx: -400, dy: -400)).insetBy(dx: 4, dy: 4)
            let spots = candidates(around: anchor, size: size(text))
            func clear(_ r: CGRect) -> Bool {
                let padded = r.insetBy(dx: -3, dy: -3)
                return !taken.contains { $0.intersects(padded) } && !marks.indices.contains { $0 != i && marks[$0].intersects(padded) }
            }
            let pick = spots.first { screen.contains($0) && clear($0) } ?? spots.first { screen.contains($0) } ?? spots[0]
            strokes[i].labelBox = pick
            taken.append(pick)
        }
    }

    /// Spots in AppKit coordinates (y up), nearest first.
    static func candidates(around b: CGRect, size s: CGSize) -> [CGRect] {
        let g = gap, far = gap * 3 + s.height
        let above = b.maxY + g, below = b.minY - g - s.height, middle = b.midY - s.height / 2
        let right = b.maxX + g, left = b.minX - g - s.width
        let origins = [
            CGPoint(x: b.minX, y: above), CGPoint(x: b.minX, y: below), CGPoint(x: right, y: middle), CGPoint(x: left, y: middle),
            CGPoint(x: b.maxX - s.width, y: above), CGPoint(x: b.maxX - s.width, y: below),
            CGPoint(x: right, y: above), CGPoint(x: right, y: below), CGPoint(x: left, y: above), CGPoint(x: left, y: below),
            CGPoint(x: b.minX, y: b.maxY + far), CGPoint(x: b.minX, y: b.minY - far - s.height),
            CGPoint(x: b.maxX + far, y: middle), CGPoint(x: b.minX - far - s.width, y: middle),
        ]
        return origins.map { CGRect(origin: $0, size: s) }
    }
}

/// Reads how bright the screenshot is under an area, so free words can be white on dark and dark on light.
struct ToneSampler {
    private let pixels: [UInt8]
    private let width: Int, height: Int

    init?(_ image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = 160, h = max(1, Int(160 * CGFloat(cg.height) / CGFloat(max(cg.width, 1))))
        var buffer = [UInt8](repeating: 0, count: w * h)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            // Quartz fills the buffer top row first, matching normalized coordinates (origin top-left).
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        width = w; height = h; pixels = buffer
    }

    /// Average brightness (0...1) under a rect normalized to the image, origin top-left.
    func brightness(in r: CGRect) -> CGFloat {
        let x0 = max(0, min(width - 1, Int(r.minX * CGFloat(width)))), x1 = max(x0, min(width - 1, Int(r.maxX * CGFloat(width))))
        let y0 = max(0, min(height - 1, Int(r.minY * CGFloat(height)))), y1 = max(y0, min(height - 1, Int(r.maxY * CGFloat(height))))
        var total = 0, count = 0
        for y in y0...y1 { for x in x0...x1 { total += Int(pixels[y * width + x]); count += 1 } }
        return count > 0 ? CGFloat(total) / CGFloat(count * 255) : 1
    }

    func tone(in r: CGRect) -> Stroke.Tone { brightness(in: r) < 0.5 ? .light : .dark }
}

/// Orbit's handwriting: a Korean pen font for Hangul, a handwritten Latin font otherwise.
enum Handwriting {
    static func fontName(for text: String) -> String {
        let hangul = text.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) || (0x3130...0x318F).contains($0.value) }
        let choices = hangul ? ["NanumPen", "PatrickHand-Regular", "Noteworthy-Bold"] : ["PatrickHand-Regular", "Noteworthy-Bold", "NanumPen"]
        return choices.first { NSFont(name: $0, size: 12) != nil } ?? "Noteworthy-Bold"
    }
    /// Nanum Pen draws small for its point size; scale it up to match the Latin faces.
    static func scale(for name: String) -> CGFloat { name == "NanumPen" ? 1.3 : 1 }

    static func nsFont(for text: String, size: CGFloat) -> NSFont {
        let name = fontName(for: text)
        return NSFont(name: name, size: size * scale(for: name)) ?? .systemFont(ofSize: size)
    }

    static func width(of text: String, size: CGFloat) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: nsFont(for: text, size: size)]).width)
    }
}
