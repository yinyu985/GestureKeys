import SwiftUI
import AppKit
import GestureCore

enum Brand {
    static let icon = (Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String)
        .flatMap { Bundle.main.url(forResource: $0, withExtension: nil) }
        .flatMap { NSImage(contentsOf: $0) } ?? NSApp.applicationIconImage!

    static let statusIcon = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
        let tile = NSBezierPath(roundedRect: CGRect(x: 1, y: 1, width: 16, height: 16), xRadius: 4, yRadius: 4)
        NSColor.white.setFill(); tile.fill()
        NSColor.black.setFill()
        let pointer = NSBezierPath()
        pointer.move(to: CGPoint(x: 6, y: 3.4))
        for (x, y) in [(6.0, 11.1), (7.55, 9.65), (8.75, 12.15), (10.15, 11.55), (9.1, 9.25), (11.7, 9.25)] {
            pointer.line(to: CGPoint(x: x, y: y))
        }
        pointer.close(); pointer.fill()
        for (x, width) in [(3.8, 2.15), (6.7, 4.6), (12.05, 2.15)] {
            NSBezierPath(roundedRect: CGRect(x: x, y: 13.5, width: width, height: 1.45), xRadius: 0.45, yRadius: 0.45).fill()
        }
        return true
    }
}

enum MainWindowLayout {
    static let width: CGFloat = 850
    static let height: CGFloat = 580
}

