import Foundation

public struct StrokePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public func distance(to p: Self) -> Double { hypot(x - p.x, y - p.y) }
}

public struct Shortcut: Codable, Equatable, Hashable, Sendable {
    public static let mask: UInt64 = 0x1e0000 // Shift, Control, Option, Command; exclude device bits.
    public var keyCode: UInt16
    public var modifiers: UInt64
    public init(_ keyCode: UInt16 = 0, _ modifiers: UInt64 = 0) {
        self.keyCode = keyCode; self.modifiers = modifiers & Self.mask
    }
    public var display: String {
        var s = ""
        for (bit, symbol) in [(UInt64(0x40000), "⌃"), (0x80000, "⌥"), (0x20000, "⇧"), (0x100000, "⌘")] {
            if modifiers & bit != 0 { s += symbol }
        }
        let names: [UInt16: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"↩",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"Tab",49:"Space",50:"`",51:"⌫",53:"Esc",96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",109:"F10",111:"F12",115:"Home",116:"Page Up",117:"⌦",118:"F4",119:"End",120:"F2",121:"Page Down",122:"F1",123:"←",124:"→",125:"↓",126:"↑"]
        return s + (names[keyCode] ?? "Key \(keyCode)")
    }
    public var isSafeTrigger: Bool {
        modifiers != 0 || [UInt16(96), 97, 98, 99, 100, 101, 103, 109, 111, 118, 120, 122].contains(keyCode)
    }
}

public enum TriggerKind: String, Codable, CaseIterable, Sendable {
    case keyboard, gesture, click
    public var title: String {
        switch self { case .keyboard: return L10n.text("键盘快捷键"); case .gesture: return L10n.text("鼠标手势"); case .click: return L10n.text("鼠标点击") }
    }
}

public enum ActionKind: String, Codable, CaseIterable, Sendable {
    case unassigned, shortcut, pageBack, pageForward, pageTop, pageBottom, missionControl, nextDesktop, previousDesktop, openApplication, block
    case reloadPage, newTab, closeTab, reopenTab, nextTab, previousTab, find
    case cut, copy, paste, selectAll, undo, redo, save
    case hideApp, minimizeWindow, quitApp, fullScreen, showDesktop, appWindows, openFinder, screenshot
    case openLink, openFileOrFolder

