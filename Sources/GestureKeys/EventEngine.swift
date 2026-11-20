import AppKit
import ApplicationServices
import GestureCore

final class EventEngine: @unchecked Sendable {
    static let marker: Int64 = 0x474b_4559_535f_3031
    private let lock = NSLock()
    private var configuration = Configuration()
    private var frontmost = ""
    private var frontPID: pid_t = 0
    private var uiSuspended = false
    private var thread: Thread?
    private var loop: CFRunLoop?
    private var tap: CFMachPort?
    private var stopping = false
    private var epoch: UInt64 = 0
    private var runID: UInt64 = 0
    private let actions = DispatchQueue(label: "GestureKeys.actions", qos: .userInteractive)
    // Worker-thread-only state.
    private var swallowedUps = Set<Int>()
    private var stroke: StrokeSession?
    private var strokeButton = 1
    private var strokeApp = ""
    private var strokeEpoch: UInt64 = 0
    private var strokeTrace = ""
    private var secondClick = false
    private struct PendingClick {
        let button: Int, epoch: UInt64, point: StrokePoint, deadline: Double
        let events: [CGEvent], single: Rule?
        let trace: String, app: String
    }
    private var pendingClick: PendingClick?
    private var clickTimer: Timer?
    private var doubleClickInterval = NSEvent.doubleClickInterval
    private var strokeRules: [Rule] = []
    private var buffered: [CGEvent] = []
    private var lastTrailTime = 0.0
    // In-process checks inject sinks; they never create a tap or post real input.
    private var verificationReplay: (([CGEvent]) -> Void)?
    private var verificationActions: [UUID]?

    var onStatus: ((Bool, String?) -> Void)?
    var onAction: ((Rule) -> Void)?
    var onActionError: ((Rule, String) -> Void)?
    var onTrail: (([StrokePoint]?) -> Void)?

