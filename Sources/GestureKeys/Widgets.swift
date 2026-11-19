import AppKit
import SwiftUI
import GestureCore

enum Ink {
    static let base = Color(red: 0.086, green: 0.094, blue: 0.110)
    static let sidebar = Color(red: 0.110, green: 0.120, blue: 0.139)
    static let border = Color.white.opacity(0.085)
    static let surface = Color.white.opacity(0.035)
    static let accent = Color(red: 0.478, green: 0.654, blue: 1)
    static let accentText = Color(red: 0.655, green: 0.765, blue: 1)
    static let primary = Color(red: 0.902, green: 0.925, blue: 0.973)
    static let secondary = Color(red: 0.64, green: 0.67, blue: 0.72)
    static let muted = Color(red: 0.48, green: 0.51, blue: 0.57)
    static let nsAccent = NSColor(srgbRed: 0.478, green: 0.654, blue: 1, alpha: 1)
    static let nsDanger = NSColor(srgbRed: 1, green: 0.60, blue: 0.60, alpha: 1)
    static let danger = Color(nsColor: nsDanger)
}

struct EditorInputReadout: NSViewRepresentable {
    let style: TrailStyle
    func makeNSView(context: Context) -> EditorInputReadoutLabel { EditorInputReadoutLabel(frame: .zero) }
    func updateNSView(_ label: EditorInputReadoutLabel, context: Context) { label.textColor = style.nsColor }
    static func dismantleNSView(_ label: EditorInputReadoutLabel, coordinator: ()) { label.stop() }
}

final class EditorInputReadoutLabel: NSTextField {
    private var monitor: Any?
    private var expiry: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isEditable = false; isSelectable = false; isBordered = false; drawsBackground = false
        font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        lineBreakMode = .byTruncatingTail
        setAccessibilityLabel("当前按下的是")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, let sheet = self.window, sheet.isSheet, sheet.isKeyWindow, event.window === sheet else { return event }
            if event.type == .keyDown {
                self.show(Shortcut(event.keyCode, UInt64(event.modifierFlags.rawValue)).display)
            } else {
                self.show(event.buttonNumber == 0 ? "左键" : Rule.buttonName(event.buttonNumber))
            }
            return event
        }
    }
    private func show(_ title: String) {
        stringValue = "当前按下的是：\(title)"
        expiry?.invalidate()
        let timer = Timer(timeInterval: 1.4, repeats: false) { [weak self] _ in self?.stringValue = "" }
        expiry = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        expiry?.invalidate(); expiry = nil; stringValue = ""
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Shortcut?
    var onRecording: (Bool) -> Void = { _ in }
    func makeNSView(context: Context) -> RecorderButton { RecorderButton() }
    func updateNSView(_ view: RecorderButton, context: Context) {
        view.value = shortcut
        view.didRecord = { shortcut = $0 }
        view.recordingChanged = onRecording
        if !view.capturing { view.title = shortcut?.display ?? "录入"; view.needsDisplay = true }
    }
    static func dismantleNSView(_ view: RecorderButton, coordinator: ()) { view.stop() }
}

