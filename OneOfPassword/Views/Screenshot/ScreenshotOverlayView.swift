//
//  ScreenshotOverlayView.swift
//  OneOfPassword
//
//  截屏覆盖视图：以全屏快照为背景，在快照上做选区移动、标注、保存。
//  所有坐标基于视图点坐标（左上原点），与屏幕 1:1，不依赖实时屏幕状态。
//

import SwiftUI
import AppKit
import CoreGraphics

enum ResizeEdge: String { case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left }

/// 选区拖拽模式（钉钉式交互）：
/// - resize：拖边框/角（15pt 容差带）→ 缩放
/// - move：选区内拖拽（重画机会已用尽，或按住 ⌥）→ 整体平移
/// - draw：选区外拖拽，或选区内**尚未用掉重画机会**时拖拽 → 重新框选一块区域
enum SelectionDragMode {
    case none
    case resize
    case move
    case draw
    /// 选区工具下按在已有标注上 → 拖动该标注（而不是移动框选区域）
    case shape
}

/// 选区下方「尺寸 + 操作提示」浮层的实测尺寸上报通道。
/// 与 `ToolbarSizeKey` 同一套路：贴屏幕边缘时按真实宽度整体钳制，避免露到屏幕外。
struct SelectionLabelSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct ScreenshotOverlayView: View {
    var snapshot: CGImage
    var onDismiss: () -> Void
    var onCapture: (CGRect, [AnnotationShape], Bool) -> Void
    /// 自动识别的鼠标所在窗口（开启 autoWindow 时由 controller 传入，左上原点）。
    var preferredRect: CGRect? = nil