    public static var groups: [(String, [Self])] {
        [
            (L10n.text("自定义"), [.shortcut, .openApplication, .openLink, .openFileOrFolder]),
            (L10n.text("网页与标签页"), [.pageBack, .pageForward, .pageTop, .pageBottom, .reloadPage, .newTab, .closeTab, .reopenTab, .nextTab, .previousTab, .find]),
            (L10n.text("编辑"), [.cut, .copy, .paste, .selectAll, .undo, .redo, .save]),
            (L10n.text("窗口与系统"), [.hideApp, .minimizeWindow, .quitApp, .fullScreen, .missionControl, .showDesktop, .nextDesktop, .previousDesktop, .openFinder])
        ]
    }
    public var systemAppPath: String? {
        switch self {
        case .missionControl: return "/System/Applications/Mission Control.app"
        case .openFinder: return "/System/Library/CoreServices/Finder.app"
        default: return nil
        }
    }
    public var isSystemShortcut: Bool {
        [.shortcut, .nextDesktop, .previousDesktop, .showDesktop, .appWindows, .screenshot].contains(self)
    }
    public var switchesSpace: Bool { self == .nextDesktop || self == .previousDesktop }
    public var title: String {
        switch self {
        case .shortcut: return L10n.text("发送快捷键")
        case .pageBack: return L10n.text("网页后退")
        case .pageForward: return L10n.text("网页前进")
        case .pageTop: return L10n.text("网页到顶")
        case .pageBottom: return L10n.text("网页到底")
        case .missionControl: return L10n.text("调度中心")
        case .nextDesktop: return L10n.text("下一个空间")
        case .previousDesktop: return L10n.text("上一个空间")
        case .openApplication: return L10n.text("打开应用")
        case .openLink: return L10n.text("打开链接")
        case .openFileOrFolder: return L10n.text("打开文件或文件夹")
        case .block: return L10n.text("阻止触发")
        case .unassigned: return L10n.text("选择动作")
        case .reloadPage: return L10n.text("刷新网页")
        case .newTab: return L10n.text("新建标签页")
        case .closeTab: return L10n.text("关闭标签页或窗口")
        case .reopenTab: return L10n.text("重新打开关闭的标签页")
        case .nextTab: return L10n.text("下一个标签页")
        case .previousTab: return L10n.text("上一个标签页")
        case .find: return L10n.text("查找")
        case .cut: return L10n.text("剪切")
        case .copy: return L10n.text("复制")
        case .paste: return L10n.text("粘贴")
        case .selectAll: return L10n.text("全选")
        case .undo: return L10n.text("撤销")
        case .redo: return L10n.text("重做")
        case .save: return L10n.text("保存")
        case .hideApp: return L10n.text("隐藏当前应用")
        case .minimizeWindow: return L10n.text("最小化窗口")
        case .quitApp: return L10n.text("退出当前应用")
        case .fullScreen: return L10n.text("切换全屏")
        case .showDesktop: return L10n.text("显示桌面")
        case .appWindows: return L10n.text("显示当前应用的窗口")
        case .openFinder: return L10n.text("打开访达")
        case .screenshot: return L10n.text("区域截屏")
        }
    }
    public var standardShortcut: Shortcut? {
        switch self {
        case .pageBack: return Shortcut(33, 0x100000)
        case .pageForward: return Shortcut(30, 0x100000)
        case .pageTop: return Shortcut(126, 0x100000)
        case .pageBottom: return Shortcut(125, 0x100000)
        case .nextDesktop: return Shortcut(124, 0x40000)
        case .previousDesktop: return Shortcut(123, 0x40000)
        case .reloadPage: return Shortcut(15, 0x100000)
        case .newTab: return Shortcut(17, 0x100000)
        case .closeTab: return Shortcut(13, 0x100000)
        case .reopenTab: return Shortcut(17, 0x120000)
        case .nextTab: return Shortcut(30, 0x120000)
        case .previousTab: return Shortcut(33, 0x120000)
        case .find: return Shortcut(3, 0x100000)
        case .cut: return Shortcut(7, 0x100000)
        case .copy: return Shortcut(8, 0x100000)
        case .paste: return Shortcut(9, 0x100000)
        case .selectAll: return Shortcut(0, 0x100000)
        case .undo: return Shortcut(6, 0x100000)
        case .redo: return Shortcut(6, 0x120000)
        case .save: return Shortcut(1, 0x100000)
        case .hideApp: return Shortcut(4, 0x100000)
        case .minimizeWindow: return Shortcut(46, 0x100000)
        case .quitApp: return Shortcut(12, 0x100000)
        case .fullScreen: return Shortcut(3, 0x140000)
        case .showDesktop: return Shortcut(103)
        case .appWindows: return Shortcut(125, 0x40000)
        case .screenshot: return Shortcut(21, 0x120000)
        default: return nil
        }
    }
}

public struct Rule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var kind: TriggerKind
    public var triggerKey: Shortcut?
    public var mouseButton: Int // CGEvent numbering: right=1, middle=2, side4=3, side5=4.
    public var points: [StrokePoint]
    public var shapeName: String
    public var action: ActionKind
    public var outputKey: Shortcut?
    public var appPath: String
    public var linkAddress: String?
    public var fileOrFolderPath: String?
    public var bundleID: String // empty = all apps
    public var note: String
    public var needsReview: Bool
    public var storedClickCount: Int?
    public var showsName: Bool?
    public var scopeName: String?
    public var clickCount: Int {
        get { storedClickCount ?? 1 }
        set { storedClickCount = newValue }
    }

