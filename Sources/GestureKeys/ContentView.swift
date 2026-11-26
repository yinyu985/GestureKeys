import SwiftUI
import AppKit
import GestureCore

struct QuietButton: ButtonStyle {
    var prominent = false
    var destructive = false
    var width: CGFloat? = nil
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let color = destructive ? Ink.danger : prominent ? Ink.accentText : Ink.secondary
        return configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color.opacity(enabled ? 1 : 0.5))
            .padding(.horizontal, 10).frame(width: width, height: 27)
            .background(color.opacity(configuration.isPressed ? 0.19 : prominent || destructive ? 0.09 : 0.035), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(prominent || destructive ? color.opacity(0.28) : Ink.border))
    }
}

struct Surface<Content: View>: View {
    var verticalInset: CGFloat = 8
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 12).padding(.vertical, verticalInset).frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.surface, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Ink.border))
    }
}

struct PanelPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 22, weight: .semibold)).padding(.bottom, 3)
                content
            }.padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 14)
        }.scrollIndicators(.never)
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 168).background(Ink.sidebar, ignoresSafeAreaEdges: .top)
            Rectangle().fill(Ink.border).frame(width: 1).ignoresSafeArea(edges: .top)
            VStack(spacing: 0) {
                switch model.page {
                case .general: GeneralPanel(model: model)
                case .about: AboutPanel()
                default: library
                }
                if let error = footerError { footer(error) }
                if model.desktopOneUnavailable {
                    footer(L10n.text("无法启用 %1$@。它可能已被 macOS 用于「切换到桌面 1」（系统设置 → 键盘 → 键盘快捷键 → 调度中心）。", AppModel.desktopOneShortcut.display))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Ink.base)
        }
        .frame(width: MainWindowLayout.width, height: MainWindowLayout.height)
        .background(Ink.base).foregroundStyle(Ink.primary).tint(Ink.accent).preferredColorScheme(model.configuration.appearance.colorScheme)
        .sheet(item: $model.editor) { draft in RuleEditor(model: model, draft: draft) }
        .sheet(item: $model.prompt) { prompt in PromptPanel(prompt: prompt) }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(spacing: 2) {
                Image(nsImage: Brand.icon).resizable().scaledToFit().frame(width: 76, height: 76).accessibilityHidden(true)
                Text("GestureKeys").font(.system(size: 15, weight: .semibold))
            }.frame(maxWidth: .infinity).padding(.top, 24).padding(.bottom, 20)
            ForEach(SettingsPage.allCases, id: \.self) { navigation($0) }
            Spacer()
        }.padding(.horizontal, 10)
    }
    private func navigation(_ page: SettingsPage) -> some View {
        let selected = model.page == page
        return Button { model.page = page } label: {
            HStack(spacing: 19) {
                Image(systemName: page.icon).font(.system(size: 14)).frame(width: 19).accessibilityHidden(true)
                Text(page.title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.leading, 22).padding(.trailing, 8).frame(height: 32)
                .foregroundStyle(selected ? Ink.primary : Ink.secondary)
                .background(selected ? Ink.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Ink.accent.opacity(0.34) : .clear))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var library: some View {
        let rules = model.visibleRules
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(model.page.title).font(.system(size: 22, weight: .semibold))
                let count = rules.count
                Text(count == 1 ? L10n.text("1 条规则") : L10n.text("%1$@ 条规则", "\(count)")).font(.system(size: 11)).foregroundStyle(Ink.secondary)
                Spacer()
                Button(action: model.addRule) { Label(L10n.text("添加规则"), systemImage: "plus") }.buttonStyle(QuietButton(prominent: true))
            }.padding(.bottom, 18)
            RuleColumns {
                Text(L10n.text("触发方式"))
            } action: {
                Text(L10n.text("执行动作"))
            } scope: {
                Text(L10n.text("应用范围"))
            } hint: {
                Text(L10n.text("触发提示")).help(L10n.text("触发规则时显示规则名称"))
            } status: {
                Text(L10n.text("启用"))
            } tools: {
                Color.clear.accessibilityHidden(true)
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.secondary).frame(height: 24)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(rules) { rule in
                        RuleRow(model: model, rule: model.binding(for: rule.id))
                    }
                    if rules.isEmpty {
                        Text(L10n.text("还没有规则")).font(.system(size: 13)).foregroundStyle(Ink.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 38)
                    }
                }.padding(.bottom, 8)
            }.scrollIndicators(.never)
        }.padding(.horizontal, 22).padding(.top, 26)
    }
    private var footerError: String? {
        if let error = model.monitorError ?? model.actionError { return error }
        if !model.unavailableShortcuts.isEmpty {
            return L10n.text("系统未能注册：%1$@", model.unavailableShortcuts.map(\.display).joined(separator: ", "))
        }
        return nil
    }
    private func footer(_ error: String) -> some View {
        Label(error, systemImage: "exclamationmark.circle")
            .font(.system(size: 11)).foregroundStyle(Ink.danger).lineLimit(2).help(error)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22).padding(.vertical, 8).frame(minHeight: 32)
            .overlay(alignment: .top) { Rectangle().fill(Ink.border).frame(height: 1) }
    }
}

