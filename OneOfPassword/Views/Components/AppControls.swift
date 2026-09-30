//
//  AppControls.swift
//  OneOfPassword
//
//  统一下拉控件 + 全局控件度量。
//
//  === 为什么单独抽这一层（2026-09-30）===
//  用户反馈两件事：
//  ① 下拉按钮「字体小、长长的一条」，看着很丑；
//  ② 在另一台 macOS 上按钮整体变大，有部分被容器遮住了。
//
//  根因不是某一处写错，而是**每个下拉各写各的字体/内边距，且按钮高度不受约束**：
//  - 字体各写一份 → 12 / 13 / 系统默认混用，视觉上忽大忽小；
//  - 没有 `lineLimit(1)` → 文本一旦被挤到折行，控件就从 1 行变 2 行高，
//    外层那些定高（`.frame(height:)` / GroupBox 行）的容器立刻把内容裁掉。
//    这是「换一台机器按钮变大被遮住」的真正机制（不是字体本身变了）。
//
//  对策：
//  ① 字体 / 高度 / 圆角 / 内边距**全部**从 `AppMetrics` 取，不再各写一份；
//  ② 所有文本一律 `lineLimit(1)`（禁止折行），高度由 `AppMetrics` 锁死；
//  ③ 背景与描边画在 `Menu` **外层** —— 写在 `label` 里会被 `.borderlessButton`
//     菜单样式接管，实际渲染近乎透明（此前踩过，用户「看不出这里有控件」）。
//

import SwiftUI
import AppKit

// MARK: - 全局控件度量

/// 全应用统一的控件度量。**新增控件请从这里取值，不要再写魔法数字。**
///
/// 取值的两个原则：
/// - 高度固定：控件垂直尺寸只由这里决定，与所在容器、macOS 版本无关；
/// - 横向自适应：宽度允许随文字变化，但靠 `lineLimit(1)` 保证永远单行，
///   所以「宽度变 → 高度变 → 被裁切」这条链路被彻底切断。
enum AppMetrics {
    /// 文本按钮（主/次/危险）的固定高度与最小宽度。
    static let buttonHeight: CGFloat = 32
    static let buttonMinWidth: CGFloat = 88
    /// 轻量按钮（列表内「添加…」）比常规按钮矮一点。
    static let ghostButtonHeight: CGFloat = 28
    static let ghostButtonMinWidth: CGFloat = 72
    /// 下拉控件的固定高度。
    static let dropdownHeight: CGFloat = 28
    /// 下拉标题的最小宽度：让「字号 18」「修改时间」这类短标题的控件宽度趋于一致，
    /// 不会因为标题只有两个字就缩成一小坨。
    static let dropdownTitleMinWidth: CGFloat = 36
    static let dropdownCorner: CGFloat = 6
    static let buttonCorner: CGFloat = 8

    /// 字号：常规按钮 14、轻量按钮 13、下拉 13。
    /// 不再用 19 —— 那个尺寸在 macOS 上明显偏大，是「按钮显得很大」的直接原因之一。
    static let buttonFontSize: CGFloat = 14
    static let ghostFontSize: CGFloat = 13
    static let dropdownFontSize: CGFloat = 13

    /// 下拉控件左右内边距。
    static let dropdownPaddingH: CGFloat = 10
    /// 按钮左右内边距。
    static let buttonPaddingH: CGFloat = 16

    /// 设置页里「开关 / 路径」这类一行的最小高度。
    /// 用途与按钮高度同理：这一行由系统控件（`Toggle`）或长文本组成，
    /// 高度不受我们控制，给个下限可避免某台机器上被外层容器裁掉。
    static let settingRowMinHeight: CGFloat = 26
    /// 存储位置等「左侧标签」列的固定宽度（原先各处硬编码 100）。
    static let pathLabelWidth: CGFloat = 88
    /// 行内小图标按钮（复制路径 / 在访达中显示）的宽度。
    /// 加它是因为不同 SF Symbol 的自然宽度不同（`doc.on.doc` 比 `arrow.right.circle` 窄），
    /// 不锁宽的话两个按钮并排会随图标切换而左右抖动。
    static let iconButtonWidth: CGFloat = 16
}

