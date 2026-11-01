// Renders Orbit's face as a full-bleed app icon: swift scripts/make-icon.swift <output.icns>
import AppKit
import SwiftUI

struct OrbitFaceIcon: View {
    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            ZStack {
                LinearGradient(stops: [
                    .init(color: Color(red: 0.93, green: 0.96, blue: 1), location: 0),
                    .init(color: Color(red: 0.84, green: 0.91, blue: 1), location: 0.2),
                    .init(color: Color(red: 0.64, green: 0.78, blue: 1), location: 0.55),
                    .init(color: Color(red: 0.6, green: 0.8, blue: 0.97), location: 0.82),
                    .init(color: Color(red: 0.64, green: 0.82, blue: 0.97), location: 1)
                ], startPoint: .top, endPoint: .bottom)
                // Glassy highlight.
                Ellipse().fill(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                    .frame(width: s * 0.78, height: s * 0.36).offset(y: -s * 0.33)
                HStack(spacing: s * 0.17) {
                    Capsule().fill(.black)
                    Capsule().fill(.black)
                }
                .frame(width: s * 0.33, height: s * 0.22).offset(y: -s * 0.07)
                HStack(spacing: s * 0.42) {
                    Ellipse().fill(Color(red: 1, green: 0.55, blue: 0.62).opacity(0.45))
                    Ellipse().fill(Color(red: 1, green: 0.55, blue: 0.62).opacity(0.45))
                }
                .frame(width: s * 0.62, height: s * 0.07).offset(y: s * 0.07)
            }
            .frame(width: s, height: s)
        }
        .frame(width: 1024, height: 1024)
        .clipped()
    }
}

let output = CommandLine.arguments[1]
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Orbit-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: OrbitFaceIcon())
    renderer.scale = 1
    let master = NSBitmapImageRep(cgImage: renderer.cgImage!)
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = size * scale
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            master.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
            NSGraphicsContext.restoreGraphicsState()
            let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
            try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
        }
    }
    try! master.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension("png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try task.run(); task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(task.terminationStatus)
