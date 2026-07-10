//
//  Extensions.swift
//  OneOfPassword
//
//  扩展方法
//

import SwiftUI

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
