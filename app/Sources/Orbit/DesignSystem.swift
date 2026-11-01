import AppKit
import SwiftUI

// Orbit design system — a bright retro-desktop language: soft gray canvas with a dot grid,
// glossy aqua and silver pills, little Mac windows, lowercase copy. Every view reads from DS.
enum DS {
    enum Colors {
        static let canvas = Color(hex: 0xF5F5F5)
        static let surface = Color.white
        static let ink = Color.black
        static let ink2 = Color.black.opacity(0.55)
        static let ink3 = Color.black.opacity(0.35)
        static let hairline = Color.black.opacity(0.08)
        static let dot = Color.black.opacity(0.07)
        static let link = Color(hex: 0x2F7CF6)
        static let live = Color(hex: 0x34C759)
        static let danger = Color(hex: 0xE5484D)
        static let dangerTint = Color(hex: 0xE5484D).opacity(0.08)

        static let aqua = LinearGradient(stops: [
            .init(color: Color(hex: 0xEDF4FF), location: 0),
            .init(color: Color(hex: 0xD6E7FF), location: 0.18),
            .init(color: Color(hex: 0xA2C7FF), location: 0.5),
            .init(color: Color(hex: 0x99CBF8), location: 0.8),
            .init(color: Color(hex: 0xA2D2F7), location: 1)
        ], startPoint: .top, endPoint: .bottom)
        static let aquaEdge = Color(hex: 0x221898)
        static let silver = LinearGradient(stops: [
            .init(color: Color(hex: 0xFBFBFB), location: 0),
            .init(color: Color(hex: 0xEDEDED), location: 0.42),
            .init(color: Color(hex: 0xE4E4E4), location: 1)
        ], startPoint: .top, endPoint: .bottom)
        static let silverEdge = Color(hex: 0x626262)
        static let chrome = LinearGradient(colors: [Color(hex: 0xF7F7F7), Color(hex: 0xE9E9E9)], startPoint: .top, endPoint: .bottom)
    }

    enum Typography {
        static let display = Font.system(size: 56, weight: .medium)
        static let title = Font.system(size: 20, weight: .medium)
        static let body = Font.system(size: 14)
        static let bodyMedium = Font.system(size: 14, weight: .medium)
        static let label = Font.system(size: 13)
        static let caption = Font.system(size: 11)
        static let mono = Font.system(size: 11, design: .monospaced)
    }

    enum Space {
        static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 40
    }

    enum Radius {
        static let window: CGFloat = 10, card: CGFloat = 12, bubble: CGFloat = 18
    }

    static let edge: CGFloat = 0.7
    static let shadow = Color.black.opacity(0.12)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension View {
    func dsShadow(_ on: Bool = true) -> some View { shadow(color: on ? DS.shadow : .clear, radius: 12, y: 10) }
}

// MARK: - Buttons

enum PillKind { case aqua, silver, ghost }

struct PillButtonStyle: ButtonStyle {
    var kind: PillKind = .silver
    var compact = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? DS.Typography.label : DS.Typography.bodyMedium)
            .lineLimit(1)
            .foregroundStyle(DS.Colors.ink)
            .padding(.horizontal, compact ? 12 : 18)
            .frame(height: compact ? 28 : 36)
            .background {
                let pill = RoundedRectangle(cornerRadius: compact ? 14 : 18, style: .continuous)
                ZStack(alignment: .top) {
                    pill.fill(fill)
                    if kind != .ghost {
                        // The glassy highlight across the top of each pill.
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.5)).frame(height: compact ? 9 : 12).padding(.horizontal, compact ? 8 : 10).padding(.top, 2)
                        pill.strokeBorder(edge, lineWidth: DS.edge)
                    }
                }
                .compositingGroup()
                .dsShadow(kind != .ghost && !compact)
            }
            .brightness(configuration.isPressed ? -0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(enabled ? 1 : 0.45)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
    private var fill: AnyShapeStyle {
        switch kind {
        case .aqua: return AnyShapeStyle(DS.Colors.aqua)
        case .silver: return AnyShapeStyle(DS.Colors.silver)
        case .ghost: return AnyShapeStyle(Color.black.opacity(0.04))
        }
    }
    private var edge: Color { kind == .aqua ? DS.Colors.aquaEdge : DS.Colors.silverEdge }
}

struct LinkButtonStyle: ButtonStyle {
    var color = DS.Colors.link
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(DS.Typography.label).foregroundStyle(color).opacity(configuration.isPressed ? 0.6 : 1)
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12)).foregroundStyle(DS.Colors.ink3)
            .frame(width: 24, height: 24).contentShape(Rectangle())
            .background(Circle().fill(Color.black.opacity(configuration.isPressed ? 0.08 : 0)))
    }
}

// MARK: - Surfaces

/// The dotted canvas behind everything.
struct DotGrid: View {
    var spacing: CGFloat = 18
    var body: some View {
        Canvas { context, size in
            var path = Path()
            var y: CGFloat = spacing / 2
            while y < size.height {
                var x: CGFloat = spacing / 2
                while x < size.width { path.addEllipse(in: CGRect(x: x, y: y, width: 1.6, height: 1.6)); x += spacing }
                y += spacing
            }
            context.fill(path, with: .color(DS.Colors.dot))
        }
        .background(DS.Colors.canvas)
    }
}

struct TrafficLights: View {
    var body: some View {
        HStack(spacing: 6) {
            ForEach([0xFF5F57, 0xFEBC2E, 0x28C840], id: \.self) { hex in
                Circle().fill(Color(hex: UInt32(hex))).overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5)).frame(width: 10, height: 10)
            }
        }
    }
}