private struct RuleColumns<Trigger: View, Action: View, Scope: View, Hint: View, Status: View, Tools: View>: View {
    @ViewBuilder var trigger: Trigger
    @ViewBuilder var action: Action
    @ViewBuilder var scope: Scope
    @ViewBuilder var hint: Hint
    @ViewBuilder var status: Status
    @ViewBuilder var tools: Tools
    var body: some View {
        HStack(spacing: 6) {
            trigger.frame(width: 125, alignment: .leading)
            action.frame(width: 166, alignment: .leading)
            scope.frame(width: 96, alignment: .leading)
            hint.frame(width: 68)
            status.frame(width: 48)
            tools.frame(width: 84, alignment: .trailing)
        }.padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RuleIconButton: View {
    let title: String
    let icon: String
    var destructive = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let highlight = destructive ? Ink.danger : Ink.accentText
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovered ? highlight : Ink.secondary)
                .frame(width: 26, height: 26)
                .background(hovered ? highlight.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hovered = $0 }.accessibilityLabel(title).help(title)
    }
}

struct RuleRow: View {
    @ObservedObject var model: AppModel
    @Binding var rule: Rule
    @State private var hovered = false
    private var friendlyName: String {
        if rule.action == .shortcut, let key = rule.outputKey, rule.name == key.display {
            let names: [Shortcut: String] = [Shortcut(13, 0x100000): L10n.text("关闭标签或窗口"), Shortcut(12, 0x100000): L10n.text("退出应用"),
                Shortcut(8, 0x100000): L10n.text("复制"), Shortcut(9, 0x100000): L10n.text("粘贴"), Shortcut(36): L10n.text("回车"), Shortcut(33, 0x100000): L10n.text("后退")]
            return names[key] ?? rule.name
        }
        return rule.displayName
    }
    var body: some View {
        RuleColumns {
            if rule.kind == .keyboard {
                ShortcutRecorder(shortcut: Binding(get: { rule.triggerKey }, set: { key in
                    var edited = rule; edited.triggerKey = key
                    if let error = model.commit(edited, isNew: false) { model.prompt = AppPrompt(title: L10n.text("无法修改快捷键"), detail: error) }
                }), onRecording: { model.recordingShortcut = $0 }).frame(width: 88, height: 24)
            } else {
                let button = Rule.buttonName(rule.mouseButton)
                let detail = rule.kind == .gesture ? (ShapePreset(rawValue: rule.shapeName)?.title ?? L10n.text("手绘轨迹")) : (rule.clickCount == 2 ? L10n.text("双击") : L10n.text("单击"))
                Button { model.edit(rule) } label: {
                    HStack(spacing: 12) {
                        Text(button).frame(width: 63, alignment: .leading)
                        if rule.kind == .gesture {
                            GestureThumbnail(points: rule.points)
                        } else {
                            Text(detail).frame(width: 50).foregroundStyle(Ink.secondary)
                        }
                    }.font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.accentText).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(button)，\(detail)").help("\(button)  \(detail)")
            }
        } action: {
            Button { model.edit(rule) } label: {
                HStack(spacing: 8) {
                    Text(friendlyName).foregroundStyle(Ink.primary).fontWeight(.medium).lineLimit(1).layoutPriority(1)
                    if rule.action == .shortcut, let key = rule.outputKey, key.display != friendlyName {
                        Text(key.display).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.secondary).lineLimit(1).fixedSize()
                    } else if rule.action != .shortcut, rule.actionDescription != friendlyName {
                        Text(rule.actionDescription).foregroundStyle(Ink.secondary).lineLimit(1)
                    }
                }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(rule.actionDescription == friendlyName ? friendlyName : "\(friendlyName) · \(rule.actionDescription)")
        } scope: {
            let title = ApplicationNames.scope(for: rule)
            Button { model.edit(rule) } label: {
                Text(title).font(.system(size: 11)).foregroundStyle(Ink.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(L10n.text("应用范围：%1$@", "\(title)"))
        } hint: {
            Toggle(L10n.text("显示触发提示：%1$@", "\(friendlyName)"), isOn: Binding(get: { rule.showsName == true }, set: { model.setTriggerHint($0, for: rule.id) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini).help(L10n.text("触发规则时显示规则名称"))
        } status: {
            Toggle(L10n.text("启用 %1$@", "\(friendlyName)"), isOn: Binding(get: { rule.enabled }, set: { model.setEnabled($0, for: rule) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini)
        } tools: {
            HStack(spacing: 3) {
                RuleIconButton(title: L10n.text("编辑"), icon: "pencil") { model.edit(rule) }
                RuleIconButton(title: L10n.text("复制"), icon: "plus.square.on.square") { model.duplicate(rule) }
                RuleIconButton(title: L10n.text("删除"), icon: "trash", destructive: true) { model.confirmDelete(rule) }
            }
        }.frame(height: 34)
            .background(hovered ? Ink.rowHover : Ink.surface, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(hovered ? Ink.rowBorderHover : Ink.border))
            .onHover { hovered = $0 }
    }
}

struct PromptPanel: View {
    let prompt: AppPrompt
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: prompt.destructive ? 8 : 12) {
            Label(prompt.title, systemImage: prompt.destructive ? "trash" : prompt.confirm == nil ? "info.circle" : "exclamationmark.circle")
                .font(.system(size: prompt.destructive ? 15 : 17, weight: .semibold)).foregroundStyle(prompt.destructive ? Ink.danger : Ink.primary)
            if !prompt.detail.isEmpty {
                if prompt.destructive {
                    Text(prompt.detail).font(.system(size: 12)).foregroundStyle(Ink.secondary)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true).help(prompt.detail)
                } else {
                    ScrollView { Text(prompt.detail).font(.system(size: 12)).foregroundStyle(Ink.secondary).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                        .scrollIndicators(.never).frame(minHeight: 24, idealHeight: 46, maxHeight: 120)
                }
            }
            HStack(spacing: 8) {
                Spacer()
                if prompt.confirm != nil { Button(L10n.text("取消")) { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction) }
                Button(prompt.confirmTitle) {
                    dismiss()
                    if let next = prompt.confirm { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: next) }
                }.buttonStyle(QuietButton(prominent: !prompt.destructive, destructive: prompt.destructive))
                    .keyboardShortcut(prompt.destructive ? KeyboardShortcut("\r", modifiers: [.command]) : .defaultAction)
            }
        }.padding(.horizontal, prompt.destructive ? 14 : 18)
            .padding(.vertical, prompt.destructive ? 12 : 18)
            .frame(width: prompt.destructive ? 264 : 360).fixedSize(horizontal: false, vertical: true)
            .background(Ink.sidebar).foregroundStyle(Ink.primary)
    }
}

struct GeneralPanel: View {
    @ObservedObject var model: AppModel
    private let smallButtonWidth: CGFloat = 104
    @Environment(\.locale) private var locale
    private func languageTitle(_ language: AppLanguage) -> String {
        switch language {
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
    private var trailColor: Binding<Color> {
        Binding(get: { Color(nsColor: model.configuration.trailStyle.nsColor) }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            var style = model.configuration.trailStyle
            style.red = min(1, max(0, rgb.redComponent)); style.green = min(1, max(0, rgb.greenComponent)); style.blue = min(1, max(0, rgb.blueComponent))
            model.configuration.trailStyle = style
        })
    }
    var body: some View {
        PanelPage(title: L10n.text("通用")) {
            Surface {
                VStack(spacing: 4) {
                    EditorField(label: L10n.text("语言")) {
                        ChoiceMenu(selection: Binding(get: { model.appLanguage }, set: model.setLanguage),
                                   options: AppLanguage.allCases, title: languageTitle)
                    }
                    DividerLine()
                    EditorField(label: L10n.text("外观")) {
                        ForEach(AppAppearance.allCases, id: \.self) { appearance in
                            SelectionButton(title: appearance.title, selected: model.configuration.appearance == appearance) {
                                model.configuration.appearance = appearance
                            }
                        }
                    }
                    DividerLine()
                    EditorField(label: L10n.text("登录时启动")) {
                        Toggle(L10n.text("登录时启动"), isOn: Binding(get: { model.loginItemStatus == .enabled }, set: model.setLaunchAtLogin))
                            .labelsHidden().toggleStyle(.switch).controlSize(.mini).disabled(model.loginItemStatus == .requiresApproval)
                    }
                    if model.loginItemStatus == .requiresApproval {
                        EditorField(label: L10n.text("需要在系统设置中批准登录项")) {
                            Button(L10n.text("打开登录项"), action: model.showLoginItems).buttonStyle(QuietButton())
                        }
                    }
                }
            }
            Surface {
                VStack(spacing: 4) {
                    EditorField(label: L10n.text("显示手势轨迹")) {
                        Toggle(L10n.text("显示手势轨迹"), isOn: $model.configuration.showTrail).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                    DividerLine()
                    EditorField(label: L10n.text("轨迹样式")) {
                        TrailSample(style: model.configuration.trailStyle).frame(width: 76, height: 30).accessibilityHidden(true)
                        ColorPicker(L10n.text("轨迹颜色"), selection: trailColor, supportsOpacity: false).labelsHidden().controlSize(.small)
                        Slider(value: Binding(get: { model.configuration.trailStyle.width }, set: { model.configuration.trailStyle.width = $0.rounded() }), in: TrailStyle.widthRange) { Text(L10n.text("轨迹粗细")) }
                            .labelsHidden().controlSize(.small).frame(width: 102)
                        Text("\(Int(model.configuration.trailStyle.width)) pt").font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Ink.secondary).frame(width: 38, alignment: .trailing)
                    }.disabled(!model.configuration.showTrail).opacity(model.configuration.showTrail ? 1 : 0.52)
                }
            }
            Surface {
                VStack(alignment: .trailing, spacing: 4) {
                    EditorField(label: L10n.text("应用图标")) {
                        ForEach(IconLocation.allCases, id: \.self) { location in
                            SelectionButton(title: location.title, selected: model.configuration.iconLocation == location) {
                                model.configuration.iconLocation = location
                            }
                        }
                    }
                    if model.configuration.iconLocation == .hidden {
                        Text(L10n.text("可从「应用程序」重新打开 GestureKeys。"))
                            .font(.system(size: 11)).foregroundStyle(Ink.secondary)
                    }
                }
            }
            sectionTitle(L10n.text("权限"))
            Surface {
                VStack(spacing: 5) {
                    permission(L10n.text("辅助功能"), detail: L10n.text("向应用发送快捷键"), granted: model.accessibilityGranted, action: model.requestAccessibility)
                    DividerLine()
                    permission(L10n.text("输入监控"), detail: L10n.text("识别鼠标点击与手势"), granted: model.inputGranted, action: model.requestInput)
                }
            }
            sectionTitle(L10n.text("配置"))
            Surface {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Button(L10n.text("导入"), action: model.importConfiguration).buttonStyle(QuietButton(prominent: true, width: smallButtonWidth))
                        Button(L10n.text("导出"), action: model.exportConfiguration).buttonStyle(QuietButton(width: smallButtonWidth))
                        Spacer()
                        Button(L10n.text("打开配置文件夹"), action: model.showConfigurationFolder).buttonStyle(QuietButton())
                    }
                    if let date = model.configurationSavedAt {
                        Text(L10n.text("最近保存：%1$@", date.formatted(.dateTime.year().month().day().hour().minute().second().locale(locale))))
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(Ink.secondary)
                    }
                }
            }
            sectionTitle(L10n.text("排障"))
            Surface {
                EditorField(label: L10n.text("诊断日志")) {
                    Button(L10n.text("在 Finder 中显示"), action: model.showDiagnosticLog).buttonStyle(QuietButton())
                }
            }
        }
    }
    private func permission(_ title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle" : "lock").foregroundStyle(granted ? Ink.accentText : Ink.secondary).frame(width: 18)
            Text(title).font(.system(size: 12))
            Text(detail).font(.system(size: 11)).foregroundStyle(Ink.secondary)
            Spacer()
            Button(granted ? L10n.text("查看") : L10n.text("授权"), action: action).buttonStyle(QuietButton(prominent: !granted, width: smallButtonWidth))
        }.frame(minHeight: 30)
    }
}

private struct TrailSample: View {
    var style: TrailStyle
    var body: some View {
        Canvas { context, size in
            let inset = style.width / 2 + 3
            let h = size.height - 2 * inset
            var path = Path(); path.move(to: CGPoint(x: inset, y: inset + 0.70 * h))
            path.addQuadCurve(to: CGPoint(x: size.width * 0.48, y: inset + 0.54 * h), control: CGPoint(x: size.width * 0.28, y: inset - 1))
            path.addQuadCurve(to: CGPoint(x: size.width - inset, y: inset + 0.20 * h), control: CGPoint(x: size.width * 0.72, y: size.height - inset + 3))
            context.stroke(path, with: .color(Color(nsColor: style.nsColor)), style: StrokeStyle(lineWidth: style.width, lineCap: .round, lineJoin: .round))
        }
    }
}

struct AboutPanel: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—" }
    var body: some View {
        PanelPage(title: L10n.text("关于")) {
            Surface {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(nsImage: Brand.icon).resizable().scaledToFit().frame(width: 42, height: 42).accessibilityHidden(true)
                        Text("GestureKeys").font(.system(size: 17, weight: .semibold))
                        Text(version).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.accentText)
                            .padding(.horizontal, 7).padding(.vertical, 3).background(Ink.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Text(L10n.text("用全局快捷键、鼠标点击或手势，执行常用操作。")).font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    DividerLine()
                    Text(L10n.text("规则与备份仅保存在本机。关闭窗口后，已启用的规则仍会在后台运行。"))
                        .font(.system(size: 11)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(4)
            }
        }
    }
}
