//
//  AnnotationModel.swift
//  OneOfPassword
//
//  截屏标注数据模型
//

import SwiftUI

enum AnnotationTool: String, CaseIterable, Hashable {
    case selection
    case rectangle
    case circle
    case arrow
    case pen
    case text

    var label: String {
        switch self {
        case .selection: return "选区"
        case .rectangle: return "矩形"
        case .circle:    return "圆形"
        case .arrow:     return "箭头"
        case .pen:       return "画笔"
        case .text:      return "文本"
        }
    }

    var systemImage: String {
        switch self {
        case .selection: return "arrow.up.left.and.arrow.down.right"
        case .rectangle: return "rectangle"
        case .circle:    return "circle"
        case .arrow:     return "arrow.up.right"
        case .pen:       return "scribble"
        case .text:      return "textformat"
        }
    }
}

struct AnnotationShape: Identifiable, Hashable {
    let id: UUID
    var tool: AnnotationTool
    var points: [CGPoint]
    var color: Color
    var lineWidth: CGFloat
    var text: String?

    init(id: UUID = UUID(), tool: AnnotationTool, points: [CGPoint],
         color: Color, lineWidth: CGFloat, text: String? = nil) {
        self.id = id
        self.tool = tool
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
        self.text = text
    }

    /// 在指定 rect 内绘制该标注（points 为 view 局部坐标）。
    @MainActor
    func path() -> Path {
        guard let first = points.first else { return Path() }
        var path = Path()
        switch tool {
        case .rectangle:
            let r = CGRect(from: first, to: points.last ?? first)
            path.addRect(r)
        case .circle:
            let r = CGRect(from: first, to: points.last ?? first)
            path.addEllipse(in: r)
        case .arrow:
            let end = points.last ?? first
            path.move(to: first)
            path.addLine(to: end)
            // 箭头
            let angle = atan2(end.y - first.y, end.x - first.x)
            let len: CGFloat = max(12, lineWidth * 4)
            let a1 = CGPoint(x: end.x - len * cos(angle - .pi / 6),
                             y: end.y - len * sin(angle - .pi / 6))
            let a2 = CGPoint(x: end.x - len * cos(angle + .pi / 6),
                             y: end.y - len * sin(angle + .pi / 6))
            path.move(to: end)
            path.addLine(to: a1)
            path.move(to: end)
            path.addLine(to: a2)
        case .pen:
            path.move(to: first)
            for p in points.dropFirst() { path.addLine(to: p) }
        case .text, .selection:
            // 文本/选区工具不画 Path
            return Path()
        }
        return path
    }
}

extension CGRect {
    init(from a: CGPoint, to b: CGPoint) {
        self = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