final class RecorderButton: NSButton {
    var value: Shortcut?
    var didRecord: ((Shortcut) -> Void)?
    var recordingChanged: ((Bool) -> Void)?
    private(set) var capturing = false
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var hovered = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false; focusRingType = .none
        font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        target = self; action = #selector(beginRecording)
        toolTip = "点击后按下新的快捷键；Esc 取消"
        setAccessibilityLabel("录入快捷键")
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        let color = capturing ? Ink.nsDanger : Ink.nsAccent
        color.withAlphaComponent(capturing ? 0.20 : hovered ? 0.14 : 0.08).setFill(); box.fill()
        color.withAlphaComponent(capturing ? 0.92 : 0.40).setStroke(); box.lineWidth = 1; box.stroke()
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: capturing ? Ink.nsDanger : NSColor(srgbRed: 0.655, green: 0.765, blue: 1, alpha: 1), .paragraphStyle: paragraph]
        let height = (title as NSString).size(withAttributes: attributes).height
        (title as NSString).draw(in: NSRect(x: 6, y: bounds.midY - height / 2, width: bounds.width - 12, height: height), withAttributes: attributes)
        if window?.firstResponder === self && window?.isKeyWindow == true {
            color.setStroke(); box.lineWidth = 2; box.stroke()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func beginRecording() {
        if capturing { stop(); return }
        diagnostics.record("shortcut.capture_started")
        capturing = true; title = "请按键"; setAccessibilityLabel("正在录入快捷键，按 Esc 取消"); needsDisplay = true; recordingChanged?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.capturing else { return event }
            if event.type == .keyDown {
                let flags = event.modifierFlags.rawValue & UInt(Shortcut.mask)
                if event.keyCode != 53 || flags != 0 {
                    let shortcut = Shortcut(event.keyCode, UInt64(flags))
                    self.value = shortcut; self.didRecord?(shortcut)
                    diagnostics.record("shortcut.captured")
                } else { diagnostics.record("shortcut.capture_cancelled") }
                self.stop()
            }
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.stop() }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }; resignObserver = nil
        let wasCapturing = capturing; capturing = false; title = value?.display ?? "录入"; needsDisplay = true
        if wasCapturing { setAccessibilityLabel("录入快捷键"); recordingChanged?(false) }
    }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}

extension TrailStyle {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
}

struct StrokeCanvas: NSViewRepresentable {
    var points: [StrokePoint]
    var preset: ShapePreset?
    var style = TrailStyle()
    var onRecord: ([StrokePoint]) -> Void
    func makeNSView(context: Context) -> StrokeCanvasView { StrokeCanvasView() }
    func updateNSView(_ view: StrokeCanvasView, context: Context) {
        view.savedPoints = points; view.preset = preset; view.style = style; view.onRecord = onRecord; view.needsDisplay = true
    }
}

final class StrokeCanvasView: NSView {
    var savedPoints: [StrokePoint] = []
    var preset: ShapePreset?
    var style = TrailStyle()
    var onRecord: (([StrokePoint]) -> Void)?
    private var livePoints: [StrokePoint]?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); setAccessibilityElement(true)
        setAccessibilityLabel("手势录制区域。按住鼠标绘制轨迹。")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func point(_ event: NSEvent) -> StrokePoint {
        let p = convert(event.locationInWindow, from: nil)
        return StrokePoint(Double(p.x), Double(p.y))
    }
    override func mouseDown(with event: NSEvent) { livePoints = [point(event)]; needsDisplay = true }
    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) {
        if (livePoints?.count ?? 0) < 2048 { livePoints?.append(point(event)) }; needsDisplay = true
    }
    override func rightMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) {
        guard var points = livePoints else { return }
        points.append(point(event)); livePoints = nil
        if Shape.normalize(points) != nil { savedPoints = points; preset = nil; onRecord?(points) }
        needsDisplay = true
    }
    override func rightMouseUp(with event: NSEvent) { mouseUp(with: event) }
    override func otherMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { mouseUp(with: event) }
    var displayedPoints: [StrokePoint] {
        if let livePoints { return livePoints }
        guard let preset, let first = savedPoints.first else { return savedPoints }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in savedPoints.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        // Only built-in templates are positioned on the canvas. Freehand points are already canvas coordinates.
        let previewWidth = preset == .left || preset == .right ? min(64.0, bounds.width - 28) : bounds.width - 28
        let scale = min(1, max(1, previewWidth) / max(1, maxX - minX), max(1, bounds.height - 28) / max(1, maxY - minY))
        let centerX = (minX + maxX) / 2, centerY = (minY + maxY) / 2
        return savedPoints.map { StrokePoint(($0.x - centerX) * scale + bounds.midX, ($0.y - centerY) * scale + bounds.midY) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        NSColor.separatorColor.withAlphaComponent(0.55).setFill()
        for x in stride(from: CGFloat(16), to: bounds.width, by: 20) {
            for y in stride(from: CGFloat(16), to: bounds.height, by: 20) {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1.5, height: 1.5)).fill()
            }
        }
        let display = displayedPoints
        if let first = display.first {
            let path = NSBezierPath(); path.move(to: NSPoint(x: first.x, y: first.y))
            for p in display.dropFirst() { path.line(to: NSPoint(x: p.x, y: p.y)) }
            path.lineWidth = style.width; path.lineCapStyle = .round; path.lineJoinStyle = .round
            style.nsColor.setStroke(); path.stroke()
            style.nsColor.setFill(); NSBezierPath(ovalIn: NSRect(x: first.x - 5, y: first.y - 5, width: 10, height: 10)).fill()
            if let last = display.last {
                NSColor.controlBackgroundColor.setFill(); NSBezierPath(ovalIn: NSRect(x: last.x - 4, y: last.y - 4, width: 8, height: 8)).fill()
                style.nsColor.setStroke(); NSBezierPath(ovalIn: NSRect(x: last.x - 4, y: last.y - 4, width: 8, height: 8)).stroke()
            }
        }
    }
}