    @StateObject private var state = OverlayState()
    @State private var keyMonitor: Any?
    /// 拖动开始时工具栏已有的偏移快照：每帧都用「起始偏移 + 本次位移」重算，
    /// 避免在上一帧结果上累加导致漂移。
    @State private var toolbarDragStart: CGSize?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 快照作为背景，填满屏幕
                Image(nsImage: NSImage(cgImage: snapshot, size: NSSize(width: geo.size.width, height: geo.size.height)))
                    .resizable()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)

                // 选区外蒙版
                overlayMask(size: geo.size)

                // 全屏选区交互层：铺满整个屏幕，任意位置都能拖拽
                // （选区外重画 / 选区内部平移 / 边框缩放）
                fullscreenSelectionLayer

                // 标注层（画在选区内）
                annotationLayer

                // 选区边框 + 手柄
                selectionFrame

                // 文本浮层（正在输入的那个文本框）
                if let idx = state.editingTextIndex, idx < state.shapes.count {
                    textOverlay(idx: idx)
                }

                // 选中标注的虚线框 + 缩放手柄（文本与图形通用）。
                // 必须放在文本浮层**之后**：浮层只覆盖文本框本体，放在它上面手柄才能
                // 在「正在输入」时照样拖动（否则手柄会被浮层盖住一半、点不到）。
                shapeHandleLayer

                // 工具栏
                if state.isRegionConfirmed {
                    AnnotationToolbar(
                        selectedTool: $state.tool,
                        color: shapeAwareColorBinding,
                        lineWidth: shapeAwareLineWidthBinding,
                        textStyle: textAwareStyleBinding,
                        canUndo: state.canUndo,
                        canDelete: state.canDelete,
                        hasSelectedText: state.selectedTextIndex != nil,
                        onSave: handleSave,
                        onCopy: handleCopy,
                        onUndo: { state.undo() },
                        onDelete: { deleteSelectedShape() },
                        onCancel: { onDismiss() }
                    )
                    // 拖动热区：background 覆盖控件之间的空白（间距 / 内边距），
                    // 顶部再叠一条 6pt 边缘条（正好落在工具栏自身的 vertical padding 内，
                    // 不压任何控件）。这样既不会「拖线宽滑杆时把整条工具栏带走」，
                    // 又有一个稳定好抓的拖动位置。
                    .background(
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(toolbarDragGesture)
                    )
                    .overlay(alignment: .top) {
                        Color.clear
                            .frame(height: 6)
                            .contentShape(Rectangle())
                            .gesture(toolbarDragGesture)
                    }
                    .position(x: toolbarPosition.x, y: toolbarPosition.y)
                }
            }
            // 工具栏实测尺寸 → 供 toolbarPosition 精确钳制，避免贴屏幕边缘时露出屏幕外
            .onPreferenceChange(ToolbarSizeKey.self) { size in
                guard size.width > 0, size.height > 0, size != state.toolbarSize else { return }
                state.toolbarSize = size
            }
            // 同理，选区下方的「尺寸 + 提示」浮层也要按实测尺寸钳制
            .onPreferenceChange(SelectionLabelSizeKey.self) { size in
                guard size.width > 0, size.height > 0, size != state.labelStackSize else { return }
                state.labelStackSize = size
            }
        }
        .onAppear {
            initSelection()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // 系统保存面板（sheet）在前：键盘一律交还它自己处理。
                // 否则这里的 Esc 会把整个截屏关掉、Delete 会去删标注，而文件名输入却收不到字。
                if NSApp.keyWindow is NSSavePanel { return event }
                // 文本编辑中：Delete / 退格 / 方向键等一律交给 TextField，
                // 否则删字会变成删掉整个标注框。
                let editingText = (state.editingTextIndex != nil)
                // Esc：逐层收起 —— 结束文字输入 → 取消标注选中 → 都没有才退出截屏。
                // 这样编辑完想调样式时，不会一不小心把整个截屏关掉。
                if event.keyCode == 53 {
                    // 输入法正在组字（有 marked text）时，Esc 先交给输入法取消候选，
                    // 不要反手把整个编辑框关掉 —— 中文输入时这是高频动作。
                    if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.hasMarkedText() {
                        return event
                    }
                    if editingText {
                        state.commitEditingText()
                        return nil
                    }
                    if state.selectedShapeIndex != nil {
                        state.selectedShapeIndex = nil
                        return nil
                    }
                    onDismiss()
                    return nil
                }
                // 文本编辑中：Enter 交给 TextField 换行；**Cmd+Enter** 才是「结束输入」。
                // （不带修饰键的 Enter 一定不能拦，否则多行输入就废了）
                if editingText, event.keyCode == 36,
                   event.modifierFlags.contains(.command) {
                    state.commitEditingText()
                    return nil
                }
                if !editingText {
                    // Delete（51）/ 前向删除（117）：删除选中的标注
                    if event.keyCode == 51 || event.keyCode == 117 {
                        if state.selectedShapeIndex != nil {
                            deleteSelectedShape()
                            return nil
                        }
                    }
                    // Cmd/Ctrl + Z：撤销
                    let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    let z = event.keyCode == 6 // kVK_ANSI_Z
                    let hasCmd = mods.contains(.command)
                    let hasCtrl = mods.contains(.control)
                    if z && (hasCmd || hasCtrl) {
                        state.undo()
                        return nil
                    }
                }
                return event
            }
        }
        // 离开文本工具：结束编辑（二级工具栏的样式控件会随之收起）。
        // 选中态**保留** —— 切到别的工具后仍然可以继续拖动/缩放/删除刚选中的标注。
        .onChange(of: state.tool) { t in
            if t != .text {
                state.commitEditingText()
            }
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            // 悬停状态下直接关掉覆盖层（保存 / Esc）时，光标栈里还压着 resize 指针，必须还原
            resetHoverCursor()
        }
    }

    private func initSelection() {
        guard NSScreen.main != nil else { return }
        let area = usableArea
        // 优先级：autoWindow 识别的窗口 > 上次框选 > 默认中央 60%
        let defaultW = area.width * 0.6
        let defaultH = area.height * 0.6
        let defaultRect = CGRect(x: area.midX - defaultW / 2,
                                 y: area.midY - defaultH / 2,
                                 width: defaultW, height: defaultH)
        let lastRect = ScreenshotCaptureService.loadLastSelection()
        let raw = preferredRect ?? lastRect ?? defaultRect
        let source = preferredRect != nil ? "window" : (lastRect != nil ? "last" : "default")
        // 钳制到可用区域（菜单栏以下、Dock 以上）。识别出的窗口矩形可能包含菜单栏，
        // 也可能来自不同分辨率 / 屏幕，一律夹进来。
        let w = min(max(raw.width, 20), area.width)
        let h = min(max(raw.height, 20), area.height)
        let x = min(max(raw.minX, area.minX), area.maxX - w)
        let y = min(max(raw.minY, area.minY), area.maxY - h)
        state.selectionRect = CGRect(x: x, y: y, width: w, height: h)
        state.isRegionConfirmed = true
        ScreenshotLogger.log("overlay initSelection source=\(source) usable=\(area) rect=\(state.selectionRect)")
    }

    // MARK: - 蒙版（选区外半透明）

    private func overlayMask(size: CGSize) -> some View {
        Canvas { ctx, _ in
            // even-odd 填充：外框全屏蒙版 + 内框选区 → 选区区域被挖空为透明，露出下方快照
            var path = Path(CGRect(origin: .zero, size: size))
            path.addRect(state.selectionRect)
            ctx.fill(path,
                     with: .color(.black.opacity(0.45)),
                     style: FillStyle(eoFill: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    // MARK: - 全屏选区交互层

    /// 铺满整个覆盖层的手势入口（钉钉式）：
    /// 边框 15pt 内拖拽 → 缩放；
    /// 选区内拖拽 → 第一次是「收窄框选」（把自动框选的整窗收成子区域），机会用掉后再拖 = 平移；
    /// 选区外拖拽 → 随时可重新框选；按住 ⌥ 拖选区内 → 强制平移。
    /// 它位于标注层之下，所以工具为矩形/箭头/画笔/文本时，选区内的绘制手势优先，选区外仍可重画。
    private var fullscreenSelectionLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .gesture(unifiedGesture)
            // 手柄悬停 → 换成方向箭头指针。坐标空间与本层手势一致（全屏点坐标）。
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    updateHoverCursor(at: point)
                case .ended:
                    // 指针移出覆盖层时必须还原，否则 resize 指针会一直留在光标栈顶，
                    // 覆盖层关掉之后依然生效。
                    resetHoverCursor()
                }
            }
    }

    // MARK: - 选区边框 + 手柄（纯展示）

    private var selectionFrame: some View {
        let r = state.selectionRect
        return ZStack {
            // 边框
            Rectangle()
                .stroke(.white, lineWidth: 1.5)
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)

            // 尺寸标签 + 操作提示做成一列整体上报尺寸：
            // 贴屏幕左右边时要按真实宽度整体钳制，否则窄选区靠边时提示文案会露一截在屏幕外。
            // `fixedSize()` 不能省 —— 否则 Text 会被拉伸到父容器宽度，量出来的尺寸没有意义。
            VStack(spacing: 4) {
                // 尺寸标签
                Text("\(Int(r.width)) × \(Int(r.height))")
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.6))
                    .cornerRadius(4)

                // 操作提示：重画机会只有一次，用完就回到「拖拽=平移」，
                // 两个阶段的可用动作不同，提示文案要跟着变，否则用户会以为功能坏了。
                if state.tool == .selection {
                    Text(state.hasRedrawn
                         ? "拖拽移动 · 选区外拖拽重画 · 拖边框缩放"
                         : "拖拽框选子区域 · 单击放弃框选 · ⌥ 拖拽移动")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.45))
                        .cornerRadius(4)
                }
            }
            .fixedSize()
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: SelectionLabelSizeKey.self, value: g.size)
                }
            )
            .position(x: labelPosition.x, y: labelPosition.y)

            // 8 个手柄（仅显示）
            if state.tool == .selection {
                Group {
                    handleView(at: CGPoint(x: r.minX, y: r.maxY))
                    handleView(at: CGPoint(x: r.midX, y: r.maxY))
                    handleView(at: CGPoint(x: r.maxX, y: r.maxY))
                    handleView(at: CGPoint(x: r.maxX, y: r.midY))
                    handleView(at: CGPoint(x: r.maxX, y: r.minY))
                    handleView(at: CGPoint(x: r.midX, y: r.minY))
                    handleView(at: CGPoint(x: r.minX, y: r.minY))
                    handleView(at: CGPoint(x: r.minX, y: r.midY))
                }
            }
        }
        // 纯展示层，不拦截鼠标事件——所有拖拽交给下方全屏手势层统一处理
        .allowsHitTesting(false)
    }

    private func handleView(at pos: CGPoint) -> some View {
        let s: CGFloat = 14
        return RoundedRectangle(cornerRadius: 3)
            .fill(.white)
            .frame(width: s, height: s)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.black.opacity(0.3), lineWidth: 1))
            .position(pos)
    }

    /// 统一拖动手势（钉钉式）：按下时按位置判定模式——
    /// 近边框（15pt）→ 缩放；选区内且重画机会已用尽（或按住 ⌥）→ 平移整块；其余 → 重新框选。
    private var unifiedGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                let start = value.startLocation
                let current = value.location
                if state.dragMode == .none {
                    let r = state.selectionRect
                    let hasRect = r.width > 1 && r.height > 1
                    // 选区内按下：第一次是「收窄框选」（自动框选的整窗通常太大），
                    // 这次机会用掉之后，内部拖拽回到「平移」，免得每次微调位置都被判成重画；
                    // 按住 ⌥ 可随时强制平移（重画机会还没用掉时也一样）。
                    let optionDown = NSEvent.modifierFlags.contains(.option)
                    // 非「选择」工具且按在选区内部：交给上层标注手势，这里不介入
                    if state.tool != .selection, hasRect, r.contains(start) {
                        return
                    }
                    if hasRect, isOnEdge(at: start, in: r) {
                        let edge = detectEdge(at: start, in: r)
                        state.dragMode = .resize
                        state.resizeOrigin = r
                        state.activeEdge = edge
                        ScreenshotLogger.log("unified START(resize) start=\(start) edge=\(edge.rawValue) orig=\(r)")
                    } else if let id = hitShapeID(at: start) {
                        // 选区工具下按在已有标注上 → 拖动这个标注，而不是动框选区域。
                        // 放在边框缩放判定**之后**：贴着选区边缘时优先调整区域（那是本工具的本职）。
                        state.beginShapeDrag(id: id)
                        state.dragMode = .shape
                        ScreenshotLogger.log("unified START(shape) start=\(start) id=\(id)")
                    } else if hasRect, r.contains(start), optionDown || state.hasRedrawn {
                        // 选区内：重画机会已用完（或主动按住 ⌥）→ 平移整体
                        state.dragMode = .move
                        state.moveOrigin = r.origin
                        ScreenshotLogger.log("unified START(move) start=\(start) option=\(optionDown) hasRedrawn=\(state.hasRedrawn) orig=\(r.origin)")
                    } else {
                        // 选区外，或选区内且尚未用过重画机会 → 重新框选
                        state.dragMode = .draw
                        state.drawStart = start
                        state.preDrawRect = r
                        state.selectionRect = CGRect(origin: start, size: .zero)
                        ScreenshotLogger.log("unified START(draw) start=\(start) option=\(optionDown) inside=\(hasRect && r.contains(start)) prev=\(r)")
                    }
                }
                switch state.dragMode {
                case .resize:
                    if let edge = state.activeEdge, let orig = state.resizeOrigin {
                        applyResize(edge: edge, orig: orig,
                                    dx: value.translation.width, dy: value.translation.height)
                    }
                case .move:
                    if let origin = state.moveOrigin {
                        applyMove(origin: origin,
                                  dx: value.translation.width, dy: value.translation.height)
                    }
                case .shape:
                    state.updateShapeDrag(translation: value.translation)
                case .draw:
                    if let s = state.drawStart {
                        state.selectionRect = drawRect(from: s, to: current)
                    }
                case .none:
                    break
                }
            }
            .onEnded { value in
                if state.dragMode == .shape {
                    let isClick = state.endShapeDrag(translation: value.translation)
                    if !isClick, let id = state.selectedShapeID {
                        state.clampShapeIntoSelection(id: id)
                    }
                    state.dragMode = .none
                    state.drawStart = nil
                    state.activeEdge = nil
                    state.resizeOrigin = nil
                    state.moveOrigin = nil
                    return
                }
                if state.dragMode == .draw {
                    // 拖拽范围过小 → 视为「单击 / 手滑」，恢复原选区，避免误清空。
                    //
                    // 语义 v4：在选区内**单击一次**就等于放弃「重新框选子区域」，
                    // 立刻把机会用掉 —— 之后在选区内拖拽一律是平移。
                    // 旧版是「2 秒观察窗，期间再有操作就作废」，但每一次新按下都会
                    // 取消定时器，于是「点一下再拖」永远被判成重画，与用户直觉相反。
                    // 只有真正的手滑（>6pt 位移）才保留机会，避免误伤。
                    let r = state.selectionRect
                    if r.width < 20 || r.height < 20 {
                        let prev = state.preDrawRect
                        state.selectionRect = prev
                        let startedInside: Bool = {
                            guard let p = state.drawStart, prev.width > 1, prev.height > 1 else { return false }
                            return prev.contains(p)
                        }()
                        let jitter = abs(value.translation.width) + abs(value.translation.height)
                        if startedInside, !state.hasRedrawn, jitter < 6 {
                            state.hasRedrawn = true
                            ScreenshotLogger.log("unified END(draw) 选区内单击 start=\(state.drawStart.map { "\($0)" } ?? "nil") → 立即消耗重画机会，后续内部拖拽=平移")
                        } else {
                            ScreenshotLogger.log("unified END(draw) 过小/手滑(jitter=\(jitter))，恢复 prev=\(prev)，重画机会保留")
                        }
                    } else {
                        state.hasRedrawn = true
                        ScreenshotLogger.log("unified END(draw) 新区=\(r)，重画机会已用尽 → 后续内部拖拽=平移")
                    }
                }
                state.dragMode = .none
                state.drawStart = nil
                state.activeEdge = nil
                state.resizeOrigin = nil
                state.moveOrigin = nil
            }
    }

    /// 由拖拽起止点构造归一化、并钳制在屏幕范围内的矩形。
    private func drawRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        // 两端分别夹进可用区域，避免拖出屏幕/拖进菜单栏时产生负坐标或越界矩形
        // （越界矩形会让 crop 拿到超出快照的 cropRect，直接崩）。
        let area = usableArea
        let x0 = min(max(area.minX, min(a.x, b.x)), area.maxX)
        let y0 = min(max(area.minY, min(a.y, b.y)), area.maxY)
        let x1 = min(max(area.minX, max(a.x, b.x)), area.maxX)
        let y1 = min(max(area.minY, max(a.y, b.y)), area.maxY)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// 起始点是否落在任一边框容差带内（非纯内部）。
    private func isOnEdge(at p: CGPoint, in r: CGRect) -> Bool {
        let tol: CGFloat = 15
        return abs(p.x - r.minX) < tol || abs(p.x - r.maxX) < tol
            || abs(p.y - r.minY) < tol || abs(p.y - r.maxY) < tol
    }

    // MARK: - 手柄指针形状

    /// 8 个手柄 → 指针形状。必须用**静态表缓存**：
    /// 复用与否靠 `!==` 身份比较判断，若每次现取新实例，比较永远不等 → push/pop 失衡。
    private static let edgeCursors: [ResizeEdge: NSCursor] = {
        func makeCursor(_ edge: ResizeEdge) -> NSCursor {
            if #available(macOS 15.0, *) {
                // macOS 15 起有官方 frameResize，含四条斜向双箭头
                let position: NSCursor.FrameResizePosition
                switch edge {
                case .top:         position = .top
                case .bottom:      position = .bottom
                case .left:        position = .left
                case .right:       position = .right
                case .topLeft:     position = .topLeft
                case .topRight:    position = .topRight
                case .bottomLeft:  position = .bottomLeft
                case .bottomRight: position = .bottomRight
                }
                return NSCursor.frameResize(position: position, directions: .all)
            }
            // macOS 15 之前公开 API 没有斜向指针：角上退化为十字，四条边仍用系统双箭头
            switch edge {
            case .top, .bottom: return .resizeUpDown
            case .left, .right: return .resizeLeftRight
            default:            return .crosshair
            }
        }
        var table: [ResizeEdge: NSCursor] = [:]
        for edge in [ResizeEdge.topLeft, .top, .topRight, .right,
                     .bottomRight, .bottom, .bottomLeft, .left] {
            table[edge] = makeCursor(edge)
        }
        return table
    }()

    /// 该位置应显示的指针；不在手柄容差带内（或非选择工具）返回 nil。
    /// 判定复用 `isOnEdge` / `detectEdge`，保证指针形状与实际拖拽行为始终一致。
    private func hoverCursorKind(at p: CGPoint) -> NSCursor? {
        guard state.tool == .selection else { return nil }
        let r = state.selectionRect
        guard r.width > 1, r.height > 1, isOnEdge(at: p, in: r) else { return nil }
        return Self.edgeCursors[detectEdge(at: p, in: r)]
    }

    /// 悬停移动：形状变了才动光标栈（未变时直接返回，避免每帧 push/pop 抖动）。
    private func updateHoverCursor(at p: CGPoint) {
        let want = hoverCursorKind(at: p)
        guard want !== state.hoverCursor else { return }
        state.hoverCursor?.pop()
        state.hoverCursor = want
        want?.push()
    }

    /// 还原指针（悬停结束 / 覆盖层关闭）。
    private func resetHoverCursor() {
        state.hoverCursor?.pop()
        state.hoverCursor = nil
    }

    /// 允许框选的区域（覆盖层视图坐标，左上原点）。
    /// **只把顶部菜单栏排除在外** —— 系统菜单栏压在最顶层、覆盖层盖不住，
    /// 选区伸进去截出来是一条残破的菜单栏。
    /// 左右 / 底部一律放开到屏幕边界：`visibleFrame` 还会扣掉 Dock 占的宽度
    /// （Dock 在左侧时少 70pt、在底部时少 60pt），但覆盖层level 是 `.screenSaver`，
    /// 盖得住 Dock，把 Dock 那块也纳入框选是合理且必要的。
    private var usableArea: CGRect {
        guard let screen = NSScreen.main else { return .zero }
        let f = screen.frame
        let vf = screen.visibleFrame
        let menuBarHeight = max(0, f.height - (vf.maxY - f.minY))
        return CGRect(x: 0,
                      y: menuBarHeight,
                      width: f.width,
                      height: max(20, f.height - menuBarHeight))
    }

    /// 整体平移选区，受可用区域约束。
    private func applyMove(origin: CGPoint, dx: CGFloat, dy: CGFloat) {
        let nx = origin.x + dx
        let ny = origin.y + dy
        let area = usableArea
        let r = state.selectionRect
        state.selectionRect.origin = CGPoint(
            x: min(max(area.minX, nx), area.maxX - r.width),
            y: min(max(area.minY, ny), area.maxY - r.height)
        )
    }

    /// 根据触点位置判断属于哪个手柄（视图坐标系，左上原点：minY=顶边，maxY=底边）。
    private func detectEdge(at p: CGPoint, in r: CGRect) -> ResizeEdge {
        let tol: CGFloat = 15
        let nearLeft = abs(p.x - r.minX) < tol
        let nearRight = abs(p.x - r.maxX) < tol
        let nearTop = abs(p.y - r.minY) < tol    // 顶边 minY
        let nearBottom = abs(p.y - r.maxY) < tol // 底边 maxY
        if nearLeft && nearTop { return .topLeft }
        if nearRight && nearTop { return .topRight }
        if nearLeft && nearBottom { return .bottomLeft }
        if nearRight && nearBottom { return .bottomRight }
        if nearTop { return .top }
        if nearBottom { return .bottom }
        if nearLeft { return .left }
        if nearRight { return .right }
        return .left // 默认（选区内拖动应走 moveGesture，不应到这里）
    }

    private func edgeLabel(_ e: ResizeEdge) -> String {
        switch e {
        case .topLeft: return "↖"; case .top: return "↑"; case .topRight: return "↗"
        case .right: return "→"; case .bottomRight: return "↘"; case .bottom: return "↓"
        case .bottomLeft: return "↙"; case .left: return "←"
        }
    }

    /// 统一调整逻辑：根据 edge 决定移动哪条边。
    /// 坐标系：视图左上原点。origin.y 是顶边，origin.y+height 是底边。
    /// translation: dx 向右为正，dy 向下为正。
    private func applyResize(edge: ResizeEdge, orig: CGRect, dx: CGFloat, dy: CGFloat) {
        let area = usableArea
        // 先把位移量夹进可用区域：被拖的那条边不越界，另一条边保持不动
        // （若直接夹结果矩形，拖顶边到底时整块会跟着跳）。
        var ddx = dx
        var ddy = dy
        switch edge {
        case .left, .topLeft, .bottomLeft:
            ddx = max(ddx, area.minX - orig.minX)
        case .right, .topRight, .bottomRight:
            ddx = min(ddx, area.maxX - orig.maxX)
        case .top, .bottom:
            break
        }
        switch edge {
        case .top, .topLeft, .topRight:
            ddy = max(ddy, area.minY - orig.minY)
        case .bottom, .bottomLeft, .bottomRight:
            ddy = min(ddy, area.maxY - orig.maxY)
        case .left, .right:
            break
        }
        var newRect = orig
        switch edge {
        case .left:
            // 左边移动：右边(maxX)不动，origin.x 变、width 反向
            newRect.origin.x = orig.minX + ddx
            newRect.size.width = orig.width - ddx
        case .right:
            // 右边移动：左边(minX)不动，width 变
            newRect.size.width = orig.width + ddx
        case .top:
            // 顶边移动：底边(maxY)不动，向下拖 dy 正 → 顶边下移 → origin.y 变、height 反向
            newRect.origin.y = orig.minY + ddy
            newRect.size.height = orig.height - ddy
        case .bottom:
            // 底边移动：顶边(minY)不动，向下拖 dy 正 → 底边下移 → height 变
            newRect.size.height = orig.height + ddy
        case .topLeft:
            newRect.origin.x = orig.minX + ddx
            newRect.size.width = orig.width - ddx
            newRect.origin.y = orig.minY + ddy
            newRect.size.height = orig.height - ddy
        case .topRight:
            newRect.size.width = orig.width + ddx
            newRect.origin.y = orig.minY + ddy
            newRect.size.height = orig.height - ddy
        case .bottomLeft:
            newRect.origin.x = orig.minX + ddx
            newRect.size.width = orig.width - ddx
            newRect.size.height = orig.height + ddy
        case .bottomRight:
            newRect.size.width = orig.width + ddx
            newRect.size.height = orig.height + ddy
        }
        if newRect.width >= 20 && newRect.height >= 20 {
            state.selectionRect = newRect
        }
    }

    // MARK: - 标注层
    // Canvas 覆盖全屏，使用 GeometryReader 全局坐标（与选区同一坐标空间）。
    // 手势层限选区范围，但 DragGesture 坐标空间是 GeometryReader 全局，故 points 直接存全局坐标，
    // 与全屏 Canvas 绘制一致，不会因选区偏移产生位移。

    private var annotationLayer: some View {
        let r = state.selectionRect
        return ZStack {
            // 已完成标注 + 当前绘制（全屏 Canvas，全局坐标）
            Canvas { ctx, _ in
                for shape in state.shapes {
                    drawShape(ctx, shape)
                }
                if let current = state.drawingShape {
                    drawShape(ctx, current)
                }
                // 文本：背景/边框照画；正在输入的那个只跳过文字本身（文字由 TextField 浮层显示），
                // 这样编辑期间看到的盒子与提交后完全一致（所见即所得）。
                for (i, shape) in state.shapes.enumerated() where shape.tool == .text {
                    drawTextShape(ctx, shape, skipText: i == state.editingTextIndex)
                }
            }
            // 纯绘制层，不拦截事件——否则会挡住下方全屏手势层
            .allowsHitTesting(false)

            // 标注交互层（**唯一入口**）：铺满选区，按下时先做命中判定 ——
            // 命中已有标注 → 选中并拖动它；未命中 → 按当前工具新建（文本工具为「点击新建」）。
            // 选区工具下不启用这一层（它专管框选区域），此时标注拖动由 unifiedGesture 接管。
            if state.tool != .selection {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                    .gesture(annotationGesture)
            }
        }
    }

    /// 画图形时把「起点 → 指针」交给模型做约束：按住 **Shift** 的矩形/圆形 = 正方形/正圆。
    /// 抽成一层是为了让 `.onChanged` 与 `.onEnded` 用**同一套规则** ——
    /// 否则松手那一帧会用未约束的 `value.location` 覆盖，形状在结尾回跳一下。
    private func constrainedEnd(from start: CGPoint, to current: CGPoint,
                                tool: AnnotationTool) -> CGPoint {
        guard tool == .rectangle || tool == .circle,
              NSEvent.modifierFlags.contains(.shift) else { return current }
        return AnnotationShape.squaredEnd(from: start, to: current)
    }

    /// 标注交互手势。合并了原来的「绘制层」与「文本层」，因为两者的按下判定本质相同：
    /// **先看有没有点中已有标注，没有才谈新建** —— 否则永远只能画新的、动不了旧的。
    private var annotationGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                // 手势坐标即全屏 GeometryReader 全局坐标（左上原点、点单位），
                // 与全屏预览 Canvas / 保存转换（captureAndSave 内做 减 origin→缩放→翻转）同一坐标空间，
                // 直接采用即可，无需再叠加选区 origin（否则会偏离光标整整一个选区原点）。
                let start = value.startLocation
                let current = value.location
                if state.annotationMode == .none {
                    // 1) 命中已有标注（最上层优先）→ 拖动它
                    if let id = hitShapeID(at: start) {
                        state.beginShapeDrag(id: id)
                        state.annotationMode = .moveShape
                        return
                    }
                    // 2) 未命中：文本工具是「点击新建」（松开时位移过小才创建）
                    if state.tool == .text {
                        state.annotationMode = .textCreate
                        state.annotationStart = start
                        return
                    }
                    // 3) 其余工具：从按下点开始绘制新标注
                    state.annotationMode = .draw
                    state.drawingShape = AnnotationShape(
                        tool: state.tool,
                        points: [start, current],
                        color: state.currentColor,
                        lineWidth: state.lineWidth
                    )
                    return
                }
                switch state.annotationMode {
                case .moveShape:
                    state.updateShapeDrag(translation: value.translation)
                case .draw:
                    guard var s = state.drawingShape else { return }
                    if s.tool == .pen {
                        s.points.append(current)
                    } else if s.points.count >= 2 {
                        // 矩形/圆形/箭头：起点 + 当前点。
                        // 按住 Shift 画矩形/圆形 → 约束成正方形/正圆（大小由指针位置决定）。
                        s.points[1] = constrainedEnd(from: s.points[0], to: current, tool: s.tool)
                    } else {
                        s.points.append(current)
                    }
                    state.drawingShape = s
                case .textCreate, .none:
                    break
                }
            }
            .onEnded { value in
                switch state.annotationMode {
                case .moveShape:
                    let isClick = state.endShapeDrag(translation: value.translation)
                    if isClick {
                        // 只是点了一下：文字工具下进入编辑，其余工具下保持选中
                        if state.tool == .text,
                           let i = state.selectedShapeIndex,
                           state.shapes.indices.contains(i),
                           state.shapes[i].tool == .text {
                            beginEditing(i)
                        }
                    } else if let id = state.selectedShapeID {
                        state.clampShapeIntoSelection(id: id)
                        ScreenshotLogger.log("shape MOVE id=\(id) translation=\(value.translation)")
                    }
                case .draw:
                    if var s = state.drawingShape {
                        if s.tool != .pen, s.points.count >= 2 {
                            s.points[1] = constrainedEnd(from: s.points[0],
                                                         to: value.location, tool: s.tool)
                        }
                        // 只是点了一下产生的退化图形（矩形/圆形/箭头）直接丢弃，不留垃圾
                        if s.isMeaningful {
                            state.shapes.append(s)
                        } else {
                            ScreenshotLogger.log("shape DROP 过小误触 tool=\(s.tool.rawValue)")
                        }
                        state.drawingShape = nil
                    }
                case .textCreate:
                    let moved = abs(value.translation.width) + abs(value.translation.height)
                    if moved < 3, let p = state.annotationStart {
                        createText(at: p)
                    }
                    state.annotationStart = nil
                case .none:
                    break
                }
                state.annotationMode = .none
            }
    }

    /// 命中测试：从最上层（后绘制 = 后绘制在数组尾部）往下找第一个命中的标注。
    ///
    /// 判定用 `hitContains`：图形走「笔画容差带」，所以大矩形**内部**的空白处不算命中，
    /// 仍可继续绘制新标注；一旦某个图形处于选中态，它的整个外接矩形都可抓取，
    /// 免得选中后还得对准细边框才能拖动。文本框始终按盒子判定。
    private func hitShapeID(at p: CGPoint) -> UUID? {
        let pad: CGFloat = 8
        for (i, shape) in state.shapes.enumerated().reversed() {
            guard shape.tool != .selection else { continue }
            let selected = (state.selectedShapeIndex == i)
            if shape.hitContains(p, pad: pad, allowInterior: selected) {
                return shape.id
            }
        }
        return nil
    }

    // MARK: - 文本标注（绘制）

    /// 画文本框：背景 → 边框 → 文字。
    /// `skipText` 用于「正在输入」的那个框：文字交给 TextField 浮层显示（避免重影），
    /// 但背景/边框仍由 Canvas 画，保证编辑期间和提交后外观一致。
    private func drawTextShape(_ ctx: GraphicsContext, _ shape: AnnotationShape, skipText: Bool) {
        guard let str = shape.text, !str.isEmpty, let p = shape.points.first else { return }
        let style = shape.style
        let box = CGRect(origin: p, size: style.boxSize(for: str))
        let radius = min(style.fontSize * 0.22, 8)
        if style.backgroundOpacity > 0 {
            ctx.fill(Path(roundedRect: box, cornerRadius: radius),
                     with: .color(style.backgroundColor.opacity(style.backgroundOpacity)))
        }
        if style.borderWidth > 0 {
            ctx.stroke(Path(roundedRect: box, cornerRadius: radius),
                       with: .color(style.borderColor),
                       lineWidth: style.borderWidth)
        }
        guard !skipText else { return }
        // 文字用 `style.textColor`（**不是** `shape.color`）—— 四套颜色互相独立，
        // 图形颜色、文字色、背景色、边框色分别对应四个字段，改一个不会连带改别的。
        ctx.draw(Text(str).font(style.swiftUIFont()).foregroundColor(style.textColor),
                 at: CGPoint(x: p.x + style.paddingH, y: p.y + style.paddingV),
                 anchor: .topLeading)
    }

    private func drawShape(_ ctx: GraphicsContext, _ shape: AnnotationShape) {
        if shape.tool == .text || shape.tool == .selection { return }
        ctx.stroke(shape.path(),
                   with: .color(shape.color),
                   lineWidth: shape.lineWidth)
    }

    // MARK: - 标注创建 / 编辑 / 删除

    /// 点选区空白处（文本工具）：新建文本框并立即进入编辑
    private func createText(at loc: CGPoint) {
        // 先结束上一段编辑（空内容会被丢弃，不留空壳）
        state.commitEditingText()
        var s = AnnotationShape(tool: .text, points: [loc],
                                // 文本框的渲染只用 `style.textColor`，这里的 `color` 只是
                                // 建个一致的值（不再有「文字借用图形色」那条耦合）
                                color: state.textStyle.textColor, lineWidth: state.lineWidth)
        s.text = ""
        s.style = state.textStyle
        state.shapes.append(s)
        let idx = state.shapes.count - 1
        state.selectedShapeIndex = idx
        state.editingTextIndex = idx
        ScreenshotLogger.log("text CREATE idx=\(idx) at=\(loc) fontSize=\(s.style.fontSize)")
    }

    /// 点已有文本框 → 进入编辑
    private func beginEditing(_ idx: Int) {
        guard state.shapes.indices.contains(idx), state.shapes[idx].tool == .text else { return }
        state.selectedShapeIndex = idx
        state.editingTextIndex = idx
        ScreenshotLogger.log("text EDIT idx=\(idx)")
    }

    /// 删除当前选中的标注。Delete / 退格键、工具栏垃圾桶按钮都走这里。
    private func deleteSelectedShape() {
        guard let i = state.selectedShapeIndex, state.shapes.indices.contains(i) else { return }
        ScreenshotLogger.log("shape DELETE idx=\(i) tool=\(state.shapes[i].tool.rawValue)")
        state.removeShape(at: i)
    }

    // MARK: - 选中框 + 缩放手柄（手柄仅图形有；文本按字号自动定宽高）

    @ViewBuilder
    private var shapeHandleLayer: some View {
        if let idx = state.selectedShapeIndex, state.shapes.indices.contains(idx) {
            let shape = state.shapes[idx]
            let box = shape.bounds()
            ZStack {
                // 选中指示：虚线框（纯展示，不能拦事件，否则会挡住本体拖动/文本输入）
                RoundedRectangle(cornerRadius: 4)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(width: box.width + 6, height: box.height + 6)
                    .position(x: box.midX, y: box.midY)
                    .allowsHitTesting(false)

                // 8 个手柄（复用选区手柄的视觉）。
                // **文本框不给手柄**：它的宽高完全由字号 + 内容推导（boxSize(for:)），
                // 不需要、也不应该被拉伸（改字号的入口在二级工具栏的滑杆）。
                // 而且手柄的命中区盖在文本框上时，点下去会被缩放手势抢走 ——
                // 这正是「文本框点不进去、无法输入文字」的原因。
                if shape.tool != .text {
                    ForEach(0..<8, id: \.self) { i in
                        interactiveHandle(at: handlePoint(i, in: box),
                                          gesture: resizeGesture(index: idx, handleIndex: i, box: box))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 可交互手柄。三个要点：
    /// 1. 手势必须挂在 `.position` **之前** —— `.position` 返回的容器会撑满父视图，
    ///    挂在它后面会导致命中区域变成整个覆盖层（那时随便点哪都在缩放）。
    /// 2. 命中区比视觉方块大一圈（22 vs 14），靠近边缘时更好抓。
    /// 3. 因此手势的**默认坐标空间是手柄自身**，所以 `resizeGesture` 里必须写
    ///    `coordinateSpace: .global`，否则 `value.location` 只有 0~22，缩放比会算飞。
    private func interactiveHandle<G: Gesture>(at pos: CGPoint, gesture: G) -> some View {
        ZStack {
            Color.clear.frame(width: 22, height: 22)
            RoundedRectangle(cornerRadius: 3)
                .fill(.white)
                .frame(width: 14, height: 14)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.black.opacity(0.3), lineWidth: 1))
        }
        .contentShape(Rectangle())
        .gesture(gesture)
        .position(pos)
    }

    /// 8 个手柄的位置：0 = 左上，顺时针排列（3 = 右边中点，7 = 左边中点）。
    private func handlePoint(_ i: Int, in box: CGRect) -> CGPoint {
        switch i {
        case 0: return CGPoint(x: box.minX, y: box.minY)
        case 1: return CGPoint(x: box.midX, y: box.minY)
        case 2: return CGPoint(x: box.maxX, y: box.minY)
        case 3: return CGPoint(x: box.maxX, y: box.midY)
        case 4: return CGPoint(x: box.maxX, y: box.maxY)
        case 5: return CGPoint(x: box.midX, y: box.maxY)
        case 6: return CGPoint(x: box.minX, y: box.maxY)
        default: return CGPoint(x: box.minX, y: box.midY)
        }
    }

    /// 图形缩放的统一入口（文本没有手柄，不参与缩放）。
    ///
    /// **必须显式指定 `.global` 坐标空间**：这个手势挂在手柄上，而手柄随后又被
    /// `.position` 摆到屏幕上。默认的 `.local` 会把 `value.location` 解析成
    /// 「22×22 手柄内部坐标」（如 (5,5)），而锚点 / 起始包围盒都是全局坐标 ——
    /// 两者一比就把缩放比算成 0 或几十倍，表现为「一拖动手柄，图形立刻飞到别处」。
    private func resizeGesture(index: Int, handleIndex: Int, box: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard state.shapes.indices.contains(index),
                      state.shapes[index].tool != .text else { return }
                shapeResizeChanged(index: index, handleIndex: handleIndex, box: box, value: value)
            }
            .onEnded { _ in
                if let st = state.shapeResizeStart, st.index == index {
                    state.shapeResizeStart = nil
                    if state.shapes.indices.contains(index) {
                        ScreenshotLogger.log("shape RESIZE idx=\(index) box=\(state.shapes[index].bounds())")
                    }
                }
            }
    }

    /// 图形缩放：锚点 = 被拖手柄的**对角 / 对边中点**；把指针位置换算成 x、y 两个方向的缩放比，
    /// 再以起始点集为基准整体缩放。数学在 `AnnotationShape.resizedPoints` 里（纯函数，可离线验证）。
    private func shapeResizeChanged(index: Int, handleIndex: Int, box: CGRect,
                                    value: DragGesture.Value) {
        // 对角手柄：0↔4、1↔5、2↔6、3↔7
        let anchorIndex = (handleIndex + 4) % 8
        if state.shapeResizeStart == nil {
            state.shapeResizeStart = ShapeResizeStart(
                index: index,
                startBox: box,
                startPoints: state.shapes[index].points,
                anchor: handlePoint(anchorIndex, in: box))
            state.selectedShapeIndex = index
        }
        guard let st = state.shapeResizeStart, st.index == index,
              state.shapes.indices.contains(index) else { return }
        var n = state.shapes[index]
        // 按住 Shift 拖手柄：矩形/圆形保持正方形/正圆（与「画的时候」同一套语义）
        let square = (n.tool == .rectangle || n.tool == .circle)
            && NSEvent.modifierFlags.contains(.shift)
        n.points = AnnotationShape.resizedPoints(startPoints: st.startPoints,
                                                 startBox: st.startBox,
                                                 anchor: st.anchor,
                                                 handleIndex: handleIndex,
                                                 pointer: value.location,
                                                 square: square)
        state.shapes[index] = n
    }

    // MARK: - 文本浮层（正在输入）

    private func textOverlay(idx: Int) -> some View {
        let sh = state.shapes[idx]
        let style = sh.style
        let box = sh.bounds()
        let textSize = style.textSize(for: sh.text ?? "")
        let radius = min(style.fontSize * 0.22, 8)
        // 用 AppKit 的多行编辑器（`NSTextView`），而不是 SwiftUI 的 `TextField`：
        // 后者在 Return 上会走「提交/全选」而不是插入换行，且输入过程中的变化
        // 不会即时回灌模型 —— 表现就是「回车不换行」「长度要等失焦才变」。
        // 详见 `MultilineTextEditor` 的注释。
        return MultilineTextEditor(
            text: sh.text ?? "",
            style: style,
            textColor: style.textColor,
            onChange: { newText in
                guard idx < state.shapes.count else { return }
                var n = state.shapes[idx]
                // 内容真的变了才写回：写回会触发重绘，而本视图的 frame 又由内容算出，
                // 无变化时不写可以避免多余的一轮布局。
                guard (n.text ?? "") != newText else { return }
                n.text = newText
                state.shapes[idx] = n
            },
            onCommit: { state.commitEditingText() }
        )
        // 内容区 = 实测文字尺寸（与 Canvas 同一套度量：含尾部冗余），再补内边距 →
        // 浮层总尺寸与 Canvas 画的盒子完全相等，编辑期间不会跳动。
        // 宽度随每次输入实时重算，所以盒子是跟着字一个字一个字长的。
        .frame(width: max(textSize.width, style.fontSize * 1.2), height: textSize.height)
        .padding(.horizontal, style.paddingH)
        .padding(.vertical, style.paddingV)
        .background(
            RoundedRectangle(cornerRadius: radius)
                .fill(style.backgroundColor.opacity(style.backgroundOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .stroke(style.borderColor, lineWidth: style.borderWidth)
        )
        .position(x: box.midX, y: box.midY)
    }

    // MARK: - 样式绑定路由（选中标注 ↔ 新建默认值）

    /// 主色板：选中任何标注（文本或图形）就改它的颜色，否则改「新建默认色」。
    /// 两边都写，颜色才会被下一个新建的标注继承。
    private var shapeAwareColorBinding: Binding<Color> {
        Binding(
            get: {
                if let i = state.selectedShapeIndex, state.shapes.indices.contains(i) {
                    return state.shapes[i].color
                }
                return state.currentColor
            },
            set: { newColor in
                if let i = state.selectedShapeIndex, state.shapes.indices.contains(i) {
                    var n = state.shapes[i]
                    n.color = newColor
                    state.shapes[i] = n
                }
                state.currentColor = newColor
            }
        )
    }

    /// 线宽滑杆：同理，作用在选中的标注上（文本用二级工具栏的边框粗细，这里的值对它无影响）。
    private var shapeAwareLineWidthBinding: Binding<CGFloat> {
        Binding(
            get: {
                if let i = state.selectedShapeIndex, state.shapes.indices.contains(i) {
                    return state.shapes[i].lineWidth
                }
                return state.lineWidth
            },
            set: { w in
                if let i = state.selectedShapeIndex, state.shapes.indices.contains(i) {
                    var n = state.shapes[i]
                    n.lineWidth = w
                    state.shapes[i] = n
                }
                state.lineWidth = w
            }
        )
    }

    /// 二级工具栏的样式绑定：选中了文本框就改它，否则改「新建默认样式」。
    private var textAwareStyleBinding: Binding<TextStyle> {
        Binding(
            get: {
                if let i = state.selectedTextIndex, state.shapes.indices.contains(i) {
                    return state.shapes[i].style
                }
                return state.textStyle
            },
            set: { newStyle in
                if let i = state.selectedTextIndex, state.shapes.indices.contains(i) {
                    var n = state.shapes[i]
                    n.style = newStyle
                    state.shapes[i] = n
                }
                state.textStyle = newStyle
            }
        )
    }

    // MARK: - 工具栏位置

    /// 手柄命中带的外扩量：15pt 容差 + 手柄半径，再留 4pt 余量。
    /// 工具栏任何一条边都不得进入这条带，否则会压住角 / 边中点手柄，导致选区拖不动。
    private static let toolbarHandleClearance: CGFloat = 22

    /// 工具栏**中心点**坐标 = 自动基准位置 + 用户拖动偏移，再整体钳制在屏幕内。
    /// `.position` 收的是中心坐标，所以钳制必须按半宽 / 半高算 ——
    /// 原先按整宽（且是硬编码的 380，而工具栏实测约 650）算，选区贴屏幕左右边时就会露出一截。
    private var toolbarPosition: CGPoint {
        let base = toolbarBasePosition
        return clampToolbarCenter(
            CGPoint(x: base.x + state.toolbarDragOffset.width,
                    y: base.y + state.toolbarDragOffset.height)
        )
    }

    /// 自动摆放的基准位置（未叠加用户拖动）。
    /// 优先级：选区上方 → 选区下方 → 选区内部靠顶。
    /// 前两种要求整条工具栏落在选区之外，且与选区边界留出 `toolbarHandleClearance`，
    /// 保证不压住 8 个缩放手柄；两者都放不下时（最大化窗口 / 选区铺满整屏）
    /// 才浮到选区内部顶部 —— 允许盖住画面内容，但不碰顶部那三个手柄。
    private var toolbarBasePosition: CGPoint {
        let r = state.selectionRect
        let screenW = NSScreen.main?.frame.width ?? 1000
        let screenH = NSScreen.main?.frame.height ?? 800
        let size = state.toolbarSize
        let halfW = size.width / 2
        let halfH = size.height / 2
        let clearance = Self.toolbarHandleClearance

        // 工具栏比屏幕还宽时可用区间为空，退化为居中 —— 至少能操作，不至于整条推出屏幕
        let x: CGFloat = size.width >= screenW ? screenW / 2
                                                : min(max(r.midX, halfW), screenW - halfW)

        // ① 选区上方：整条工具栏 + 手柄余量都放得下
        let aboveCenter = r.minY - clearance - halfH
        if aboveCenter - halfH >= 0 {
            return CGPoint(x: x, y: aboveCenter)
        }
        // ② 选区下方：同理
        let belowCenter = r.maxY + clearance + halfH
        if belowCenter + halfH <= screenH {
            return CGPoint(x: x, y: belowCenter)
        }
        // ③ 上下都被顶死（最大化窗口）：浮在选区内部靠顶，垂直方向避开顶部手柄带
        let insideCenter = r.minY + clearance + halfH
        return CGPoint(x: x, y: min(max(insideCenter, halfH), max(halfH, screenH - halfH)))
    }

    /// 把工具栏中心点钳制到「整条工具栏都在屏幕内」；比屏幕还大时退化为居中。
    private func clampToolbarCenter(_ p: CGPoint) -> CGPoint {
        let screenW = NSScreen.main?.frame.width ?? 1000
        let screenH = NSScreen.main?.frame.height ?? 800
        let size = state.toolbarSize
        let halfW = size.width / 2
        let halfH = size.height / 2
        let x = size.width >= screenW ? screenW / 2 : min(max(p.x, halfW), screenW - halfW)
        let y = size.height >= screenH ? screenH / 2 : min(max(p.y, halfH), screenH - halfH)
        return CGPoint(x: x, y: y)
    }

    /// 工具栏拖动：每帧都用「起始偏移 + 本次位移」重算（不在上一帧结果上累加，避免漂移），
    /// 并在拖动过程中就钳制，免得松手后位置被纠正而「跳一下」。
    private var toolbarDragGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                if toolbarDragStart == nil { toolbarDragStart = state.toolbarDragOffset }
                guard let start = toolbarDragStart else { return }
                let base = toolbarBasePosition
                let desired = CGPoint(x: base.x + start.width + value.translation.width,
                                      y: base.y + start.height + value.translation.height)
                let clamped = clampToolbarCenter(desired)
                state.toolbarDragOffset = CGSize(width: clamped.x - base.x,
                                                 height: clamped.y - base.y)
            }
            .onEnded { _ in toolbarDragStart = nil }
    }

    /// 选区下方「尺寸 + 操作提示」浮层的中心点，同样按实测尺寸整体钳制在屏幕内。
    /// 竖向：浮层顶边贴选区底边下方 5pt；底边顶到屏幕下沿时向上收 ——
    /// 宁可压住一点选区，也好过整个看不见。
    private var labelPosition: CGPoint {
        let r = state.selectionRect
        let screenW = NSScreen.main?.frame.width ?? 1000
        let screenH = NSScreen.main?.frame.height ?? 800
        // 首帧尚未量到尺寸时用估值兜底，量到后立刻纠正
        let w = state.labelStackSize.width > 0 ? state.labelStackSize.width : 240
        let h = state.labelStackSize.height > 0 ? state.labelStackSize.height : 38
        let halfW = w / 2, halfH = h / 2

        let x = w >= screenW ? screenW / 2 : min(max(r.midX, halfW), screenW - halfW)
        // 竖向：优先贴选区底边下方 5pt；下方放不下时（选区铺满整屏）浮到选区内部靠底，
        // 并给底边手柄留出 `toolbarHandleClearance` —— 否则会压住 bottom / bottomLeft / bottomRight。
        let belowCenter = r.maxY + 5 + halfH
        let y: CGFloat
        if belowCenter + halfH <= screenH {
            y = belowCenter
        } else {
            y = min(max(r.maxY - Self.toolbarHandleClearance - halfH, halfH),
                    max(halfH, screenH - halfH))
        }
        return CGPoint(x: x, y: y)
    }

    // MARK: - 保存/复制

    private func handleSave() {
        guard state.isRegionConfirmed, state.selectionRect.width > 5 else {
            ScreenshotLogger.log("handleSave aborted: no valid selection")
            return
        }
        onCapture(state.selectionRect, state.shapes, true)
    }

    private func handleCopy() {
        guard state.isRegionConfirmed, state.selectionRect.width > 5 else {
            ScreenshotLogger.log("handleCopy aborted: no valid selection")
            return
        }
        onCapture(state.selectionRect, state.shapes, false)
    }
}

/// 图形缩放的起始快照。每帧都以「起始点集 + 起始盒子」为基准重算，
/// 而不是在上一帧结果上累加，避免连续缩放产生漂移。
struct ShapeResizeStart {
    let index: Int
    /// 起始包围盒（用于把指针位置换算成 x/y 两个方向的缩放比例）
    let startBox: CGRect
    /// 起始点集（所有变换都基于它重算）
    let startPoints: [CGPoint]
    /// 固定不动的锚点 = 被拖手柄的对角/对边中点
    let anchor: CGPoint
}

/// 标注层手势模式：按下时先判定命中，命中 → 拖动；未命中 → 按当前工具新建。
enum AnnotationDragMode {
    case none
    case moveShape
    case draw
    /// 文本工具在空白处按下：松开时位移过小才真正创建文本框
    case textCreate
}

// MARK: - 共享状态

final class OverlayState: ObservableObject {
    @Published var selectionRect: CGRect = .zero
    @Published var isRegionConfirmed = false
    @Published var tool: AnnotationTool = .selection
    @Published var shapes: [AnnotationShape] = []
    @Published var drawingShape: AnnotationShape?
    @Published var currentColor: Color = .red
    @Published var lineWidth: CGFloat = 3
    /// 正在输入文字的文本框下标（决定是否显示 TextField 浮层）
    @Published var editingTextIndex: Int? = nil
    /// 当前选中的标注下标（**文本与图形共用**）：显示虚线框 + 8 个缩放手柄，
    /// 二级工具栏 / 主色板 / 线宽滑杆 / 删除键都作用在它身上。
    @Published var selectedShapeIndex: Int? = nil
    /// 派生：选中的若是文本框则给出它的下标，否则 nil。
    /// 保留这个名字是为了让既有文本逻辑（二级工具栏样式路由等）零改动地继续工作。
    var selectedTextIndex: Int? {
        guard let i = selectedShapeIndex, shapes.indices.contains(i),
              shapes[i].tool == .text else { return nil }
        return i
    }
    /// 选中标注的 id（下标会随删除前移，跨调用时用 id 定位才安全）
    var selectedShapeID: UUID? {
        guard let i = selectedShapeIndex, shapes.indices.contains(i) else { return nil }
        return shapes[i].id
    }
    /// 新建文本框的默认样式（也是「未选中任何文本框」时二级工具栏的作用对象）
    @Published var textStyle = TextStyle()
    /// 图形拖动期间的临时状态（同样不加 `@Published`）。
    var shapeDragID: UUID? = nil
    var shapeDragOriginPoints: [CGPoint]? = nil
    var shapeResizeStart: ShapeResizeStart? = nil
    /// 标注层当前的手势模式（`annotationGesture` 用）
    var annotationMode: AnnotationDragMode = .none
    /// 文本工具下「按下点」暂存：松开时位移过小才创建文本框（拖拽不创建）
    var annotationStart: CGPoint? = nil
    @Published var resizeOrigin: CGRect? = nil
    @Published var activeEdge: ResizeEdge? = nil
    @Published var moveOrigin: CGPoint? = nil
    /// 当前拖拽模式
    @Published var dragMode: SelectionDragMode = .none
    /// draw 模式的起点
    @Published var drawStart: CGPoint? = nil
    /// draw 模式开始前的选区（拖拽过小视为误触时恢复用）
    @Published var preDrawRect: CGRect = .zero
    /// 本次截屏是否已经用掉「重画机会」。
    /// 初始选区（自动框选的整窗 / 上次框选）允许在内部拖拽收窄一次；
    /// 用过之后内部拖拽回到「平移」，避免每次微调位置都被判成重画。
    /// 消耗时机：① 内部拖出有效的新区域；② 在选区内单击一下（= 放弃重画）。
    @Published var hasRedrawn = false

    /// 当前因悬停手柄而 push 上去的指针形状，用于成对 pop 还原。
    /// 故意**不加** `@Published`：鼠标每移动一次都会赋值，发布出去会引发整屏重绘。
    var hoverCursor: NSCursor? = nil
    /// 工具栏实测尺寸（由 `ToolbarSizeKey` 上报）。首帧尚未量到前用估值兜底，
    /// 只影响第一帧的钳制，量到后立刻纠正。
    @Published var toolbarSize: CGSize = CGSize(width: 380, height: 44)
    /// 用户手动拖动工具栏产生的位移（相对自动计算的基准位置）。
    /// 最大化窗口时选区几乎铺满整屏，工具栏无论放哪都会压在选区上，
    /// 所以允许用户把它拖开；拖动结果只在本次截屏内有效。
    @Published var toolbarDragOffset: CGSize = .zero
    /// 选区下方「尺寸 + 提示」浮层的实测尺寸（同为上报所得）
    @Published var labelStackSize: CGSize = .zero

    var canUndo: Bool {
        drawingShape != nil || !shapes.isEmpty
    }

    var canDelete: Bool {
        selectedShapeIndex != nil
    }

    /// 删除指定下标的标注，并把所有「下标型」状态一起前移。
    /// 所有删除都必须走这里 —— 否则选中态会指向错位的形状（甚至越界崩溃）。
    func removeShape(at k: Int) {
        guard shapes.indices.contains(k) else { return }
        let wasEditing = (editingTextIndex == k)
        shapes.remove(at: k)
        selectedShapeIndex = Self.shift(selectedShapeIndex, removed: k)
        if !wasEditing { editingTextIndex = Self.shift(editingTextIndex, removed: k) }
        else { editingTextIndex = nil }
        // 拖动/缩放的临时状态引用的都是被删对象，一律清空
        shapeResizeStart = nil
        shapeDragID = nil
        shapeDragOriginPoints = nil
    }

    /// 下标在「删除第 removed 个元素」后的新值。
    private static func shift(_ i: Int?, removed k: Int) -> Int? {
        guard let i = i else { return nil }
        if i == k { return nil }
        return i > k ? i - 1 : i
    }

    /// 结束文本编辑：把该框的样式/颜色记成新建默认值；内容为空则整个丢弃。
    /// （放在状态层是因为选中态与形状数组都在这里，视图只需调用。）
    func commitEditingText() {
        guard let idx = editingTextIndex, shapes.indices.contains(idx),
              shapes[idx].tool == .text else {
            editingTextIndex = nil
            return
        }
        // 只把文本框的**样式**记成新建默认值。
        // 注意：**不要**把它的颜色写进 `currentColor` —— 那是「图形/画笔」的默认色，
        // 拿文字色去覆盖它等于又把两套颜色混起来（四套颜色互相独立是硬要求）。
        textStyle = shapes[idx].style
        // 多行输入后可能只剩换行/空格 —— 全空白同样视为空内容，不留不可见的空壳。
        let content = shapes[idx].text ?? ""
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            removeShape(at: idx)
        }
        editingTextIndex = nil
    }

    // MARK: - 图形拖动

    /// 开始拖动某个标注（文本/图形通用，按 id 定位以免下标漂移）。
    /// 顺带结束可能正在进行的其它文字编辑，并把它设为选中项。
    func beginShapeDrag(id: UUID) {
        if let e = editingTextIndex, shapes.indices.contains(e), shapes[e].id != id {
            commitEditingText()
        }
        guard let i = shapes.firstIndex(where: { $0.id == id }) else { return }
        selectedShapeIndex = i
        shapeDragID = id
        shapeDragOriginPoints = shapes[i].points
        shapeResizeStart = nil
    }

    func updateShapeDrag(translation: CGSize) {
        guard let id = shapeDragID, let origin = shapeDragOriginPoints,
              let i = shapes.firstIndex(where: { $0.id == id }) else { return }
        var n = shapes[i]
        n.points = origin.map { CGPoint(x: $0.x + translation.width,
                                        y: $0.y + translation.height) }
        shapes[i] = n
    }

    /// 结束拖动。返回是否为「单击」（位移 < 3pt）——调用方据此决定要不要进入文字编辑。
    @discardableResult
    func endShapeDrag(translation: CGSize) -> Bool {
        let moved = abs(translation.width) + abs(translation.height)
        shapeDragID = nil
        shapeDragOriginPoints = nil
        return moved < 3
    }

    /// 拖动结束后把标注整体夹回选区内（整个超出就贴左/上边），避免拖出截图范围丢内容。
    func clampShapeIntoSelection(id: UUID) {
        guard let i = shapes.firstIndex(where: { $0.id == id }) else { return }
        let box = shapes[i].bounds()
        let sel = selectionRect
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        if box.width >= sel.width { dx = sel.minX - box.minX }
        else if box.minX < sel.minX { dx = sel.minX - box.minX }
        else if box.maxX > sel.maxX { dx = sel.maxX - box.maxX }
        if box.height >= sel.height { dy = sel.minY - box.minY }
        else if box.minY < sel.minY { dy = sel.minY - box.minY }
        else if box.maxY > sel.maxY { dy = sel.maxY - box.maxY }
        guard dx != 0 || dy != 0 else { return }
        var n = shapes[i]
        n.translate(by: dx, dy: dy)
        shapes[i] = n
    }

    /// 撤销：优先丢弃正在绘制中的标注，否则移除最后一个已完成标注。
    func undo() {
        if drawingShape != nil {
            drawingShape = nil
            return
        }
        guard !shapes.isEmpty else { return }
        removeShape(at: shapes.count - 1)
    }
}
