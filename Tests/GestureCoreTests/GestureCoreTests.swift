import Foundation
import Carbon
import GestureCore

// Standalone assertion helpers: this machine has Command Line Tools, not XCTest.
private func XCTFail(_ message: String = "Assertion failed", file: StaticString = #filePath, line: UInt = #line) -> Never {
    fputs("FAIL \(file):\(line): \(message)\n", stderr); exit(1)
}
private func XCTAssertTrue(_ value: @autoclosure () -> Bool) { if !value() { XCTFail("Expected true") } }
private func XCTAssertFalse(_ value: @autoclosure () -> Bool) { if value() { XCTFail("Expected false") } }
private func XCTAssertNil<T>(_ value: T?) { if value != nil { XCTFail("Expected nil") } }
private func XCTAssertNotNil<T>(_ value: T?) { if value == nil { XCTFail("Expected non-nil") } }
private func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T) { if a != b { XCTFail("\(a) != \(b)") } }
private func XCTAssertEqual(_ a: Double, _ b: Double, accuracy: Double) { if abs(a - b) > accuracy { XCTFail("\(a) != \(b)") } }
private func XCTAssertGreaterThan(_ a: Double, _ b: Double) { if !(a > b) { XCTFail("\(a) <= \(b)") } }
private func XCTAssertLessThan(_ a: Double, _ b: Double) { if !(a < b) { XCTFail("\(a) >= \(b)") } }
private func XCTAssertThrowsError(_ expression: @autoclosure () throws -> Void) {
    do { try expression(); XCTFail("Expected an error") } catch {}
}
private struct XCTSkip: Error { let message: String; init(_ message: String) { self.message = message } }

@main
struct CoreChecks {
    @MainActor static func main() throws {
        let suite = GestureCoreTests()
        let checks: [(String, () throws -> Void)] = [
            ("modifier normalization", suite.testModifiersDropDeviceBits),
            ("safe keyboard triggers", suite.testPlainTypingCannotBeRegistered),
            ("64-point sampling", suite.testNormalizationProduces64Points),
            ("translation and scale", suite.testTranslationAndScaleDoNotChangeShape),
            ("thumbnail fits wide, tall and custom strokes", suite.testThumbnail),
            ("direction discrimination", suite.testDirectionsRemainDistinct),
            ("all preset shapes", suite.testPresetsRecognizeWithoutCrossMatches),
            ("noisy V", suite.testJitteredVMatchesV),
            ("ambiguous rejection", suite.testAmbiguousShapesDoNotExecute),
            ("rejection diagnostics use ranked distances and thresholds", suite.testRecognitionDiagnostics),
            ("invalid paths", suite.testShortAndNonFinitePathsRejected),
            ("app override", suite.testAppOverrideBlocksGlobal),
            ("disabled and unreviewed rules", suite.testDisabledAndReviewRulesExcluded),
            ("conflict detection", suite.testDuplicateHotkeysDetectedButDifferentScopesAllowed),
            ("indexed keyboard, mouse and gesture bindings", suite.testRuleIndex),
            ("config round trip", suite.testConfigurationRoundTripAndDuplicateIDs),
            ("click/drag and timeout", suite.testStrokeDistinguishesClickAndDragAndBoundsDuration),
            ("BAB importer skips unsupported rules", suite.testBABImportKnownKeyboardAndUnknownShape),
            ("default right-click stays native; upward gesture opens Mission Control", suite.testDefaultMissionControl),
            ("legacy placeholder migration", suite.testLegacyMigration),
            ("dated rollover backup", suite.testBackup),
            ("diagnostic log rotation and JSON lines", suite.testDiagnostics),
            ("legacy dated backup migration", suite.testLegacyBackup),
            ("trail cap and icon location compatibility", suite.testPreferences),
            ("appearance compatibility and round trip", suite.testAppearance),
            ("app language preference is independent of system languages", suite.testAppLanguage),
            ("Space defaults, legacy actions and custom system shortcuts", suite.testSpaceShortcuts),
            ("single and double click scope", suite.testClickScopes),
            ("rule library order", suite.testLibraryOrder),
            ("blank rules and preset coverage", suite.testBlankRulesAndActions),
            ("opening links, files and folders", suite.testOpenLocations),
            ("scoped freehand overrides, same-scope ambiguity", suite.testFreehandOverride),
            ("scoped hotkey failure lifetime", suite.testHotKeyFailures),
            ("German and US physical key labels", suite.testLayoutLabels),
            ("export discards inactive targets only", suite.testExportTargets),
            ("large native export restores; foreign limits remain", suite.testLargeExport),
            ("actual user export", suite.testActualUserExportWhenSupplied)
        ]
        var passed = 0
        for (name, check) in checks {
            do { try check(); passed += 1; print("PASS \(name)") }
            catch let skip as XCTSkip { print("SKIP \(name): \(skip.message)") }
        }
        print("\(passed)/\(checks.count) checks passed")
    }
}

