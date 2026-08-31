//
//  AnnotationToolbar.swift
//  OneOfPassword
//
//  截屏标注工具栏：矩形/圆形/箭头/画笔/文本 + 颜色 + 线宽 + 保存/复制/取消。
//

import SwiftUI

struct AnnotationToolbar: View {
    @Binding var selectedTool: AnnotationTool
    @Binding var color: Color
    @Binding var lineWidth: CGFloat
    var canUndo: Bool
    var onSave: () -> Void
    var onCopy: () -> Void
    var onUndo: () -> Void
    var onCancel: () -> Void

    private let colors: [Color] = [.red, .yellow, .green, .blue, .white, .black]

    var body: some View {
        HStack(spacing: 10) {
            // 工具
            HStack(spacing: 4) {
                ForEach(AnnotationTool.allCases, id: \.self) { tool in
                    toolButton(tool)
                }
            }

            Divider().frame(height: 24).background(.white.opacity(0.4))

            // 颜色
            HStack(spacing: 4) {
                ForEach(colors, id: \.self) { c in
                    colorButton(c)
                }
            }

            Divider().frame(height: 24).background(.white.opacity(0.4))

            // 线宽
            HStack(spacing: 6) {
                Image(systemName: "minus.circle")
                    .font(.system(size: 13)).foregroundColor(.white.opacity(0.8))
                Slider(value: $lineWidth, in: 1...12)
                    .frame(width: 70)
                Image(systemName: "plus.circle")
                    .font(.system(size: 13)).foregroundColor(.white.opacity(0.8))
            }

            Divider().frame(height: 24).background(.white.opacity(0.4))

            // 后退（撤销）
            actionButton("arrow.uturn.backward", color: .white, enabled: canUndo, action: onUndo)

            Divider().frame(height: 24).background(.white.opacity(0.4))

            // 操作
            HStack(spacing: 6) {
                actionButton("doc.on.doc", color: .white, action: onCopy)
                actionButton("square.and.arrow.down", color: .green, action: onSave)
                actionButton("xmark.circle", color: .red, action: onCancel)
            }
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

    private func actionButton(_ icon: String, color: Color, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17))
                .foregroundColor(enabled ? color : .white.opacity(0.3))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help("撤销")
    }
}
