import AppKit
import SwiftUI
import ApplicationServices
import Carbon
import GestureCore
import UniformTypeIdentifiers

struct RuleDraft: Identifiable {
    var rule: Rule
    var isNew: Bool
    var id: UUID { rule.id }
}

struct AppPrompt: Identifiable {
    let id = UUID()
    let title: String
    var detail = ""
    var confirmTitle = "知道了"
    var destructive = false
    var confirm: (() -> Void)?
}

@MainActor
final class AppModel: ObservableObject {
    @Published var configuration = Configuration.defaults {
        didSet {
            if initialized && configuration != oldValue {
                if configuration.iconLocation != oldValue.iconLocation { onIconLocationChanged?(configuration.iconLocation) }
                if !configuration.showTrail { trail.update(nil) }
                if configuration.showTrail != oldValue.showTrail || configuration.trailStyle != oldValue.trailStyle || configuration.iconLocation != oldValue.iconLocation {
                    diagnostics.record("settings.changed", ["trail": String(configuration.showTrail), "trail_width": String(configuration.trailStyle.width), "icon": configuration.iconLocation.rawValue])
                }
                syncAutomaticMonitoring(); scheduleSave()
            }
        }
    }
    @Published var editor: RuleDraft?
    @Published var prompt: AppPrompt?
    private enum MonitorState { case idle, starting, running, stopping }
    private var monitorState = MonitorState.idle
    var running: Bool { monitorState == .running }
    @Published private(set) var monitorError: String?
    @Published private(set) var actionError: String?
    private let isSmokeTest = ProcessInfo.processInfo.environment["GESTUREKEYS_SMOKE_TEST"] != nil
    var message: String? {
        didSet { if let message { prompt = AppPrompt(title: "GestureKeys", detail: message) } }
    }
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var inputGranted = CGPreflightListenEventAccess()
    @Published var filter = "键盘"
    @Published var recording = false { didSet { syncEngine() } }
    private let engine = EventEngine()
    private let hotKeys = GlobalHotKeys()
    @Published private(set) var unavailableShortcuts: [Shortcut] = []
    @Published private(set) var configurationSavedAt: Date?
    var onIconLocationChanged: ((IconLocation) -> Void)?
    private let trail = TrailOverlay()
    private let nameHUD = RuleNameHUD()
    private var workspaceObserver: NSObjectProtocol?
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
    var isRulePage: Bool { filter == "键盘" || filter == "鼠标" }

