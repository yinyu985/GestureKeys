import AppKit
import SwiftUI
import ApplicationServices
import Carbon
import GestureCore
import UniformTypeIdentifiers
import ServiceManagement

enum SettingsPage: CaseIterable {
    case keyboard, mouse, general, about

    var title: String {
        switch self {
        case .keyboard: return L10n.text("键盘")
        case .mouse: return L10n.text("鼠标")
        case .general: return L10n.text("通用")
        case .about: return L10n.text("关于")
        }
    }
    var icon: String {
        switch self {
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        case .general: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

struct RuleDraft: Identifiable {
    var rule: Rule
    var isNew: Bool
    var id: UUID { rule.id }
}

struct AppPrompt: Identifiable {
    let id = UUID()
    let title: String
    var detail = ""
    var confirmTitle = L10n.text("知道了")
    var destructive = false
    var confirm: (() -> Void)?
}

@MainActor
final class AppModel: ObservableObject {
    @Published var configuration = Configuration.defaults {
        didSet {
            if initialized && configuration != oldValue {
                if configuration.rules != oldValue.rules { ruleIndex = RuleIndex(configuration.rules) }
                if configuration.iconLocation != oldValue.iconLocation { onIconLocationChanged?(configuration.iconLocation) }
                if configuration.appearance != oldValue.appearance { Ink.apply(configuration.appearance) }
                if !configuration.showTrail || configuration.trailStyle.effect != oldValue.trailStyle.effect { trail.hide() }
                if configuration.showTrail != oldValue.showTrail || configuration.trailStyle != oldValue.trailStyle || configuration.iconLocation != oldValue.iconLocation || configuration.appearance != oldValue.appearance {
                    diagnostics.record("settings.changed", ["trail": String(configuration.showTrail), "trail_width": String(configuration.trailStyle.width), "trail_effect": configuration.trailStyle.effect.rawValue, "icon": configuration.iconLocation.rawValue, "appearance": configuration.appearance.rawValue])
                }
                syncAutomaticMonitoring(); scheduleSave()
            }
        }
    }
    @Published var editor: RuleDraft? { didSet { if (editor == nil) != (oldValue == nil) { syncEngine() } } }
    @Published var prompt: AppPrompt? { didSet { if (prompt == nil) != (oldValue == nil) { syncEngine() } } }
    private enum MonitorState { case idle, starting, running, stopping }
    private var monitorState = MonitorState.idle
    var running: Bool { monitorState == .running }
    @Published private var monitorIssue: MonitorIssue?
    @Published private var actionIssue: (ruleName: String, failure: ActionFailure)?
    var monitorError: String? { monitorIssue.map { L10n.text($0.rawValue) } }
    var actionError: String? { actionIssue.map { L10n.text("「%1$@」执行失败：%2$@", $0.ruleName, $0.failure.message) } }
    private let isSmokeTest = ProcessInfo.processInfo.environment["GESTUREKEYS_SMOKE_TEST"] != nil
    var message: String? {
        didSet { if let message { prompt = AppPrompt(title: "GestureKeys", detail: message) } }
    }
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var inputGranted = CGPreflightListenEventAccess()
    @Published var page = SettingsPage.keyboard
    @Published private(set) var appLanguage = AppLanguage.load()
    var recordingShortcut = false { didSet { if recordingShortcut != oldValue { syncEngine() } } }
    private var filePanelOpen = false { didSet { if filePanelOpen != oldValue { syncEngine() } } }
    private var sheetVisible = false
    private var isShuttingDown = false
    private var sheetObservers: [NSObjectProtocol] = []
    private let engine = EventEngine()
    private let hotKeys = GlobalHotKeys()
    private lazy var ruleIndex = RuleIndex(configuration.rules)
    private var hotKeysWereRunning = false
    private var lastRejectedHotKeys = Set<Shortcut>()
    private var hotKeyFailures = HotKeyFailures()
    static let desktopOneShortcut = Shortcut(UInt16(kVK_ANSI_1), CGEventFlags.maskControl.rawValue)
    @Published private(set) var desktopOneUnavailable = false
    @Published private(set) var unavailableShortcuts: [Shortcut] = []
    @Published private(set) var configurationSavedAt: Date?
    @Published private(set) var loginItemStatus: SMAppService.Status = .notRegistered
    var onIconLocationChanged: ((IconLocation) -> Void)?
    private let trail = TrailOverlay()
    private let nameHUD = RuleNameHUD()
    private var workspaceObserver: NSObjectProtocol?
    private var layoutObserver: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var pendingSave: DispatchWorkItem?
    private var initialized = false
    private var writable = true
    private var saveErrorShown = false
    private var loggedContext: [String: String] = [:]
    private var loggedPermissions: [String: String] = [:]
    private var loggedMonitorDecision = ""
    let storageURL: URL
    var storage: ConfigStorage { ConfigStorage(storageURL) }
    var isRulePage: Bool { page == .keyboard || page == .mouse }
    var acceptsNewRule: Bool { isRulePage && editor == nil && prompt == nil }

    init() {
        diagnostics.record("app.started", ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev", "macos": ProcessInfo.processInfo.operatingSystemVersionString, "pid": String(ProcessInfo.processInfo.processIdentifier)])
        let base = isSmokeTest
            ? URL(fileURLWithPath: "/tmp/GestureKeys-smoke-\(ProcessInfo.processInfo.processIdentifier)")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        storageURL = base.appendingPathComponent("GestureKeys", isDirectory: true).appendingPathComponent("config.json")
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated {
            if KeyboardLayoutLabels.refresh() { self?.objectWillChange.send() }
        } }
        KeyboardLayoutLabels.refresh()
        var needsMigration = false
        do {
            if FileManager.default.fileExists(atPath: storageURL.path) {
                let data = try Data(contentsOf: storageURL)
                var config = try JSONDecoder().decode(Configuration.self, from: data)
                try config.validate()
                if config.rules.contains(where: \.needsReview) {
                    needsMigration = true
                    config.removeLegacyPlaceholders()
                    config.addDefaultMissionControlGestureIfMissing()
                }
                configuration = config
            } else if let seed = Bundle.main.url(forResource: "InitialRules", withExtension: "json") {
                let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: seed))
                try config.validate(); configuration = config
            }
            diagnostics.record("config.loaded", ["source": FileManager.default.fileExists(atPath: storageURL.path) ? "saved" : "seed_or_defaults", "rules": String(configuration.rules.count)])
        } catch {
            diagnostics.record("config.load_failed", diagnosticError(error))
            writable = false
            prompt = AppPrompt(title: L10n.text("无法读取配置"), detail: L10n.text("已保留原文件。可通过导入有效配置恢复。\n%1$@", "\(error.localizedDescription)"))
        }
        engine.onStatus = { [weak self] running, error in
            guard let self else { return }
            if running {
                guard self.monitorState == .starting else { return }
                self.monitorState = .running
                self.syncAutomaticMonitoring()
            } else {
                self.monitorState = .idle
                self.trail.hide(); self.nameHUD.hide()
                if let error { self.monitorIssue = error; self.syncEngine() }
                else { self.syncAutomaticMonitoring() }
            }
        }
        hotKeys.onPress = { [weak self] shortcut in
            guard let self, self.running else { return }
            self.syncEngine()
            self.engine.press(shortcut)
        }
        engine.onAction = { [weak self] rule in
            guard let self else { return }
            if self.actionIssue != nil { self.actionIssue = nil }
            if rule.showsName == true { self.nameHUD.show(rule.displayName) }
        }
        engine.onActionError = { [weak self] rule, failure in
            self?.actionIssue = (rule.name, failure)
        }
        engine.onTrail = { [weak self] points in
            guard let self else { return }
            if !self.configuration.showTrail { self.trail.hide() }
            else if let points { self.trail.update(points, style: self.configuration.trailStyle) }
            else { self.trail.finish() }
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.syncEngine(); self?.refreshLoginItem() } }
        sheetObservers = [NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let visible = note.name == NSWindow.willBeginSheetNotification
                MainActor.assumeIsolated { self?.sheetVisible = visible; self?.syncEngine() }
                if !visible { DispatchQueue.main.async { self?.syncEngine() } }
            }
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions(); self?.refreshLoginItem() }
        }
        configurationSavedAt = storage.savedAt
        initialized = true; refreshPermissions(); refreshLoginItem()
        do { try storage.migrateLegacyBackup() }
        catch { diagnostics.record("config.backup_migration_failed", diagnosticError(error)); message = L10n.text("无法重命名旧备份，原文件未改动。\n%1$@", "\(error.localizedDescription)") }
        if needsMigration { saveNow() }
    }
    func setLanguage(_ language: AppLanguage) {
        guard appLanguage != language else { return }
        language.save()
        appLanguage = language
    }
    var visibleRules: [Rule] {
        RuleResolver.libraryOrder(configuration.rules, keyboard: page == .keyboard)
    }
    func routingReason(pid: pid_t) -> String {
        if pid <= 0 { return "no_foreground" }
        guard pid == ProcessInfo.processInfo.processIdentifier else { return "none" }
        if filePanelOpen { return "file_dialog" }
        if recordingShortcut { return "shortcut_capture" }
        if editor != nil { return "rule_editor" }
        if prompt != nil { return "confirmation_dialog" }
        if sheetVisible || NSApp.modalWindow != nil { return "modal_window" }
        return "none"
    }
    func syncEngine(retryRejected: Bool = false) {
        guard initialized, !isShuttingDown else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let foreground = front?.bundleIdentifier ?? ""
        let pid = front?.processIdentifier ?? 0
        let reason = routingReason(pid: pid)
        let suspended = reason != "none"
        let context = ["app": foreground, "pid": String(pid), "routing": reason]
        if context != loggedContext { loggedContext = context; diagnostics.record("input.context", context) }
        let update = engine.update(ruleIndex, showTrail: configuration.showTrail, frontmost: foreground, suspended: suspended, pid: pid)
        if update.contextChanged { trail.hide() }
        let registrationChanged = update.contextChanged || running != hotKeysWereRunning
        guard registrationChanged || (retryRejected && !lastRejectedHotKeys.isEmpty) else { return }
        let scope = running && !suspended ? update.rules : .empty
        let rejected = Set(hotKeys.replace(with: scope.shortcuts))
        guard registrationChanged || rejected != lastRejectedHotKeys else { return }
        hotKeysWereRunning = running
        lastRejectedHotKeys = rejected
        if running { hotKeyFailures.update(rules: ruleIndex.activeKeyboardRules, attempted: scope.keyboardRules, rejected: rejected) }
        else { hotKeyFailures = HotKeyFailures() }
        let desktopOne = Self.desktopOneShortcut
        let failures = hotKeyFailures.shortcuts
        if desktopOneUnavailable != failures.contains(desktopOne) { desktopOneUnavailable = failures.contains(desktopOne) }
        let others = failures.subtracting([desktopOne]).sorted { $0.display < $1.display }
        if unavailableShortcuts != others { unavailableShortcuts = others }
    }
    func refreshPermissions() {
        let accessibility = AXIsProcessTrusted(), input = CGPreflightListenEventAccess()
        if accessibilityGranted != accessibility { accessibilityGranted = accessibility }
        if inputGranted != input { inputGranted = input }
        let permissions = ["accessibility": String(accessibility), "input_monitoring": String(input),
                           "event_posting": String(CGPreflightPostEventAccess()), "secure_input": String(IsSecureEventInputEnabled())]
        if permissions != loggedPermissions { loggedPermissions = permissions; diagnostics.record("input.permissions", permissions) }
        syncAutomaticMonitoring(retryRejected: true)
    }
    private func refreshLoginItem() {
        guard !isSmokeTest else { return }
        let status = SMAppService.mainApp.status
        if loginItemStatus != status {
            loginItemStatus = status
            diagnostics.record("login_item.status", ["status": String(status.rawValue)])
        }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isSmokeTest else { return }
        let item = SMAppService.mainApp
        diagnostics.record("login_item.requested", ["enabled": String(enabled)])
        defer { refreshLoginItem() }
        do {
            if enabled { try item.register() }
            else { try item.unregister() }
        } catch {
            // Registration may require the user to approve it in System Settings.
            if enabled && item.status == .requiresApproval { return }
            diagnostics.record("login_item.failed", diagnosticError(error))
            prompt = AppPrompt(title: L10n.text("无法更改登录项"), detail: error.localizedDescription)
        }
    }
    func showLoginItems() { SMAppService.openSystemSettingsLoginItems() }
    func requestAccessibility() {
        diagnostics.record("permission.requested", ["kind": "accessibility"])
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        openPrivacy("Privacy_Accessibility")
    }
    func requestInput() {
        diagnostics.record("permission.requested", ["kind": "input_monitoring"])
        _ = CGRequestListenEventAccess(); openPrivacy("Privacy_ListenEvent")
    }
    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
    private func syncAutomaticMonitoring(retryRejected: Bool = false) {
        guard !isSmokeTest else { syncEngine(); return }
        let hasRules = ruleIndex.hasEnabledRules
        let permissionsOK = accessibilityGranted && inputGranted && CGPreflightPostEventAccess()
        let hasConflicts = ruleIndex.hasConflicts
        let issue: MonitorIssue? = hasConflicts ? .conflictingRules : hasRules && !permissionsOK ? .missingPermissions : nil
        let decision = !writable ? "invalid_configuration" : !hasRules ? "no_enabled_rules" : hasConflicts ? "rule_conflicts" : !permissionsOK ? "missing_permissions" : "allow"
        if loggedMonitorDecision != decision {
            loggedMonitorDecision = decision; diagnostics.record("monitor.policy", ["decision": decision])
        }
        if decision != "allow" {
            if monitorIssue != issue { monitorIssue = issue }
            if monitorState == .running || monitorState == .starting {
                monitorState = .stopping; engine.stop()
            }
        } else if monitorState == .idle {
            monitorState = .starting
            syncEngine(); engine.start(); return
        } else if monitorState == .running && monitorIssue != nil {
            monitorIssue = nil
        }
        syncEngine(retryRejected: retryRejected)
    }
    func addRule() {
        guard acceptsNewRule, !filePanelOpen else { return }
        let kind: TriggerKind = page == .mouse ? .gesture : .keyboard
        let rule = Rule(name: "", kind: kind, button: 0, action: .unassigned)
        diagnostics.record("rule.add_opened", diagnosticRule(rule))
        editor = RuleDraft(rule: rule, isNew: true)
    }
    func edit(_ rule: Rule) {
        diagnostics.record("rule.edit_opened", diagnosticRule(rule))
        editor = RuleDraft(rule: rule, isNew: false)
    }
    func confirmDelete(_ rule: Rule) {
        prompt = AppPrompt(title: L10n.text("删除规则？"), detail: rule.name, confirmTitle: L10n.text("删除"), destructive: true) { [weak self] in
            guard let self else { return }
            var updated = self.configuration; updated.rules.removeAll { $0.id == rule.id }
            do { try self.persist(updated); self.configuration = updated; diagnostics.record("rule.deleted", diagnosticRule(rule)) }
            catch { diagnostics.record("rule.delete_failed", diagnosticRule(rule).merging(diagnosticError(error)) { _, new in new }); self.prompt = AppPrompt(title: L10n.text("无法删除规则"), detail: error.localizedDescription) }
        }
    }
    func duplicate(_ original: Rule) {
        var rule = original; rule.id = UUID(); rule.name = L10n.text("%1$@ 副本", original.name); rule.enabled = false
        diagnostics.record("rule.duplicate_opened", diagnosticRule(rule).merging(["source_rule": original.id.uuidString]) { _, new in new })
        editor = RuleDraft(rule: rule, isNew: true)
    }
    func commit(_ draft: Rule, isNew: Bool, operation: String? = nil) -> String? {
        let rule = draft.withoutUnusedActionFields
        let facts = diagnosticRule(rule)
        if let error = rule.validationError { diagnostics.record("rule.validation_failed", facts.merging(["reason": error]) { _, new in new }); return error }
        var updated = configuration
        if isNew { updated.rules.append(rule) }
        else if let index = updated.rules.firstIndex(where: { $0.id == rule.id }) { updated.rules[index] = rule }
        else { diagnostics.record("rule.not_found", facts); return L10n.text("找不到这条规则。") }
        if let conflict = updated.rules.first(where: { $0.id != rule.id && $0.enabled && rule.enabled && $0.validationError == nil && $0.bundleID == rule.bundleID && RuleResolver.sameTrigger($0, rule) }) {
            diagnostics.record("rule.conflict", facts.merging(["other_rule": conflict.id.uuidString]) { _, new in new })
            return L10n.text("与「%1$@」使用相同的触发方式。", "\(conflict.name)")
        }
        do { try persist(updated) } catch {
            diagnostics.record("rule.save_failed", facts.merging(diagnosticError(error)) { _, new in new }); return L10n.text("保存失败：%1$@", "\(error.localizedDescription)")
        }
        diagnostics.record(operation ?? (isNew ? "rule.created" : "rule.updated"), facts.merging(["enabled": String(rule.enabled), "scope": rule.bundleID.isEmpty ? "all" : rule.bundleID]) { _, new in new })
        configuration = updated; editor = nil
        return nil
    }
    private func persist(_ updated: Configuration) throws {
        guard writable else { throw ConfigError.invalid(L10n.text("当前配置无法写入。请先导入有效配置。")) }
        try storage.save(configuration)
        try storage.save(updated)
        updateSavedDate()
    }
    private func updateSavedDate() {
        let date = storage.savedAt
        if configurationSavedAt != date { configurationSavedAt = date }
    }
    func showDiagnosticLog() {
        diagnostics.record("diagnostic.revealed")
        NSWorkspace.shared.activateFileViewerSelecting([diagnostics.file])
    }
    func showConfigurationFolder() {
        do {
            try FileManager.default.createDirectory(at: storage.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            NSWorkspace.shared.open(storage.folder)
        } catch { message = L10n.text("无法打开配置文件夹：%1$@", "\(error.localizedDescription)") }
    }
    func setEnabled(_ enabled: Bool, for original: Rule) {
        if !enabled {
            var updated = configuration
            guard let index = updated.rules.firstIndex(where: { $0.id == original.id }) else { return }
            updated.rules[index].enabled = false
            do { try persist(updated); configuration = updated; diagnostics.record("rule.disabled", diagnosticRule(original)) }
            catch { diagnostics.record("rule.disable_failed", diagnosticRule(original).merging(diagnosticError(error)) { _, new in new }); prompt = AppPrompt(title: L10n.text("无法停用规则"), detail: error.localizedDescription) }
        } else {
            var edited = original; edited.enabled = true
            if let issue = commit(edited, isNew: false, operation: "rule.enabled") { prompt = AppPrompt(title: L10n.text("无法启用规则"), detail: issue) }
        }
    }
    func setTriggerHint(_ show: Bool, for id: UUID) {
        var updated = configuration
        guard let index = updated.rules.firstIndex(where: { $0.id == id }), (updated.rules[index].showsName == true) != show else { return }
        updated.rules[index].showsName = show ? true : nil
        let facts = diagnosticRule(updated.rules[index]).merging(["shown": String(show)]) { _, new in new }
        do {
            try persist(updated); configuration = updated
            diagnostics.record("rule.trigger_hint_changed", facts)
        } catch {
            diagnostics.record("rule.trigger_hint_failed", facts.merging(diagnosticError(error)) { _, new in new })
            prompt = AppPrompt(title: L10n.text("无法保存触发提示"), detail: error.localizedDescription)
        }
    }
    func binding(for id: UUID) -> Binding<Rule> {
        Binding(get: { self.configuration.rules.first { $0.id == id } ?? Rule() }, set: { new in
            if let index = self.configuration.rules.firstIndex(where: { $0.id == id }) { self.configuration.rules[index] = new }
        })
    }
    func chooseApplication(_ completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        chooseItem(panel, completion)
    }
    func chooseFileOrFolder(_ completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        chooseItem(panel, completion)
    }
    private func chooseItem(_ panel: NSOpenPanel, _ completion: @escaping (URL) -> Void) {
        panel.allowsMultipleSelection = false; panel.prompt = L10n.text("选择")
        filePanelOpen = true
        panel.begin { [weak self] response in
            self?.filePanelOpen = false
            if response == .OK, let url = panel.url { completion(url) }
        }
    }
    func importConfiguration() {
        diagnostics.record("config.import_opened")
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "BABPreset") ?? .data]
        panel.prompt = L10n.text("导入"); panel.message = L10n.text("支持 BetterAndBetter 的 .BABPreset 或 GestureKeys 的 JSON 配置。")
        filePanelOpen = true
        panel.begin { [weak self] response in
            guard let self else { return }; self.filePanelOpen = false
            guard response == .OK, let url = panel.url else { diagnostics.record("config.import_cancelled"); return }
            do {
                let (config, warnings) = try ConfigStorage.importFile(at: url)
                self.prompt = AppPrompt(title: L10n.text("替换当前配置？"), detail: L10n.text("导入 %1$@ 条规则。当前配置会保留为上一版，新规则将自动生效。", "\(config.rules.count)"), confirmTitle: L10n.text("导入并替换")) { [weak self] in
                    guard let self else { return }
                    do {
                        if self.writable { try self.storage.save(self.configuration) }
                        try self.storage.save(config)
                        self.writable = true; self.configuration = config; self.syncAutomaticMonitoring(); self.updateSavedDate()
                        diagnostics.record("config.imported", ["rules": String(config.rules.count), "warnings": String(warnings.count)])
                        self.prompt = AppPrompt(title: L10n.text("已导入 %1$@ 条规则", "\(config.rules.count)"), detail: warnings.joined(separator: "\n"))
                    } catch { diagnostics.record("config.import_failed", diagnosticError(error)); self.message = L10n.text("导入失败，未替换当前规则。\n%1$@", "\(error.localizedDescription)") }
                }
            } catch { diagnostics.record("config.import_failed", diagnosticError(error)); self.message = L10n.text("导入失败，未替换当前规则。\n%1$@", "\(error.localizedDescription)") }
        }
    }
    func exportConfiguration() {
        diagnostics.record("config.export_opened")
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = ConfigStorage.datedName("GestureKeys-")
        filePanelOpen = true
        panel.begin { [weak self] response in
            guard let self else { return }; self.filePanelOpen = false
            guard response == .OK, let url = panel.url else { diagnostics.record("config.export_cancelled"); return }
            do {
                try ConfigStorage.export(self.configuration, to: url)
                diagnostics.record("config.exported", ["rules": String(self.configuration.rules.count)])
            } catch { diagnostics.record("config.export_failed", diagnosticError(error)); self.message = L10n.text("导出失败：%1$@", "\(error.localizedDescription)") }
        }
    }
    private func scheduleSave() {
        pendingSave?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = task; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
    }
    func saveNow() {
        guard writable else { return }
        do {
            try storage.save(configuration)
            if configurationSavedAt != storage.savedAt { diagnostics.record("config.saved", ["rules": String(configuration.rules.count)]) }
            updateSavedDate(); saveErrorShown = false
        } catch {
            if !saveErrorShown { diagnostics.record("config.save_failed", diagnosticError(error)); message = L10n.text("配置保存失败：%1$@", "\(error.localizedDescription)"); saveErrorShown = true }
        }
    }
    func shutdown() {
        guard !isShuttingDown else { return }; isShuttingDown = true
        permissionTimer?.invalidate()
        sheetObservers.forEach(NotificationCenter.default.removeObserver)
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        if let layoutObserver { DistributedNotificationCenter.default().removeObserver(layoutObserver) }
        engine.onStatus = nil
        pendingSave?.cancel(); saveNow(); _ = hotKeys.replace(with: []); engine.stop(); trail.hide()
        diagnostics.record("app.exiting"); diagnostics.flush()
    }

    func verifyMissingApplication() {
        let key = Shortcut(23, 0x40000)
        var rule = Rule(name: "Open test", key: key, action: .openApplication)
        rule.appPath = "/nonexistent-gesturekeys-\(UUID().uuidString)/Test App.app"
        let front = NSWorkspace.shared.frontmostApplication
        engine.update(RuleIndex([rule]), showTrail: false, frontmost: front?.bundleIdentifier ?? "", suspended: false, pid: front?.processIdentifier ?? 0)
        engine.press(key)
    }
}