    public init(name: String = L10n.text("新规则"), kind: TriggerKind = .keyboard,
                key: Shortcut? = nil, button: Int = 1,
                points: [StrokePoint] = [], shapeName: String = "",
                action: ActionKind = .shortcut, output: Shortcut? = nil,
                bundleID: String = "", enabled: Bool = true, note: String = "", needsReview: Bool = false) {
        id = UUID(); self.name = name; self.kind = kind; triggerKey = key; mouseButton = button
        self.points = points; self.shapeName = shapeName; self.action = action; outputKey = output
        appPath = ""; self.bundleID = bundleID; self.enabled = enabled; self.note = note; self.needsReview = needsReview
    }
    public var triggerDescription: String {
        switch kind {
        case .keyboard: return triggerKey?.display ?? L10n.text("未录入")
        case .click: return "\(Self.buttonName(mouseButton)) · \(clickCount == 2 ? L10n.text("双击") : L10n.text("单击"))"
        case .gesture: return "\(Self.buttonName(mouseButton)) · \(ShapePreset(rawValue: shapeName)?.title ?? L10n.text("手绘轨迹"))"
        }
    }
    public var displayName: String {
        // Keep user-defined names; only relabel the old names of these two built-in actions.
        if action == .nextDesktop && ["下一个桌面", "Next Desktop"].contains(name) { return action.title }
        if action == .previousDesktop && ["上一个桌面", "Previous Desktop"].contains(name) { return action.title }
        return name
    }
    public var shortcutToSend: Shortcut? { action == .shortcut ? outputKey : action.standardShortcut }
    public static func webURL(_ input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil else { return nil }
        return components.url
    }
    public var locationToOpen: URL? {
        switch action {
        case .openLink: return Self.webURL(linkAddress ?? "")
        case .openFileOrFolder:
            guard let path = fileOrFolderPath, path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
            return URL(fileURLWithPath: path)
        default: return nil
        }
    }
    public var actionDescription: String {
        if action == .shortcut { return outputKey?.display ?? L10n.text("未录入") }
        if action == .openApplication, !appPath.isEmpty { return URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent }
        if action == .openLink, let host = locationToOpen?.host { return host }
        if action == .openFileOrFolder, let url = locationToOpen { return url.lastPathComponent }
        return action.title
    }
    public static func buttonName(_ n: Int) -> String {
        switch n { case 0: return L10n.text("选择按键"); case 1: return L10n.text("右键"); case 2: return L10n.text("中键"); default: return L10n.text("第 %1$@ 键", "\(n + 1)") }
    }
    public var validationError: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return L10n.text("请填写规则名称。") }
        if needsReview { return L10n.text("此规则来自旧版不支持的导入格式。") }
        if kind == .keyboard && triggerKey == nil { return L10n.text("请录入触发快捷键。") }
        if kind == .keyboard && triggerKey?.isSafeTrigger != true { return L10n.text("请使用修饰键组合或功能键。") }
        if kind != .keyboard && !(1...7).contains(mouseButton) { return L10n.text("请选择右键、中键或侧键。") }
        if kind == .gesture && Shape.normalize(points) == nil { return L10n.text("请绘制轨迹。") }
        if kind == .click && !(1...2).contains(clickCount) { return L10n.text("请选择单击或双击。") }
        if action == .unassigned { return L10n.text("请选择执行动作。") }
        if action == .shortcut && outputKey == nil { return L10n.text("请录入要发送的快捷键。") }
        if action == .openApplication && appPath.isEmpty { return L10n.text("请选择要打开的应用。") }
        if action == .openLink && locationToOpen == nil { return L10n.text("请输入完整的 http:// 或 https:// 链接。") }
        if action == .openFileOrFolder && locationToOpen == nil { return L10n.text("请选择要打开的文件或文件夹。") }
        if !bundleID.isEmpty && !bundleID.contains(".") { return L10n.text("应用范围需要有效的 bundle ID。") }
        return nil
    }
}

public struct TrailStyle: Codable, Equatable, Sendable {
    public static let widthRange = 1.0...10.0
    public var red = 0.478, green = 0.654, blue = 1.0, width = 3.0
    public init() {}
    // Keep old files with 11–12 pt readable. Rendering uses the new limit.
    public var isValid: Bool { [red, green, blue].allSatisfy { (0...1).contains($0) } && (1...12).contains(width) }
}

public enum IconLocation: String, Codable, CaseIterable, Sendable {
    case dock, menuBar, hidden
    public var title: String {
        switch self { case .dock: return L10n.text("程序坞"); case .menuBar: return L10n.text("菜单栏"); case .hidden: return L10n.text("都不显示") }
    }
}

public enum AppAppearance: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}

