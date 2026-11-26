import AppKit
import SwiftUI
import GestureCore

extension AppAppearance {
    var title: String {
        switch self { case .system: return L10n.text("跟随系统"); case .light: return L10n.text("浅色"); case .dark: return L10n.text("深色") }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
}

enum Ink {
    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
    private static func adaptive(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light }
    }
    static let nsBase = adaptive(rgb(0xF8FAFD), rgb(0x16181C))
    static let base = Color(nsColor: nsBase)
    static let sidebar = Color(nsColor: adaptive(rgb(0xEDF1F7), rgb(0x1C1F23)))
    static let border = Color(nsColor: adaptive(rgb(0x20334E, 0.15), rgb(0xFFFFFF, 0.085)))
    static let surface = Color(nsColor: adaptive(rgb(0xFFFFFF, 0.86), rgb(0xFFFFFF, 0.035)))
    static let rowHover = Color(nsColor: adaptive(rgb(0xEAF1FA), rgb(0xFFFFFF, 0.060)))
    static let rowBorderHover = Color(nsColor: adaptive(rgb(0x20334E, 0.25), rgb(0xFFFFFF, 0.13)))
    static let nsAccent = adaptive(rgb(0x285BB4), rgb(0x7AA7FF))
    static let nsAccentText = adaptive(rgb(0x204F9F), rgb(0xA7C3FF))
    static let accent = Color(nsColor: nsAccent)
    static let accentText = Color(nsColor: nsAccentText)
    static let primary = Color(nsColor: adaptive(rgb(0x192638), rgb(0xE6ECF8)))
    static let secondary = Color(nsColor: adaptive(rgb(0x4B5C73), rgb(0xA3ABB8)))
    static let muted = Color(nsColor: adaptive(rgb(0x5E6E84), rgb(0x8995AA)))
    static let nsDanger = adaptive(rgb(0xA82635), rgb(0xFF9999))
    static let danger = Color(nsColor: nsDanger)

    @MainActor static func apply(_ appearance: AppAppearance) {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
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
        setAccessibilityLabel(L10n.text("当前按下的是"))
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
                self.show(event.buttonNumber == 0 ? L10n.text("左键") : Rule.buttonName(event.buttonNumber))
            }
            return event
        }
    }
    private func show(_ title: String) {
        stringValue = L10n.text("当前按下的是：%1$@", "\(title)")
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
    private let label: String
    let physicalOutput: Bool
    let onRecording: (Bool) -> Void
    init(shortcut: Binding<Shortcut?>, physicalOutput: Bool = false, onRecording: @escaping (Bool) -> Void = { _ in }) {
        self.physicalOutput = physicalOutput; _shortcut = shortcut; self.onRecording = onRecording
        // A layout change can change the label without changing the bound physical key.
        label = shortcut.wrappedValue?.display ?? L10n.text("录入")
    }
    func makeNSView(context: Context) -> RecorderButton { RecorderButton() }
    func updateNSView(_ view: RecorderButton, context: Context) {
        view.physicalOutput = physicalOutput
        view.value = shortcut
        view.didRecord = { shortcut = $0 }
        view.recordingChanged = onRecording
        if !view.capturing { view.title = label; view.needsDisplay = true }
    }
    static func dismantleNSView(_ view: RecorderButton, coordinator: ()) { view.stop() }
}

