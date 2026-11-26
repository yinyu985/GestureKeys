import SwiftUI
import AppKit
import GestureCore

struct DividerLine: View {
    var body: some View { Rectangle().fill(Ink.border).frame(height: 1).accessibilityHidden(true) }
}

func sectionTitle(_ title: String) -> some View {
    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Ink.secondary)
}

struct EditorField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(Ink.secondary)
            Spacer(minLength: 10)
            content
        }.frame(minHeight: 28)
    }
}

struct PopupRow: View {
    let title: String
    var icon: String? = nil
    var selected = false
    var showsCheckmark = true
    var destructive = false
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).frame(width: 14).accessibilityHidden(true) }
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                if selected && showsCheckmark { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).accessibilityHidden(true) }
            }.padding(.horizontal, 8).frame(height: 26).font(.system(size: 12))
                .foregroundStyle(destructive ? Ink.danger : (selected || hovered) ? Ink.accentText : Ink.primary)
                .background((selected || hovered) ? Ink.accent.opacity(selected ? 0.21 : 0.11) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }.accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension View {
    func popupSurface(width: CGFloat) -> some View {
        self.padding(5).frame(width: width).background(Ink.sidebar).foregroundStyle(Ink.primary)
    }
}

struct SelectionButton: View {
    let title: String
    let selected: Bool
    var width: CGFloat? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: selected ? "largecircle.fill.circle" : "circle")
                .lineLimit(1)
        }.buttonStyle(QuietButton(prominent: selected, width: width))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ChoiceButton<Popup: View>: View {
    let title: String
    let width: CGFloat
    @Binding var expanded: Bool
    @ViewBuilder var popup: Popup
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 8) {
                Text(title).lineLimit(1)
                Spacer(minLength: 3)
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold)).accessibilityHidden(true)
            }.font(.system(size: 12, weight: .medium)).foregroundStyle(enabled ? Ink.accentText : Ink.muted)
                .padding(.horizontal, 8).frame(width: width, height: 26)
                .background(Ink.accent.opacity(!enabled ? 0.025 : expanded || hovered ? 0.14 : 0.075), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Ink.accent.opacity(!enabled ? 0.13 : expanded || hovered ? 0.60 : 0.34)))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }.accessibilityHint(L10n.text("打开选项"))
            .popover(isPresented: $expanded, arrowEdge: .bottom) { popup }
    }
}

struct ChoiceMenu<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    var width: CGFloat = 112
    let title: (Value) -> String
    @State private var expanded = false
    var body: some View {
        ChoiceButton(title: title(selection), width: width, expanded: $expanded) {
            VStack(spacing: 1) {
                ForEach(options, id: \.self) { option in
                    PopupRow(title: title(option), selected: selection == option) { selection = option; expanded = false }
                }
            }.popupSurface(width: max(112, width))
        }
    }
}

private struct ChoiceGrid<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    @State private var expanded = false
    var body: some View {
        let columnWidth: CGFloat = 176
        let columns = Array(repeating: GridItem(.fixed(columnWidth), spacing: 1), count: 2)
        ChoiceButton(title: title(selection), width: columnWidth, expanded: $expanded) {
            LazyVGrid(columns: columns, spacing: 1) {
                ForEach(options, id: \.self) { option in
                    PopupRow(title: title(option), selected: selection == option) {
                        selection = option
                        expanded = false
                    }
                }
            }.popupSurface(width: 2 * columnWidth + 11)
        }
    }
}

private enum TrailPresetOption: Hashable {
    case forward(ShapePreset)
    case reverse(ShapePreset)

    static let options = ShapePreset.editorOptions.flatMap { preset -> [Self] in
        switch preset {
        case .circle: return [.reverse(preset), .forward(preset)]
        case .v, .caret: return [.forward(preset), .reverse(preset)]
        default: return [.forward(preset)]
        }
    }

    var preset: ShapePreset {
        switch self {
        case .forward(let preset), .reverse(let preset): return preset
        }
    }

    var title: String {
        switch self {
        case .reverse(.circle): return L10n.text("O 逆时针")
        case .forward(.circle): return L10n.text("O 顺时针")
        case .forward(.v), .forward(.caret): return L10n.text("%1$@ · 左起笔", preset.title)
        case .reverse(.v), .reverse(.caret): return L10n.text("%1$@ · 右起笔", preset.title)
        default: return preset.title
        }
    }