final class TrailOverlay {
    private var panel: NSPanel?
    private var drawing: TrailView?
    func update(_ points: [StrokePoint]?, style: TrailStyle = TrailStyle()) {
        guard let points, !points.isEmpty else { panel?.orderOut(nil); return }
        guard let main = NSScreen.screens.first else { return }
        let frame = NSScreen.screens.reduce(main.frame) { $0.union($1.frame) }
        if panel == nil {
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.backgroundColor = .clear; p.isOpaque = false; p.hasShadow = false
            p.ignoresMouseEvents = true; p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let view = TrailView(frame: NSRect(origin: .zero, size: frame.size)); p.contentView = view
            panel = p; drawing = view
        }
        panel?.setFrame(frame, display: false)
        drawing?.style = style
        drawing?.points = points.map { CGPoint(x: $0.x - frame.minX, y: main.frame.maxY - $0.y - frame.minY) }
        drawing?.needsDisplay = true; panel?.orderFrontRegardless()
    }
}

final class TrailView: NSView {
    var points: [CGPoint] = []
    var style = TrailStyle()
    override func draw(_ dirtyRect: NSRect) {
        guard let first = points.first else { return }
        let path = NSBezierPath(); path.move(to: first)
        for point in points.dropFirst() { path.line(to: point) }
        path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.lineWidth = style.width; NSColor.black.withAlphaComponent(0.33).setStroke(); path.stroke()
        path.lineWidth = style.width; style.nsColor.setStroke(); path.stroke()
    }
}

@MainActor
final class RuleNameHUD {
    private var panel: NSPanel?
    private var timer: Timer?
    func show(_ name: String) {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { return }
        let label = NSTextField(labelWithString: name)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white; label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        let width = min(370, max(94, label.intrinsicContentSize.width + 32))
        let height: CGFloat = 38
        let frame = NSRect(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.minY + 52, width: width, height: height)
        let p = panel ?? NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.backgroundColor = .clear; p.isOpaque = false; p.hasShadow = true
        p.ignoresMouseEvents = true; p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let surface = NSView(frame: NSRect(origin: .zero, size: frame.size)); surface.wantsLayer = true
        surface.layer?.backgroundColor = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 0.96).cgColor
        surface.layer?.cornerRadius = 9; surface.layer?.borderWidth = 1
        surface.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        label.frame = NSRect(x: 12, y: (height - label.intrinsicContentSize.height) / 2, width: width - 24, height: label.intrinsicContentSize.height)
        surface.addSubview(label); p.contentView = surface; p.setFrame(frame, display: true)
        panel = p; p.orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.25, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }
    func hide() { timer?.invalidate(); timer = nil; panel?.orderOut(nil) }
}