    func update(_ config: Configuration, frontmost: String, suspended: Bool, pid: pid_t = 0) {
        lock.lock(); defer { lock.unlock() }
        if self.frontmost != frontmost || frontPID != pid || uiSuspended != suspended || configuration.rules != config.rules { epoch &+= 1 }
        configuration = config; self.frontmost = frontmost; frontPID = pid; uiSuspended = suspended
    }
    func press(_ shortcut: Shortcut) {
        let (config, app, suspended, stopping) = snapshot()
        let trace = UUID().uuidString
        let facts = ["trace": trace, "app": app, "shortcut": shortcut.display]
        diagnostics.record("hotkey.received", facts)
        guard !suspended, !stopping else { diagnostics.record("input.skipped", facts.merging(["reason": "monitor_unavailable"]) { _, new in new }); return }
        guard let rule = RuleResolver.scoped(config.rules, bundleID: app).first(where: { $0.kind == .keyboard && $0.triggerKey == shortcut }) else {
            diagnostics.record("input.no_rule", facts); return
        }
        execute(rule, trace: trace, app: app)
    }
    private func snapshot() -> (Configuration, String, Bool, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (configuration, frontmost, uiSuspended, stopping)
    }
    func start() {
        let interval = NSEvent.doubleClickInterval
        lock.lock()
        guard thread == nil else { lock.unlock(); return }
        stopping = false; epoch &+= 1; runID &+= 1; doubleClickInterval = interval
        let t = Thread { [self] in run() }
        t.name = "GestureKeys.input"; t.qualityOfService = .userInteractive
        thread = t; lock.unlock()
        diagnostics.record("tap.starting")
        t.start()
    }
    func stop() {
        lock.lock(); stopping = true; let currentLoop = loop; lock.unlock()
        if let currentLoop {
            CFRunLoopPerformBlock(currentLoop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(currentLoop) }
            CFRunLoopWakeUp(currentLoop)
        }
    }
    private func status(_ running: Bool, _ message: String? = nil) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(running, message) }
    }
    private func run() {
        let mask = [CGEventType.rightMouseDown, .rightMouseUp, .rightMouseDragged,
                    .otherMouseDown, .otherMouseUp, .otherMouseDragged, .leftMouseDown]
            .reduce(UInt64(0)) { $0 | (UInt64(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { proxy, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<EventEngine>.fromOpaque(context).takeUnretainedValue().handle(proxy, type, event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                  options: .defaultTap, eventsOfInterest: mask, callback: callback,
                  userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            lock.lock(); thread = nil; lock.unlock()
            diagnostics.record("tap.start_failed")
            status(false, L10n.text("无法监听输入。请授予辅助功能和输入监控权限，然后重试。"))
            return
        }
        let runLoop = CFRunLoopGetCurrent()!
        lock.lock(); tap = port; loop = runLoop; let shouldStop = stopping; lock.unlock()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        if !shouldStop {
            diagnostics.record("tap.started")
            status(true)
            CFRunLoopRun()
        }
        CGEvent.tapEnable(tap: port, enable: false)
        // Releasing a pending intercepted press prevents a stuck button in downstream apps.
        resolvePendingClick(replayOnly: true)
        flushPending()
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFMachPortInvalidate(port)
        swallowedUps.removeAll()
        lock.lock(); tap = nil; loop = nil; thread = nil; lock.unlock()
        diagnostics.record("tap.stopped")
        status(false)
    }
    private func hideTrail() {
        DispatchQueue.main.async { [weak self] in self?.onTrail?(nil) }
    }
    private func resetStroke() {
        stroke = nil; secondClick = false; buffered.removeAll(keepingCapacity: true); strokeRules.removeAll(keepingCapacity: true)
        hideTrail()
    }
    private func replay(_ events: [CGEvent], proxy: CGEventTapProxy? = nil) {
        if let verificationReplay { verificationReplay(events); return }
        for event in events {
            event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
            if let proxy { event.tapPostEvent(proxy) }
            else { event.post(tap: .cgSessionEventTap) }
        }
    }
    private func flushPending() {
        guard stroke != nil else { return }
        let sameContext = executionToken().0 == strokeEpoch
        diagnostics.record("mouse.cancelled", ["trace": strokeTrace, "reason": "tap_flush", "replayed": String(sameContext)])
        if sameContext { replay(buffered) }
        resetStroke()
    }
    private func executionToken() -> (UInt64, pid_t, Bool) {
        lock.lock(); defer { lock.unlock() }
        return (epoch, frontPID, stopping || uiSuspended)
    }
    private func currentRunID() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        return stopping ? nil : runID
    }
    private func armClickTimer() {
        clickTimer?.invalidate()
        guard verificationActions == nil else { return }
        let timer = Timer(timeInterval: doubleClickInterval, repeats: false) { [weak self] _ in self?.resolvePendingClick() }
        clickTimer = timer; RunLoop.current.add(timer, forMode: .common)
    }
    private func resolvePendingClick(proxy: CGEventTapProxy? = nil, replayOnly: Bool = false) {
        clickTimer?.invalidate(); clickTimer = nil
        guard let pending = pendingClick else { return }
        pendingClick = nil
        let current = executionToken()
        if replayOnly {
            let sameContext = current.0 == pending.epoch
            diagnostics.record("mouse.cancelled", ["trace": pending.trace, "reason": "tap_flush", "replayed": String(sameContext)])
            if sameContext { replay(pending.events, proxy: proxy) }
        } else if current.0 == pending.epoch && !current.2 {
            if let single = pending.single { execute(single, trace: pending.trace, app: pending.app) }
            else {
                diagnostics.record("mouse.no_match", ["trace": pending.trace, "reason": "no_second_click", "replayed": "true"])
                replay(pending.events, proxy: proxy)
            }
        } else { diagnostics.record("mouse.cancelled", ["trace": pending.trace, "reason": "context_changed", "replayed": "false"]) }
    }
    private func execute(_ rule: Rule, trace: String, app: String) {
        let facts = diagnosticRule(rule).merging(["trace": trace, "app": app]) { _, new in new }
        diagnostics.record("input.matched", facts)
        if verificationActions != nil { verificationActions?.append(rule.id); return }
        let token = executionToken()
        let stillCurrent: () -> Bool = { [weak self] in
            guard let self else { return false }
            let current = self.executionToken()
            return !current.2 && current.0 == token.0 && current.1 == token.1
        }
        actions.async { [weak self] in
            guard let self else { return }
            guard stillCurrent() else { diagnostics.record("action.cancelled", facts.merging(["reason": "context_changed"]) { _, new in new }); return }
            DispatchQueue.main.async { [weak self] in self?.onAction?(rule) }
            if rule.action == .block { diagnostics.record("action.blocked_by_rule", facts); return }
            if let target = rule.action == .openApplication ? rule.appPath : rule.action.systemAppPath {
                let url = URL(fileURLWithPath: target)
                let name = url.deletingPathExtension().lastPathComponent
                guard let run = self.currentRunID() else { return }
                DispatchQueue.main.async {
                    guard stillCurrent() else { diagnostics.record("action.cancelled", facts.merging(["reason": "context_changed"]) { _, new in new }); return }
                    let failure: (String) -> Void = { detail in
                        guard self.currentRunID() == run else { return }
                        self.onActionError?(rule, detail)
                    }
                    guard FileManager.default.fileExists(atPath: target) else {
                        diagnostics.record("action.open_failed", facts.merging(["reason": "application_not_found"]) { _, new in new })
                        failure(L10n.text("找不到应用「%1$@」", "\(name)"))
                        return
                    }
                    diagnostics.record("action.open_requested", facts)
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { application, error in
                        if let error {
                            diagnostics.record("action.open_failed", facts.merging(diagnosticError(error)) { _, new in new })
                            DispatchQueue.main.async { failure(L10n.text("无法打开「%1$@」：%2$@", "\(name)", "\(error.localizedDescription)")) }
                        } else if let application {
                            diagnostics.record("action.open_confirmed", facts.merging(["target_bundle": application.bundleIdentifier ?? ""]) { _, new in new })
                        } else { diagnostics.record("action.open_unconfirmed", facts) }
                    }
                }
            } else {
                let shortcut = rule.action == .shortcut ? rule.outputKey : rule.action.standardShortcut
                guard let shortcut else { diagnostics.record("action.shortcut_missing", facts); return }
                let source = CGEventSource(stateID: .privateState)
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: false) else {
                    diagnostics.record("action.shortcut_failed", facts.merging(["reason": "event_creation_failed"]) { _, new in new }); return
                }
                let targeted = token.1 > 0 && !rule.action.isSystemShortcut
                for event in [down, up] {
                    event.flags = CGEventFlags(rawValue: shortcut.modifiers)
                    event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
                    if targeted { event.postToPid(token.1) }
                    else { event.post(tap: .cghidEventTap) }
                }
                diagnostics.record("action.shortcut_posted", facts.merging(["shortcut": shortcut.display, "route": targeted ? "pid" : "system", "pid": String(token.1)]) { _, new in new })
            }
        }
    }
    private func handle(_ proxy: CGEventTapProxy?, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            resolvePendingClick(replayOnly: true)
            flushPending()
            let reason = type == .tapDisabledByTimeout ? "timeout" : "system_request"
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            let enabled = tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
            diagnostics.record("tap.recovery", ["reason": reason, "enabled": String(enabled)])
            if !enabled { CFRunLoopStop(CFRunLoopGetCurrent()) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return Unmanaged.passUnretained(event) }
        let (config, app, suspended, stopping) = snapshot()
        let isUp = type == .rightMouseUp || type == .otherMouseUp
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        if isUp && swallowedUps.remove(button) != nil { return nil }
        if stopping { return Unmanaged.passUnretained(event) }
        if suspended {
            resolvePendingClick()
            if stroke != nil {
                let finishesCapturedButton = isUp && button == strokeButton
                if !finishesCapturedButton { swallowedUps.insert(strokeButton) }
                diagnostics.record("mouse.cancelled", ["trace": strokeTrace, "reason": "editor_focused", "replayed": "false"])
                resetStroke()
                if finishesCapturedButton { return nil }
            }
            return Unmanaged.passUnretained(event)
        }
        let isDown = type == .rightMouseDown || type == .otherMouseDown
        let isDrag = type == .rightMouseDragged || type == .otherMouseDragged
        let point = StrokePoint(event.location.x, event.location.y)
        let time = ProcessInfo.processInfo.systemUptime
        let eventEpoch = executionToken().0
        if pendingClick != nil && (pendingClick?.epoch != eventEpoch || type == .leftMouseDown) {
            resolvePendingClick(proxy: proxy)
        }
        if stroke != nil && (app != strokeApp || strokeEpoch != eventEpoch) {
            // Nothing was delivered to the old target: do not replay a press into a different app.
            let finishesCapturedButton = isUp && button == strokeButton
            if !finishesCapturedButton { swallowedUps.insert(strokeButton) }
            diagnostics.record("mouse.cancelled", ["trace": strokeTrace, "reason": "context_changed", "replayed": "false"])
            resetStroke()
            if finishesCapturedButton { return nil }
        }
        if stroke != nil && ((isDown && button != strokeButton) || type == .leftMouseDown) {
            resolvePendingClick(proxy: proxy)
            diagnostics.record("mouse.cancelled", ["trace": strokeTrace, "reason": "overlapping_button", "replayed": "true"])
            replay(buffered, proxy: proxy); resetStroke()
        }
        if isDown {
            let candidates = RuleResolver.scoped(config.rules, bundleID: app).filter { $0.kind != .keyboard && $0.mouseButton == button }
            let doubleEnabled = candidates.contains { $0.kind == .click && $0.clickCount == 2 }
            if let pending = pendingClick {
                secondClick = doubleEnabled && pending.button == button && pending.deadline >= time && pending.point.distance(to: point) <= 8
                if secondClick { armClickTimer() }
                else { resolvePendingClick(proxy: proxy) }
            }
            let trace = UUID().uuidString
            diagnostics.record("mouse.received", ["trace": trace, "app": app, "button": Rule.buttonName(button), "candidates": String(candidates.count)])
            guard !candidates.isEmpty else { diagnostics.record("input.no_rule", ["trace": trace]); return Unmanaged.passUnretained(event) }
            strokeTrace = trace
            strokeButton = button; strokeApp = app; strokeEpoch = eventEpoch; strokeRules = candidates
            stroke = StrokeSession(start: point, time: time)
            buffered = event.copy().map { [$0] } ?? []
            return nil
        }
        if (isDrag || isUp), button == strokeButton, stroke != nil {
            if let copy = event.copy() { buffered.append(copy) }
            guard buffered.count <= 4096, stroke!.append(point, time: time) else {
                diagnostics.record("mouse.cancelled", ["trace": strokeTrace, "reason": "stroke_limit", "replayed": "true"])
                resolvePendingClick(proxy: proxy)
                replay(buffered, proxy: proxy); resetStroke()
                return nil
            }
            if secondClick && stroke!.isDrag { resolvePendingClick(proxy: proxy); secondClick = false }
            if config.showTrail && stroke!.isDrag && time - lastTrailTime > 1.0 / 30 {
                lastTrailTime = time
                let path = stroke!.points
                DispatchQueue.main.async { [weak self] in self?.onTrail?(path) }
            }
            if isUp {
                let current = stroke!
                var matched: Rule?
                var missReason = "no_click_rule"
                if current.isDrag {
                    let candidates = strokeRules.filter { $0.kind == .gesture }
                    switch Shape.recognize(current.points, rules: candidates) {
                    case .matched(let id, let distance):
                        matched = candidates.first { $0.id == id }
                        diagnostics.record("gesture.recognized", ["trace": strokeTrace, "distance": String(distance), "candidates": String(candidates.count)])
                    case .ambiguous: missReason = "ambiguous_gesture"
                    case .noMatch: missReason = candidates.isEmpty ? "no_gesture_rule" : "no_matching_shape"
                    }
                } else {
                    let single = strokeRules.first { $0.kind == .click && $0.clickCount == 1 }
                    if let double = strokeRules.first(where: { $0.kind == .click && $0.clickCount == 2 }) {
                        if secondClick, pendingClick != nil {
                            if let pending = pendingClick { diagnostics.record("mouse.double_click", ["trace": strokeTrace, "first_click": pending.trace]) }
                            clickTimer?.invalidate(); clickTimer = nil; pendingClick = nil; matched = double
                        } else {
                            pendingClick = PendingClick(button: button, epoch: eventEpoch, point: point,
                                deadline: time + doubleClickInterval, events: buffered, single: single, trace: strokeTrace, app: app)
                            diagnostics.record("mouse.awaiting_double_click", ["trace": strokeTrace])
                            armClickTimer()
                            resetStroke(); return nil
                        }
                    } else { matched = single }
                }
                if let matched { execute(matched, trace: strokeTrace, app: app) }
                else {
                    diagnostics.record("mouse.no_match", ["trace": strokeTrace, "reason": missReason, "replayed": "true"])
                    replay(buffered, proxy: proxy)
                }
                resetStroke()
            }
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    static func runInputChecks() throws -> Int {
        var replayed = 0
        var checks = 0
        func engine(_ rules: [Rule]) -> EventEngine {
            let e = EventEngine(); var config = Configuration(rules: rules); config.showTrail = false
            e.update(config, frontmost: "test.browser", suspended: false)
            e.verificationActions = []; e.verificationReplay = { replayed += $0.count }
            return e
        }
        func require(_ condition: Bool, _ name: String) throws {
            if !condition { throw ConfigError.invalid(L10n.text("输入状态机检查失败：%1$@", "\(name)")) }
            checks += 1
        }
        func mouse(_ e: EventEngine, _ type: CGEventType, _ x: Double, _ y: Double,
                   button: Int = 1, flags: UInt64 = 0) -> Bool {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y),
                                mouseButton: CGMouseButton(rawValue: UInt32(button))!)!
            event.flags = CGEventFlags(rawValue: flags)
            return e.handle(nil, type, event) == nil
        }
        let hotkey = Rule(key: Shortcut(18, 0x40000), action: .pageBack)
        let h = engine([hotkey])
        h.press(Shortcut(18, 0x40000)); h.press(Shortcut(19, 0x40000))
        try require(h.verificationActions == [hotkey.id], "系统热键分发仅执行已绑定规则")
        h.update(Configuration(rules: [hotkey]), frontmost: "test.browser", suspended: true)
        h.press(Shortcut(18, 0x40000))
        try require(h.verificationActions == [hotkey.id], "设置时不执行热键")

        let diagonal = Rule(kind: .gesture, points: Shape.preset(.upRight), shapeName: "↗", action: .closeTab)
        let d = engine([diagonal])
        try require(mouse(d, .rightMouseDown, 0, 100), "手势按下")
        _ = mouse(d, .rightMouseDragged, 50, 50)
        try require(mouse(d, .rightMouseUp, 100, 0) && d.verificationActions == [diagonal.id], "斜线命中")
        replayed = 0
        let miss = engine([diagonal])
        _ = mouse(miss, .rightMouseDown, 100, 50); _ = mouse(miss, .rightMouseDragged, 50, 50)
        _ = mouse(miss, .rightMouseUp, 0, 50)
        try require(miss.verificationActions!.isEmpty && replayed == 3, "未匹配完整回放")

        let click = Rule(kind: .click, action: .missionControl)
        let mixed = engine([diagonal, click])
        _ = mouse(mixed, .rightMouseDown, 1, 1); _ = mouse(mixed, .rightMouseUp, 2, 1)
        try require(mixed.verificationActions == [click.id], "点击与手势分流")
        let shifted = engine([click])
        _ = mouse(shifted, .rightMouseDown, 0, 0, flags: 0x20000)
        _ = mouse(shifted, .rightMouseUp, 0, 0, flags: 0x20000)
        try require(shifted.verificationActions == [click.id], "鼠标规则不依赖 Shift")

        let switched = engine([diagonal]); replayed = 0
        _ = mouse(switched, .rightMouseDown, 0, 100)
        switched.update(Configuration(rules: [diagonal]), frontmost: "test.other", suspended: false)
        _ = mouse(switched, .rightMouseUp, 100, 0)
        try require(switched.verificationActions!.isEmpty && replayed == 0, "切换应用不误操作新应用")

        let timeout = engine([diagonal]); replayed = 0
        _ = mouse(timeout, .rightMouseDown, 0, 100)
        _ = timeout.handle(nil, .tapDisabledByTimeout, CGEvent(source: nil)!)
        try require(timeout.stroke == nil && replayed == 1, "超时清理并恢复原始按下")

        let injected = engine([click])
        let marked = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: .zero, mouseButton: .right)!
        marked.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        try require(injected.handle(nil, .rightMouseDown, marked) != nil && injected.stroke == nil, "回放事件不循环")

        var double = Rule(kind: .click, action: .showDesktop); double.clickCount = 2
        let both = engine([click, double]); replayed = 0
        _ = mouse(both, .rightMouseDown, 4, 5); _ = mouse(both, .rightMouseUp, 4, 5)
        try require(both.verificationActions!.isEmpty && both.pendingClick != nil, "有双击规则时等待第二击")
        _ = mouse(both, .rightMouseDown, 5, 6); _ = mouse(both, .rightMouseUp, 5, 6)
        try require(both.verificationActions == [double.id] && both.pendingClick == nil && replayed == 0, "双击只执行双击动作")
        _ = mouse(both, .rightMouseDown, 4, 5); _ = mouse(both, .rightMouseUp, 4, 5)
        both.resolvePendingClick()
        try require(both.verificationActions == [double.id, click.id], "窗口到期执行单击")
        let doublesOnly = engine([double]); replayed = 0
        _ = mouse(doublesOnly, .rightMouseDown, 4, 5); _ = mouse(doublesOnly, .rightMouseUp, 4, 5)
        doublesOnly.resolvePendingClick()
        try require(replayed == 2 && doublesOnly.verificationActions!.isEmpty, "仅绑定双击时回放普通单击")
        let other = engine([click, double]); replayed = 0
        _ = mouse(other, .rightMouseDown, 4, 5); _ = mouse(other, .rightMouseUp, 4, 5)
        other.update(Configuration(rules: [click, double]), frontmost: "test.other", suspended: false)
        other.resolvePendingClick()
        try require(replayed == 0 && other.verificationActions!.isEmpty, "切换前台后不派发旧单击")

        let sideRule = Rule(kind: .click, button: 4, output: Shortcut(8, 0x100000))
        let side = engine([sideRule])
        _ = mouse(side, .otherMouseDown, 0, 0, button: 4); _ = mouse(side, .otherMouseUp, 0, 0, button: 4)
        try require(side.verificationActions == [sideRule.id], "第五键点击")
        return checks
    }
}
