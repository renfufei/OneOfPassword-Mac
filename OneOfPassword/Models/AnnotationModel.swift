//
//  AnnotationModel.swift
//  OneOfPassword
//
//  截屏标注数据模型
//

import SwiftUI
import AppKit

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

    /// 悬停提示：说清楚**怎么用**（含修饰键），而不是把名字重复一遍。
    var hint: String {
        switch self {
        case .selection: return "选区：拖拽移动 / 拖边框缩放 / 拖选区外重新框选"
        case .rectangle: return "矩形：拖拽绘制（按住 Shift = 正方形）"
        case .circle:    return "圆形：拖拽绘制（按住 Shift = 正圆）"
        case .arrow:     return "箭头：从起点拖到终点"
        case .pen:       return "画笔：按住自由绘制"
        case .text:      return "文本：点一下输入（回车换行，⌘↩ 或 Esc 结束）"
        }
    }
}

/// 文本标注可选字体族（对应二级工具栏的「字体」）。
enum TextFontDesign: String, CaseIterable, Hashable {
    case system
    case rounded
    case serif
    case monospaced

    var label: String {
        switch self {
        case .system:     return "系统"
        case .rounded:    return "圆体"
        case .serif:      return "衬线"
        case .monospaced: return "等宽"
        }
    }

    /// SwiftUI 侧字体设计。
    var swiftUIDesign: Font.Design {
        switch self {
        case .system:     return .default
        case .rounded:    return .rounded
        case .serif:      return .serif
        case .monospaced: return .monospaced
        }
    }

    /// AppKit 侧字体设计（保存图片时用）。`.system` 无对应设计，返回 nil。
    var nsDesign: NSFontDescriptor.SystemDesign? {
        switch self {
        case .system:     return nil
        case .rounded:    return .rounded
        case .serif:      return .serif
        case .monospaced: return .monospaced
        }
    }
}

/// 一枚预设颜色 + 中文名。
/// 名字有两个用途：① 下拉菜单项的文字（macOS 菜单里色块只能是 `Image`、文字是 `Text`）；
/// ② 悬停提示 `.help("文字颜色：红")` —— 光秃秃的色块用户根本猜不到点下去会改什么。
struct ColorOption: Hashable {
    var color: Color
    var name: String
}

/// 颜色的**用途**。四个用途各自的取值互相独立（见 `TextStyle` 的说明），
/// 所以每处色板与悬停提示都按用途区分。
enum AnnotationColorRole: String, CaseIterable {
    case shape
    case text
    case background
    case border

    var label: String {
        switch self {
        case .shape:      return "图形"
        case .text:       return "文字"
        case .background: return "背景"
        case .border:     return "边框"
        }
    }

    /// 该用途提供的预设色板。
    var options: [ColorOption] {
        switch self {
        case .shape, .text: return AnnotationPalette.drawing
        case .background:   return AnnotationPalette.background
        case .border:       return AnnotationPalette.border
        }
    }

    /// 颜色的中文名（不在预设里就返回「自定义」，不会崩）。
    func name(of color: Color) -> String {
        options.first { $0.color == color }?.name ?? "自定义"
    }
}

enum AnnotationPalette {
    /// 图形 / 画笔 / 箭头 / 文字共用同一组可选色
    /// —— 注意只是「可选色相同」，写进去的是两个互不相同的字段。
    static let drawing: [ColorOption] = [
        ColorOption(color: .red,    name: "红"),
        ColorOption(color: .yellow, name: "黄"),
        ColorOption(color: .green,  name: "绿"),
        ColorOption(color: .blue,   name: "蓝"),
        ColorOption(color: .white,  name: "白"),
        ColorOption(color: .black,  name: "黑"),
    ]

    /// 底色偏深色 —— 截图内容大多是浅色，深底浅字更清楚。
    static let background: [ColorOption] = [
        ColorOption(color: .black,  name: "黑"),
        ColorOption(color: .white,  name: "白"),
        ColorOption(color: .yellow, name: "黄"),
        ColorOption(color: .blue,   name: "蓝"),
    ]