final class RecorderButton: NSButton {
    private static weak var activeRecorder: RecorderButton?
    var value: Shortcut?
    var physicalOutput = false
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
        toolTip = L10n.text("点击后按下新的快捷键；Esc 取消")
        setAccessibilityLabel(L10n.text("录入快捷键"))
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
            .foregroundColor: capturing ? Ink.nsDanger : Ink.nsAccentText, .paragraphStyle: paragraph]
        let height = (title as NSString).size(withAttributes: attributes).height
        (title as NSString).draw(in: NSRect(x: 6, y: bounds.midY - height / 2, width: bounds.width - 12, height: height), withAttributes: attributes)
        if window?.firstResponder === self && window?.isKeyWindow == true {
            color.setStroke(); box.lineWidth = 2; box.stroke()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func beginRecording() {
        if capturing { stop(); return }
        Self.activeRecorder?.stop()
        Self.activeRecorder = self
        diagnostics.record("shortcut.capture_started")
        capturing = true; title = L10n.text("请按键"); setAccessibilityLabel(L10n.text("正在录入快捷键，按 Esc 取消")); needsDisplay = true; recordingChanged?(true)
        var held: [UInt16] = [], peak: [UInt16] = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self, self.capturing else { return event }
            guard let window = self.window, event.window === window else { self.stop(); return event }
            if event.type == .flagsChanged {
                guard self.physicalOutput, let side = Shortcut.sides[event.keyCode] else { return event }
                if UInt64(event.modifierFlags.rawValue) & side.device != 0 {
                    if !held.contains(event.keyCode) { held.append(event.keyCode) }; peak = held
                    self.title = Shortcut(physical: held)?.display ?? ""
                } else {
                    held.removeAll { $0 == event.keyCode }
                    if held.isEmpty, let chord = Shortcut(physical: peak) {
                        self.value = chord; self.didRecord?(chord); self.stop()
                    }
                }
                return nil
            }
            if event.type != .keyDown && event.type != .keyUp {
                if !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.stop() }
                return event
            }
            if event.type == .keyDown {
                let flags = event.modifierFlags.rawValue & UInt(Shortcut.mask)
                if event.keyCode != 53 || flags != 0 {
                    let physical = self.physicalOutput && Shortcut.flags(for: held) & Shortcut.mask == UInt64(flags)
                    let shortcut = (physical ? Shortcut(physical: held, main: event.keyCode) : nil) ?? Shortcut(event.keyCode, UInt64(flags))
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
        if Self.activeRecorder === self { Self.activeRecorder = nil }
        let wasCapturing = capturing; capturing = false; title = value?.display ?? L10n.text("录入"); needsDisplay = true
        if wasCapturing { setAccessibilityLabel(L10n.text("录入快捷键")); recordingChanged?(false) }
    }
    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}

extension TrailStyle {
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    var nsEffectColor: NSColor {
        let tint = self.tint
        return NSColor(srgbRed: tint.red, green: tint.green, blue: tint.blue, alpha: 1)
    }
}

private struct StrokePreview {
    let start: CGPoint
    let line: CGPath
    let arrow: CGPath?

    init?(_ points: [StrokePoint], arrowLength: Double?) {
        guard let first = points.first else { return nil }
        start = CGPoint(x: first.x, y: first.y)
        var visible = points
        if let arrowLength, points.count > 2, let last = points.last, last.distance(to: first) < arrowLength * 0.5 {
            // Leave a small gap between the start dot and the arrow on a closed loop.
            var inset = arrowLength * 0.7
            while visible.count > 1 {
                let end = visible.removeLast()
                let previous = visible[visible.count - 1]
                let length = end.distance(to: previous)
                if length > inset {
                    let fraction = inset / length
                    visible.append(StrokePoint(end.x + (previous.x - end.x) * fraction,
                                               end.y + (previous.y - end.y) * fraction))
                    break
                }
                inset -= length
            }
        }
        let path = CGMutablePath()
        path.move(to: start)
        for point in visible.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
        line = path

        guard let arrowLength, visible.count > 1, let tip = visible.last else { arrow = nil; return }
        let previous = visible.dropLast().last(where: { $0.distance(to: tip) >= arrowLength * 0.75 }) ?? first
        let distance = tip.distance(to: previous)
        guard distance > 0 else { arrow = nil; return }
        let length = min(arrowLength, distance)
        let dx = (tip.x - previous.x) / distance, dy = (tip.y - previous.y) / distance
        let base = CGPoint(x: tip.x - dx * length, y: tip.y - dy * length)
        let spread = length * 0.55
        let head = CGMutablePath()
        head.move(to: CGPoint(x: base.x - dy * spread, y: base.y + dx * spread))
        head.addLine(to: CGPoint(x: tip.x, y: tip.y))
        head.addLine(to: CGPoint(x: base.x + dy * spread, y: base.y - dx * spread))
        arrow = head
    }
}

struct GestureThumbnail: View {
    let points: [StrokePoint]
    var width: CGFloat = 48
    var body: some View {
        Canvas { context, size in
            let fitted = Shape.thumbnail(points, width: size.width, height: size.height, padding: 4, maxWidthToHeightRatio: 2)
            guard let preview = StrokePreview(fitted, arrowLength: 4) else { return }
            let color = GraphicsContext.Shading.color(Ink.accentText)
            let style = StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
            context.stroke(Path(preview.line), with: color, style: style)
            if let arrow = preview.arrow { context.stroke(Path(arrow), with: color, style: style) }
            let start = preview.start
            context.fill(Path(ellipseIn: CGRect(x: start.x - 1.5, y: start.y - 1.5, width: 3, height: 3)), with: color)
        }.frame(width: width, height: 24).accessibilityHidden(true)
    }
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
        setAccessibilityLabel(L10n.text("手势录制区域。按住鼠标绘制轨迹。"))
        setAccessibilityHelp(L10n.text("实心点是起点，箭头是终点。"))
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
        let pitch: CGFloat = 10
        let diameter: CGFloat = 1.25
        let dots = NSBezierPath()
        for x in stride(from: pitch, through: bounds.width - pitch, by: pitch) {
            for y in stride(from: pitch, through: bounds.height - pitch, by: pitch) {
                dots.appendOval(in: NSRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter))
            }
        }
        NSColor.separatorColor.withAlphaComponent(0.38).setFill(); dots.fill()
        let arrowLength = livePoints == nil ? max(9, style.width * 1.2 + 3) : nil
        guard let preview = StrokePreview(displayedPoints, arrowLength: arrowLength),
              let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let color = style.nsColor.cgColor
        context.setStrokeColor(color); context.setFillColor(color)
        context.setLineCap(.round); context.setLineJoin(.round)
        context.setLineWidth(style.width)
        context.addPath(preview.line); context.strokePath()
        if let arrow = preview.arrow {
            context.setLineWidth(min(style.width, 3))
            context.addPath(arrow); context.strokePath()
        }
        let startRadius = max(5, style.width / 2 + 1)
        let start = preview.start
        context.fillEllipse(in: CGRect(x: start.x - startRadius, y: start.y - startRadius,
                                       width: startRadius * 2, height: startRadius * 2))
    }
}

