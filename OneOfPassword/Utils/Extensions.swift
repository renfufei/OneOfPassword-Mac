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
    /// 悬停时把光标切成「小手」——可点击的视觉提示。
    ///
    /// 用 `push`/`pop` 而不是 `set()`：`set()` 会把光标永久改成小手，直到别处再改回来，
    /// 鼠标快速划过时经常留下「停在空白处还是小手」的残影。`push`/`pop` 成对出入栈，
    /// 由系统负责还原成箭头。`pushed` 守卫是必须的：视图若在悬停中被移除，
    /// `onHover` 可能只收到 `false`，没有守卫就会多 `pop` 一次、把别的光标弹掉。
    func pointingHandOnHover() -> some View {
        modifier(PointingHandCursorModifier())
    }

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

/// `pointingHandOnHover()` 的实现。抽成独立类型是为了持有 `@State`（记录是否已入栈）。
struct PointingHandCursorModifier: ViewModifier {
    @State private var pushed = false

    func body(content: Content) -> some View {
        content.onHover { inside in
            if inside, !pushed {
                NSCursor.pointingHand.push()
                pushed = true
            } else if !inside, pushed {
                NSCursor.pop()
                pushed = false
            }
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