    static let border: [ColorOption] = [
        ColorOption(color: .white,  name: "白"),
        ColorOption(color: .black,  name: "黑"),
        ColorOption(color: .red,    name: "红"),
    ]
}

/// 文本标注样式：字号 / 字体族 / 粗细 / 文字色 / 背景 / 边框。
///
/// **四套颜色互相独立，禁止互相借用**（2026-09-29 用户明确要求）：
/// | 用途 | 字段 | 谁在改 |
/// |---|---|---|
/// | 图形（矩形/圆形/箭头/画笔）颜色 | `AnnotationShape.color` | 工具栏第一行「颜色」 |
/// | 文字颜色 | `TextStyle.textColor` | 二级工具栏「文字」 |
/// | 背景色（+ `backgroundOpacity`） | `TextStyle.backgroundColor` | 二级工具栏「背景」 |
/// | 边框色（+ `borderWidth`） | `TextStyle.borderColor` | 二级工具栏「边框」 |
/// 历史坑：文字颜色一度直接复用 `shape.color`，于是「改图形颜色」会顺手把文字也改掉。
struct TextStyle: Hashable {
    /// 字号（点）。UI 只提供 **14…72** 的预设档位点选（见 `AnnotationToolbar.fontSizePresets`），
    /// 不再用滑杆 —— 拖动既难精确命中，又会拖出 15.7 这类非整数。
    var fontSize: CGFloat = 18
    var design: TextFontDesign = .system
    /// true → semibold，false → regular。默认偏粗，截图上更醒目。
    var bold: Bool = true

    /// 文字颜色。**独立于 `AnnotationShape.color`**（后者只是图形颜色）。
    var textColor: Color = .white

    /// 背景填充不透明度：0 = 完全透明（不画背景）。0…1。
    var backgroundOpacity: Double = 0
    var backgroundColor: Color = .black

    /// 边框线宽（点）：0 = 无边框。
    var borderWidth: CGFloat = 0
    var borderColor: Color = .white

    /// 内边距**按字号等比缩放**（而不是写死 6/3）。
    /// 这样保存时只要把 `fontSize` 乘上屏幕缩放系数，文字尺寸与内边距会一起等比放大，
    /// 预览与成品不会出现「框紧字松」的偏差。（18pt 时约 6.1 / 3.1，与旧版手感一致）
    var paddingH: CGFloat { fontSize * 0.34 }
    var paddingV: CGFloat { fontSize * 0.17 }

    // MARK: - 字体

    func nsFont() -> NSFont {
        let weight: NSFont.Weight = bold ? .semibold : .regular
        if design == .monospaced {
            return NSFont.monospacedSystemFont(ofSize: fontSize, weight: weight)
        }
        let base = NSFont.systemFont(ofSize: fontSize, weight: weight)
        guard let d = design.nsDesign,
              let desc = base.fontDescriptor.withDesign(d),
              let f = NSFont(descriptor: desc, size: fontSize) else { return base }
        return f
    }

    func swiftUIFont() -> Font {
        .system(size: fontSize, weight: bold ? .semibold : .regular, design: design.swiftUIDesign)
    }

    // MARK: - 尺寸

    /// 文本自身实测尺寸。支持 **多行**（Enter 换行）：
    /// 宽 = 最长那一行的宽度，高 = 行数 × 行高。
    /// 空文本给一行行高（宽度 0），保证盒子仍有可见高度、能显示光标。
    ///
    /// 用 `components(separatedBy:)` 而不是 `split`：必须**保留空行** ——
    /// "a\n" 是两行（光标在第二行），用 split 会漏掉尾部空行导致盒子矮一行。
    func textSize(for text: String) -> CGSize {
        let f = nsFont()
        let lineH = ceil(f.ascender - f.descender + f.leading)
        let lines = text.components(separatedBy: "\n")
        let widest = lines.reduce(CGFloat(0)) { acc, line in
            max(acc, (line as NSString).size(withAttributes: [.font: f]).width)
        }
        // 尾部冗余半个字号（约半个中文字 / 一个西文半角字符）：
        // ① 末尾光标不会紧贴边框；② 输入过程中盒子逐字变宽时留有余量，不会顶到边上。
        // 编辑浮层与保存绘制都走这一个函数，所以预览与成品永远一致。
        let slack = ceil(f.pointSize * 0.5)
        let h = lineH * CGFloat(max(lines.count, 1))
        return CGSize(width: ceil(widest) + slack, height: max(ceil(h), lineH))
    }