@main
struct GestureKeysApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow
    var body: some Scene {
        Window("GestureKeys", id: "main") {
            ContentView(model: model)
                .onAppear { delegate.connect(model, reopen: { openWindow(id: "main") }) }
        }
        .defaultSize(width: MainWindowLayout.width, height: MainWindowLayout.height)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加规则", action: model.addRule).keyboardShortcut("n").disabled(!model.isRulePage)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private weak var model: AppModel?
    private var smokeScheduled = false
    private var reopen: (() -> Void)?
    @MainActor func connect(_ model: AppModel, reopen: @escaping () -> Void) {
        self.model = model; self.reopen = reopen
        model.onIconLocationChanged = { [weak self] in self?.updateIconLocation($0) }
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }) {
            window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(srgbRed: 0.086, green: 0.094, blue: 0.110, alpha: 1)
            window.isRestorable = false
            window.styleMask.remove(.resizable)
            window.standardWindowButton(.zoomButton)?.isEnabled = false
        }
        updateIconLocation(model.configuration.iconLocation)
        if let mode = ProcessInfo.processInfo.environment["GESTUREKEYS_SMOKE_TEST"], !smokeScheduled {
            smokeScheduled = true
            if mode.contains("dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.smokeTest() }
        }
    }
    @MainActor private func updateIconLocation(_ location: IconLocation) {
        let policy: NSApplication.ActivationPolicy = location == .dock ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            let foreground = NSApp.isActive
            NSApp.setActivationPolicy(policy)
            if foreground { NSApp.activate(ignoringOtherApps: true) }
        }
        if location != .menuBar, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item); statusItem = nil
        } else if location == .menuBar && statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = Brand.statusIcon
            item.button?.toolTip = "GestureKeys — 键盘与鼠标规则"
            let menu = NSMenu(); menu.delegate = self; item.menu = menu; statusItem = item
        }
    }
    @MainActor func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = NSMenuItem(title: "打开应用", action: #selector(showWindow), keyEquivalent: "")
        open.target = self; menu.addItem(open)
        let quit = NSMenuItem(title: "退出应用", action: #selector(quitApplication), keyEquivalent: "")
        quit.target = self; menu.addItem(quit)
    }
    @MainActor @objc private func quitApplication() { NSApp.terminate(nil) }
    @MainActor @objc private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else { reopen?() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    @MainActor func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow(); return false }
        return true
    }
    @MainActor func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor private func smokeTest() {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0 is NSPanel) }), let view = window.contentView, let model else {
            fputs("SMOKE FAIL: no content window\n", stderr); exit(1)
        }
        do { print("PASS \(try EventEngine.runInputChecks()) input-state checks (no tap, no posted input)") }
        catch { fputs("SMOKE FAIL: \(error)\n", stderr); exit(1) }
        guard let button = descendants(view).compactMap({ $0 as? RecorderButton }).first else {
            fputs("SMOKE FAIL: no shortcut recorder\n", stderr); exit(1)
        }
        let original = model.configuration
        for page in ["键盘", "鼠标"] {
            model.filter = page; model.addRule()
            guard let draft = model.editor, draft.isNew, draft.rule.enabled, draft.rule.name.isEmpty,
                  draft.rule.triggerKey == nil, draft.rule.outputKey == nil, draft.rule.action == .unassigned,
                  draft.rule.points.isEmpty, model.configuration == original else {
                fputs("SMOKE FAIL: blank rule draft\n", stderr); exit(1)
            }
            model.editor = nil
        }
        model.filter = "键盘"
        print("PASS new rules are empty, enabled and unsaved")
        button.performClick(nil)
        guard button.capturing, button.title == "请按键" else { fputs("SMOKE FAIL: shortcut capture state\n", stderr); exit(1) }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0,
                  windowNumber: window.windowNumber, context: nil, characters: "5", charactersIgnoringModifiers: "5", isARepeat: false, keyCode: 23) else { exit(1) }
        NSApp.sendEvent(event)
        guard !button.capturing, model.configuration.rules[0].triggerKey == Shortcut(23, 0x40000) else {
            fputs("SMOKE FAIL: shortcut recording\n", stderr); exit(1)
        }
        print("PASS local shortcut recorder")
        model.configuration = original
        if let gesture = model.configuration.rules.first(where: { $0.kind == .gesture }) {
            model.edit(gesture)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { self.checkCanvas(window, original: original) }
    }
    @MainActor private func checkCanvas(_ window: NSWindow, original: Configuration) {
        guard let view = window.attachedSheet?.contentView ?? window.contentView, let model,
              let canvas = descendants(view).compactMap({ $0 as? StrokeCanvasView }).first else {
            fputs("SMOKE FAIL: no gesture canvas\n", stderr); exit(1)
        }
        let samples: [(NSEvent.EventType, CGPoint)] = [(.rightMouseDown, CGPoint(x: 25, y: 100)), (.rightMouseDragged, CGPoint(x: 70, y: 90)), (.rightMouseUp, CGPoint(x: 140, y: 30))]
        for (type, point) in samples {
            let location = canvas.convert(point, to: nil)
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { exit(1) }
            switch type {
            case .rightMouseDown: canvas.rightMouseDown(with: event)
            case .rightMouseDragged: canvas.rightMouseDragged(with: event)
            default: canvas.rightMouseUp(with: event)
            }
        }
        guard canvas.savedPoints == samples.map({ StrokePoint($0.1.x, $0.1.y) }),
              canvas.displayedPoints == canvas.savedPoints, model.configuration == original else {
            fputs("SMOKE FAIL: gesture recording\n", stderr); exit(1)
        }
        print("PASS local gesture recorder preserves position and scale")
        model.configuration = original
        let mode = ProcessInfo.processInfo.environment["GESTUREKEYS_SMOKE_TEST"] ?? "1"
        if mode.contains("gesture") { model.filter = "鼠标" }
        else { model.editor = nil }
        if mode.contains("general") { model.filter = "通用" }
        if mode.contains("about") { model.filter = "关于" }
        if mode == "delete-prompt", let rule = model.configuration.rules.first { model.confirmDelete(rule) }
        if mode == "action-error" { model.verifyMissingApplication() }
        guard !window.styleMask.contains(.resizable), window.contentMinSize == window.contentMaxSize,
              window.frame.width == MainWindowLayout.width, window.frame.height >= MainWindowLayout.height else {
            fputs("SMOKE FAIL: main window mask=\(window.styleMask.rawValue) frame=\(window.frame) content=\(String(describing: window.contentView?.frame.size)) min=\(window.contentMinSize) max=\(window.contentMaxSize)\n", stderr); exit(1)
        }
        print("PASS fixed main window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.captureSmoke(window, mode: mode) }
    }
    @MainActor private func captureSmoke(_ window: NSWindow, mode: String) {
        let captureWindow = (mode.contains("editor") || mode.contains("prompt")) ? (window.attachedSheet ?? window) : window
        if !mode.contains("editor"), model?.editor != nil {
            model?.editor = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.captureSmoke(window, mode: mode) }
            return
        }
        if mode == "locations" {
            verifyIconLocations(window)
            return
        }
        if mode == "action-error" {
            guard model?.actionError?.contains("找不到应用「测试应用」") == true else {
                fputs("SMOKE FAIL: missing application report\n", stderr); exit(1)
            }
            print("PASS missing application reports an action error")
        }
        guard let view = captureWindow.contentView else { exit(1) }
        view.layoutSubtreeIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                let filename = mode == "1" ? "/tmp/GestureKeys-ui.png" : "/tmp/GestureKeys-ui-\(mode).png"
                try? data.write(to: URL(fileURLWithPath: filename))
            }
        }
        print("SMOKE PASS: window=\(Int(window.frame.width))x\(Int(window.frame.height)) rules=\(model?.configuration.rules.count ?? 0) engine=\(model?.running == true ? "active" : "paused")")
        model?.shutdown()
        fflush(stdout)
        exit(0)
    }
    @MainActor private func verifyIconLocations(_ window: NSWindow) {
        updateIconLocation(.dock)
        guard NSApp.activationPolicy() == .regular, statusItem == nil else { fputs("SMOKE FAIL: Dock visibility\n", stderr); exit(1) }
        updateIconLocation(.menuBar)
        guard let menu = statusItem?.menu, statusItem?.button?.image?.isTemplate == false, NSApp.activationPolicy() == .accessory else { fputs("SMOKE FAIL: menu-bar visibility\n", stderr); exit(1) }
        menuNeedsUpdate(menu)
        guard menu.items.map(\.title) == ["打开应用", "退出应用"] else { fputs("SMOKE FAIL: menu actions\n", stderr); exit(1) }
        updateIconLocation(.hidden)
        guard statusItem == nil, NSApp.activationPolicy() == .accessory else { fputs("SMOKE FAIL: hidden visibility\n", stderr); exit(1) }
        window.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            _ = self.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }) else {
                    fputs("SMOKE FAIL: reopen hidden app\n", stderr); exit(1)
                }
                print("PASS all icon locations, menu entry and reopening a hidden window")
                self.model?.shutdown(); fflush(stdout); exit(0)
            }
        }
    }
}
