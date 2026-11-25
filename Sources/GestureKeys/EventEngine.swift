import AppKit
import ApplicationServices
import GestureCore

enum MonitorIssue: String, Sendable {
    case conflictingRules = "存在重复触发规则，请修改或停用其中一条。"
    case missingPermissions = "缺少输入权限，请在「通用」中授权。"
    case cannotListen = "无法监听输入。请授予辅助功能和输入监控权限，然后重试。"
}

enum ActionFailure: Sendable {
    case missingApplication(String)
    case cannotOpen(String, String)
    case wouldRetriggerHotkey

    var message: String {
        switch self {
        case .missingApplication(let name): return L10n.text("找不到应用「%1$@」", name)
        case .cannotOpen(let name, let detail): return L10n.text("无法打开「%1$@」：%2$@", name, detail)
        case .wouldRetriggerHotkey: return L10n.text("此系统快捷键也是触发键，请改用不同的组合键。")
        }
    }
}

final class EventEngine: @unchecked Sendable {
    static let marker: Int64 = 0x474b_4559_535f_3031
    private let lock = NSLock()
    private var configuration = Configuration()
    /// Capture this under the same lock as the rules. An action must never acquire a new target.
    private struct Target: Equatable {
        var app = "", pid: pid_t = 0, epoch: UInt64 = 0
    }
    private var target = Target()
    private var uiSuspended = false
    private var thread: Thread?
    private var loop: CFRunLoop?
    private var tap: CFMachPort?
    private var stopping = false
    private var runID: UInt64 = 0
    private let actions = DispatchQueue(label: "GestureKeys.actions", qos: .userInteractive)
    // Worker-thread-only state.
    private var discardUntilUp = Set<Int>()
    private var stroke: StrokeSession?
    private var strokeButton = 1
    private var strokeTarget = Target()
    private var strokeTrace = ""
    private var secondClick = false
    private struct PendingClick {
        let button: Int, target: Target, point: StrokePoint, releasedAt: TimeInterval
        let events: [CGEvent], single: Rule?
        let trace: String
    }
    private var pendingClick: PendingClick?
    private var clickTimer: Timer?
    private var doubleClickInterval = NSEvent.doubleClickInterval
    private var strokeRules: [Rule] = []
    private var canMatchGesture = false
    private var buffered: [CGEvent] = []
    private var lastTrailTime = 0.0
    // In-process checks inject sinks; they never create a tap or post real input.
    private var verificationReplay: (([CGEvent]) -> Void)?
    private var verificationActions: [UUID]?

    private let foregroundPID: () -> pid_t?
    private let postKey: (CGEvent, pid_t?) -> Void
    init(foregroundPID: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
         postKey: @escaping (CGEvent, pid_t?) -> Void = { event, pid in
             if let pid { event.postToPid(pid) } else { event.post(tap: .cghidEventTap) }
         }) { self.foregroundPID = foregroundPID; self.postKey = postKey }

    var onStatus: ((Bool, MonitorIssue?) -> Void)?
    var onAction: ((Rule) -> Void)?
    var onActionError: ((Rule, ActionFailure) -> Void)?
    var onTrail: (([StrokePoint]?) -> Void)?