    /// 文本框整体尺寸 = 文字尺寸 + 内边距。空文本给一个最小宽度，便于点选与显示光标。
    func boxSize(for text: String) -> CGSize {
        let t = textSize(for: text)
        return CGSize(width: max(t.width, fontSize * 1.2) + paddingH * 2,
                      height: t.height + paddingV * 2)
    }
}

struct AnnotationShape: Identifiable, Hashable {
    let id: UUID
    var tool: AnnotationTool
    var points: [CGPoint]
    var color: Color
    var lineWidth: CGFloat
    var text: String?
    /// 仅 `.text` 使用：字号 / 字体 / 背景 / 边框。
    var style: TextStyle

    init(id: UUID = UUID(), tool: AnnotationTool, points: [CGPoint],
         color: Color, lineWidth: CGFloat, text: String? = nil,
         style: TextStyle = TextStyle()) {
        self.id = id
        self.tool = tool
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
        self.text = text
        self.style = style
    }

    /// 按住 Shift 画矩形/圆形时，把「起点 → 当前点」约束成正方形 / 正圆：
    /// 边长取两个方向位移中较大者，方向跟随指针所在象限 —— 形状始终从起点往外长，
    /// 大小由指针离起点的距离决定。返回的是「对角点」，与 `CGRect(from:to:)` 配套。
    static func squaredEnd(from start: CGPoint, to current: CGPoint) -> CGPoint {
        let dx = current.x - start.x
        let dy = current.y - start.y
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: start.x + (dx < 0 ? -side : side),
                       y: start.y + (dy < 0 ? -side : side))
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

    // MARK: - 几何 / 命中