public struct Configuration: Codable, Equatable, Sendable {
    public var version = 1
    public var rules: [Rule]
    public var showTrail = true
    public var storedTrailStyle: TrailStyle?
    public var storedIconLocation: IconLocation?
    public var storedAppearance: AppAppearance?
    public var appearance: AppAppearance {
        get { storedAppearance ?? .system }
        set { storedAppearance = newValue == .system ? nil : newValue }
    }
    public var iconLocation: IconLocation {
        get { storedIconLocation ?? .menuBar }
        set { storedIconLocation = newValue == .menuBar ? nil : newValue }
    }
    public var trailStyle: TrailStyle {
        get {
            var style = storedTrailStyle ?? TrailStyle()
            if style.isValid { style.width = min(style.width, TrailStyle.widthRange.upperBound) }
            return style
        }
        set { storedTrailStyle = newValue }
    }
    public init(rules: [Rule] = []) { self.rules = rules }
    public mutating func removeLegacyPlaceholders() { rules.removeAll(where: \.needsReview) }
    public mutating func addDefaultRightClickIfMissing() {
        guard !rules.contains(where: { $0.kind == .click && $0.mouseButton == 1 && $0.bundleID.isEmpty }) else { return }
        rules.append(Rule(name: L10n.text("调度中心"), kind: .click, action: .missionControl))
    }
    public func validate() throws {
        guard version == 1, rules.count <= 500, Set(rules.map(\.id)).count == rules.count else {
            throw ConfigError.invalid(L10n.text("配置版本不支持、规则过多或 ID 重复。"))
        }
        guard (storedTrailStyle ?? TrailStyle()).isValid else { throw ConfigError.invalid(L10n.text("轨迹颜色或粗细无效。")) }
        for rule in rules {
            guard rule.points.count <= 4096, rule.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  (rule.triggerKey?.modifiers ?? 0) & ~Shortcut.mask == 0,
                  (rule.outputKey?.modifiers ?? 0) & ~Shortcut.mask == 0 else {
                throw ConfigError.invalid(L10n.text("配置中包含无效轨迹或修饰键。"))
            }
        }
    }
    public static var defaults: Self {
        var rules: [Rule] = zip([UInt16(18),19,20,21], [ActionKind.pageBack,.pageForward,.pageTop,.pageBottom]).map {
            Rule(name: $1.title, key: Shortcut($0, 0x40000), action: $1)
        }
        rules.append(Rule(name: L10n.text("关闭当前标签或窗口"), kind: .gesture, points: Shape.preset(.upRight), shapeName: "↗", output: Shortcut(13, 0x100000)))
        rules.append(Rule(name: L10n.text("退出当前应用"), kind: .gesture, points: Shape.preset(.v), shapeName: "V", output: Shortcut(12, 0x100000)))
        rules.append(Rule(name: ActionKind.nextDesktop.title, kind: .gesture, points: Shape.preset(.right), shapeName: "→", action: .nextDesktop))
        rules.append(Rule(name: ActionKind.previousDesktop.title, kind: .gesture, points: Shape.preset(.left), shapeName: "←", action: .previousDesktop))
        rules.append(Rule(name: L10n.text("复制"), kind: .click, button: 4, output: Shortcut(8, 0x100000)))
        rules.append(Rule(name: L10n.text("粘贴"), kind: .click, button: 3, output: Shortcut(9, 0x100000)))
        var config = Self(rules: rules)
        config.addDefaultRightClickIfMissing()
        return config
    }
}

public enum ConfigError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let s): return s } }
}

public enum RuleResolver {
    /// Sort the library without changing the stored order or the order used for recognition.
    public static func libraryOrder(_ rules: [Rule], keyboard: Bool) -> [Rule] {
        rules.enumerated().filter { ($0.element.kind == .keyboard) == keyboard }.sorted { a, b in
            if keyboard {
                let aKey = a.element.triggerKey, bKey = b.element.triggerKey
                let aModifiers = aKey?.modifiers ?? .max, bModifiers = bKey?.modifiers ?? .max
                if aModifiers != bModifiers { return aModifiers < bModifiers }
                let keys = (aKey?.display ?? "").localizedStandardCompare(bKey?.display ?? "")
                if keys != .orderedSame { return keys == .orderedAscending }
            } else if a.element.mouseButton != b.element.mouseButton {
                return a.element.mouseButton < b.element.mouseButton
            }
            return a.offset < b.offset
        }.map(\.element)
    }
    /// Exact app rules replace equivalent global triggers, including explicit block rules.
    public static func scoped(_ rules: [Rule], bundleID: String) -> [Rule] {
        let active = rules.filter { $0.enabled && $0.validationError == nil && ($0.bundleID.isEmpty || $0.bundleID == bundleID) }
        let local = active.filter { !$0.bundleID.isEmpty }
        return local + active.filter { global in
            global.bundleID.isEmpty && !local.contains { sameTrigger($0, global) }
        }
    }
    public static func sameTrigger(_ a: Rule, _ b: Rule) -> Bool {
        guard a.kind == b.kind else { return false }
        switch a.kind {
        case .keyboard: return a.triggerKey == b.triggerKey
        case .click: return a.mouseButton == b.mouseButton && a.clickCount == b.clickCount
        case .gesture: return a.mouseButton == b.mouseButton && (a.points == b.points || ShapePreset.allCases.contains { $0.rawValue == a.shapeName && $0.rawValue == b.shapeName })
        }
    }
    public static func conflicts(_ rules: [Rule]) -> [String] {
        let active = rules.filter { $0.enabled && $0.validationError == nil }
        var result: [String] = []
        for i in active.indices {
            for j in active.indices where j > i && active[i].bundleID == active[j].bundleID {
                if sameTrigger(active[i], active[j]) { result.append(L10n.text("「%1$@」和「%2$@」使用相同触发方式。", "\(active[i].name)", "\(active[j].name)")) }
            }
        }
        return result
    }
}