    func update(_ config: Configuration, frontmost: String, suspended: Bool, pid: pid_t = 0) {
        lock.lock(); defer { lock.unlock() }
        if target.app != frontmost || target.pid != pid || uiSuspended != suspended || configuration.rules != config.rules { target.epoch &+= 1 }
        configuration = config; target.app = frontmost; target.pid = pid; uiSuspended = suspended
    }
    func press(_ shortcut: Shortcut) {
        let (config, target, suspended, stopping) = snapshot()
        let app = target.app, trace = UUID().uuidString
        let facts = ["trace": trace, "app": app, "shortcut": shortcut.display]
        diagnostics.record("hotkey.received", facts)
        guard !suspended, !stopping else { diagnostics.record("input.skipped", facts.merging(["reason": "monitor_unavailable"]) { _, new in new }); return }
        guard let rule = RuleResolver.scoped(config.rules, bundleID: app).first(where: { $0.kind == .keyboard && $0.triggerKey == shortcut }) else {
            diagnostics.record("input.no_rule", facts); return
        }
        execute(rule, trace: trace, target: target)
    }
    private func snapshot() -> (config: Configuration, target: Target, suspended: Bool, stopping: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (configuration, target, uiSuspended, stopping)
    }
    private func isCurrent(_ expected: Target) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopping && !uiSuspended && target == expected
    }
    func start() {
        let interval = NSEvent.doubleClickInterval
        lock.lock()
        guard thread == nil else { lock.unlock(); return }
        stopping = false; target.epoch &+= 1; runID &+= 1; doubleClickInterval = interval
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
    private func status(_ running: Bool, _ issue: MonitorIssue? = nil) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(running, issue) }
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
            status(false, .cannotListen)
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
        // Submit any buffered down before disabling the tap and allowing new physical ups through.
        resolvePendingClick(replayOnly: true)
        releaseStroke("tap_flush")
        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFMachPortInvalidate(port)
        discardUntilUp.removeAll()
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
    /// Hand a complete prefix back to the same context. A new target must not see a drag or an up without a down.
    private func releaseStroke(_ reason: String, proxy: CGEventTapProxy? = nil, finished: Bool = false, log: String = "mouse.cancelled") {
        guard stroke != nil else { return }
        let sameContext = snapshot().target == strokeTarget
        diagnostics.record(log, ["trace": strokeTrace, "reason": reason, "replayed": String(sameContext)])
        if sameContext { replay(buffered, proxy: proxy) }
        else if !finished { discardUntilUp.insert(strokeButton) }
        resetStroke()
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
        if replayOnly {
            let sameContext = snapshot().target == pending.target
            diagnostics.record("mouse.cancelled", ["trace": pending.trace, "reason": "tap_flush", "replayed": String(sameContext)])
            if sameContext { replay(pending.events, proxy: proxy) }
        } else if isCurrent(pending.target) {
            if let single = pending.single { execute(single, trace: pending.trace, target: pending.target) }
            else {
                diagnostics.record("mouse.no_match", ["trace": pending.trace, "reason": "no_second_click", "replayed": "true"])
                replay(pending.events, proxy: proxy)
            }
        } else { diagnostics.record("mouse.cancelled", ["trace": pending.trace, "reason": "context_changed", "replayed": "false"]) }
    }
    static func shortcutFlags(_ shortcut: Shortcut, system: Bool) -> CGEventFlags {
        var flags = CGEventFlags(rawValue: shortcut.modifiers)
        // System hotkeys see an arrow as a navigation key, unlike app-local key handlers.
        if system && (123...126).contains(shortcut.keyCode) { flags.formUnion([.maskSecondaryFn, .maskNumericPad]) }
        return flags
    }
    private func execute(_ rule: Rule, trace: String, target: Target) {
        let facts = diagnosticRule(rule).merging(["trace": trace, "app": target.app]) { _, new in new }
        diagnostics.record("input.matched", facts)
        // Activation notifications may still be queued. Before posting/opening, also check the live PID;
        // it is a veto only, never a replacement destination.
        func canExecute(confirmForeground: Bool = false) -> Bool {
            guard (!confirmForeground || (target.pid > 0 && foregroundPID() == target.pid)), isCurrent(target) else {
                diagnostics.record("action.cancelled", facts.merging(["reason": "context_changed"]) { _, new in new }); return false
            }
            return true
        }
        guard canExecute() else { return }
        if verificationActions != nil { verificationActions?.append(rule.id); return }
        actions.async { [weak self] in
            guard let self else { return }
            guard canExecute() else { return }
            if rule.action == .block {
                diagnostics.record("action.blocked_by_rule", facts)
                DispatchQueue.main.async { [weak self] in self?.onAction?(rule) }; return
            }
            let appPath = rule.action == .openApplication ? rule.appPath : rule.action.systemAppPath
            let destination = appPath.map { URL(fileURLWithPath: $0) } ?? rule.locationToOpen
            if let url = destination {
                guard let run = self.currentRunID() else { return }
                let name = appPath != nil ? url.deletingPathExtension().lastPathComponent : rule.actionDescription
                DispatchQueue.main.async {
                    guard canExecute(confirmForeground: true) else { return }
                    self.onAction?(rule)
                    let failure: (ActionFailure) -> Void = { detail in
                        guard self.currentRunID() == run else { return }
                        self.onActionError?(rule, detail)
                    }
                    if appPath != nil && !FileManager.default.fileExists(atPath: url.path) {
                        diagnostics.record("action.open_failed", facts.merging(["reason": "application_not_found"]) { _, new in new })
                        failure(.missingApplication(name)); return
                    }
                    let workspace = NSWorkspace.shared
                    let options = NSWorkspace.OpenConfiguration()
                    diagnostics.record("action.open_requested", facts)
                    let completed: (NSRunningApplication?, Error?) -> Void = { application, error in
                        if let error {
                            diagnostics.record("action.open_failed", facts.merging(diagnosticError(error)) { _, new in new })
                            DispatchQueue.main.async { failure(.cannotOpen(name, error.localizedDescription)) }
                        } else if let application {
                            diagnostics.record("action.open_confirmed", facts.merging(["target_bundle": application.bundleIdentifier ?? ""]) { _, new in new })
                        } else {
                            diagnostics.record("action.open_unconfirmed", facts)
                        }
                    }
                    if appPath != nil { workspace.openApplication(at: url, configuration: options, completionHandler: completed) }
                    else { workspace.open(url, configuration: options, completionHandler: completed) }
                }
            } else {
                guard let shortcut = rule.shortcutToSend else { diagnostics.record("action.shortcut_missing", facts); return }
                // A user-defined shortcut travels the normal keyboard route, including system hotkeys.
                let targeted = !rule.action.isSystemShortcut
                if !targeted {
                    let config = self.snapshot().config
                    if RuleResolver.scoped(config.rules, bundleID: target.app).contains(where: { $0.kind == .keyboard && $0.triggerKey == shortcut }) {
                        diagnostics.record("action.shortcut_failed", facts.merging(["reason": "would_retrigger_hotkey"]) { _, new in new })
                        DispatchQueue.main.async { [weak self] in
                            self?.onActionError?(rule, .wouldRetriggerHotkey)
                        }
                        return
                    }
                }
                let source = CGEventSource(stateID: .privateState)
                guard let down = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: true),
                      let up = CGEvent(keyboardEventSource: source, virtualKey: shortcut.keyCode, keyDown: false) else {
                    diagnostics.record("action.shortcut_failed", facts.merging(["reason": "event_creation_failed"]) { _, new in new }); return
                }
                let flags = Self.shortcutFlags(shortcut, system: !targeted)
                guard canExecute(confirmForeground: true) else { return }
                for event in [down, up] {
                    event.flags = flags
                    event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
                    self.postKey(event, targeted ? target.pid : nil)
                }
                DispatchQueue.main.async { [weak self] in self?.onAction?(rule) }
                diagnostics.record("action.shortcut_posted", facts.merging(["shortcut": shortcut.display, "route": targeted ? "pid" : "system", "pid": String(target.pid), "event_flags": String(flags.rawValue, radix: 16)]) { _, new in new })
            }
        }
    }
    private func handle(_ proxy: CGEventTapProxy?, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            resolvePendingClick(replayOnly: true)
            releaseStroke("tap_flush", proxy: proxy)
            let reason = type == .tapDisabledByTimeout ? "timeout" : "system_request"
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            let enabled = tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false
            diagnostics.record("tap.recovery", ["reason": reason, "enabled": String(enabled)])
            if !enabled { CFRunLoopStop(CFRunLoopGetCurrent()) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return Unmanaged.passUnretained(event) }
        let (config, target, suspended, stopping) = snapshot()
        let app = target.app, button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        let isDown = type == .rightMouseDown || type == .otherMouseDown
        let isUp = type == .rightMouseUp || type == .otherMouseUp
        let isDrag = type == .rightMouseDragged || type == .otherMouseDragged
        if let pending = pendingClick, stopping || suspended || pending.target != target || type == .leftMouseDown {
            resolvePendingClick(proxy: proxy, replayOnly: stopping)
        }
        if stroke != nil && (stopping || suspended || target != strokeTarget) {
            // On stop, post the intercepted down through the proxy *before* passing its physical up.
            releaseStroke(stopping ? "tap_flush" : suspended ? "editor_focused" : "context_changed", proxy: proxy)
        }
        if isDown { discardUntilUp.remove(button) }
        if isUp && discardUntilUp.remove(button) != nil { return nil }
        if isDrag && discardUntilUp.contains(button) { return nil }
        if stopping || suspended { return Unmanaged.passUnretained(event) }
        let point = StrokePoint(event.location.x, event.location.y)
        let time = event.timestamp == 0 ? ProcessInfo.processInfo.systemUptime : TimeInterval(event.timestamp) / 1_000_000_000
        if stroke != nil && ((isDown && button != strokeButton) || type == .leftMouseDown) {
            resolvePendingClick(proxy: proxy)
            releaseStroke("overlapping_button", proxy: proxy)
        }
        if isDown {
            let candidates = RuleResolver.scoped(config.rules, bundleID: app).filter { $0.kind != .keyboard && $0.mouseButton == button }
            let doubleEnabled = candidates.contains { $0.kind == .click && $0.clickCount == 2 }
            if let pending = pendingClick {
                let gap = time - pending.releasedAt
                secondClick = doubleEnabled && pending.button == button && (0...doubleClickInterval).contains(gap) && pending.point.distance(to: point) <= 8
                if secondClick { armClickTimer() }
                else { resolvePendingClick(proxy: proxy) }
            }
            let trace = UUID().uuidString
            diagnostics.record("mouse.received", ["trace": trace, "app": app, "button": Rule.buttonName(button), "candidates": String(candidates.count)])
            guard !candidates.isEmpty else { diagnostics.record("input.no_rule", ["trace": trace]); return Unmanaged.passUnretained(event) }
            strokeTrace = trace
            strokeButton = button; strokeTarget = target; strokeRules = candidates
            canMatchGesture = candidates.contains { $0.kind == .gesture }
            stroke = StrokeSession(start: point, time: time)
            buffered = event.copy().map { [$0] } ?? []
            return nil
        }
        if (isDrag || isUp), button == strokeButton, stroke != nil {
            if let copy = event.copy() { buffered.append(copy) }
            guard buffered.count <= 4096, stroke!.append(point, time: time) else {
                resolvePendingClick(proxy: proxy)
                releaseStroke("stroke_limit", proxy: proxy, finished: isUp)
                return nil
            }
            if secondClick && stroke!.isDrag { resolvePendingClick(proxy: proxy); secondClick = false }
            if stroke!.isDrag && !canMatchGesture {
                releaseStroke("no_gesture_rule", proxy: proxy, finished: isUp, log: "mouse.no_match")
                return nil
            }
            let now = ProcessInfo.processInfo.systemUptime
            if config.showTrail && stroke!.isDrag && now - lastTrailTime > 1.0 / 30 {
                lastTrailTime = now
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
                    case .noMatch: missReason = "no_matching_shape"
                    }
                } else {
                    let single = strokeRules.first { $0.kind == .click && $0.clickCount == 1 }
                    if let double = strokeRules.first(where: { $0.kind == .click && $0.clickCount == 2 }) {
                        if secondClick, pendingClick != nil {
                            if let pending = pendingClick { diagnostics.record("mouse.double_click", ["trace": strokeTrace, "first_click": pending.trace]) }
                            clickTimer?.invalidate(); clickTimer = nil; pendingClick = nil; matched = double
                        } else {
                            pendingClick = PendingClick(button: button, target: strokeTarget, point: point,
                                releasedAt: time, events: buffered, single: single, trace: strokeTrace)
                            diagnostics.record("mouse.awaiting_double_click", ["trace": strokeTrace])
                            armClickTimer()
                            resetStroke(); return nil
                        }
                    } else { matched = single }
                }
                if let matched { execute(matched, trace: strokeTrace, target: strokeTarget); resetStroke() }
                else { releaseStroke(missReason, proxy: proxy, finished: true, log: "mouse.no_match") }
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
                   button: Int = 1, flags: UInt64 = 0, time: TimeInterval? = nil) -> Bool {
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y),
                                mouseButton: CGMouseButton(rawValue: UInt32(button))!)!
            event.flags = CGEventFlags(rawValue: flags)
            if let time { event.timestamp = UInt64(time * 1_000_000_000) }
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
        try require(mouse(switched, .rightMouseDragged, 40, 60) && mouse(switched, .rightMouseDragged, 60, 40) && mouse(switched, .rightMouseUp, 100, 0), "新应用不会收到孤立的拖动与松开事件")
        try require(switched.verificationActions!.isEmpty && replayed == 0, "切换应用不误操作新应用")

        let timeout = engine([diagonal]); replayed = 0
        _ = mouse(timeout, .rightMouseDown, 0, 100)
        _ = timeout.handle(nil, .tapDisabledByTimeout, CGEvent(source: nil)!)
        try require(timeout.stroke == nil && replayed == 1, "超时清理并恢复原始按下")

        let stopping = engine([diagonal]); var sequence: [CGEventType] = []
        stopping.verificationReplay = { sequence += $0.map(\.type) }
        _ = mouse(stopping, .rightMouseDown, 0, 0); stopping.stop()
        if !mouse(stopping, .rightMouseUp, 0, 0) { sequence.append(.rightMouseUp) }
        stopping.releaseStroke("tap_flush")
        try require(sequence == [.rightMouseDown, .rightMouseUp], "停止监听时先还按下再通过松开")

        // Exercise the actual final send site, not just the matched rule ID. Never post to the OS.
        var appRule = diagonal; appRule.bundleID = "test.A"
        let config = Configuration(rules: [appRule]); var sent: [pid_t?] = [], livePID: pid_t = 111
        let route = EventEngine(foregroundPID: { livePID }, postKey: { _, pid in sent.append(pid) })
        route.verificationReplay = { _ in }
        func draw() { _ = mouse(route, .rightMouseDown, 0, 100); _ = mouse(route, .rightMouseUp, 100, 0) }
        route.update(config, frontmost: "test.A", suspended: false, pid: 111)
        draw(); route.actions.sync {}
        try require(sent == [111,111], "不切前台时仅向原 PID 发送按下和松开")
        sent.removeAll()
        let matchedTarget = route.snapshot().target
        route.update(config, frontmost: "test.B", suspended: false, pid: 222)
        route.execute(appRule, trace: "check-after-match", target: matchedTarget); route.actions.sync {}
        try require(sent.isEmpty, "匹配后切换不重新领取目标 PID")
        route.update(config, frontmost: "test.A", suspended: false, pid: 111)
        route.actions.suspend(); draw()
        route.update(config, frontmost: "test.B", suspended: false, pid: 222)
        route.update(config, frontmost: "test.A", suspended: false, pid: 111)
        route.actions.resume(); route.actions.sync {}
        try require(sent.isEmpty, "排队期间切走又切回也取消旧动作")
        livePID = 222; draw(); route.actions.sync {}
        try require(sent.isEmpty, "前台通知尚未到达时也不发送旧动作")

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

        let backlog = engine([click, double]); backlog.doubleClickInterval = 0.5
        _ = mouse(backlog, .rightMouseDown, 1, 1, time: 10); _ = mouse(backlog, .rightMouseUp, 1, 1, time: 10.01)
        _ = mouse(backlog, .rightMouseDown, 1, 1, time: 10.59); _ = mouse(backlog, .rightMouseUp, 1, 1, time: 10.6)
        backlog.resolvePendingClick()
        try require(backlog.verificationActions == [click.id, click.id], "积压事件按实际发生时间区分两次单击")

        let middle = engine([Rule(kind: .click, button: 2, action: .copy)]); sequence = []
        middle.verificationReplay = { sequence += $0.map(\.type) }
        _ = mouse(middle, .otherMouseDown, 0, 0, button: 2)
        _ = mouse(middle, .otherMouseDragged, 2, 0, button: 2)
        _ = mouse(middle, .otherMouseDragged, 12, 0, button: 2)
        try require(sequence == [.otherMouseDown, .otherMouseDragged, .otherMouseDragged] && middle.stroke == nil, "只配单击时拖动一旦越界立即交还原事件")
        try require(!mouse(middle, .otherMouseDragged, 24, 0, button: 2) && !mouse(middle, .otherMouseUp, 24, 0, button: 2) && middle.verificationActions!.isEmpty, "后续拖动和松开直接通过")

        let sideRule = Rule(kind: .click, button: 4, output: Shortcut(8, 0x100000))
        let side = engine([sideRule])
        _ = mouse(side, .otherMouseDown, 0, 0, button: 4); _ = mouse(side, .otherMouseUp, 0, 0, button: 4)
        try require(side.verificationActions == [sideRule.id], "第五键点击")
        _ = mouse(side, .otherMouseDown, 0, 0, button: 4)
        for i in 0..<8 { _ = mouse(side, .otherMouseDragged, i.isMultiple(of: 2) ? 1 : -1, 0, button: 4) }
        _ = mouse(side, .otherMouseUp, 0, 0, button: 4)
        try require(side.verificationActions == [sideRule.id, sideRule.id], "容差内原地抖动仍是单击")
        return checks
    }
}