final class GestureCoreTests {
    func testAppLanguage() throws {
        let domain = "GestureKeys-Check-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domain) else { XCTFail("Cannot create test preferences") }
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(["en-US"], forKey: "AppleLanguages")
        XCTAssertEqual(AppLanguage.load(from: defaults), .simplifiedChinese)
        XCTAssertEqual(AppLanguage.allCases, [.simplifiedChinese, .english])
        for language in AppLanguage.allCases.reversed() {
            language.save(to: defaults)
            XCTAssertEqual(AppLanguage.load(from: defaults), language)
            XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en-US"])
        }
    }
    func testModifiersDropDeviceBits() {
        XCTAssertEqual(Shortcut(18, 270592), Shortcut(18, 0x40000))
        XCTAssertEqual(Shortcut(18, 270592).display, "⌃1")
    }
    @MainActor func testLayoutLabels() throws {
        // Read installed layouts (including disabled ones); never select an input source.
        func layout(_ name: String) throws -> TISInputSource {
            let filter = [kTISPropertyInputSourceID as String: "com.apple.keylayout.\(name)"] as CFDictionary
            let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]
            guard let source = sources?.first else { throw XCTSkip("Layout not installed: \(name)") }
            return source
        }
        let keys = [Shortcut(6, 0x100000), Shortcut(16, 0x100000)]
        defer { KeyboardLayoutLabels.refresh() }
        KeyboardLayoutLabels.refresh(from: try layout("German"))
        XCTAssertEqual(keys.map(\.display), ["⌘Y", "⌘Z"])
        XCTAssertEqual(Shortcut(123, 0x40000).display, "⌃←")
        KeyboardLayoutLabels.refresh(from: try layout("US"))
        XCTAssertEqual(keys.map(\.display), ["⌘Z", "⌘Y"])
        XCTAssertEqual(keys.map(\.keyCode), [6, 16])
    }
    func testPlainTypingCannotBeRegistered() {
        XCTAssertNotNil(Rule(key: Shortcut(0)).validationError)
        XCTAssertNil(Rule(key: Shortcut(122), action: .copy).validationError)
    }
    func testNormalizationProduces64Points() {
        let p = Shape.normalize(Shape.preset(.v))
        XCTAssertEqual(p?.count, 64)
        XCTAssertEqual(p!.reduce(0) { $0 + $1.x }, 0, accuracy: 0.000001)
    }
    func testTranslationAndScaleDoNotChangeShape() {
        let original = Shape.preset(.c)
        let moved = original.map { StrokePoint($0.x * 3 + 741, $0.y * 3 - 951) }
        XCTAssertLessThan(Shape.distance(Shape.normalize(original)!, Shape.normalize(moved)!), 0.000001)
    }
    func testDirectionsRemainDistinct() {
        let a = Shape.normalize(Shape.preset(.left))!, b = Shape.normalize(Shape.preset(.right))!
        XCTAssertGreaterThan(Shape.distance(a, b), 0.4)
    }
    func testPresetsRecognizeWithoutCrossMatches() {
        let rules = ShapePreset.allCases.map { Rule(name: $0.rawValue, kind: .gesture, points: Shape.preset($0), shapeName: $0.rawValue) }
        for (i, preset) in ShapePreset.allCases.enumerated() {
            guard case .matched(let id, _) = Shape.recognize(Shape.preset(preset), rules: rules) else {
                XCTFail("Failed preset \(preset)")
            }
            XCTAssertEqual(id, rules[i].id)
        }
    }
    func testThumbnail() {
        func fit(_ points: [StrokePoint]) -> [StrokePoint] { Shape.thumbnail(points, width: 48, height: 24, padding: 5) }
        let line = fit([StrokePoint(440, 173), StrokePoint(0, 173)])
        XCTAssertEqual(line, [StrokePoint(43, 12), StrokePoint(5, 12)])
        let compressed = Shape.thumbnail([StrokePoint(440, 173), StrokePoint(0, 173)], width: 48, height: 24, padding: 5, maxWidthToHeightRatio: 2)
        XCTAssertEqual(compressed.count, 2)
        XCTAssertTrue(compressed[0].x - compressed[1].x < 26)
        XCTAssertEqual(compressed.map(\.y), [12, 12])
        XCTAssertEqual(fit([StrokePoint(220, 0), StrokePoint(220, 175)]), [StrokePoint(24, 5), StrokePoint(24, 19)])
        let seven = [StrokePoint(8, 30), StrokePoint(86, 30), StrokePoint(44, 108)]
        let preview = fit(seven)
        XCTAssertEqual(preview.count, seven.count)
        XCTAssertEqual(preview[1].x - preview[0].x, preview[2].y - preview[1].y)
        XCTAssertTrue(fit([StrokePoint(1, 1), StrokePoint(1, 1)]).isEmpty)
        XCTAssertTrue(fit([StrokePoint(0, 0), StrokePoint(.infinity, 1)]).isEmpty)
    }
    func testJitteredVMatchesV() {
        let v = Rule(kind: .gesture, points: Shape.preset(.v))
        let noisy = Shape.normalize(Shape.preset(.v))!.enumerated().map { i, p in
            StrokePoint(p.x * 140 + (i % 2 == 0 ? 1 : -1), p.y * 140 + (i % 3 == 0 ? 1 : -1))
        }
        guard case .matched(let id, _) = Shape.recognize(noisy, rules: [v]) else { XCTFail() }
        XCTAssertEqual(id, v.id)
    }
    func testAmbiguousShapesDoNotExecute() {
        let a = Rule(kind: .gesture, points: Shape.preset(.upRight))
        let b = Rule(kind: .gesture, points: Shape.preset(.upRight))
        XCTAssertEqual(Shape.recognize(Shape.preset(.upRight), rules: [a,b]), .ambiguous)
    }
    func testShortAndNonFinitePathsRejected() {
        XCTAssertNil(Shape.normalize([StrokePoint(0,0), StrokePoint(1,1)]))
        XCTAssertNil(Shape.normalize([StrokePoint(.infinity,0), StrokePoint(100,0)]))
        XCTAssertNil(Shape.normalize(Array(repeating: StrokePoint(0,0), count: 5000)))
    }
    func testAppOverrideBlocksGlobal() {
        let global = Rule(name: "Global", key: Shortcut(18,0x40000), action: .pageBack)
        let block = Rule(name: "Finder", key: global.triggerKey, action: .block, bundleID: "com.apple.finder")
        XCTAssertEqual(RuleResolver.scoped([global,block], bundleID: "com.apple.finder").map(\.id), [block.id])
        XCTAssertEqual(RuleResolver.scoped([global,block], bundleID: "com.apple.Safari").map(\.id), [global.id])
    }
    func testFreehandOverride() {
        let up = Shape.preset(.up), freehand = [StrokePoint(35,105), StrokePoint(36,70), StrokePoint(35,20)]
        let global = Rule(kind: .gesture, points: up, shapeName: "↑", action: .missionControl)
        var local = Rule(kind: .gesture, points: freehand, action: .copy, bundleID: "com.apple.Safari")
        func match(_ points: [StrokePoint], _ rules: [Rule], in app: String) -> Shape.Match {
            let expected = Shape.recognize(points, rules: RuleResolver.scoped(rules, bundleID: app))
            let scoped = RuleIndex(rules).scoped(to: app)
            let actual = Shape.recognize(points, templates: scoped.mouseBindings(for: 1).templates).match
            XCTAssertEqual(actual, expected)
            return actual
        }
        for preset in [false, true] {
            if preset { local.points = up; local.shapeName = "↑" }
            for drawn in [up, freehand] {
                guard case .matched(let a, _) = match(drawn, [global, local], in: local.bundleID),
                      case .matched(let b, _) = match(drawn, [global, local], in: "com.apple.finder") else { XCTFail("Missing override") }
                XCTAssertEqual(a, local.id); XCTAssertEqual(b, global.id)
            }
        }
        var other = local; other.id = UUID(); other.points = freehand; other.shapeName = ""
        XCTAssertEqual(match(freehand, [local, other, global], in: local.bundleID), .ambiguous)
        // Midway between two *distinct* directions is not a reason to pick the scoped rule.
        other.points = [StrokePoint(0,100), StrokePoint(30,0)]
        XCTAssertEqual(match([StrokePoint(0,100), StrokePoint(15,0)], [global, other], in: local.bundleID), .ambiguous)
    }
    func testRuleIndex() {
        let safari = "com.apple.Safari", finder = "com.apple.finder"
        let key = Shortcut(18, 0x40000)
        let global = Rule(key: key, action: .copy)
        let override = Rule(key: key, action: .block, bundleID: safari)
        let other = Rule(key: Shortcut(19, 0x40000), action: .paste, bundleID: finder)
        let click = Rule(kind: .click, button: 3, action: .copy)
        var double = Rule(kind: .click, button: 3, action: .paste, bundleID: safari)
        double.clickCount = 2
        let stroke = Rule(kind: .gesture, button: 3, points: Shape.preset(.up), action: .copy)
        let invalid = Rule(kind: .gesture, button: 3, action: .copy)
        let disabled = Rule(key: key, action: .paste, enabled: false)
        let rules = [global, click, other, stroke, double, override, invalid, disabled]
        let index = RuleIndex(rules)
        XCTAssertTrue(index.hasEnabledRules)
        XCTAssertFalse(index.hasConflicts)
        XCTAssertEqual(index.activeKeyboardRules, [global, other, override])
        for app in ["", safari, finder, "example.Other"] {
            let scope = index.scoped(to: app)
            let expected = RuleResolver.scoped(rules, bundleID: app)
            let keys = expected.filter { $0.kind == .keyboard }
            XCTAssertEqual(scope.keyboardRules, keys)
            XCTAssertEqual(scope.shortcuts, Set(keys.compactMap(\.triggerKey)))
            XCTAssertEqual(scope.keyboardRule(for: key), keys.first { $0.triggerKey == key })
            for button in 1...7 {
                let mouse = expected.filter { $0.kind != .keyboard && $0.mouseButton == button }
                let bindings = scope.mouseBindings(for: button)
                XCTAssertEqual(bindings.count, mouse.count)
                XCTAssertEqual(bindings.singleClick, mouse.first { $0.kind == .click && $0.clickCount == 1 })
                XCTAssertEqual(bindings.doubleClick, mouse.first { $0.kind == .click && $0.clickCount == 2 })
                XCTAssertEqual(bindings.templates.map(\.rule), mouse.filter { $0.kind == .gesture })
            }
        }
        XCTAssertFalse(RuleIndex([invalid, disabled]).hasEnabledRules)
        let duplicate = Rule(key: key, action: .paste)
        XCTAssertTrue(RuleIndex(rules + [duplicate]).hasConflicts)
        let duplicateClick = Rule(kind: .click, button: 3, action: .undo)
        let conflicting = RuleIndex([stroke, click, duplicateClick])
        let bindings = conflicting.scoped(to: safari).mouseBindings(for: 3)
        XCTAssertTrue(conflicting.hasConflicts)
        XCTAssertEqual(bindings.count, 3)
        XCTAssertEqual(bindings.singleClick, click)
        let oldScope = index.scoped(to: safari)
        XCTAssertEqual(RuleIndex([global]).scoped(to: safari).keyboardRule(for: key), global)
        XCTAssertEqual(oldScope.keyboardRule(for: key), override)
    }
    func testHotKeyFailures() {
        let safari = "com.apple.Safari", one = Shortcut(18, 0x40000), two = Shortcut(19, 0x40000)
        let a = Rule(key: one, action: .copy, bundleID: safari), b = Rule(key: two, action: .paste, bundleID: safari)
        let finder = Rule(key: two, action: .copy, bundleID: "com.apple.finder"), rules = [a,b,finder]
        var failures = HotKeyFailures()
        failures.update(rules: rules, attempted: [a,b], rejected: [one,two])
        failures.update(rules: rules, attempted: [], rejected: [])  // return to settings
        failures.update(rules: rules, attempted: [finder], rejected: [])
        XCTAssertEqual(failures.shortcuts, [one,two])
        failures.update(rules: rules, attempted: [a,b], rejected: [two])  // real retry of a
        XCTAssertEqual(failures.shortcuts, [two])
        var disabled = b; disabled.enabled = false
        failures.update(rules: [a,disabled,finder], attempted: [], rejected: [])
        XCTAssertTrue(failures.shortcuts.isEmpty)
        failures.update(rules: rules, attempted: [b], rejected: [two])
        failures.update(rules: [a,finder], attempted: [], rejected: [])  // deleted
        XCTAssertTrue(failures.shortcuts.isEmpty)
    }
    func testDisabledAndReviewRulesExcluded() {
        var rule = Rule(key: Shortcut(18,0x40000), action: .pageBack); rule.needsReview = true
        XCTAssertTrue(RuleResolver.scoped([rule], bundleID: "app").isEmpty)
        rule.needsReview = false; rule.enabled = false
        XCTAssertTrue(RuleResolver.scoped([rule], bundleID: "app").isEmpty)
    }
    func testDuplicateHotkeysDetectedButDifferentScopesAllowed() {
        let a = Rule(key: Shortcut(18,0x40000), action: .pageBack), b = Rule(key: Shortcut(18,0x40000), action: .copy)
        XCTAssertEqual(RuleResolver.conflicts([a,b]).count, 1)
        var scoped = b; scoped.bundleID = "com.apple.finder"
        XCTAssertTrue(RuleResolver.conflicts([a,scoped]).isEmpty)
    }
    func testConfigurationRoundTripAndDuplicateIDs() throws {
        let initial = Configuration.defaults
        let data = try JSONEncoder().encode(initial)
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: data), initial)
        try initial.validate()
        var duplicate = initial; duplicate.rules.append(duplicate.rules[0])
        XCTAssertThrowsError(try duplicate.validate())
    }
    func testStrokeDistinguishesClickAndDragAndBoundsDuration() {
        var session = StrokeSession(start: StrokePoint(0,0), time: 0)
        for i in 0..<8 { XCTAssertTrue(session.append(StrokePoint(i.isMultiple(of: 2) ? 1 : -1, 0), time: 0.01 * Double(i))) }
        XCTAssertTrue(session.append(StrokePoint(2,0), time: 0.1)); XCTAssertFalse(session.isDrag)
        XCTAssertTrue(session.append(StrokePoint(40,0), time: 0.2)); XCTAssertTrue(session.isDrag)
        XCTAssertTrue(session.append(StrokePoint(0,0), time: 0.3)); XCTAssertTrue(session.isDrag)
        XCTAssertFalse(session.append(StrokePoint(80,0), time: 11))
    }
    func testBABImportKnownKeyboardAndUnknownShape() throws {
        let root: [String:Any] = ["ruleOfKeyboard": [["AppName":"All Applications", "All Rules":[
            ["Enable":"1", "Gesture":["keyCode":18, "modifierFlags":270592], "Action":["ActionType":"Preset", "Action":"Page Back"]]
        ]]], "ruleOfNormalMouse": [["AppName":"All Applications", "All Rules":[
            ["Enable":"1", "Gesture":" IOf2Key", "Action":["ActionType":"Preset", "Action":"Mission Control"]]
        ]]]]
        let data = try NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: true)
        let result = try BABImport.read(data)
        XCTAssertEqual(result.configuration.rules.count, 1)
        XCTAssertEqual(result.configuration.rules[0].triggerKey, Shortcut(18, 0x40000))
        XCTAssertEqual(result.configuration.rules[0].action, .pageBack)
        XCTAssertEqual(result.warnings, [L10n.text("已跳过 %1$@ 条不支持的规则。", "1")])
    }
    func testDefaultMissionControl() {
        let rules = RuleResolver.scoped(Configuration.defaults.rules, bundleID: "com.apple.finder").filter { $0.mouseButton == 1 }
        XCTAssertFalse(rules.contains { $0.kind == .click })
        guard case .matched(let id, _) = Shape.recognize([StrokePoint(20, 90), StrokePoint(20, 10)], rules: rules.filter { $0.kind == .gesture }) else { XCTFail("Upward gesture did not match") }
        XCTAssertEqual(rules.first { $0.id == id }?.action, .missionControl)
        let custom = Rule(kind: .gesture, points: Shape.preset(.up), action: .copy)
        var config = Configuration(rules: [custom]); config.addDefaultMissionControlGestureIfMissing()
        XCTAssertEqual(config.rules, [custom])
        var freehand = custom; freehand.points = [StrokePoint(35,105), StrokePoint(36,70), StrokePoint(35,20)]
        config = Configuration(rules: [freehand]); config.addDefaultMissionControlGestureIfMissing()
        XCTAssertEqual(config.rules, [freehand])  // migration must not make a user's own global ↑ ambiguous
        var full = Configuration(rules: (0..<Configuration.maxRules).map { Rule(name: "Rule \($0)", enabled: false) })
        full.addDefaultMissionControlGestureIfMissing(); XCTAssertEqual(full.rules.count, Configuration.maxRules)
    }
    func testLegacyMigration() {
        let kept = Rule(name: "User rule", enabled: false)
        let placeholder = Rule(name: "Old placeholder", kind: .gesture, enabled: false, needsReview: true)
        var config = Configuration(rules: [kept, placeholder])
        config.removeLegacyPlaceholders()
        config.addDefaultMissionControlGestureIfMissing()
        config.addDefaultMissionControlGestureIfMissing()
        XCTAssertEqual(config.rules.count, 2)
        XCTAssertEqual(config.rules[0], kept)
        XCTAssertEqual(config.rules[1].kind, .gesture)
        XCTAssertEqual(config.rules[1].points, Shape.preset(.up))
        XCTAssertEqual(config.rules[1].mouseButton, 1)
        XCTAssertEqual(config.rules[1].action, .missionControl)
        XCTAssertTrue(config.rules[1].enabled)
    }
    func testDiagnostics() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = DiagnosticLog(folder: folder, maxBytes: 880, archives: 2)
        for n in 0..<35 { log.record("test.line", ["n": String(n), "sample": "a\nb"]) }
        log.flush()
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.map(\.lastPathComponent).sorted(), ["GestureKeys.1.log", "GestureKeys.2.log", "GestureKeys.log"])
        var seen: [Int] = []
        for file in files.sorted(by: { a, b in
            let order = ["GestureKeys.2.log", "GestureKeys.1.log", "GestureKeys.log"]
            return order.firstIndex(of: a.lastPathComponent)! < order.firstIndex(of: b.lastPathComponent)!
        }) {
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
            let bytes = try Data(contentsOf: file)
            XCTAssertTrue(bytes.count <= 880)
            for line in bytes.split(separator: 0x0a) {
                let item = try JSONSerialization.jsonObject(with: Data(line)) as! [String: Any]
                XCTAssertEqual(item["session"] as? String, log.session)
                XCTAssertNotNil(item["time"] as? String)
                XCTAssertEqual(item["event"] as? String, "test.line")
                let fields = item["fields"] as! [String: String]
                XCTAssertEqual(fields["sample"], "a\nb")
                seen.append(Int(fields["n"]!)!)
            }
        }
        XCTAssertEqual(seen.last, 34)
        XCTAssertEqual(seen, Array((35 - seen.count)..<35))
    }
    func testBackup() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = ConfigStorage(folder.appendingPathComponent("config.json"))
        func backups() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("config-backup-") }
        }
        let first = Configuration.defaults
        try storage.save(first)
        let initially = try backups(); XCTAssertTrue(initially.isEmpty)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: storage.url.path)
        XCTAssertEqual(storage.savedAt, date)
        let expected = folder.appendingPathComponent(ConfigStorage.datedName("config-backup-", date: date))
        var second = first; second.showTrail = false
        try storage.save(second); try storage.save(second)
        XCTAssertEqual(try backups().map(\.lastPathComponent), [expected.lastPathComponent])
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: expected)), first)
        let manual = folder.appendingPathComponent("config-before-import-test.json")
        try Data().write(to: manual)
        var third = second; third.trailStyle.width = 7
        try storage.save(third)
        let remaining = try backups()
        XCTAssertEqual(remaining.count, 1)
        guard let backup = remaining.first else { throw CocoaError(.fileNoSuchFile) }
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: backup)), second)
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: storage.url)), third)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manual.path))
    }
    func testLegacyBackup() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = ConfigStorage(folder.appendingPathComponent("config.json"))
        try storage.save(Configuration.defaults)
        let legacy = folder.appendingPathComponent("config.previous.json")
        let bytes = try ConfigStorage.encode(Configuration(rules: []))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try bytes.write(to: legacy)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: legacy.path)
        try storage.migrateLegacyBackup(); try storage.migrateLegacyBackup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(ConfigStorage.datedName("config-backup-", date: date))), bytes)
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: storage.url)).rules.count, 11)
    }
    func testSpaceShortcuts() throws {
        let left = try JSONDecoder().decode(ActionKind.self, from: Data(#""previousDesktop""#.utf8))
        let right = try JSONDecoder().decode(ActionKind.self, from: Data(#""nextDesktop""#.utf8))
        XCTAssertEqual(left.standardShortcut, Shortcut(123, 0x40000))
        XCTAssertEqual(right.standardShortcut, Shortcut(124, 0x40000))
        XCTAssertTrue(left.switchesSpace && right.switchesSpace)
        let oldName = Rule(name: "上一个桌面", action: left)
        XCTAssertEqual(oldName.displayName, left.title)
        XCTAssertEqual(oldName.name, "上一个桌面")
        XCTAssertTrue(oldName.action.isSystemShortcut)
        XCTAssertEqual(Rule(name: "my rule", action: left).displayName, "my rule")
        let rule = Rule(name: "Custom previous Space", output: Shortcut(123, 0x20000))
        let data = try ConfigStorage.encode(Configuration(rules: [rule]))
        let saved = try JSONDecoder().decode(Configuration.self, from: data)
        XCTAssertTrue(saved.rules[0].action.isSystemShortcut)
        XCTAssertEqual(saved.rules[0].shortcutToSend, Shortcut(123, 0x20000))
        XCTAssertFalse(ActionKind.pageBack.isSystemShortcut)
    }
    func testAppearance() throws {
        let legacy = Data(#"{"version":1,"rules":[],"showTrail":true}"#.utf8)
        var config = try JSONDecoder().decode(Configuration.self, from: legacy)
        XCTAssertEqual(config.appearance, .system)
        XCTAssertNil(config.storedAppearance)
        for appearance in AppAppearance.allCases {
            config.appearance = appearance
            let saved = try JSONDecoder().decode(Configuration.self, from: ConfigStorage.encode(config))
            XCTAssertEqual(saved.appearance, appearance)
        }
        config.appearance = .system
        XCTAssertNil(config.storedAppearance)
    }
    func testPreferences() throws {
        var legacy = Configuration.defaults
        legacy.trailStyle.width = 12
        let decoded = try JSONDecoder().decode(Configuration.self, from: ConfigStorage.encode(legacy))
        XCTAssertEqual(decoded.trailStyle.width, 10)
        XCTAssertEqual(decoded.iconLocation, .menuBar)
        legacy.trailStyle.width = 13
        XCTAssertNil(try? legacy.validate())
        for location in IconLocation.allCases {
            var config = Configuration.defaults; config.iconLocation = location
            XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: ConfigStorage.encode(config)).iconLocation, location)
        }
    }
    func testClickScopes() {
        let single = Rule(kind: .click, action: .missionControl)
        var double = Rule(kind: .click, action: .closeTab); double.clickCount = 2
        var scoped = double; scoped.id = UUID(); scoped.bundleID = "com.apple.finder"
        XCTAssertTrue(RuleResolver.conflicts([single, double]).isEmpty)
        XCTAssertEqual(Set(RuleResolver.scoped([single, double, scoped], bundleID: scoped.bundleID).map(\.id)), Set([single.id, scoped.id]))
    }
    func testLibraryOrder() {
        let right = Rule(kind: .gesture, action: .copy)
        let side = Rule(kind: .click, button: 4, action: .paste)
        let middle = Rule(kind: .click, button: 2, action: .copy)
        let rightClick = Rule(kind: .click, action: .closeTab)
        let four = Rule(key: Shortcut(21, 0x40000), action: .pageBottom)
        let one = Rule(key: Shortcut(18, 0x40000), action: .pageBack)
        let commandOne = Rule(key: Shortcut(18, 0x100000), action: .openFinder)
        let rules = [side, right, commandOne, middle, four, rightClick, one]
        XCTAssertEqual(RuleResolver.libraryOrder(rules, keyboard: false).map(\.id), [right.id, rightClick.id, middle.id, side.id])
        XCTAssertEqual(RuleResolver.libraryOrder(rules, keyboard: true).map(\.id), [one.id, four.id, commandOne.id])
    }
    func testBlankRulesAndActions() {
        let rule = Rule(name: "", button: 0, action: .unassigned)
        XCTAssertTrue(rule.enabled); XCTAssertNil(rule.triggerKey); XCTAssertNil(rule.outputKey)
        XCTAssertTrue(rule.points.isEmpty); XCTAssertNotNil(rule.validationError)
        let groups = ActionKind.groups.flatMap { $0.1 }
        XCTAssertEqual(groups.count, Set(groups).count)
        let legacy: [ActionKind] = [.block, .appWindows, .screenshot]
        XCTAssertEqual(Set(groups + [.unassigned] + legacy), Set(ActionKind.allCases))
        for action in legacy {
            XCTAssertFalse(groups.contains(action))
            let fixtures = Configuration(rules: [Rule(kind: .click, action: action)])
            XCTAssertEqual(try? JSONDecoder().decode(Configuration.self, from: ConfigStorage.encode(fixtures)), fixtures)
            XCTAssertNil(fixtures.rules.first?.validationError)
        }
        for action in [.newTab, .closeTab, .reopenTab, .nextTab, .previousTab] as [ActionKind] {
            XCTAssertTrue(groups.contains(action))
            XCTAssertNotNil(action.standardShortcut)
        }
        // Control-Tab is the tab shortcut browsers document, so the fixed actions must send it.
        XCTAssertEqual(ActionKind.nextTab.standardShortcut, Shortcut(48, 0x40000))
        XCTAssertEqual(ActionKind.previousTab.standardShortcut, Shortcut(48, 0x60000))
        for action in groups where ![.shortcut, .openApplication, .openLink, .openFileOrFolder].contains(action) {
            XCTAssertTrue(action.standardShortcut != nil || action.systemAppPath != nil)
        }
    }
    func testOpenLocations() throws {
        var link = Rule(name: "Docs", kind: .click, action: .openLink)
        XCTAssertNotNil(link.validationError)
        for input in ["example.com", "https:///no-host", "http://exa mple.com", "file:///tmp/test", "javascript:alert(1)", "https://user:secret@example.com"] {
            link.linkAddress = input
            XCTAssertNil(link.locationToOpen)
            XCTAssertNotNil(link.validationError)
        }
        link.linkAddress = "  https://example.com/path?q=test&mode=2#guide  "
        XCTAssertEqual(link.locationToOpen?.absoluteString, "https://example.com/path?q=test&mode=2#guide")
        XCTAssertNil(link.validationError)
        XCTAssertEqual(link.actionDescription, "example.com")
        XCTAssertNotNil(Rule.webURL("http://127.0.0.1:8080"))
        var item = Rule(name: "Project files", kind: .click, action: .openFileOrFolder)
        for path in ["", "./folder", "~/Downloads", "/tmp/not\0allowed"] {
            item.fileOrFolderPath = path
            XCTAssertNil(item.locationToOpen)
            XCTAssertNotNil(item.validationError)
        }
        for path in ["/tmp/项目文件", "/tmp/Project files/Notes.txt"] {
            item.fileOrFolderPath = path
            XCTAssertEqual(item.locationToOpen?.path, path)
            XCTAssertNil(item.validationError)
        }
        var app = Rule(name: "Finder", kind: .click, action: .openApplication)
        app.appPath = "/System/Library/CoreServices/Finder.app"
        XCTAssertNil(app.locationToOpen)
        let config = Configuration(rules: [link, item, app])
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: ConfigStorage.encode(config)), config)
    }
    func testExportTargets() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        var rule = Rule(name: "Keep my name", kind: .click, output: Shortcut(18,0x40000), note: "Keep my note")
        rule.linkAddress = "https://example.invalid/?token=test-private"; rule.appPath = "/Test.app"; rule.fileOrFolderPath = "/tmp/test-path"
        for action in [ActionKind.copy, .openLink, .openApplication, .openFileOrFolder, .shortcut] {
            rule.action = action
            try ConfigStorage.export(Configuration(rules: [rule]), to: url)
            let (restored, warnings) = try ConfigStorage.importFile(at: url)
            XCTAssertTrue(warnings.isEmpty)
            let saved = restored.rules[0]
            XCTAssertEqual(saved.linkAddress, action == .openLink ? rule.linkAddress : nil)
            XCTAssertEqual(saved.fileOrFolderPath, action == .openFileOrFolder ? rule.fileOrFolderPath : nil)
            XCTAssertEqual(saved.appPath, action == .openApplication ? rule.appPath : "")
            XCTAssertEqual(saved.outputKey, action == .shortcut ? rule.outputKey : nil)
            XCTAssertEqual(saved.id, rule.id); XCTAssertEqual(saved.name, rule.name); XCTAssertEqual(saved.note, rule.note)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).contains("test-private"), action == .openLink)
        }
    }
    func testLargeExport() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let json = folder.appendingPathComponent("rules.json"), bab = folder.appendingPathComponent("rules.BABPreset")
        let points = (0..<1_500).map { StrokePoint(42, Double($0) / 8) }
        let config = Configuration(rules: (0..<60).map { Rule(kind: .gesture, points: points, action: .copy, bundleID: "test.app\($0)") })
        try ConfigStorage.export(config, to: json)
        let bytes = try json.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertTrue(bytes > 4_000_000)
        let (restored, warnings) = try ConfigStorage.importFile(at: json)
        XCTAssertTrue(restored == config && warnings.isEmpty)
        // Sparse files: verify both size guards without allocating giant archives or decoding them.
        for (url, size, message) in [(bab, 4_000_001, L10n.text("预设文件超过 4 MB。")),
                                     (json, 256_000_001, L10n.text("配置文件超过 %1$@ MB。", "256"))] {
            try Data().write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(size)); try handle.close()
            do { _ = try ConfigStorage.importFile(at: url); XCTFail("Oversize import succeeded") }
            catch let error as ConfigError { XCTAssertEqual(error.localizedDescription, message) }
        }
    }
    func testActualUserExportWhenSupplied() throws {
        guard let path = ProcessInfo.processInfo.environment["BAB_INPUT"] else { throw XCTSkip("No local export supplied") }
        let result = try BABImport.read(from: URL(fileURLWithPath: path))
        XCTAssertFalse(result.configuration.rules.isEmpty)
        XCTAssertTrue(result.configuration.rules.allSatisfy { $0.validationError == nil })
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: ConfigStorage.encode(result.configuration)), result.configuration)
    }
}
