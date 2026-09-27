//
//  AnnotationToolbar.swift
//  OneOfPassword
//
//  截屏标注工具栏：矩形/圆形/箭头/画笔/文本 + 颜色 + 线宽 + 保存/复制/取消。
//  文本工具下额外展开第二行「文本样式」工具栏（字号/字体/加粗/文字色/背景/边框）。
//

import SwiftUI

/// 工具栏实际渲染尺寸上报通道。
/// 位置钳制必须用真实尺寸：之前按硬编码 380 算，而工具栏实际约 650pt，
/// 于是选区被拖到屏幕左右边缘时会露出屏幕外。加/减按钮都会让硬编码失效，所以改成实测。
/// 文本模式下工具栏会多出一行，高度随之变化，同样靠这条通道自动跟随。
struct ToolbarSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// 边框粗细档位（二级工具栏用）。数值为「点」。
enum TextBorderPreset: String, CaseIterable, Hashable {
    case none
    case thin
    case medium

    var label: String {
        switch self {
        case .none:   return "无"
        case .thin:   return "细"
        case .medium: return "中"
        }
    }

    var width: CGFloat {
        switch self {
        case .none:   return 0
        case .thin:   return 1.5
        case .medium: return 3
        }
    }
}

struct AnnotationToolbar: View {
    @Binding var selectedTool: AnnotationTool
    @Binding var color: Color
    @Binding var lineWidth: CGFloat
    /// 文本样式。选中某个文本框时是那个框的样式，否则是「新建文本框」的默认样式。
    @Binding var textStyle: TextStyle
    var canUndo: Bool
    /// 是否有选中的标注（决定垃圾桶按钮是否可用）
    var canDelete: Bool
    /// 当前是否选中了某个**文本框**（决定是否展开二级「文本样式」行）。
    /// 文本框不能靠手柄拉伸，宽高完全由字号推导 —— 所以只要选中了文本框，
    /// 就要把字号/字体/背景/边框这一行露出来，否则用户没有调整尺寸的入口。
    var hasSelectedText: Bool = false
    var onSave: () -> Void
    var onCopy: () -> Void
    var onUndo: () -> Void
    var onDelete: () -> Void
    var onCancel: () -> Void

    private let colors: [Color] = [.red, .yellow, .green, .blue, .white, .black]
    private let bgColors: [Color] = [.black, .white, .yellow, .blue]
    private let borderColors: [Color] = [.white, .black, .red]

    /// 下拉控件的悬停高亮：默认底色很淡，鼠标移上去变亮，让人看得出「这里能点」。
    @State private var hoverFontSize = false
    @State private var hoverFont = false

    private var isTextMode: Bool { selectedTool == .text }

    /// 是否展示二级「文本样式」行：文本工具下始终展示（此时改的是新建默认样式），
    /// 或者当前选中了某个文本框（此时改的是那个框）—— 文本框不能拉伸，必须有这个入口。
    private var showTextStyle: Bool { isTextMode || hasSelectedText }

