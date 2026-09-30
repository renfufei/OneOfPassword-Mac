//
//  AnnotationToolbar.swift
//  OneOfPassword
//
//  截屏标注工具栏：矩形/圆形/箭头/画笔/文本 + 颜色 + 线宽 + 保存/复制/取消。
//  文本工具下额外展开第二行「文本样式」工具栏（字号/字体/加粗/文字色/背景/边框）。
//
//  === 可用性约定（2026-09-29）===
//  ① **每个控件都有 `.help(...)` 悬停提示**，文案里带「用途 + 当前值」：
//     如「文字颜色：红（点击选择）」「背景：透明（当前，不画底色）」「边框粗细：细」。
//     光看色块/图标用户猜不到点下去会改什么 —— 这是本轮的主要反馈。
//  ② 颜色不再平铺一排色卡，改成 **1 张当前色卡 + 下拉弹出**（`colorWell`）：
//     弹出层按中文名列出该用途的全部预设色（菜单项左侧是色块图），选中后当前色卡被替换。
//  ③ 四套颜色**互相独立**（图形 / 文字 / 背景 / 边框），各用各的色板与提示文案，
//     对应模型里的 `AnnotationShape.color`、`TextStyle.textColor`、
//     `TextStyle.backgroundColor`、`TextStyle.borderColor` 四个字段，禁止互相借用。
//  ④ 色板分组的可见标签（`groupLabel`）：「文字 / 背景 / 边框」——
//     不依赖鼠标悬停也能看懂那一组是干什么的。
//
//  === 控件尺寸约定（2026-09-30）===
//  本工具栏的下拉（字号 / 字体 / 颜色）**全部**基于 `AppControls.swift` 里的
//  `AppDropdown` / `AppColorDropdown` + `DropdownStyle.dark`，高度统一 26pt、
//  字号统一 13pt、背景/描边/悬停高亮由 `DropdownChrome` 一处提供。
//  改造前每个下拉各写一份字体（11/12）与内边距，视觉上忽大忽小；
//  且尺寸跟随 macOS 版本漂移（新系统的菜单按钮更高更宽）→ 工具栏被撑高后位置钳制失效。
//  本文件**不再自己拼 Menu**，要加下拉请直接用上面的统一控件。
//

