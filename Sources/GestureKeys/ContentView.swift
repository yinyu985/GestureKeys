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
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.system(size: 22, weight: .semibold)).padding(.bottom, 3)
                content
            }.padding(.horizontal, 22).padding(.top, 26).padding(.bottom, 14)
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
                switch model.filter {
                case "通用": GeneralPanel(model: model)
                case "关于": AboutPanel()
                default: library
                }
                if let error = footerError { footer(error) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Ink.base)
        }
        .frame(width: MainWindowLayout.width, height: MainWindowLayout.height)
        .background(Ink.base).foregroundStyle(Ink.primary).tint(Ink.accent).preferredColorScheme(.dark)
        .sheet(item: $model.editor) { draft in RuleEditor(model: model, draft: draft) }
        .sheet(item: $model.prompt) { prompt in PromptPanel(prompt: prompt) }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(spacing: 2) {
                Image(nsImage: Brand.icon).resizable().scaledToFit().frame(width: 76, height: 76).accessibilityHidden(true)
                Text("GestureKeys").font(.system(size: 15, weight: .semibold))
            }.frame(maxWidth: .infinity).padding(.top, 24).padding(.bottom, 20)
            navigation("键盘", icon: "keyboard")
            navigation("鼠标", icon: "computermouse")
            navigation("通用", icon: "gearshape")
            navigation("关于", icon: "info.circle")
            Spacer()
        }.padding(.horizontal, 10)
    }
    private func navigation(_ title: String, icon: String) -> some View {
        Button { model.filter = title } label: {
            HStack(spacing: 19) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 19).accessibilityHidden(true)
                Text(title).font(.system(size: 13, weight: model.filter == title ? .semibold : .regular))
                Spacer(minLength: 0)
            }.padding(.horizontal, 22).frame(height: 32)
                .foregroundStyle(model.filter == title ? Ink.primary : Ink.secondary)
                .background(model.filter == title ? Ink.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(model.filter == title ? Ink.accent.opacity(0.34) : .clear))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(model.filter == title ? .isSelected : [])
    }
    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(model.filter).font(.system(size: 22, weight: .semibold))
                Text("\(model.visibleRules.count) 条规则").font(.system(size: 11)).foregroundStyle(Ink.secondary)
                Spacer()
                Button(action: model.addRule) { Label("添加规则", systemImage: "plus") }.buttonStyle(QuietButton(prominent: true))
            }.padding(.bottom, 18)
            RuleColumns {
                Text("触发方式")
            } action: {
                Text("执行动作")
            } scope: {
                Text("应用范围")
            } controls: {
                Text("启用")
            }.font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.secondary).frame(height: 24)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(model.visibleRules) { rule in
                        RuleRow(model: model, rule: model.binding(for: rule.id))
                    }
                    if model.visibleRules.isEmpty {
                        Text("还没有规则").font(.system(size: 13)).foregroundStyle(Ink.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 38)
                    }
                }.padding(.bottom, 8)
            }.scrollIndicators(.never)
        }.padding(.horizontal, 22).padding(.top, 26)
    }
    private var footerError: String? {
        if let error = model.monitorError ?? model.actionError { return error }
        if !model.unavailableShortcuts.isEmpty {
            return "系统未能注册：\(model.unavailableShortcuts.map(\.display).joined(separator: "、"))"
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

private struct RuleColumns<Trigger: View, Action: View, Scope: View, Controls: View>: View {
    @ViewBuilder var trigger: Trigger
    @ViewBuilder var action: Action
    @ViewBuilder var scope: Scope
    @ViewBuilder var controls: Controls
    var body: some View {
        HStack(spacing: 12) {
            trigger.frame(width: 125, alignment: .leading)
            action.frame(maxWidth: .infinity, alignment: .leading)
            scope.frame(width: 114, alignment: .leading)
            controls.frame(width: 66, alignment: .leading)
        }.padding(.horizontal, 10)
    }
}

struct RuleRow: View {
    @ObservedObject var model: AppModel
    @Binding var rule: Rule
    @State private var hovered = false
    @State private var showMenu = false
    private var friendlyName: String {
        if rule.action == .shortcut, let key = rule.outputKey, rule.name == key.display {
            let names: [Shortcut: String] = [Shortcut(13, 0x100000): "关闭标签或窗口", Shortcut(12, 0x100000): "退出应用",
                Shortcut(8, 0x100000): "复制", Shortcut(9, 0x100000): "粘贴", Shortcut(36): "回车", Shortcut(33, 0x100000): "后退"]
            return names[key] ?? rule.name
        }
        return rule.name
    }
    var body: some View {
        RuleColumns {
            if rule.kind == .keyboard {
                ShortcutRecorder(shortcut: Binding(get: { rule.triggerKey }, set: { key in
                    var edited = rule; edited.triggerKey = key
                    if let error = model.commit(edited, isNew: false) { model.prompt = AppPrompt(title: "无法修改快捷键", detail: error) }
                }), onRecording: { model.recording = $0 }).frame(width: 88, height: 24)
            } else {
                let button = Rule.buttonName(rule.mouseButton)
                let detail = rule.kind == .gesture ? (ShapePreset(rawValue: rule.shapeName)?.title ?? "手绘轨迹") : (rule.clickCount == 2 ? "双击" : "单击")
                Button { model.edit(rule) } label: {
                    HStack(spacing: 12) {
                        Text(button).frame(width: 53, alignment: .leading)
                        if rule.kind == .gesture {
                            GestureThumbnail(points: rule.points).accessibilityHidden(true)
                        } else {
                            Text(detail).frame(width: 48).foregroundStyle(Ink.secondary)
                        }
                    }.font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.accentText).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(button)，\(detail)").help("\(button)  \(detail)")
            }
        } action: {
            Button { model.edit(rule) } label: {
                HStack(spacing: 16) {
                    Text(friendlyName).foregroundStyle(Ink.primary).fontWeight(.medium).lineLimit(1)
                    if rule.action == .shortcut, let key = rule.outputKey, key.display != friendlyName {
                        Text(key.display).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.secondary).lineLimit(1).fixedSize()
                    } else if rule.action != .shortcut, rule.actionDescription != friendlyName {
                        Text(rule.actionDescription).foregroundStyle(Ink.secondary).lineLimit(1)
                    }
                }.font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help("\(friendlyName) · \(rule.actionDescription)")
        } scope: {
            let title = ApplicationNames.scope(for: rule)
            Button { model.edit(rule) } label: {
                Text(title).font(.system(size: 11)).foregroundStyle(Ink.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help("应用范围：\(title)")
        } controls: {
            HStack(spacing: 7) {
                Toggle("启用 \(friendlyName)", isOn: Binding(get: { rule.enabled }, set: { model.setEnabled($0, for: rule) })).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                Button { showMenu.toggle() } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).frame(width: 25, height: 24)
                        .foregroundStyle(showMenu ? Ink.accentText : Ink.secondary)
                        .background(showMenu ? Ink.accent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("规则操作").help("规则操作")
                    .popover(isPresented: $showMenu, arrowEdge: .trailing) {
                        VStack(spacing: 2) {
                            PopupRow(title: "编辑", icon: "pencil") { showMenu = false; afterMenu { model.edit(rule) } }
                            PopupRow(title: "复制", icon: "plus.square.on.square") { showMenu = false; afterMenu { model.duplicate(rule) } }
                            Rectangle().fill(Ink.border).frame(height: 1).padding(.vertical, 2)
                            PopupRow(title: "删除", icon: "trash", destructive: true) { showMenu = false; afterMenu { model.confirmDelete(rule) } }
                        }.popupSurface(width: 132)
                    }
            }
        }.frame(height: 34)
            .background(Color.white.opacity(hovered ? 0.060 : 0.032), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(hovered ? 0.13 : 0.065)))
            .onHover { hovered = $0 }
    }
    private func afterMenu(_ action: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: action) }
}

private struct GestureThumbnail: View {
    let points: [StrokePoint]
    var body: some View {
        Canvas { context, size in
            let fitted = Shape.thumbnail(points, width: size.width, height: size.height, padding: 5, maxWidthToHeightRatio: 2)
            guard let first = fitted.first else { return }
            var path = Path(); path.move(to: CGPoint(x: first.x, y: first.y))
            for point in fitted.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
            context.stroke(path, with: .color(Ink.accentText), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            context.fill(Path(ellipseIn: CGRect(x: first.x - 1.5, y: first.y - 1.5, width: 3, height: 3)), with: .color(Ink.accentText))
        }.frame(width: 48, height: 24)

    }
}

struct PromptPanel: View {
    let prompt: AppPrompt
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(prompt.title, systemImage: prompt.destructive ? "trash" : prompt.confirm == nil ? "info.circle" : "exclamationmark.circle")
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(prompt.destructive ? Ink.danger : Ink.primary)
            if !prompt.detail.isEmpty {
                ScrollView { Text(prompt.detail).font(.system(size: 12)).foregroundStyle(Ink.secondary).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    .scrollIndicators(.never).frame(minHeight: 24, idealHeight: 46, maxHeight: 120)
            }
            HStack(spacing: 8) {
                Spacer()
                if prompt.confirm != nil { Button("取消") { dismiss() }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction) }
                Button(prompt.confirmTitle) {
                    dismiss()
                    if let next = prompt.confirm { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: next) }
                }.buttonStyle(QuietButton(prominent: !prompt.destructive, destructive: prompt.destructive))
                    .keyboardShortcut(prompt.destructive ? KeyboardShortcut("\r", modifiers: [.command]) : .defaultAction)
            }
        }.padding(18).frame(width: 360).fixedSize(horizontal: false, vertical: true)
            .background(Ink.sidebar).foregroundStyle(Ink.primary).preferredColorScheme(.dark)
    }
}

