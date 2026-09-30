//
//  CopyButton.swift
//  OneOfPassword
//
//  复制按钮组件 + 全局按钮样式
//
//  === 样式约定（2026-09-30 重做）===
//  用户反馈：换一台 macOS（27.0.1）后按钮整体变大，有部分被容器遮住了。
//  根因是**按钮高度不受约束**：label 只给了 `.padding(.vertical, 7)`，
//  文本一旦被挤到折行，按钮就从 1 行高变成 2 行高，外层定高的 HStack / GroupBox 立刻裁切。
//  因此这里统一：
//  ① 高度来自 `AppMetrics`（`minHeight`，不是 padding），跨机器一致；
//  ② 文本一律 `lineLimit(1)` —— **禁止折行**，这是「高度不可控」的唯一入口；
//  ③ 字号由 19 收到 14：19pt 在 macOS 上明显偏大，是「按钮显得很大」的直接原因；
//  ④ 最小宽度给出，避免单字按钮缩成一坨；宽度仍可增长（长文案 / 本地化不受影响）。
//

import SwiftUI

// MARK: - 主操作按钮（填充色）

struct FilledButtonStyle: ButtonStyle {
    var tint: Color
    var isDisabled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: AppMetrics.buttonFontSize, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, AppMetrics.buttonPaddingH)
            .frame(minWidth: AppMetrics.buttonMinWidth,
                   minHeight: AppMetrics.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: AppMetrics.buttonCorner)
                    .fill(tint.opacity(isDisabled ? 0.30 : (configuration.isPressed ? 0.75 : 1.0)))
            )
            .foregroundColor(isDisabled ? .white.opacity(0.5) : .white)
            .contentShape(RoundedRectangle(cornerRadius: AppMetrics.buttonCorner))
    }
}

// MARK: - 次要操作按钮（轮廓线）

struct OutlineButtonStyle: ButtonStyle {
    var tint: Color
    var isDisabled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: AppMetrics.buttonFontSize, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, AppMetrics.buttonPaddingH)
            .frame(minWidth: AppMetrics.buttonMinWidth,
                   minHeight: AppMetrics.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: AppMetrics.buttonCorner)
                    .fill(tint.opacity(configuration.isPressed ? 0.10 : 0.0))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppMetrics.buttonCorner)
                            .stroke(tint.opacity(isDisabled ? 0.25 : 0.55), lineWidth: 1)
                    )
            )
            .foregroundColor(isDisabled ? tint.opacity(0.35) : tint)
            .contentShape(RoundedRectangle(cornerRadius: AppMetrics.buttonCorner))
    }
}

// MARK: - 轻量添加按钮（浅色填充，用于列表内 "添加xxx"）

struct GhostButtonStyle: ButtonStyle {
    var tint: Color
    var isDisabled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: AppMetrics.ghostFontSize))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minWidth: AppMetrics.ghostButtonMinWidth,
                   minHeight: AppMetrics.ghostButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: AppMetrics.dropdownCorner)
                    .fill(tint.opacity(isDisabled ? 0.05 : (configuration.isPressed ? 0.18 : 0.10)))
            )
            .foregroundColor(isDisabled ? tint.opacity(0.3) : tint)
            .contentShape(RoundedRectangle(cornerRadius: AppMetrics.dropdownCorner))
    }
}

// MARK: - 便捷扩展

extension ButtonStyle where Self == FilledButtonStyle {
    /// 主操作：蓝色填充（保存、确认、导出、使用）
    static func primary(disabled: Bool = false) -> FilledButtonStyle {
        FilledButtonStyle(tint: .accentColor, isDisabled: disabled)
    }
    /// 危险操作：红色填充（删除确认）
    static func destructive(disabled: Bool = false) -> FilledButtonStyle {
        FilledButtonStyle(tint: .red, isDisabled: disabled)
    }
}

extension ButtonStyle where Self == OutlineButtonStyle {
    /// 次要操作：蓝色轮廓（取消、上一步）
    static func secondary(disabled: Bool = false) -> OutlineButtonStyle {
        OutlineButtonStyle(tint: .accentColor, isDisabled: disabled)
    }
    /// 次要危险：红色轮廓（取消、关闭向导）
    static func secondaryDestructive(disabled: Bool = false) -> OutlineButtonStyle {
        OutlineButtonStyle(tint: .red, isDisabled: disabled)
    }
}

extension ButtonStyle where Self == GhostButtonStyle {
    /// 轻量添加：蓝色 ghost（列表内添加操作）
    static func addAction(disabled: Bool = false) -> GhostButtonStyle {
        GhostButtonStyle(tint: .accentColor, isDisabled: disabled)
    }
    /// 轻量生成：绿色 ghost（生成密码）
    static func generate(disabled: Bool = false) -> GhostButtonStyle {
        GhostButtonStyle(tint: .green, isDisabled: disabled)
    }
}

// MARK: - 旧样式兼容别名（逐步迁移用）

struct TintedButtonStyle: ButtonStyle {
    var tint: Color
    var isDisabled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: AppMetrics.ghostFontSize))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minWidth: AppMetrics.ghostButtonMinWidth,
                   minHeight: AppMetrics.ghostButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: AppMetrics.dropdownCorner)
                    .fill(tint.opacity(isDisabled ? 0.08 : (configuration.isPressed ? 0.25 : 0.12)))
            )
            .foregroundColor(isDisabled ? .secondary : tint)
            .contentShape(RoundedRectangle(cornerRadius: AppMetrics.dropdownCorner))
    }
}

extension ButtonStyle where Self == TintedButtonStyle {
    static func confirm(disabled: Bool = false) -> TintedButtonStyle {
        TintedButtonStyle(tint: .accentColor, isDisabled: disabled)
    }
    static func danger(disabled: Bool = false) -> TintedButtonStyle {
        TintedButtonStyle(tint: .red, isDisabled: disabled)
    }
}

// MARK: - 图标按钮（圆形背景）

struct IconCircleButtonStyle: ButtonStyle {
    var tint: Color = .secondary
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .foregroundColor(configuration.isPressed ? tint.opacity(0.6) : tint)
            // 宽高都是显式固定值：图标按钮的形状不随所在容器变化
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(tint.opacity(configuration.isPressed ? 0.15 : 0.0))
            )
            .contentShape(Circle())
    }
}

extension ButtonStyle where Self == IconCircleButtonStyle {
    static func iconCircle(tint: Color = .secondary, size: CGFloat = 28) -> IconCircleButtonStyle {
        IconCircleButtonStyle(tint: tint, size: size)
    }
}

// MARK: - 复制按钮组件

struct CopyButton: View {
    let text: String
    let label: String
    @State private var copied = false

    var body: some View {
        Button(action: copyToClipboard) {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundColor(copied ? .green : .accentColor)
                Text(label)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            // 固定单行高度：borderless 按钮的高度会随文字换行/系统版本漂移，
            // 这里钉死，保证在密集行里不会把邻居挤走。
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }

    private func copyToClipboard() {
        ClipboardManager.shared.copy(text)
        withAnimation {
            copied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copied = false }
        }
    }
}
