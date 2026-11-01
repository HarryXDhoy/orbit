import AppKit
import SwiftUI

@MainActor
final class OrbitDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var window: NSWindow?
    private var status: NSStatusItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        FontRegistry.registerBundledFonts()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1010, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Orbit"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // An empty unified toolbar makes the title bar 52pt tall so the traffic lights line up with Orbit's top bar.
        window.toolbar = NSToolbar(identifier: "orbit")
        window.toolbarStyle = .unified
        window.backgroundColor = NSColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        window.minSize = CGSize(width: 980, height: 630)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AppView(state: state))
        window.center()
        self.window = window
        state.showWindow = { [weak self] in self?.showWindow() }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status?.button?.image = Self.menuBarFace()
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Orbit", action: #selector(showWindow), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Connections", action: #selector(showConnections), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Type to Orbit", action: #selector(typeToOrbit), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Clear Drawings", action: #selector(clearDrawings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Orbit", action: #selector(quit), keyEquivalent: "q").target = self
        status?.menu = menu
        let appMenu = NSMenu()
        let mainItem = NSMenuItem(); mainItem.submenu = menu.copy() as? NSMenu
        appMenu.addItem(mainItem)
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; appMenu.addItem(editItem)
        NSApp.mainMenu = appMenu
        showWindow()
        state.updateCompanion()
    }
    @objc func showWindow() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func showSettings() { state.selectedPage = "settings"; showWindow() }
    @objc func showConnections() { state.selectedPage = "connections"; showWindow() }
    @objc func typeToOrbit() { state.beginTyping() }
    @objc func clearDrawings() { state.overlay.model.clear(); state.overlay.model.say(nil) }
    /// Orbit's face as a menu bar template image: an orb outline and two eyes.
    static func menuBarFace() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let orb = NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 12, height: 12)); orb.lineWidth = 1.4; orb.stroke()
            NSBezierPath(roundedRect: NSRect(x: 6.6, y: 7.6, width: 1.6, height: 3.4), xRadius: 0.8, yRadius: 0.8).fill()
            NSBezierPath(roundedRect: NSRect(x: 9.8, y: 7.6, width: 1.6, height: 3.4), xRadius: 0.8, yRadius: 0.8).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
    @objc func quit() { state.stop(); NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
}

MainActor.assumeIsolated {
let application = NSApplication.shared
if let smokeIndex = CommandLine.arguments.firstIndex(of: "--smoke-provider"), CommandLine.arguments.count > smokeIndex + 1 {
    let name = CommandLine.arguments[smokeIndex + 1]
    Task { @MainActor in
        do {
            var settings = ConnectionSettings()
            guard let provider = ProviderKind(rawValue: name) else { throw OrbitError("Unknown provider") }
            settings.provider = provider
            let client = ProviderClient()
            let vision = CommandLine.arguments.contains("--smoke-image")
            var fixture: Data?
            if vision {
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 80, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                for y in 0..<80 { for x in 0..<80 { bitmap.setColor(.red, atX: x, y: y) } }
                fixture = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
            }
            let prompt = vision ? "What is the dominant color in this image? Reply with only the color name." : "Reply with exactly: Orbit connection OK."
            let reply = try await client.reply(settings: settings, messages: [ChatMessage(role: "user", text: prompt)], image: fixture)
            print("PROVIDER=\(name) REPLY=\(reply.text)")
            exit(0)
        } catch { print("PROVIDER=\(name) ERROR=\(error.localizedDescription)"); exit(1) }
    }
    application.run()
} else {
    application.setActivationPolicy(.regular)
    let delegate = OrbitDelegate()
    application.delegate = delegate
    application.run()
    withExtendedLifetime(delegate) {}
}

}