struct GeneralPanel: View {
    @ObservedObject var model: AppModel
    private let smallButtonWidth: CGFloat = 86
    private var trailColor: Binding<Color> {
        Binding(get: { Color(nsColor: model.configuration.trailStyle.nsColor) }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            var style = model.configuration.trailStyle
            style.red = min(1, max(0, rgb.redComponent)); style.green = min(1, max(0, rgb.greenComponent)); style.blue = min(1, max(0, rgb.blueComponent))
            model.configuration.trailStyle = style
        })
    }
    var body: some View {
        PanelPage(title: "通用") {
            Surface {
                VStack(spacing: 4) {
                    EditorField(label: "显示手势轨迹") {
                        Toggle("显示手势轨迹", isOn: $model.configuration.showTrail).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                    DividerLine()
                    EditorField(label: "轨迹样式") {
                        TrailSample(style: model.configuration.trailStyle).frame(width: 76, height: 30).accessibilityHidden(true)
                        ColorPicker("轨迹颜色", selection: trailColor, supportsOpacity: false).labelsHidden().controlSize(.small)
                        Slider(value: Binding(get: { model.configuration.trailStyle.width }, set: { model.configuration.trailStyle.width = $0.rounded() }), in: TrailStyle.widthRange) { Text("轨迹粗细") }
                            .labelsHidden().controlSize(.small).frame(width: 102)
                        Text("\(Int(model.configuration.trailStyle.width)) pt").font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Ink.secondary).frame(width: 38, alignment: .trailing)
                    }.disabled(!model.configuration.showTrail).opacity(model.configuration.showTrail ? 1 : 0.52)
                }
            }
            Surface {
                VStack(alignment: .trailing, spacing: 4) {
                    EditorField(label: "应用图标") {
                        ForEach(IconLocation.allCases, id: \.self) { location in
                            SelectionButton(title: location.title, selected: model.configuration.iconLocation == location) {
                                model.configuration.iconLocation = location
                            }
                        }
                    }
                    if model.configuration.iconLocation == .hidden {
                        Text("可从「应用程序」重新打开 GestureKeys。")
                            .font(.system(size: 11)).foregroundStyle(Ink.secondary)
                    }
                }
            }
            sectionTitle("权限")
            Surface {
                VStack(spacing: 5) {
                    permission("辅助功能", detail: "向应用发送快捷键", granted: model.accessibilityGranted, action: model.requestAccessibility)
                    DividerLine()
                    permission("输入监控", detail: "识别鼠标点击与手势", granted: model.inputGranted, action: model.requestInput)
                }
            }
            sectionTitle("配置")
            Surface {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        Button("导入", action: model.importConfiguration).buttonStyle(QuietButton(prominent: true, width: smallButtonWidth))
                        Button("导出", action: model.exportConfiguration).buttonStyle(QuietButton(width: smallButtonWidth))
                        Spacer()
                        Button("打开配置文件夹", action: model.showConfigurationFolder).buttonStyle(QuietButton())
                    }
                    if let date = model.configurationSavedAt {
                        Text("最近保存：\(date.formatted(.dateTime.year().month().day().hour().minute().second()))")
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(Ink.secondary)
                    }
                }
            }
            sectionTitle("排障")
            Surface {
                EditorField(label: "诊断日志") {
                    Button("在 Finder 中显示", action: model.showDiagnosticLog).buttonStyle(QuietButton())
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
            Button(granted ? "查看" : "授权", action: action).buttonStyle(QuietButton(prominent: !granted, width: smallButtonWidth))
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
        PanelPage(title: "关于") {
            Surface {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(nsImage: Brand.icon).resizable().scaledToFit().frame(width: 42, height: 42).accessibilityHidden(true)
                        Text("GestureKeys").font(.system(size: 17, weight: .semibold))
                        Text(version).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.accentText)
                            .padding(.horizontal, 7).padding(.vertical, 3).background(Ink.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Text("用全局快捷键、鼠标点击或手势，执行常用操作。").font(.system(size: 12)).foregroundStyle(Ink.secondary)
                    DividerLine()
                    Text("规则与备份仅保存在本机。关闭窗口后，已启用的规则仍会在后台运行。")
                        .font(.system(size: 11)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(4)
            }
        }
    }
}