    init() {
        diagnostics.record("app.started", ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev", "macos": ProcessInfo.processInfo.operatingSystemVersionString, "pid": String(ProcessInfo.processInfo.processIdentifier)])
        let base = isSmokeTest
            ? URL(fileURLWithPath: "/tmp/GestureKeys-smoke-\(ProcessInfo.processInfo.processIdentifier)")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        storageURL = base.appendingPathComponent("GestureKeys", isDirectory: true).appendingPathComponent("config.json")
        var needsMigration = false
        do {
            if FileManager.default.fileExists(atPath: storageURL.path) {
                let data = try Data(contentsOf: storageURL)
                var config = try JSONDecoder().decode(Configuration.self, from: data)
                try config.validate()
                if config.rules.contains(where: \.needsReview) {
                    needsMigration = true
                    config.removeLegacyPlaceholders()
                    config.addDefaultRightClickIfMissing()
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
            prompt = AppPrompt(title: "无法读取配置", detail: "已保留原文件。可通过导入有效配置恢复。\n\(error.localizedDescription)")
        }
        engine.onStatus = { [weak self] running, error in
            guard let self else { return }
            if running {
                guard self.monitorState == .starting else { return }
                self.monitorState = .running
                self.syncAutomaticMonitoring()
            } else {
                self.monitorState = .idle
                self.trail.update(nil); self.nameHUD.hide()
                if let error { self.monitorError = error; self.syncEngine() }
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
            self.actionError = nil
            if rule.showsName == true { self.nameHUD.show(rule.name) }
        }
        engine.onActionError = { [weak self] rule, detail in
            self?.actionError = "「\(rule.name)」执行失败：\(detail)"
        }
        engine.onTrail = { [weak self] points in
            guard let self else { return }
            self.trail.update(self.configuration.showTrail ? points : nil, style: self.configuration.trailStyle)
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.syncEngine() } }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        configurationSavedAt = storage.savedAt
        initialized = true; refreshPermissions()
        do { try storage.migrateLegacyBackup() }
        catch { diagnostics.record("config.backup_migration_failed", diagnosticError(error)); message = "无法重命名旧备份，原文件未改动。\n\(error.localizedDescription)" }
        if needsMigration { saveNow() }
    }
    var visibleRules: [Rule] {
        RuleResolver.libraryOrder(configuration.rules, keyboard: filter == "键盘")
    }
    var conflicts: [String] { RuleResolver.conflicts(configuration.rules) }
    func syncEngine() {
        let front = NSWorkspace.shared.frontmostApplication
        let foreground = front?.bundleIdentifier ?? ""
        let pid = front?.processIdentifier ?? 0
        let reason = recording ? "recording_or_dialog" : pid == 0 ? "no_foreground" : pid == ProcessInfo.processInfo.processIdentifier ? "own_window" : "none"
        let suspended = reason != "none"
        let context = ["app": foreground, "pid": String(pid), "routing": reason]
        if context != loggedContext { loggedContext = context; diagnostics.record("input.context", context) }
        engine.update(configuration, frontmost: foreground, suspended: suspended, pid: pid)
        if running && !suspended {
            let wanted = Set(RuleResolver.scoped(configuration.rules, bundleID: foreground).filter { $0.kind == .keyboard }.compactMap(\.triggerKey))
            let failed = hotKeys.replace(with: wanted)
            if failed != unavailableShortcuts { unavailableShortcuts = failed }
        } else {
            _ = hotKeys.replace(with: [])
        }
    }
    func refreshPermissions() {
        let accessibility = AXIsProcessTrusted(), input = CGPreflightListenEventAccess()
        if accessibilityGranted != accessibility { accessibilityGranted = accessibility }
        if inputGranted != input { inputGranted = input }
        let permissions = ["accessibility": String(accessibility), "input_monitoring": String(input),
                           "event_posting": String(CGPreflightPostEventAccess()), "secure_input": String(IsSecureEventInputEnabled())]
        if permissions != loggedPermissions { loggedPermissions = permissions; diagnostics.record("input.permissions", permissions) }
        syncAutomaticMonitoring()
    }
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
    private func syncAutomaticMonitoring() {
        guard !isSmokeTest else { syncEngine(); return }
        let hasRules = configuration.rules.contains { $0.enabled && $0.validationError == nil }
        let permissionsOK = accessibilityGranted && inputGranted && CGPreflightPostEventAccess()
        let hasConflicts = hasRules && !conflicts.isEmpty
        let problem = hasConflicts ? "存在重复触发规则，请修改或停用其中一条。" :
            hasRules && !permissionsOK ? "缺少输入权限，请在「通用」中授权。" : nil
        let decision = !writable ? "invalid_configuration" : !hasRules ? "no_enabled_rules" : hasConflicts ? "rule_conflicts" : !permissionsOK ? "missing_permissions" : "allow"
        if loggedMonitorDecision != decision {
            loggedMonitorDecision = decision; diagnostics.record("monitor.policy", ["decision": decision])
        }
        if decision != "allow" {
            if monitorError != problem { monitorError = problem }
            if monitorState == .running || monitorState == .starting {
                monitorState = .stopping; engine.stop()
            }
            if !unavailableShortcuts.isEmpty { unavailableShortcuts = [] }
        } else if monitorState == .idle {
            monitorState = .starting
            syncEngine(); engine.start(); return
        } else if monitorState == .running && monitorError != nil {
            monitorError = nil
        }
        syncEngine()
    }
    func addRule() {
        guard isRulePage, editor == nil else { return }
        let kind: TriggerKind = filter == "鼠标" ? .gesture : .keyboard
        let rule = Rule(name: "", kind: kind, button: 0, action: .unassigned)
        diagnostics.record("rule.add_opened", diagnosticRule(rule))
        editor = RuleDraft(rule: rule, isNew: true)
    }
    func edit(_ rule: Rule) {
        diagnostics.record("rule.edit_opened", diagnosticRule(rule))
        editor = RuleDraft(rule: rule, isNew: false)
    }
    func confirmDelete(_ rule: Rule) {
        prompt = AppPrompt(title: "删除规则？", detail: rule.name, confirmTitle: "删除", destructive: true) { [weak self] in
            guard let self else { return }
            var updated = self.configuration; updated.rules.removeAll { $0.id == rule.id }
            do { try self.persist(updated); self.configuration = updated; diagnostics.record("rule.deleted", diagnosticRule(rule)) }
            catch { diagnostics.record("rule.delete_failed", diagnosticRule(rule).merging(diagnosticError(error)) { _, new in new }); self.prompt = AppPrompt(title: "无法删除规则", detail: error.localizedDescription) }
        }
    }
    func duplicate(_ original: Rule) {
        var rule = original; rule.id = UUID(); rule.name += " 副本"; rule.enabled = false
        diagnostics.record("rule.duplicate_opened", diagnosticRule(rule).merging(["source_rule": original.id.uuidString]) { _, new in new })
        editor = RuleDraft(rule: rule, isNew: true)
    }
    func commit(_ rule: Rule, isNew: Bool, operation: String? = nil) -> String? {
        let facts = diagnosticRule(rule)
        if let error = rule.validationError { diagnostics.record("rule.validation_failed", facts.merging(["reason": error]) { _, new in new }); return error }
        var updated = configuration
        if isNew { updated.rules.append(rule) }
        else if let index = updated.rules.firstIndex(where: { $0.id == rule.id }) { updated.rules[index] = rule }
        else { diagnostics.record("rule.not_found", facts); return "找不到这条规则。" }
        if let conflict = updated.rules.first(where: { $0.id != rule.id && $0.enabled && rule.enabled && $0.validationError == nil && $0.bundleID == rule.bundleID && RuleResolver.sameTrigger($0, rule) }) {
            diagnostics.record("rule.conflict", facts.merging(["other_rule": conflict.id.uuidString]) { _, new in new })
            return "与「\(conflict.name)」使用相同的触发方式。"
        }
        do { try persist(updated) } catch {
            diagnostics.record("rule.save_failed", facts.merging(diagnosticError(error)) { _, new in new }); return "保存失败：\(error.localizedDescription)"
        }
        diagnostics.record(operation ?? (isNew ? "rule.created" : "rule.updated"), facts.merging(["enabled": String(rule.enabled), "scope": rule.bundleID.isEmpty ? "all" : rule.bundleID]) { _, new in new })
        configuration = updated; editor = nil
        return nil
    }
    private func persist(_ updated: Configuration) throws {
        guard writable else { throw ConfigError.invalid("当前配置无法写入。请先导入有效配置。") }
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
        } catch { message = "无法打开配置文件夹：\(error.localizedDescription)" }
    }
    func setEnabled(_ enabled: Bool, for original: Rule) {
        if !enabled {
            var updated = configuration
            guard let index = updated.rules.firstIndex(where: { $0.id == original.id }) else { return }
            updated.rules[index].enabled = false
            do { try persist(updated); configuration = updated; diagnostics.record("rule.disabled", diagnosticRule(original)) }
            catch { diagnostics.record("rule.disable_failed", diagnosticRule(original).merging(diagnosticError(error)) { _, new in new }); prompt = AppPrompt(title: "无法停用规则", detail: error.localizedDescription) }
        } else {
            var edited = original; edited.enabled = true
            if let issue = commit(edited, isNew: false, operation: "rule.enabled") { prompt = AppPrompt(title: "无法启用规则", detail: issue) }
        }
    }
    func binding(for id: UUID) -> Binding<Rule> {
        Binding(get: { self.configuration.rules.first { $0.id == id } ?? Rule() }, set: { new in
            if let index = self.configuration.rules.firstIndex(where: { $0.id == id }) { self.configuration.rules[index] = new }
        })
    }
    func chooseApplication(_ completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.prompt = "选择"
        recording = true
        panel.begin { [weak self] response in
            self?.recording = false
            if response == .OK, let url = panel.url { completion(url) }
        }
    }
    func importConfiguration() {
        diagnostics.record("config.import_opened")
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json, UTType(filenameExtension: "BABPreset") ?? .data]
        panel.prompt = "导入"; panel.message = "支持 BetterAndBetter 的 .BABPreset 或 GestureKeys 的 JSON 配置。"
        recording = true
        panel.begin { [weak self] response in
            guard let self else { return }; self.recording = false
            guard response == .OK, let url = panel.url else { diagnostics.record("config.import_cancelled"); return }
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 4_000_000 else { throw ConfigError.invalid("配置文件超过 4 MB。") }
                var config: Configuration; var warnings: [String] = []
                if url.pathExtension.lowercased() == "babpreset" {
                    let imported = try BABImport.read(data); config = imported.configuration; warnings = imported.warnings
                } else {
                    config = try JSONDecoder().decode(Configuration.self, from: data); try config.validate()
                    let oldCount = config.rules.count; config.removeLegacyPlaceholders()
                    if oldCount != config.rules.count { warnings = ["已跳过 \(oldCount - config.rules.count) 条旧版占位规则。"] }
                }
                self.prompt = AppPrompt(title: "替换当前配置？", detail: "导入 \(config.rules.count) 条规则。当前配置会保留为上一版，新规则将自动生效。", confirmTitle: "导入并替换") { [weak self] in
                    guard let self else { return }
                    do {
                        if self.writable { try self.storage.save(self.configuration) }
                        try self.storage.save(config)
                        self.writable = true; self.configuration = config; self.syncAutomaticMonitoring(); self.updateSavedDate()
                        diagnostics.record("config.imported", ["rules": String(config.rules.count), "warnings": String(warnings.count)])
                        self.prompt = AppPrompt(title: "已导入 \(config.rules.count) 条规则", detail: warnings.joined(separator: "\n"))
                    } catch { diagnostics.record("config.import_failed", diagnosticError(error)); self.message = "导入失败，未替换当前规则。\n\(error.localizedDescription)" }
                }
            } catch { diagnostics.record("config.import_failed", diagnosticError(error)); self.message = "导入失败，未替换当前规则。\n\(error.localizedDescription)" }
        }
    }
    func exportConfiguration() {
        diagnostics.record("config.export_opened")
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = ConfigStorage.datedName("GestureKeys-")
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { diagnostics.record("config.export_cancelled"); return }
            do { let data = try ConfigStorage.encode(self.configuration); try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                diagnostics.record("config.exported", ["rules": String(self.configuration.rules.count)])
            } catch { diagnostics.record("config.export_failed", diagnosticError(error)); self.message = "导出失败：\(error.localizedDescription)" }
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
            if !saveErrorShown { diagnostics.record("config.save_failed", diagnosticError(error)); message = "配置保存失败：\(error.localizedDescription)"; saveErrorShown = true }
        }
    }
    func shutdown() {
        permissionTimer?.invalidate()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        engine.onStatus = nil
        pendingSave?.cancel(); saveNow(); _ = hotKeys.replace(with: []); engine.stop(); trail.update(nil)
        diagnostics.record("app.exiting"); diagnostics.flush()
    }

    func verifyMissingApplication() {
        let key = Shortcut(23, 0x40000)
        var rule = Rule(name: "启动测试", key: key, action: .openApplication)
        rule.appPath = "/nonexistent-gesturekeys-\(UUID().uuidString)/测试应用.app"
        engine.update(Configuration(rules: [rule]), frontmost: "test.browser", suspended: false)
        engine.press(key)
    }
}