@MainActor
final class TrailOverlay {
    private var panel: NSPanel?
    private var drawing: TrailView?
    private var fadeTimer: Timer?
    private var startedAt: TimeInterval?

    func update(_ points: [StrokePoint], style: TrailStyle) {
        guard points.count > 1 else { return }
        guard let main = NSScreen.screens.first else { return }
        let frame = NSScreen.screens.reduce(main.frame) { $0.union($1.frame) }
        if panel == nil {
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.backgroundColor = .clear; p.isOpaque = false; p.hasShadow = false
            p.sharingType = .none
            p.ignoresMouseEvents = true; p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let view = TrailView(frame: NSRect(origin: .zero, size: frame.size)); p.contentView = view
            panel = p; drawing = view
        }
        if panel?.frame != frame { panel?.setFrame(frame, display: false) }
        let now = ProcessInfo.processInfo.systemUptime
        if fadeTimer != nil || startedAt == nil { startedAt = now }
        fadeTimer?.invalidate()
        fadeTimer = nil
        let phase = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : now - (startedAt ?? now)
        let local = points.map { CGPoint(x: $0.x - frame.minX, y: $0.y - main.frame.maxY + frame.maxY) }
        drawing?.update(local, style: style, phase: phase)
        if panel?.isVisible == false { panel?.orderFrontRegardless() }
    }

    func finish() {
        guard let drawing, panel?.isVisible == true, fadeTimer == nil else { return }
        guard drawing.style.effect != .line, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { hide(); return }
        let began = ProcessInfo.processInfo.systemUptime
        let duration = 0.22
        let timer = Timer(timeInterval: 1 / 30.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.fadeTimer === timer else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                if elapsed >= duration { self.hide(); return }
                self.drawing?.fade(opacity: 1 - elapsed / duration, elapsed: elapsed)
            }
        }
        fadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func hide() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        startedAt = nil
        if let drawing { drawing.update([], style: drawing.style, phase: 0) }
        if panel?.isVisible == true { panel?.orderOut(nil) }
    }
}

final class TrailView: NSView {
    private var points: [CGPoint] = []
    private(set) var style = TrailStyle()
    private var phase = 0.0
    private var fadeElapsed = 0.0
    private var opacity = 1.0
    private var inkBounds = CGRect.null

    override var isFlipped: Bool { true }

    func update(_ points: [CGPoint], style: TrailStyle, phase: Double) {
        let oldBounds = inkBounds
        self.points = points
        self.style = style
        self.phase = phase
        fadeElapsed = 0
        opacity = 1
        inkBounds = TrailRenderer.bounds(points, style: style)
        let dirty = oldBounds.union(inkBounds)
        if !dirty.isNull { setNeedsDisplay(dirty) }
    }

    func fade(opacity: Double, elapsed: Double) {
        self.opacity = opacity
        fadeElapsed = elapsed
        if !inkBounds.isNull { setNeedsDisplay(inkBounds) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        TrailRenderer.draw(points, style: style, phase: phase + fadeElapsed, opacity: opacity, in: context)
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