// MARK: - 下拉控件配色

/// 下拉控件的配色方案。两套：浅色界面（设置页、列表）与深色浮层（截屏标注工具栏）。
struct DropdownStyle {
    var foreground: Color
    var fill: Color
    var fillHover: Color
    var border: Color
    var borderHover: Color

    /// 浅色界面（跟随系统明暗：底/描边用中性灰，文字用 `.primary`）。
    static let light = DropdownStyle(
        foreground: .primary,
        fill: Color.gray.opacity(0.12),
        fillHover: Color.gray.opacity(0.22),
        border: Color.gray.opacity(0.30),
        borderHover: Color.gray.opacity(0.50)
    )

    /// 深色浮层（截屏标注工具栏）。**数值与改造前逐值一致**，不要随手调，
    /// 否则截屏工具栏的观感会回退。
    static let dark = DropdownStyle(
        foreground: .white,
        fill: .white.opacity(0.18),
        fillHover: .white.opacity(0.30),
        border: .white.opacity(0.50),
        borderHover: .white.opacity(0.75)
    )
}

// MARK: - 下拉控件的壳

/// 下拉控件的「壳」：固定高度 + 圆角底 + 描边 + 悬停高亮。
///
/// 必须作为**修饰器**作用在 `Menu` 外层，而不是写进 `label`：
/// `.borderlessButton` 菜单样式会接管 label 里的背景，渲染出来几乎看不见。
private struct DropdownChrome: ViewModifier {
    var style: DropdownStyle
    var height: CGFloat
    var corner: CGFloat

    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: corner)
                    .fill(hovering ? style.fillHover : style.fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner)
                    .stroke(hovering ? style.borderHover : style.border, lineWidth: 1)
            )
            // 显式命中形状：HStack 里的透明间隙默认不参与命中测试，
            // 只有图标/文字那几像素能点到，看起来就像「点不动」。
            .contentShape(RoundedRectangle(cornerRadius: corner))
            .onHover { hovering = $0 }
    }
}

extension View {
    /// 套上下拉控件的统一外观（固定高度 + 圆角底 + 描边 + 悬停高亮）。
    func dropdownChrome(_ style: DropdownStyle = .light,
                        height: CGFloat = AppMetrics.dropdownHeight,
                        corner: CGFloat = AppMetrics.dropdownCorner) -> some View {
        modifier(DropdownChrome(style: style, height: height, corner: corner))
    }
}

// MARK: - 下拉按钮的 label

/// 下拉按钮左侧的装饰：无 / SF Symbol / 色块（颜色下拉用）。
enum DropdownLeading {
    case none
    case icon(String)
    case swatch(Color)
}

/// 下拉按钮的 label：`[装饰] 标题 ▾`。
/// 三个要点（缺一个就会出现「小字体」「长长一条」「点不动」）：
/// ① 标题**永远单行**（`lineLimit(1)` + `truncationMode(.tail)`），折行会撑高控件；
/// ② 标题给一个最小宽度，让短标题的控件不至于缩成一小坨；
/// ③ 整块挂 `contentShape`（在 `DropdownChrome` 里），左侧图标区也能点开。
struct DropdownLabel: View {
    var title: String
    var leading: DropdownLeading = .none
    var fontSize: CGFloat = AppMetrics.dropdownFontSize
    var foreground: Color = .primary
    var titleMinWidth: CGFloat = AppMetrics.dropdownTitleMinWidth
    var paddingH: CGFloat = AppMetrics.dropdownPaddingH

    /// 标题为空时**整个文本节点都不渲染** —— 颜色下拉只有一张色卡 + 箭头，
    /// 留一个空 `Text` 会白占 5pt 间距还多一次布局。
    private var hasTitle: Bool { !title.isEmpty }

    var body: some View {
        HStack(spacing: hasTitle ? 5 : 4) {
            switch leading {
            case .none:
                EmptyView()
            case .icon(let name):
                Image(systemName: name)
                    .font(.system(size: fontSize - 2, weight: .semibold))
            case .swatch(let color):
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: 16, height: 16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(.white.opacity(0.85), lineWidth: 1)
                    )
            }

            if hasTitle {
                Text(title)
                    .font(.system(size: fontSize, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: titleMinWidth, alignment: .leading)
            }

            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .opacity(0.9)
        }
        .foregroundColor(foreground)
        .padding(.horizontal, paddingH)
    }
}

