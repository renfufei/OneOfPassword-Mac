//
//  CopyButton.swift
//  OneOfPassword
//
//  复制按钮组件 + 全局按钮样式
//

import SwiftUI

// MARK: - 主操作按钮（填充色）

struct FilledButtonStyle: ButtonStyle {
    var tint: Color
    var isDisabled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 19).weight(.medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(isDisabled ? 0.30 : (configuration.isPressed ? 0.75 : 1.0)))
            )
            .foregroundColor(isDisabled ? .white.opacity(0.5) : .white)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 次要操作按钮（轮廓线）

struct OutlineButtonStyle: ButtonStyle {
    var tint: Color
    var isDisabled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 19).weight(.medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(configuration.isPressed ? 0.10 : 0.0))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(tint.opacity(isDisabled ? 0.25 : 0.55), lineWidth: 1)
                    )
            )
            .foregroundColor(isDisabled ? tint.opacity(0.35) : tint)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 轻量添加按钮（浅色填充，用于列表内 "添加xxx"）

struct GhostButtonStyle: ButtonStyle {
    var tint: Color
    var isDisabled: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 19))
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(tint.opacity(isDisabled ? 0.05 : (configuration.isPressed ? 0.18 : 0.10)))
            )
            .foregroundColor(isDisabled ? tint.opacity(0.3) : tint)
            .contentShape(RoundedRectangle(cornerRadius: 7))
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
            .font(.system(size: 19))
            .padding(.horizontal, 18)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(isDisabled ? 0.08 : (configuration.isPressed ? 0.25 : 0.12)))
            )
            .foregroundColor(isDisabled ? .secondary : tint)
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
            .font(.system(size: 13))
            .foregroundColor(configuration.isPressed ? tint.opacity(0.6) : tint)
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
                    .font(.caption)
            }
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
