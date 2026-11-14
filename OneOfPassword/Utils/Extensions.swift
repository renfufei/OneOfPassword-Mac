//
//  Extensions.swift
//  OneOfPassword
//
//  扩展方法
//

import SwiftUI
import AppKit

// MARK: - View Extensions

extension View {
    func placeholder<Content: View>(
        when shouldShow: Bool,
        alignment: Alignment = .leading,
        @ViewBuilder placeholder: () -> Content
    ) -> some View {
        ZStack(alignment: alignment) {
            placeholder().opacity(shouldShow ? 1 : 0)
            self
        }
    }
}

// MARK: - Color Extensions

extension Color {
    static let primaryAccent = Color.blue
    static let secondaryAccent = Color.gray.opacity(0.6)
}

// MARK: - 外部链接

/// 设置页与「帮助」菜单共用同一份地址，别在两处硬编码。
enum AppLinks {
    static let githubHomepage = URL(string: "https://github.com/renfufei/OneOfPassword-Mac")!

    /// 交给系统默认浏览器打开（菜单里没有 SwiftUI 的 `openURL` 环境值，统一走这一处）。
    static func openGitHubHomepage() {
        NSWorkspace.shared.open(githubHomepage)
    }
}
