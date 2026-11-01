import AppKit
import SwiftUI

/// A small box next to the cursor for typing to Orbit from any app. It takes keys without
/// bringing Orbit to the front, so the app you're in stays where it was.
final class QuickTypePanel: NSPanel {
    var onCancel: () -> Void = {}
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 64), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1) // above the overlay
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }
    override func resignKey() { super.resignKey(); onCancel() }
}

@MainActor
final class QuickTypeModel: ObservableObject {
    @Published var text = ""
    @Published var focus = UUID()
}

@MainActor
final class QuickTypeController {
    private let panel = QuickTypePanel()
    private let model = QuickTypeModel()
    var onSend: (String) -> Void = { _ in }
    var isVisible: Bool { panel.isVisible }

    init() {
        panel.contentView = NSHostingView(rootView: QuickTypeView(model: model, submit: { [weak self] in self?.submit() }))
        panel.onCancel = { [weak self] in self?.hide() }
    }

    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        // Just below and right of the buddy, kept on screen.
        var origin = CGPoint(x: mouse.x + 14, y: mouse.y - size.height - 34)
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
        origin.y = min(max(origin.y, bounds.minY + 8), bounds.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        model.focus = UUID()
    }
    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }
    func toggle() { isVisible ? hide() : show() }

    private func submit() {
        let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.text = ""
        hide() // out of the way before Orbit looks at the screen
        onSend(text)
    }
}

struct QuickTypeView: View {
    @ObservedObject var model: QuickTypeModel
    var submit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            OrbitMark(size: 22)
            TextField("ask orbit about your screen…", text: $model.text)
                .textFieldStyle(.plain).font(.system(size: 15)).foregroundStyle(DS.Colors.ink)
                .focused($focused)
                .onSubmit(submit)
            Text("↩ send · esc").font(DS.Typography.caption).foregroundStyle(DS.Colors.ink3).fixedSize()
        }
        .padding(.horizontal, 14).frame(height: 44)
        .background(DS.Colors.silver, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(DS.Colors.silverEdge.opacity(0.55), lineWidth: DS.edge))
        .dsShadow()
        .padding(10)
        .onChange(of: model.focus) { _, _ in focused = true }
        .onAppear { focused = true }
    }
}