    /// 标注的包围盒（视图坐标，左上原点）。
    /// 文本 = 文本框；图形 = points 的外接矩形。
    /// 退化的维度（水平箭头、竖直画笔…）向两侧各撑开 4pt —— 否则外接矩形宽/高为 0，
    /// 既点不中也摆不下缩放手柄。
    func bounds() -> CGRect {
        if tool == .text {
            let o = points.first ?? .zero
            return CGRect(origin: o, size: style.boxSize(for: text ?? ""))
        }
        guard let first = points.first else { return .zero }
        if tool == .rectangle || tool == .circle, points.count >= 2 {
            var r = CGRect(from: first, to: points[1])
            if r.width < 1 { r = r.insetBy(dx: -4, dy: 0) }
            if r.height < 1 { r = r.insetBy(dx: 0, dy: -4) }
            return r
        }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        var r = CGRect(x: xs.min()!, y: ys.min()!,
                       width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        if r.width < 1 { r = r.insetBy(dx: -4, dy: 0) }
        if r.height < 1 { r = r.insetBy(dx: 0, dy: -4) }
        return r
    }

    /// 命中判定路径（含容差带）。
    /// 文本 = 盒子外扩 pad；图形 = **沿笔画外扩 pad 的带状区域**。
    ///
    /// 刻意不用外接矩形：矩形/圆形内部往往是空白，若按外接矩形判定命中，
    /// 画完一个大矩形后就再也没法在它内部画箭头之类的标注了。
    /// 用笔画带则「贴着边框/笔画」才算抓到图形，内部空白照常绘制。
    @MainActor
    func hitPath(pad: CGFloat) -> Path {
        if tool == .text {
            return Path(bounds().insetBy(dx: -pad, dy: -pad))
        }
        guard tool != .selection else { return Path() }
        let band = max(lineWidth, 2) + pad * 2
        return path().strokedPath(StrokeStyle(lineWidth: band, lineCap: .round, lineJoin: .round))
    }

    /// 是否命中。`allowInterior` 用于**已选中**的图形：整个外接矩形都可抓取，
    /// 免得选中之后还得对准细边框才能拖动。
    @MainActor
    func hitContains(_ p: CGPoint, pad: CGFloat, allowInterior: Bool = false) -> Bool {
        guard tool != .selection else { return false }
        if allowInterior, bounds().insetBy(dx: -pad, dy: -pad).contains(p) { return true }
        return hitPath(pad: pad).contains(p)
    }

    /// 拖拽结果是否值得保留：矩形/圆形/箭头过小视为误触（只是点了一下），直接丢弃。
    var isMeaningful: Bool {
        switch tool {
        case .rectangle, .circle:
            guard points.count >= 2 else { return false }
            let a = points[0], b = points[1]
            return abs(b.x - a.x) >= 4 && abs(b.y - a.y) >= 4
        case .arrow:
            guard let a = points.first, let b = points.last else { return false }
            return hypot(b.x - a.x, b.y - a.y) >= 8
        case .pen:
            return points.count >= 2
        case .text, .selection:
            return false
        }
    }

    // MARK: - 变换

    mutating func translate(by dx: CGFloat, dy: CGFloat) {
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    /// 图形缩放：以 `anchor` 为固定点，把指针位置换算成 x / y 两个方向的缩放比，
    /// 再作用到 `startPoints` 上，返回新的点集。
    ///
    /// 做成纯函数有两个好处：视图里不藏数学（可离线逐值验证），
    /// 且天然保证「每帧从起始值重算」—— 不会在上一帧结果上累加产生漂移。
    ///
    /// 两个方向各自钳制 `minSize`：指针越过锚点时盒子只会缩到最小，不会翻面成负尺寸。
    ///
    /// `square = true`（按住 Shift）时把两个缩放比统一，结果成为正方形 / 正圆：
    /// 边长取 `max(W·sx, H·sy)`（跟随指针那一侧较大者），再各自反推缩放比。
    /// 锚点仍然不动 —— 与普通缩放走完全同一条路径，所以不会引入新的边界情况。
    static func resizedPoints(startPoints: [CGPoint], startBox: CGRect, anchor: CGPoint,
                              handleIndex: Int, pointer: CGPoint,
                              minSize: CGFloat = 6, square: Bool = false) -> [CGPoint] {
        // 手柄：0=左上，顺时针（3=右边中点，7=左边中点）
        let movesX = [0, 2, 3, 4, 6, 7].contains(handleIndex)
        let movesY = [0, 1, 2, 4, 5, 6].contains(handleIndex)
        let leftSide = [0, 6, 7].contains(handleIndex)
        let topSide = [0, 1, 2].contains(handleIndex)

        var sx: CGFloat = 1
        var sy: CGFloat = 1
        if movesX, startBox.width > 1 {
            let raw = leftSide ? (anchor.x - pointer.x) : (pointer.x - anchor.x)
            sx = max(raw, minSize) / startBox.width
        }
        if movesY, startBox.height > 1 {
            let raw = topSide ? (anchor.y - pointer.y) : (pointer.y - anchor.y)
            sy = max(raw, minSize) / startBox.height
        }
        if square, startBox.width > 1, startBox.height > 1 {
            let side = max(startBox.width * sx, startBox.height * sy)
            sx = side / startBox.width
            sy = side / startBox.height
        }
        return startPoints.map {
            CGPoint(x: anchor.x + ($0.x - anchor.x) * sx,
                    y: anchor.y + ($0.y - anchor.y) * sy)
        }
    }
}

extension CGRect {
    init(from a: CGPoint, to b: CGPoint) {
        self = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
