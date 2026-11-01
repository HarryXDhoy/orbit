import AppKit
import SceneKit
import SwiftUI

/// A small 3D model Orbit builds on screen, piece by piece, from simple shapes.
struct Sculpture: Equatable {
    enum Shape: String, CaseIterable { case box, sphere, cylinder, cone, capsule, torus, pyramid }
    struct Part: Equatable {
        var shape: Shape
        var position: SIMD3<Float>
        var size: SIMD3<Float>
        var rotation: SIMD3<Float> // degrees
        var color: NSColor
    }
    /// Where the model sits, as fractions of the screenshot (origin top-left).
    var center = CGPoint(x: 0.5, y: 0.45)
    /// Width of the model's window as a fraction of the screen width.
    var size: CGFloat = 0.3
    var title: String?
    var parts: [Part] = []

    /// The model's window in global AppKit coordinates, kept on screen.
    func frame(in screen: CGRect) -> CGRect {
        let side = min(max(size * screen.width, 240), min(720, screen.height * 0.8))
        let c = CGPoint(x: screen.minX + center.x * screen.width, y: screen.maxY - center.y * screen.height)
        var rect = CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
        rect.origin.x = min(max(rect.minX, screen.minX), screen.maxX - side)
        rect.origin.y = min(max(rect.minY, screen.minY), screen.maxY - side)
        return rect
    }
    /// Roughly where a part shows up on screen, so the buddy can hover over it while building.
    static func screenPoint(of part: Part, in frame: CGRect) -> CGPoint {
        let scale = frame.width / 2.8
        return CGPoint(x: frame.midX + CGFloat(part.position.x) * scale, y: frame.midY + CGFloat(part.position.y) * scale)
    }
}

/// Parses `[MODEL:…]` and `[PART:…]` tags and returns the reply without them.
enum ModelScript {
    static let maxParts = 60
    private static let regex = try! NSRegularExpression(pattern: #"\[(MODEL|PART):([^\]\n]{1,400})\]"#)

    static func parse(_ text: String) -> (text: String, sculpture: Sculpture?) {
        let range = NSRange(text.startIndex..., in: text)
        var sculpture = Sculpture()
        for match in regex.matches(in: text, range: range) {
            guard let kr = Range(match.range(at: 1), in: text), let br = Range(match.range(at: 2), in: text) else { continue }
            let fields = text[br].split(separator: ":", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            if text[kr] == "MODEL" {
                guard let n = numbers(fields[0]), n.count == 3, (0...1).contains(n[0]), (0...1).contains(n[1]), n[2] > 0, n[2] <= 1 else { continue }
                sculpture.center = CGPoint(x: CGFloat(n[0]), y: CGFloat(n[1]))
                sculpture.size = CGFloat(n[2])
                sculpture.title = fields.count > 1 && !fields[1].isEmpty ? String(fields[1].prefix(60)) : nil
            } else if sculpture.parts.count < maxParts, let part = part(fields) {
                sculpture.parts.append(part)
            }
        }
        let clean = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (clean, sculpture.parts.isEmpty ? nil : sculpture)
    }

    /// `shape:px,py,pz:sx,sy,sz:color[:rx,ry,rz]`
    private static func part(_ f: [String]) -> Sculpture.Part? {
        guard f.count >= 3, let shape = Sculpture.Shape(rawValue: f[0].lowercased()),
              let p = numbers(f[1]), p.count == 3, let s = numbers(f[2]), (1...3).contains(s.count) else { return nil }
        let size = s.count == 3 ? s : s.count == 2 ? [s[0], s[1], s[0]] : [s[0], s[0], s[0]]
        guard size.allSatisfy({ $0 > 0 && $0 <= 3 }) else { return nil }
        let r = f.count > 4 ? (numbers(f[4]) ?? []) : []
        func clamp(_ v: Double, _ limit: Double) -> Float { Float(min(max(v, -limit), limit)) }
        return Sculpture.Part(
            shape: shape,
            position: SIMD3(clamp(p[0], 2), clamp(p[1], 2), clamp(p[2], 2)),
            size: SIMD3(Float(size[0]), Float(size[1]), Float(size[2])),
            rotation: r.count == 3 ? SIMD3(clamp(r[0], 360), clamp(r[1], 360), clamp(r[2], 360)) : .zero,
            color: color(f.count > 3 ? f[3] : ""))
    }

    private static func numbers(_ s: String) -> [Double]? {
        let values = s.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !values.isEmpty, values.allSatisfy({ $0 != nil && $0!.isFinite }) else { return nil }
        return values.map { $0! }
    }

    static func color(_ s: String) -> NSColor {
        let named: [String: String] = ["red": "E5484D", "orange": "F5A623", "yellow": "F7D34A", "green": "46A758", "blue": "2F7CF6",
                                       "purple": "8E4EC6", "pink": "F28DB2", "brown": "8B5A2B", "white": "F5F5F5", "gray": "9BA1A6",
                                       "grey": "9BA1A6", "black": "2B2B2B", "wood": "B7814E", "glass": "BFE3FF", "gold": "D4A72C", "silver": "C8CCD0"]
        var hex = s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if let mapped = named[hex] { hex = mapped.lowercased() }
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return NSColor(DS.Colors.link) }
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: s.lowercased() == "glass" ? 0.45 : 1)
    }
}