import SwiftUI
import AppKit

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
    /// 图形颜色（矩形/圆形/箭头/画笔）。**不是**文字颜色 —— 文字颜色在 `textStyle.textColor`。
    @Binding var color: Color
    @Binding var lineWidth: CGFloat
    /// 文本样式（字号/字体/文字色/背景/边框）。选中某个文本框时是那个框的样式，
    /// 否则是「新建文本框」的默认样式。
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

    private var isTextMode: Bool { selectedTool == .text }

    /// 是否展示二级「文本样式」行：文本工具下始终展示（此时改的是新建默认样式），
    /// 或者当前选中了某个文本框（此时改的是那个框）—— 文本框不能拉伸，必须有这个入口。
    private var showTextStyle: Bool { isTextMode || hasSelectedText }

    var body: some View {
        VStack(spacing: 6) {
            // 第一行：工具 + 颜色 + 线宽 + 撤销/删除 + 保存/复制/取消。
            // 文本模式下隐藏「颜色」「线宽」两组 —— 它们搬到第二行、且语义变成文字样式，
            // 避免同一个工具栏出现两个互相打架的色板。
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(AnnotationTool.allCases, id: \.self) { tool in
                        toolButton(tool)
                    }
                }

                smallDivider

                if !showTextStyle {
                    colorWell($color, role: .shape)

                    smallDivider

                    HStack(spacing: 6) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 13)).foregroundColor(.white.opacity(0.8))
                        Slider(value: $lineWidth, in: 1...12)
                            .frame(width: 70)
                        Image(systemName: "plus.circle")
                            .font(.system(size: 13)).foregroundColor(.white.opacity(0.8))
                    }
                    .help("线宽：\(Int(lineWidth.rounded())) pt（拖动调整）")

                    smallDivider
                }

                actionButton("arrow.uturn.backward", color: .white, enabled: canUndo,
                             help: "撤销（⌘Z）", action: onUndo)
                actionButton("trash", color: .white, enabled: canDelete,
                             help: canDelete ? "删除选中的标注（Delete）" : "删除选中的标注（先选中一个标注）",
                             action: onDelete)

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

            // 文字颜色（独立字段 `textStyle.textColor`，与图形颜色无关）
            groupLabel("文字")
            colorWell($textStyle.textColor, role: .text)

            smallDivider

            // 背景：透明是一个**状态**，单独一个按钮；颜色用下拉
            groupLabel("背景")
            HStack(spacing: 4) {
                transparentSwatch
                colorWell($textStyle.backgroundColor, role: .background)
            }

            smallDivider

            // 边框：粗细预设（无/细/中）+ 边框颜色下拉
            groupLabel("边框")
            HStack(spacing: 4) {
                ForEach(TextBorderPreset.allCases, id: \.self) { p in
                    borderPresetButton(p)
                }
                colorWell($textStyle.borderColor, role: .border)
            }
        }
    }

    // MARK: - 颜色控件（1 张当前色卡 + 下拉弹出）

    /// 紧凑颜色控件：**1 张当前色卡 + 一个下拉箭头**，点任意位置弹出该用途的全部预设色。
    ///
    /// 实现已统一到 `AppColorDropdown`（固定高度 + 统一字体/内边距/悬停高亮/色块图），
    /// 这里只负责把 `AnnotationColorRole` 的色板与当前值适配过去。
    /// `role` 同时决定配色与提示文案，四套颜色（图形/文字/背景/边框）互不串用。
    private func colorWell(_ color: Binding<Color>, role: AnnotationColorRole) -> some View {
        let current = color.wrappedValue
        return AppColorDropdown(
            current: current,
            options: role.options.map { (name: $0.name, color: $0.color) },
            onPick: { color.wrappedValue = $0 },
            style: .dark,
            // 截屏工具栏是紧凑深色浮层：26pt 与同排的工具按钮(30)/样式按钮(26)对齐，
            // 比设置页的 28pt 矮一点，避免工具栏被撑高。
            height: 26,
            help: "\(role.label)颜色：\(role.name(of: current))（点击选择）"
        )
    }

    /// 「背景透明」按钮 —— 它是状态（`backgroundOpacity = 0`）而不是一种颜色，所以不进色板。
    private var transparentSwatch: some View {
        let active = textStyle.backgroundOpacity <= 0.01
        return Button { textStyle.backgroundOpacity = 0 } label: {
            Image(systemName: "circle.dashed")
                .font(.system(size: 11))
                .foregroundColor(active ? .black : .white.opacity(0.85))
                .frame(width: 24, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(active ? .white : .white.opacity(0.18))
                )
        }
        .buttonStyle(.plain)
        .help(active ? "背景：透明（当前，不画底色）" : "背景：设为透明（不画底色）")
    }

    private func borderPresetButton(_ p: TextBorderPreset) -> some View {
        let active = abs(textStyle.borderWidth - p.width) < 0.01
        return Button { textStyle.borderWidth = p.width } label: {
            Text(p.label)
                .font(.system(size: 11))
                .foregroundColor(active ? .black : .white.opacity(0.85))
                .frame(width: 24, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(active ? .white : .white.opacity(0.18))
                )
        }
        .buttonStyle(.plain)
        .help(active ? "边框粗细：\(p.label)（当前）" : "边框粗细：\(p.label)")
    }

    // MARK: - 字号 / 字体

    /// 常用字号预设：最小 14、最大 72，中间按常用档位排布。
    /// 用点选代替滑杆 —— 拖动选择既难精确命中目标值，又会拖出 15.7 这类非整数。
    private let fontSizePresets: [CGFloat] = [14, 16, 18, 20, 22, 24, 28, 32, 36, 42, 48, 56, 64, 72]

    /// 字号控件：预设下拉（14–72）。
    ///
    /// 改用统一的 `AppDropdown`（深色）实现：字体 / 高度 / 内边距 / 悬停高亮全部来自
    /// `AppMetrics` 与 `DropdownStyle`，不再各写一份 —— 之前这个控件写 12pt、
    /// 旁边的图标写 11pt、边框按钮又写 11pt，视觉上就是用户说的「字体小、忽大忽小」。
    /// 图标 + 「字号 18」+ 箭头都在按钮内，左侧整片区域都是热区。
    private var fontSizeControl: some View {
        AppDropdown(
            title: "字号 \(Int(textStyle.fontSize.rounded()))",
            leading: .icon("textformat.size"),
            items: fontSizePresets,
            label: { "\(Int($0))" },
            isCurrent: { abs(textStyle.fontSize - $0) < 0.5 },
            onPick: { textStyle.fontSize = $0 },
            style: .dark,
            // 截屏工具栏是紧凑深色浮层：26pt 与同排按钮对齐
            height: 26,
            help: "字号：\(Int(textStyle.fontSize.rounded()))（点击选择 14–72）"
        )
    }

    /// 字体族下拉（深色），同样走统一控件。
    private var fontMenu: some View {
        AppDropdown(
            title: textStyle.design.label,
            leading: .icon("character"),
            items: TextFontDesign.allCases,
            label: { $0.label },
            isCurrent: { textStyle.design == $0 },
            onPick: { textStyle.design = $0 },
            style: .dark,
            height: 26,
            help: "字体：\(textStyle.design.label)（点击切换）"
        )
    }

    private var boldButton: some View {
        Button { textStyle.bold.toggle() } label: {
            Image(systemName: "bold")
                .font(.system(size: 13))
                .foregroundColor(textStyle.bold ? .black : .white)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(textStyle.bold ? .white : .white.opacity(0.18))
                )
        }
        .buttonStyle(.plain)
        .help(textStyle.bold ? "加粗：开（点击关闭）" : "加粗：关（点击开启）")
    }

    // MARK: - 基础控件

    /// 分组小标题（文字 / 背景 / 边框）。
    /// 颜色控件光看色块猜不出用途，写出来最直接 —— 不依赖鼠标悬停也能看懂。
    private func groupLabel(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11))
            .foregroundColor(.white.opacity(0.75))
            .fixedSize()
    }

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
        .help(tool.hint)
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