/// A miniature Mac window: chrome bar with traffic lights and a filename-style title.
struct MacWindow<Content: View>: View {
    var title: String
    var highlighted = false
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title).font(DS.Typography.caption).foregroundStyle(DS.Colors.ink3).lineLimit(1)
                HStack { TrafficLights(); Spacer() }
            }
            .padding(.horizontal, 10).frame(height: 26).background(DS.Colors.chrome)
            Rectangle().fill(DS.Colors.hairline).frame(height: 1)
            content.frame(maxWidth: .infinity, alignment: .leading).background(DS.Colors.surface)
        }
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.window))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.window).strokeBorder(highlighted ? DS.Colors.aquaEdge.opacity(0.7) : .black.opacity(0.14), lineWidth: highlighted ? 1.2 : DS.edge))
        .dsShadow()
    }
}

/// Speech bubble with a tail — aqua for you, silver for the buddy.
struct SpeechBubble<Content: View>: View {
    var mine: Bool
    /// Which corner the tail comes out of; by default it follows `mine`, at the bottom.
    var tailOnRight: Bool? = nil
    var tailOnTop = false
    @ViewBuilder var content: Content
    var body: some View {
        let shape = BubbleShape(tailOnRight: tailOnRight ?? mine, tailOnTop: tailOnTop)
        content
            .padding(.horizontal, 15).padding(.vertical, 10)
            .background { shape.fill(mine ? AnyShapeStyle(DS.Colors.aqua) : AnyShapeStyle(DS.Colors.silver)) }
            .overlay { shape.stroke(mine ? DS.Colors.aquaEdge.opacity(0.8) : DS.Colors.silverEdge.opacity(0.55), lineWidth: DS.edge) }
            .dsShadow()
    }
}

struct BubbleShape: Shape {
    var tailOnRight: Bool
    var tailOnTop = false
    func path(in rect: CGRect) -> Path {
        let r = min(DS.Radius.bubble, rect.height / 2)
        var body = Path(roundedRect: rect, cornerRadius: r, style: .continuous)
        let x = tailOnRight ? rect.maxX - 14 : rect.minX + 14
        let dir: CGFloat = tailOnRight ? 1 : -1
        let edge = tailOnTop ? rect.minY : rect.maxY
        let out: CGFloat = tailOnTop ? -1 : 1 // away from the bubble
        var tail = Path()
        tail.move(to: CGPoint(x: x - 6 * dir, y: edge - 1 * out))
        tail.addQuadCurve(to: CGPoint(x: x + 10 * dir, y: edge + 7 * out), control: CGPoint(x: x + 2 * dir, y: edge + 6 * out))
        tail.addQuadCurve(to: CGPoint(x: x + 4 * dir, y: edge - 6 * out), control: CGPoint(x: x + 4 * dir, y: edge + 2 * out))
        tail.closeSubpath()
        body.addPath(tail)
        return body
    }
}

/// The pill-shaped audio meter: gray bars, animated while listening.
struct Waveform: View {
    var active: Bool
    var bars = 13
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !active)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<bars, id: \.self) { i in
                    let wave = active ? (sin(t * 7 + Double(i) * 0.8) + 1) / 2 : 0.15
                    Capsule().fill(active ? DS.Colors.ink.opacity(0.55) : DS.Colors.ink3.opacity(0.6))
                        .frame(width: 3, height: 4 + 12 * wave * envelope(i))
                }
            }.frame(height: 18)
        }
    }
    private func envelope(_ i: Int) -> Double { 1 - abs(Double(i) / Double(bars - 1) - 0.5) * 1.2 }
}

/// Plain field on a white inset, used across forms.
struct DSField: View {
    var title: String
    @Binding var text: String
    var placeholder: String
    var secure = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.lowercased()).font(DS.Typography.caption).foregroundStyle(DS.Colors.ink2)
            Group {
                if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
            }
            .textFieldStyle(.plain).font(DS.Typography.label)
            .padding(.horizontal, 12).frame(height: 32)
            .background(DS.Colors.canvas, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DS.Colors.hairline))
        }
    }
}

/// Status dot + lowercase label, like a menu bar item.
struct StatusPill: View {
    var text: String
    var live = true
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(live ? DS.Colors.live : DS.Colors.ink3).frame(width: 6, height: 6)
            Text(text).font(DS.Typography.label).foregroundStyle(DS.Colors.ink2)
        }
    }
}

/// Orbit's own mark: a glossy aqua orb with two eyes.
struct OrbitMark: View {
    var size: CGFloat = 58
    var body: some View {
        ZStack {
            Circle().fill(DS.Colors.aqua)
            Circle().strokeBorder(DS.Colors.aquaEdge.opacity(0.8), lineWidth: max(0.7, size * 0.02))
            Ellipse().fill(.white.opacity(0.7)).frame(width: size * 0.55, height: size * 0.24).offset(y: -size * 0.27)
            HStack(spacing: size * 0.14) {
                Capsule().fill(DS.Colors.ink)
                Capsule().fill(DS.Colors.ink)
            }.frame(width: size * 0.27, height: size * 0.17).offset(y: size * 0.02)
        }.frame(width: size, height: size)
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
        }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [(items: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] = []
        var current: [Int] = [], x: CGFloat = 0, y: CGFloat = 0, height: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !current.isEmpty, x + size.width > width {
                rows.append((current, y, x - spacing, height)); y += height + spacing
                current = []; x = 0; height = 0
            }
            current.append(i); x += size.width + spacing; height = max(height, size.height)
        }
        if !current.isEmpty { rows.append((current, y, x - spacing, height)) }
        return rows
    }
}