    var body: some View {
        VStack(spacing: 6) {
            // 第一行：工具 + 撤销 + 保存/复制/取消。
            // 文本模式下隐藏「颜色」「线宽」两组——它们搬到第二行、且语义变成文字样式，
            // 避免同一个工具栏出现两个互相打架的色板。
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(AnnotationTool.allCases, id: \.self) { tool in
                        toolButton(tool)
                    }
                }

                smallDivider

                if !showTextStyle {
                    HStack(spacing: 4) {
                        ForEach(colors, id: \.self) { c in
                            colorButton(c)
                        }
                    }

                    smallDivider

                    HStack(spacing: 6) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 13)).foregroundColor(.white.opacity(0.8))
                        Slider(value: $lineWidth, in: 1...12)
                            .frame(width: 70)
                        Image(systemName: "plus.circle")
                            .font(.system(size: 13)).foregroundColor(.white.opacity(0.8))
                    }

                    smallDivider
                }

                actionButton("arrow.uturn.backward", color: .white, enabled: canUndo,
                             help: "撤销", action: onUndo)
                actionButton("trash", color: .white, enabled: canDelete,
                             help: "删除选中标注（Delete）", action: onDelete)

                smallDivider

                HStack(spacing: 6) {
                    actionButton("doc.on.doc", color: .white, help: "复制到剪贴板", action: onCopy)
                    actionButton("square.and.arrow.down", color: .green, help: "保存为文件", action: onSave)
                    actionButton("xmark.circle", color: .red, help: "取消截屏（Esc）", action: onCancel)
                }
            }

            if showTextStyle { textStyleRow }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.black.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                )
        )
        // 实测自身尺寸并上报，供 overlay 钳制位置使用。
        // 放在最后：此时量到的是含 padding / background 的最终尺寸（文本模式下含第二行）。
        .background(
            GeometryReader { g in
                Color.clear.preference(key: ToolbarSizeKey.self, value: g.size)
            }
        )
    }

    // MARK: - 第二行：文本样式

    private var textStyleRow: some View {
        HStack(spacing: 10) {
            // 字号：预设下拉（14~72）。滑杆很难精确拖到目标值，
            // 而且会拖出 15.7 这种奇怪数值，改成点选更快更准。
            // 图标已经并进控件内部，整个左侧区域都是热区。
            fontSizeControl

            smallDivider

            // 字体族 + 加粗
            HStack(spacing: 6) {
                fontMenu
                boldButton
            }

            smallDivider

            // 文字颜色（与主色板同一个绑定值）
            HStack(spacing: 4) {
                ForEach(colors, id: \.self) { c in
                    colorButton(c)
                }
            }
            .help("文字颜色")

            smallDivider

            // 背景色 / 透明
            HStack(spacing: 4) {
                transparentSwatch
                ForEach(bgColors, id: \.self) { c in
                    bgSwatch(c)
                }
            }

            smallDivider

            // 边框粗细 + 边框颜色
            HStack(spacing: 4) {
                ForEach(TextBorderPreset.allCases, id: \.self) { p in
                    borderPresetButton(p)
                }
                ForEach(borderColors, id: \.self) { c in
                    borderSwatch(c)
                }
            }
        }
    }

    /// 常用字号预设：最小 14、最大 72，中间按常用档位排布。
    /// 用点选代替滑杆 —— 拖动选择既难精确命中目标值，又会拖出 15.7 这类非整数。
    private let fontSizePresets: [CGFloat] = [14, 16, 18, 20, 22, 24, 28, 32, 36, 42, 48, 56, 64, 72]

    /// 字号控件：预设下拉（14–72）。
    /// 三个细节都是为了「一眼能看到、随手能点开」：
    /// ① 背景 + 描边画在 `Menu` **外层** —— 写在 `label` 里的 background 会被
    ///    `.borderlessButton` 菜单样式接管，实际渲染出来近乎透明，很难发现这里有控件；
    /// ② 图标 / 文字 / 箭头**全都在 label 内**，所以控件左侧整片区域都能点开菜单
    ///    （用户预期「Aa 子工具栏左边随便点都能选字号」）；
    /// ③ 明确写出「字号」二字，而不是只留一个裸数字。
    private var fontSizeControl: some View {
        Menu {
            ForEach(fontSizePresets, id: \.self) { size in
                Button {
                    textStyle.fontSize = size
                } label: {
                    if abs(textStyle.fontSize - size) < 0.5 {
                        Label("\(Int(size))", systemImage: "checkmark")
                    } else {
                        Text("\(Int(size))")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "textformat.size")
                    .font(.system(size: 11, weight: .semibold))
                Text("字号 \(Int(textStyle.fontSize.rounded()))")
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 9)
            .frame(height: 26)
            // 显式声明命中形状：否则 HStack 里的透明间隙不参与命中测试，
            // 只有「字上」那几像素能点到，看起来就像没反应。
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(hoverFontSize ? 0.3 : 0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.white.opacity(hoverFontSize ? 0.75 : 0.5), lineWidth: 1)
        )
        .onHover { hoverFontSize = $0 }
        .help("字号（14–72）")
    }

    private var fontMenu: some View {
        Menu {
            ForEach(TextFontDesign.allCases, id: \.self) { d in
                Button {
                    textStyle.design = d
                } label: {
                    if textStyle.design == d {
                        Label(d.label, systemImage: "checkmark")
                    } else {
                        Text(d.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "character")
                    .font(.system(size: 11, weight: .semibold))
                Text(textStyle.design.label).font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(hoverFont ? 0.3 : 0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.white.opacity(hoverFont ? 0.75 : 0.5), lineWidth: 1)
        )
        .onHover { hoverFont = $0 }
        .help("字体")
    }

    private var boldButton: some View {
        Button { textStyle.bold.toggle() } label: {
            Image(systemName: "bold")
                .font(.system(size: 13))
                .foregroundColor(textStyle.bold ? .black : .white)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(textStyle.bold ? .white : .white.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
        .help("加粗")
    }

    private var transparentSwatch: some View {
        let active = textStyle.backgroundOpacity <= 0.01
        return Button { textStyle.backgroundOpacity = 0 } label: {
            Image(systemName: "circle.dashed")
                .font(.system(size: 11))
                .foregroundColor(active ? .black : .white.opacity(0.85))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(active ? .white : .white.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
        .help("背景透明")
    }

    private func bgSwatch(_ c: Color) -> some View {
        let active = textStyle.backgroundOpacity > 0.01 && textStyle.backgroundColor == c
        return Button {
            textStyle.backgroundColor = c
            // 从「透明」切到有底色时给一个默认不透明度：全不透明会把截图内容盖死
            if textStyle.backgroundOpacity <= 0.01 { textStyle.backgroundOpacity = 0.9 }
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(c)
                .frame(width: 16, height: 16)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(.white.opacity(active ? 0.95 : 0.3), lineWidth: active ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
        .help("背景色")
    }

    private func borderPresetButton(_ p: TextBorderPreset) -> some View {
        let active = abs(textStyle.borderWidth - p.width) < 0.01
        return Button { textStyle.borderWidth = p.width } label: {
            Text(p.label)
                .font(.system(size: 11))
                .foregroundColor(active ? .black : .white.opacity(0.85))
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(active ? .white : .white.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
        .help("边框粗细")
    }

    private func borderSwatch(_ c: Color) -> some View {
        let active = textStyle.borderWidth > 0.01 && textStyle.borderColor == c
        return Button {
            textStyle.borderColor = c
            if textStyle.borderWidth <= 0.01 { textStyle.borderWidth = TextBorderPreset.thin.width }
        } label: {
            Circle()
                .fill(c)
                .frame(width: 14, height: 14)
                .overlay(
                    Circle().stroke(.white.opacity(active ? 0.95 : 0.3), lineWidth: active ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
        .help("边框颜色")
    }

    // MARK: - 基础控件

    private var smallDivider: some View {
        Divider().frame(height: 20).background(.white.opacity(0.35))
    }

    private func toolButton(_ tool: AnnotationTool) -> some View {
        let selected = selectedTool == tool
        return Button(action: { selectedTool = tool }) {
            Image(systemName: tool.systemImage)
                .font(.system(size: 16))
                .foregroundColor(selected ? .black : .white)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? .white : .white.opacity(0.08))
                )
        }
        .buttonStyle(.plain)
        .help(tool.label)
    }

    private func colorButton(_ c: Color) -> some View {
        let selected = c == color
        return Button(action: { color = c }) {
            Circle()
                .fill(c)
                .frame(width: 18, height: 18)
                .overlay(
                    Circle().stroke(.white.opacity(selected ? 0.9 : 0.3), lineWidth: selected ? 2 : 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func actionButton(_ icon: String, color: Color, enabled: Bool = true,
                              help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundColor(enabled ? color : .white.opacity(0.3))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}