/// Turns a sculpture into a SceneKit scene whose parts pop in one after another, then the whole thing turns slowly.
enum SculptureScene {
    static let secondsPerPart: Double = 0.35

    static func make(_ sculpture: Sculpture, animated: Bool = true) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        let root = SCNNode()
        root.name = "model"
        scene.rootNode.addChildNode(root)
        for (index, part) in sculpture.parts.enumerated() {
            let node = SCNNode(geometry: geometry(part))
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = part.color
            material.roughness.contents = 0.55
            material.metalness.contents = 0.0
            material.transparency = part.color.alphaComponent
            node.geometry?.materials = [material]
            node.position = SCNVector3(part.position.x, part.position.y, part.position.z)
            let radians = part.rotation * (.pi / 180)
            node.eulerAngles = SCNVector3(radians.x, radians.y, radians.z)
            // SCNPyramid sits on its base; center it like the other shapes.
            if part.shape == .pyramid { node.pivot = SCNMatrix4MakeTranslation(0, CGFloat(part.size.y) / 2, 0) }
            if part.shape == .sphere, part.size.x > 0 {
                node.scale = SCNVector3(1, part.size.y / part.size.x, part.size.z / part.size.x)
            }
            if animated {
                // Drop in from a little above, growing like it's being placed.
                let finalScale = node.scale, finalPosition = node.position
                node.scale = SCNVector3(0.01, 0.01, 0.01)
                node.position.y += 0.5
                node.opacity = 0
                let place = SCNAction.group([
                    .customAction(duration: 0.3) { n, t in
                        let k = CGFloat(easeOutBack(Double(t / 0.3)))
                        n.scale = SCNVector3(finalScale.x * k, finalScale.y * k, finalScale.z * k)
                    },
                    .move(to: finalPosition, duration: 0.3),
                    .fadeIn(duration: 0.15),
                ])
                place.timingMode = .easeOut
                node.runAction(.sequence([.wait(duration: Double(index) * secondsPerPart), place]))
            }
            root.addChildNode(node)
        }
        root.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 16)))

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 34
        camera.position = SCNVector3(0, 1.1, 4.6)
        camera.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camera)

        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        scene.rootNode.addChildNode(ambient)
        let sun = SCNNode(); sun.light = SCNLight(); sun.light?.type = .directional
        sun.light?.intensity = 1100
        sun.position = SCNVector3(2, 4, 3); sun.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(sun)
        return scene
    }

    static func geometry(_ part: Sculpture.Part) -> SCNGeometry {
        let s = part.size.map { CGFloat($0) }
        switch part.shape {
        case .box: return SCNBox(width: s.x, height: s.y, length: s.z, chamferRadius: min(s.x, s.y, s.z) * 0.08)
        case .sphere: return SCNSphere(radius: s.x / 2)
        case .cylinder: return SCNCylinder(radius: s.x / 2, height: s.y)
        case .cone: return SCNCone(topRadius: 0, bottomRadius: s.x / 2, height: s.y)
        case .capsule: return SCNCapsule(capRadius: min(s.x / 2, s.y / 2), height: s.y)
        case .torus: return SCNTorus(ringRadius: s.x / 2, pipeRadius: max(0.005, min(s.y / 2, s.x / 2)))
        case .pyramid: return SCNPyramid(width: s.x, height: s.y, length: s.z)
        }
    }

    private static func easeOutBack(_ t: Double) -> Double {
        let c = 1.70158, x = min(max(t, 0), 1) - 1
        return 1 + (c + 1) * x * x * x + c * x * x
    }
}

private extension SIMD3 where Scalar == Float {
    func map(_ f: (Float) -> CGFloat) -> (x: CGFloat, y: CGFloat, z: CGFloat) { (f(x), f(y), f(z)) }
}

/// A click-through window that shows one sculpture.
final class SculptureWindow: NSWindow {
    init(sculpture: Sculpture, frame: CGRect) {
        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: SculptureView(sculpture: sculpture))
        setFrame(frame, display: false)
    }
    override var canBecomeKey: Bool { false }
}

struct SculptureView: View {
    let sculpture: Sculpture
    var body: some View {
        ZStack(alignment: .bottom) {
            SceneKitView(scene: SculptureScene.make(sculpture))
            if let title = sculpture.title {
                SpeechBubble(mine: true) { Text(title.lowercased()).font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Colors.ink).lineLimit(1) }
                    .fixedSize().padding(.bottom, 8)
            }
        }
    }
}

struct SceneKitView: NSViewRepresentable {
    let scene: SCNScene
    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.isPlaying = true
        view.rendersContinuously = true
        return view
    }
    func updateNSView(_ view: SCNView, context: Context) {}
}