// MARK: - 通用下拉（文本选项）

/// 通用下拉：一个按钮 + 弹出选项列表。
///
/// **所有「从一串选项里挑一个」的下拉都用它**，不要再用裸 `Menu` / `Picker`：
/// 裸控件会跟随 macOS 版本变化（新系统的 popup button 更高更宽），
/// 而这里的高度、字体、内边距全部被 `AppMetrics` 锁死，跨版本表现一致。
struct AppDropdown<Item: Hashable>: View {
    var title: String
    var leading: DropdownLeading = .none
    let items: [Item]
    /// 选项显示的文案
    let label: (Item) -> String
    /// 是否是当前选中项（会打勾并标注「（当前）」）
    let isCurrent: (Item) -> Bool
    let onPick: (Item) -> Void

    var style: DropdownStyle = .light
    var height: CGFloat = AppMetrics.dropdownHeight
    var fontSize: CGFloat = AppMetrics.dropdownFontSize
    var titleMinWidth: CGFloat = AppMetrics.dropdownTitleMinWidth
    var help: String? = nil

    var body: some View {
        Menu {
            ForEach(items, id: \.self) { item in
                Button {
                    onPick(item)
                } label: {
                    if isCurrent(item) {
                        Label("\(label(item))（当前）", systemImage: "checkmark")
                    } else {
                        Text(label(item))
                    }
                }
            }
        } label: {
            DropdownLabel(title: title,
                          leading: leading,
                          fontSize: fontSize,
                          foreground: style.foreground,
                          titleMinWidth: titleMinWidth)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // fixedSize：宽度由内容决定，**绝不拉伸填充** —— 这就是「长长的一条」的根治办法。
        .fixedSize()
        .dropdownChrome(style, height: height)
        .help(help ?? title)
    }
}

// MARK: - 颜色下拉（带色块的选项）

/// 颜色下拉：常驻 **1 张当前色卡** + 下拉箭头，点任意位置弹出该用途的全部预设色。
///
/// 与 `AppDropdown` 分开是因为菜单项需要「色块 + 名称」，
/// 而 macOS 菜单只渲染 `Image` / `Text`，不认 SwiftUI 的 `RoundedRectangle` ——
/// 必须先把颜色画成一张小 `NSImage` 再塞进 `Label` 的 icon 位。
struct AppColorDropdown: View {
    var current: Color
    let options: [(name: String, color: Color)]
    let onPick: (Color) -> Void

    var style: DropdownStyle = .dark
    var height: CGFloat = AppMetrics.dropdownHeight
    var help: String

    var body: some View {
        Menu {
            ForEach(options, id: \.name) { opt in
                Button {
                    onPick(opt.color)
                } label: {
                    // 必须用 `Label { } icon: { }` 显式形式：
                    // `Label("名", image: Image(...))` 会和 `Label(_:image name:)`
                    // （字符串资源名重载）打架，报「cannot convert Image to String」。
                    Label {
                        Text(opt.color == current ? "\(opt.name)（当前）" : opt.name)
                    } icon: {
                        Image(nsImage: Self.swatchImage(opt.color))
                    }
                }
            }
        } label: {
            DropdownLabel(title: "",
                          leading: .swatch(current),
                          fontSize: AppMetrics.dropdownFontSize,
                          foreground: style.foreground,
                          titleMinWidth: 0,
                          // 只有一张色卡 + 箭头，内边距比文字下拉收紧
                          paddingH: 7)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .dropdownChrome(style, height: height)
        .help(help)
    }

    /// 菜单项里的色块图。
    /// macOS 菜单只渲染 `Image` / `Text`，不认 SwiftUI 的 `Circle` / `RoundedRectangle`，
    /// 所以先把颜色画成一张小 `NSImage` 再塞进 `Label`。
    static func swatchImage(_ c: Color, size: CGFloat = 14) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let r = rect.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            NSColor(c).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }
}
