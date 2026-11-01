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

    var label: String? {
        switch self {
        case .point(_, let l), .text(_, let l): return l
        case .box(_, let l), .circle(_, _, let l), .arrow(_, _, let l): return l
        case .line, .path: return nil
        }
    }
}

/// Parses the drawing tags a reply may end with and returns the reply without them.
enum SketchScript {
    static let maxMarks = 40
    static let maxPathPoints = 160
    private static let regex = try! NSRegularExpression(pattern: #"\[(POINT|BOX|CIRCLE|ARROW|LINE|PATH|TEXT):([^\]\n]{1,4000})\]"#)

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
        let label = parts.count > 1 ? String(parts[1].trimmingCharacters(in: .whitespaces).prefix(80)) : nil
        let tag = label?.isEmpty == false ? label : nil
        switch (kind, n.count) {
        case ("POINT", 2): return .point(CGPoint(x: n[0], y: n[1]), tag ?? "here")
        case ("BOX", 4): return n[2] > 0 && n[3] > 0 ? .box(CGRect(x: n[0], y: n[1], width: n[2], height: n[3]), tag) : nil
        case ("CIRCLE", 3): return n[2] > 0 ? .circle(CGPoint(x: n[0], y: n[1]), n[2], tag) : nil
        case ("ARROW", 4): return .arrow(CGPoint(x: n[0], y: n[1]), CGPoint(x: n[2], y: n[3]), tag)
        case ("LINE", 4): return .line(CGPoint(x: n[0], y: n[1]), CGPoint(x: n[2], y: n[3]))
        case ("TEXT", 2): return tag.map { .text(CGPoint(x: n[0], y: n[1]), $0) }
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

/// A sketch mark resolved to global screen points (AppKit coordinates, origin bottom-left) as a stroke.
struct Stroke {
    var points: [CGPoint]
    var label: String?
    var labelAt: CGPoint
    var kind: Kind
    enum Kind { case point, highlight, pen, text }
    var length: CGFloat { zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } }

    /// The first `fraction` of the stroke by length, so it can be drawn as if by hand.
    func prefix(_ fraction: CGFloat) -> [CGPoint] {
        guard fraction < 1, points.count > 1 else { return points }
        var remaining = length * max(0, fraction)
        var out = [points[0]]
        for (a, b) in zip(points, points.dropFirst()) {
            let d = hypot(b.x - a.x, b.y - a.y)
            if remaining >= d { out.append(b); remaining -= d; continue }
            let t = d > 0 ? remaining / d : 0
            out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            break
        }
        return out
    }

    static func make(_ mark: SketchMark, in frame: CGRect) -> Stroke {
        func g(_ p: CGPoint) -> CGPoint { CGPoint(x: frame.minX + p.x * frame.width, y: frame.maxY - p.y * frame.height) }
        switch mark {
        case .point(let p, let label):
            return Stroke(points: [g(p)], label: label, labelAt: g(p), kind: .point)
        case .box(let r, let label):
            let a = g(CGPoint(x: r.minX, y: r.minY)), b = g(CGPoint(x: r.maxX, y: r.maxY))
            let pad: CGFloat = 6
            let minX = min(a.x, b.x) - pad, maxX = max(a.x, b.x) + pad, minY = min(a.y, b.y) - pad, maxY = max(a.y, b.y) + pad
            let pts = [CGPoint(x: minX, y: maxY), CGPoint(x: maxX, y: maxY + 1), CGPoint(x: maxX - 1, y: minY), CGPoint(x: minX + 1, y: minY - 1), CGPoint(x: minX - 2, y: maxY + 3)]
            return Stroke(points: pts, label: label, labelAt: CGPoint(x: maxX, y: minY), kind: .highlight)
        case .circle(let c, let r, let label):
            let center = g(c), radius = max(8, r * frame.width)
            let pts = (0...52).map { i -> CGPoint in
                let t = CGFloat(i) / 48 * 2 * .pi + .pi * 0.75 // runs a little past a full loop, like a pen circle
                let rr = radius * (1 + 0.04 * sin(t * 2 + 0.6)) // gentle, pen-like unevenness
                return CGPoint(x: center.x + cos(t) * rr * 1.08, y: center.y + sin(t) * rr * 0.92)
            }
            return Stroke(points: pts, label: label, labelAt: CGPoint(x: center.x + radius, y: center.y - radius), kind: .pen)
        case .arrow(let from, let to, let label):
            let a = g(from), b = g(to)
            let angle = atan2(b.y - a.y, b.x - a.x), head: CGFloat = 16
            let left = CGPoint(x: b.x - head * cos(angle - .pi / 7), y: b.y - head * sin(angle - .pi / 7))
            let right = CGPoint(x: b.x - head * cos(angle + .pi / 7), y: b.y - head * sin(angle + .pi / 7))
            let mid = CGPoint(x: (a.x + b.x) / 2 - sin(angle) * 10, y: (a.y + b.y) / 2 + cos(angle) * 10)
            let curve = (0...12).map { i -> CGPoint in
                let t = CGFloat(i) / 12, u = 1 - t
                return CGPoint(x: u * u * a.x + 2 * u * t * mid.x + t * t * b.x, y: u * u * a.y + 2 * u * t * mid.y + t * t * b.y)
            }
            return Stroke(points: curve + [left, b, right], label: label, labelAt: a, kind: .pen)
        case .line(let from, let to):
            return Stroke(points: [g(from), g(to)], label: nil, labelAt: g(to), kind: .pen)
        case .path(let pts):
            let mapped = pts.map(g)
            return Stroke(points: mapped, label: nil, labelAt: mapped.last!, kind: .pen)
        case .text(let p, let words):
            return Stroke(points: [g(p)], label: words, labelAt: g(p), kind: .text)
        }
    }
}
