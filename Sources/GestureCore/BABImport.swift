import Foundation

public struct BABImportResult {
    public var configuration: Configuration
    public var warnings: [String]
}

public enum BABImport {
    public static func read(_ data: Data) throws -> BABImportResult {
        guard data.count <= 4_000_000 else { throw ConfigError.invalid(L10n.text("预设文件超过 4 MB。")) }
        let allowed: [AnyClass] = [NSDictionary.self, NSMutableDictionary.self, NSArray.self, NSMutableArray.self,
                                  NSString.self, NSNumber.self, NSDate.self, NSData.self]
        guard let root = try NSKeyedUnarchiver.unarchivedObject(ofClasses: allowed, from: data) as? [String: Any] else {
            throw ConfigError.invalid(L10n.text("不是支持的 BetterAndBetter 预设。"))
        }
        var rules: [Rule] = []
        var warnings: [String] = []
        var skipped = 0
        var visited = 0
        for groupKey in ["ruleOfKeyboard", "ruleOfNormalMouse"] {
            for group in root[groupKey] as? [[String: Any]] ?? [] {
                let app = group["AppName"] as? String ?? "All Applications"
                let scope = app == "All Applications" ? "" : app
                for raw in group["All Rules"] as? [[String: Any]] ?? [] {
                    visited += 1
                    guard visited <= 500 else { throw ConfigError.invalid(L10n.text("预设规则超过 500 条。")) }
                    var rule = Rule(bundleID: scope)
                    rule.enabled = String(describing: raw["Enable"] ?? "0") == "1"
                    if groupKey == "ruleOfKeyboard", let g = raw["Gesture"] as? [String: Any],
                       let code = g["keyCode"] as? NSNumber, (0...65535).contains(code.intValue) {
                        rule.kind = .keyboard
                        rule.triggerKey = Shortcut(code.uint16Value, (g["modifierFlags"] as? NSNumber)?.uint64Value ?? 0)
                    } else if groupKey == "ruleOfNormalMouse", let gesture = raw["Gesture"] as? String {
                        rule.kind = .gesture
                        let parts = gesture.components(separatedBy: "Of")
                        guard parts.count == 2, parts[1].hasSuffix("Key"),
                              let number = Int(parts[1].dropLast(3)), (2...8).contains(number) else { skipped += 1; continue }
                        rule.mouseButton = number - 1
                        let symbol = parts[0].trimmingCharacters(in: .whitespaces)
                        rule.shapeName = symbol
                        if symbol == "Click" { rule.kind = .click }
                        else if let preset = ShapePreset(rawValue: symbol) { rule.points = Shape.preset(preset) }
                        else { skipped += 1; continue }
                    } else { skipped += 1; continue }
                    let action = raw["Action"] as? [String: Any] ?? [:]
                    let type = action["ActionType"] as? String ?? ""
                    if type == "Shortcut Keys", let key = action["Action"] as? [String: Any],
                       let code = key["keyCode"] as? NSNumber, (0...65535).contains(code.intValue) {
                        rule.action = .shortcut
                        rule.outputKey = Shortcut(code.uint16Value, (key["modifierFlags"] as? NSNumber)?.uint64Value ?? 0)
                    } else if type == "Preset", let name = action["Action"] as? String {
                        let mapping: [String: ActionKind] = ["Page Back": .pageBack, "Page Forward": .pageForward,
                            "Page Top": .pageTop, "Page Bottom": .pageBottom, "Mission Control": .missionControl,
                            "Next Desktop": .nextDesktop, "Previous Desktop": .previousDesktop, "Open...": .openApplication]
                        if let kind = mapping[name] {
                            rule.action = kind
                            if kind == .openApplication { rule.appPath = (action["OpenArr"] as? [String])?.first ?? "" }
                        } else { skipped += 1; continue }
                    } else { skipped += 1; continue }
                    let note = (raw["Note"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    rule.name = !note.isEmpty ? note : (rule.action == .shortcut ? rule.actionDescription : rule.action.title)
                    guard rule.validationError == nil else { skipped += 1; continue }
                    rules.append(rule)
                }
            }
        }
        guard !rules.isEmpty else { throw ConfigError.invalid(L10n.text("预设中没有支持的键盘或普通鼠标规则。")) }
        for key in ["ruleOfMagicMouse", "ruleOfTrackPad", "ruleOfHotCorners"] {
            let count = (root[key] as? [[String: Any]] ?? []).reduce(0) { $0 + (($1["All Rules"] as? [Any])?.count ?? 0) }
            if count > 0 { warnings.append(L10n.text("%1$@ 中的 %2$@ 条规则未导入，当前仅支持键盘和普通鼠标。", "\(key)", "\(count)")) }
        }
        if skipped > 0 { warnings.append(L10n.text("已跳过 %1$@ 条不支持的规则。", "\(skipped)")) }
        var config = Configuration(rules: rules)
        config.showTrail = root["displayTrackOfDrawing"] as? Bool ?? true
        try config.validate()
        return BABImportResult(configuration: config, warnings: warnings)
    }
}