    var points: [StrokePoint] {
        let points = Shape.preset(preset)
        if case .reverse = self { return Array(points.reversed()) }
        return points
    }

    init?(rule: Rule) {
        guard let preset = ShapePreset(rawValue: rule.shapeName) else { return nil }
        let reversed = Self.reverse(preset)
        self = Self.options.contains(reversed) && rule.points == reversed.points ? reversed : .forward(preset)
    }
}

private struct ActionPages: View {
    @Binding var selection: ActionKind
    let width: CGFloat
    @State private var expanded = false
    @State private var page = 0
    private let icons = ["slider.horizontal.3", "globe", "pencil", "macwindow"]
    var body: some View {
        let groups = ActionKind.groups
        ChoiceButton(title: selection.title, width: width, expanded: $expanded) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 4) {
                    ForEach(groups.indices, id: \.self) { index in
                        PopupRow(title: groups[index].0, icon: icons[index], selected: page == index, showsCheckmark: false) { page = index }
                    }
                    Spacer(minLength: 0)
                }.padding(7).frame(width: 176).background(Ink.base.opacity(0.58))
                Rectangle().fill(Ink.border).frame(width: 1).accessibilityHidden(true)
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(groups[page].1, id: \.self) { action in
                            PopupRow(title: action.title, selected: selection == action, showsCheckmark: false) { selection = action; expanded = false }
                        }
                    }.padding(7)
                }.id(page).scrollIndicators(.never).frame(width: 242)
            }.frame(height: 312).background(Ink.sidebar).foregroundStyle(Ink.primary)
                .onAppear { page = groups.firstIndex(where: { $0.1.contains(selection) }) ?? 0 }
        }
    }
}

private enum MouseMode: CaseIterable {
    case gesture, singleClick, doubleClick
    var title: String {
        switch self { case .gesture: return L10n.text("手势"); case .singleClick: return L10n.text("单击"); case .doubleClick: return L10n.text("双击") }
    }
}

enum ApplicationNames {
    static func name(_ url: URL) -> String {
        if let info = Bundle(url: url), let localized = info.localizedInfoDictionary?["CFBundleDisplayName"] as? String {
            return localized
        }
        let fileName = FileManager.default.displayName(atPath: url.path)
        let name = fileName.isEmpty ? url.lastPathComponent : fileName
        return name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
    static func scope(for rule: Rule) -> String {
        guard !rule.bundleID.isEmpty else { return L10n.text("所有应用") }
        if rule.bundleID == "com.apple.finder" { return L10n.text("访达") }
        if let name = rule.scopeName, !name.isEmpty { return name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.bundleID) { return name(url) }
        return L10n.text("应用不可用")
    }
}

struct RuleEditor: View {
    @ObservedObject var model: AppModel
    let isNew: Bool
    @State var rule: Rule
    @State var issue: String?
    @Environment(\.dismiss) private var dismiss
    private let controlWidth: CGFloat = 216
    private let controlGap: CGFloat = 8
    private var halfWidth: CGFloat { (controlWidth - controlGap) / 2 }
    init(model: AppModel, draft: RuleDraft) {
        self.model = model; isNew = draft.isNew
        var localRule = draft.rule; localRule.name = localRule.displayName
        _rule = State(initialValue: localRule)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: rule.kind == .keyboard ? "keyboard" : "computermouse").foregroundStyle(Ink.accentText)
                Text(isNew ? L10n.text("添加规则") : L10n.text("编辑规则")).font(.system(size: 17, weight: .semibold))
                Spacer()
            }.padding(.horizontal, 16).frame(height: 40)
            DividerLine()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Surface(verticalInset: 5) {
                        EditorField(label: L10n.text("规则名称")) {
                            TextField(L10n.text("输入名称"), text: $rule.name).textFieldStyle(.plain).font(.system(size: 12))
                                .accessibilityLabel(L10n.text("规则名称")).padding(.horizontal, 8).frame(width: controlWidth, height: 27)
                                .background(Ink.base, in: RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Ink.border))
                        }
                        DividerLine().padding(.vertical, 3)
                        EditorField(label: L10n.text("触发方式")) {
                            if rule.kind == .keyboard {
                                ShortcutRecorder(shortcut: $rule.triggerKey).frame(width: controlWidth, height: 27)
                            } else {
                                HStack(spacing: controlGap) {
                                    ChoiceMenu(selection: $rule.mouseButton, options: Array(1...7), width: halfWidth, title: Rule.buttonName)
                                    ChoiceMenu(selection: mouseMode, options: MouseMode.allCases, width: halfWidth) { rule.mouseButton == 0 ? L10n.text("选择方式") : $0.title }
                                        .disabled(rule.mouseButton == 0)
                                }
                            }
                        }
                    }
                    if showsTrack { track }
                    Surface(verticalInset: 5) {
                        EditorField(label: L10n.text("执行动作")) { ActionPages(selection: $rule.action, width: controlWidth) }
                        if rule.action == .shortcut {
                            DividerLine().padding(.vertical, 3)
                            EditorField(label: L10n.text("发送快捷键")) {
                                ShortcutRecorder(shortcut: $rule.outputKey, physicalOutput: true).frame(width: controlWidth, height: 27)
                                    .contextMenu {
                                        ForEach([UInt16(58), 61], id: \.self) { option in
                                            ForEach([UInt16(55), 54], id: \.self) { command in
                                                if let chord = Shortcut(physical: [option, command]) {
                                                    Button(chord.display) { rule.outputKey = chord }
                                                }
                                            }
                                        }
                                    }
                            }
                        } else if rule.action == .openApplication {
                            DividerLine().padding(.vertical, 3)
                            EditorField(label: L10n.text("打开")) {
                                Button(rule.appPath.isEmpty ? L10n.text("选择要打开的应用") : ApplicationNames.name(URL(fileURLWithPath: rule.appPath))) {
                                    model.chooseApplication { rule.appPath = $0.path }
                                }.lineLimit(1).buttonStyle(QuietButton(width: controlWidth))
                            }
                        } else if rule.action == .openLink {
                            DividerLine().padding(.vertical, 3)
                            EditorField(label: L10n.text("网址")) {
                                TextField("https://example.com", text: Binding(get: { rule.linkAddress ?? "" }, set: { rule.linkAddress = $0 }))
                                    .textFieldStyle(.plain).font(.system(size: 12)).accessibilityLabel(L10n.text("网址"))
                                    .padding(.horizontal, 8).frame(width: controlWidth, height: 27)
                                    .background(Ink.base, in: RoundedRectangle(cornerRadius: 5))
                                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Ink.border))
                            }
                        } else if rule.action == .openFileOrFolder {
                            DividerLine().padding(.vertical, 3)
                            EditorField(label: L10n.text("打开")) {
                                Button(rule.locationToOpen == nil ? L10n.text("选择文件或文件夹") : rule.actionDescription) {
                                    model.chooseFileOrFolder { rule.fileOrFolderPath = $0.path }
                                }.lineLimit(1).buttonStyle(QuietButton(width: controlWidth))
                            }
                        }
                        DividerLine().padding(.vertical, 3)
                        EditorField(label: L10n.text("应用范围")) {
                            SelectionButton(title: L10n.text("所有应用"), selected: rule.bundleID.isEmpty, width: halfWidth) { rule.bundleID = ""; rule.scopeName = nil }
                            SelectionButton(title: rule.bundleID.isEmpty ? L10n.text("选择应用") : ApplicationNames.scope(for: rule), selected: !rule.bundleID.isEmpty, width: halfWidth) {
                                model.chooseApplication { url in
                                    guard let id = Bundle(url: url)?.bundleIdentifier else { issue = L10n.text("无法识别这个应用，请选择另一个。"); return }
                                    rule.bundleID = id; rule.scopeName = ApplicationNames.name(url)
                                }
                            }.help(L10n.text("选择生效的应用"))
                        }
                    }
                }.padding(.horizontal, 16).padding(.vertical, 9)
            }.scrollIndicators(.never)
            DividerLine()
            VStack(alignment: .leading, spacing: 8) {
                if let hint = issue ?? hint {
                    Label(hint, systemImage: issue == nil ? "info.circle" : "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(issue == nil ? Ink.secondary : Ink.danger)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    EditorInputReadout(style: model.configuration.trailStyle).frame(width: 216, height: 20)
                    Spacer()
                    Button(L10n.text("取消")) { diagnostics.record("rule.editor_cancelled", diagnosticRule(rule)); dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
                    Button(L10n.text("保存"), action: save).buttonStyle(QuietButton(prominent: true)).keyboardShortcut(.defaultAction)
                }
            }.padding(.horizontal, 16).padding(.vertical, 9)
        }.frame(width: 478, height: editorHeight)
            .background(Ink.base).foregroundStyle(Ink.primary).tint(Ink.accent)
            .onChange(of: rule) { _ in issue = nil }
    }
    private var editorHeight: CGFloat {
        let extended = [.shortcut, .openApplication, .openLink, .openFileOrFolder].contains(rule.action)
        return 268 + (showsTrack ? 218 : 0) + (extended ? 35 : 0) + (issue != nil || hint != nil ? 48 : 0)
    }
    private var showsTrack: Bool { rule.kind == .gesture && rule.mouseButton > 0 }
    private var mouseMode: Binding<MouseMode> {
        Binding(get: {
            rule.kind == .gesture ? .gesture : rule.clickCount == 2 ? .doubleClick : .singleClick
        }, set: { mode in
            var updated = rule
            updated.kind = mode == .gesture ? .gesture : .click
            updated.storedClickCount = mode == .doubleClick ? 2 : nil
            rule = updated
        })
    }
    private var hint: String? {
        if rule.action.switchesSpace, let key = rule.action.standardShortcut {
            return L10n.text("默认使用 %1$@。如果你在「系统设置 → 键盘 → 键盘快捷键 → 调度中心」改过键位，请选「发送快捷键」，录入你实际设置的组合键。", key.display)
        }
        if rule.action == .block { return L10n.text("此规则会吞掉输入。例如仅对某个 App 使用时，同一个全局规则不会执行，原来的按键也不会传给该 App。") }
        if rule.kind == .click && rule.mouseButton == 1 { return rule.clickCount == 2 ? L10n.text("若也绑定了单击，单击会等到双击判定结束再触发。") : L10n.text("绑定右键单击会替代普通右键菜单。") }
        if [.appWindows, .showDesktop].contains(rule.action) { return L10n.text("使用 macOS 系统快捷键；请确认系统设置中的快捷键已启用。") }
        if rule.action == .redo { return L10n.text("恢复刚撤销的操作。") }
        return nil
    }
    private var trailPreset: Binding<TrailPresetOption?> {
        Binding(get: { TrailPresetOption(rule: rule) }, set: { selection in
            guard let selection else { return }
            rule.points = selection.points
            rule.shapeName = selection.preset.rawValue
            diagnostics.record("rule.gesture_preset_selected", ["rule": rule.id.uuidString, "preset": rule.shapeName])
        })
    }
    private var track: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                sectionTitle(L10n.text("轨迹"))
                Spacer()
                ChoiceGrid(selection: trailPreset, options: TrailPresetOption.options.map(Optional.some)) {
                    $0?.title ?? (rule.points.isEmpty ? L10n.text("预设轨迹") : L10n.text("手绘轨迹"))
                }
                Button(L10n.text("清空")) {
                    rule.points = []; rule.shapeName = ""
                    diagnostics.record("rule.gesture_cleared", ["rule": rule.id.uuidString])
                }.buttonStyle(QuietButton()).disabled(rule.points.isEmpty)
            }
            StrokeCanvas(points: rule.points, preset: ShapePreset(rawValue: rule.shapeName), style: model.configuration.trailStyle) { points in
                rule.points = points; rule.shapeName = ""
                diagnostics.record("rule.gesture_drawn", ["rule": rule.id.uuidString, "point_count": String(points.count)])
            }.frame(height: 178).clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Ink.border))
        }
    }
    private func save() {
        var normalized = rule; normalized.name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.action == .openLink { normalized.linkAddress = normalized.locationToOpen?.absoluteString }
        issue = model.commit(normalized, isNew: isNew)
    }
}
