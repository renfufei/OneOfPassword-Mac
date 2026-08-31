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

struct ScreenshotOverlayView: View {
    var snapshot: CGImage
    var onDismiss: () -> Void
    var onCapture: (CGRect, [AnnotationShape], Bool) -> Void

    @StateObject private var state = OverlayState()
    @State private var keyMonitor: Any?
    @FocusState private var textFocused: Bool

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

                // 标注层（画在选区内）
                annotationLayer

                // 选区边框 + 手柄
                selectionFrame

                // 文本浮层
                if let idx = state.editingTextIndex, idx < state.shapes.count {
                    textOverlay(idx: idx)
                }

                // 工具栏
                if state.isRegionConfirmed {
                    AnnotationToolbar(
                        selectedTool: $state.tool,
                        color: $state.currentColor,
                        lineWidth: $state.lineWidth,
                        canUndo: state.canUndo,
                        onSave: handleSave,
                        onCopy: handleCopy,
                        onUndo: { state.undo() },
                        onCancel: { onDismiss() }
                    )
                    .position(x: toolbarPosition.x, y: toolbarPosition.y)
                }
            }
        }
        .onAppear {
            initSelection()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // 文本编辑中：Esc 仅结束编辑，不退出截屏
                if event.keyCode == 53 {
                    if state.editingTextIndex != nil {
                        state.editingTextIndex = nil
                        textFocused = false
                        return nil
                    }
                    onDismiss()
                    return nil
                }
                // 文本编辑中不拦截撤销键，交给 TextField 处理
                if state.editingTextIndex == nil {
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
        .onChange(of: state.editingTextIndex) { idx in
            textFocused = (idx != nil)
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        }
    }

    private func initSelection() {
        guard let screen = NSScreen.main else { return }
        // 预选屏幕中央 60% 区域
        let w = screen.frame.width * 0.6
        let h = screen.frame.height * 0.6
        let x = (screen.frame.width - w) / 2
        let y = (screen.frame.height - h) / 2
        state.selectionRect = CGRect(x: x, y: y, width: w, height: h)
        state.isRegionConfirmed = true
        ScreenshotLogger.log("overlay initSelection rect=\(state.selectionRect)")
    }

    // MARK: - 蒙版（选区外半透明）

    private func overlayMask(size: CGSize) -> some View {
        Canvas { ctx, _ in
            let r = state.selectionRect
            // 全屏蒙版
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .color(.black.opacity(0.45)))
            // 选区内挖空（透明）
            ctx.fill(Path(r), with: .color(.clear))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    // MARK: - 选区边框 + 手柄 + 统一手势

    private var selectionFrame: some View {
        let r = state.selectionRect
        return ZStack {
            // 边框
            Rectangle()
                .stroke(.white, lineWidth: 1.5)
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)

            // 尺寸标签
            Text("\(Int(r.width)) × \(Int(r.height))")
                .font(.caption)
                .foregroundColor(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.6))
                .cornerRadius(4)
                .position(x: r.midX, y: r.maxY + 14)
                .allowsHitTesting(false)

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
                .allowsHitTesting(false)
            }

            // 统一手势层：覆盖选区边框附近区域，按下时根据位置判断 edge
            if state.tool == .selection {
                Color.clear
                    .frame(width: r.width + 20, height: r.height + 20)
                    .contentShape(Rectangle())
                    .position(x: r.midX, y: r.midY)
                    .gesture(unifiedGesture)
            }
        }
    }

    private func handleView(at pos: CGPoint) -> some View {
        let s: CGFloat = 14
        return RoundedRectangle(cornerRadius: 3)
            .fill(.white)
            .frame(width: s, height: s)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.black.opacity(0.3), lineWidth: 1))
            .position(pos)
    }

    /// 统一拖动手势：按下时判断起始位置——靠近边框则缩放，选区内部则整体平移。
    private var unifiedGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = value.startLocation
                if state.resizeOrigin == nil && state.moveOrigin == nil {
                    let r = state.selectionRect
                    if isOnEdge(at: start, in: r) {
                        state.resizeOrigin = r
                        let edge = detectEdge(at: start, in: r)
                        state.activeEdge = edge
                        ScreenshotLogger.log("unified START(resize) start=\(start) edge=\(edge.rawValue) orig=\(r)")
                    } else {
                        state.moveOrigin = r.origin
                        ScreenshotLogger.log("unified START(move) start=\(start) orig=\(r.origin)")
                    }
                }
                if let edge = state.activeEdge, let orig = state.resizeOrigin {
                    applyResize(edge: edge, orig: orig,
                               dx: value.translation.width, dy: value.translation.height)
                } else if let origin = state.moveOrigin {
                    applyMove(origin: origin,
                              dx: value.translation.width, dy: value.translation.height)
                }
            }
            .onEnded { _ in
                state.activeEdge = nil
                state.resizeOrigin = nil
                state.moveOrigin = nil
            }
    }

    /// 起始点是否落在任一边框容差带内（非纯内部）。
    private func isOnEdge(at p: CGPoint, in r: CGRect) -> Bool {
        let tol: CGFloat = 15
        return abs(p.x - r.minX) < tol || abs(p.x - r.maxX) < tol
            || abs(p.y - r.minY) < tol || abs(p.y - r.maxY) < tol
    }

    /// 整体平移选区，受屏幕边界约束。
    private func applyMove(origin: CGPoint, dx: CGFloat, dy: CGFloat) {
        let nx = origin.x + dx
        let ny = origin.y + dy
        let screen = NSScreen.main?.frame ?? .zero
        let r = state.selectionRect
        state.selectionRect.origin = CGPoint(
            x: min(max(0, nx), screen.width - r.width),
            y: min(max(0, ny), screen.height - r.height)
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
        var newRect = orig
        switch edge {
        case .left:
            // 左边移动：右边(maxX)不动，origin.x 变、width 反向
            newRect.origin.x = orig.minX + dx
            newRect.size.width = orig.width - dx
        case .right:
            // 右边移动：左边(minX)不动，width 变
            newRect.size.width = orig.width + dx
        case .top:
            // 顶边移动：底边(maxY)不动，向下拖 dy 正 → 顶边下移 → origin.y 变、height 反向
            newRect.origin.y = orig.minY + dy
            newRect.size.height = orig.height - dy
        case .bottom:
            // 底边移动：顶边(minY)不动，向下拖 dy 正 → 底边下移 → height 变
            newRect.size.height = orig.height + dy
        case .topLeft:
            newRect.origin.x = orig.minX + dx
            newRect.size.width = orig.width - dx
            newRect.origin.y = orig.minY + dy
            newRect.size.height = orig.height - dy
        case .topRight:
            newRect.size.width = orig.width + dx
            newRect.origin.y = orig.minY + dy
            newRect.size.height = orig.height - dy
        case .bottomLeft:
            newRect.origin.x = orig.minX + dx
            newRect.size.width = orig.width - dx
            newRect.size.height = orig.height + dy
        case .bottomRight:
            newRect.size.width = orig.width + dx
            newRect.size.height = orig.height + dy
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
                // 已完成文本（point 为左上角，左上原点对齐）
                for (i, shape) in state.shapes.enumerated() where shape.tool == .text {
                    if i == state.editingTextIndex { continue }
                    if let str = shape.text, !str.isEmpty, let p = shape.points.first {
                        ctx.draw(Text(str).font(.system(size: 18).weight(.medium)).foregroundColor(shape.color),
                                 at: p, anchor: .topLeading)
                    }
                }
            }

            // 标注绘制交互层：限选区范围，仅在矩形/圆形/箭头/画笔工具下接收
            if state.tool != .selection && state.tool != .text {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                    .gesture(annotationGesture)
            }

            // 文本工具：点击选区内任意位置创建文本标注并进入编辑
            if state.tool == .text {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
                    .onTapGesture { loc in
                        // 若正在编辑且已有内容，先结束当前编辑
                        if state.editingTextIndex != nil { return }
                        var s = AnnotationShape(
                            tool: .text,
                            points: [loc],
                            color: state.currentColor,
                            lineWidth: state.lineWidth
                        )
                        s.text = ""
                        state.shapes.append(s)
                        state.editingTextIndex = state.shapes.count - 1
                    }
            }
        }
    }

    private var annotationGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = value.startLocation
                let current = value.location
                if state.drawingShape == nil {
                    state.drawingShape = AnnotationShape(
                        tool: state.tool,
                        points: [start, current],
                        color: state.currentColor,
                        lineWidth: state.lineWidth
                    )
                } else if var s = state.drawingShape {
                    if s.tool == .pen {
                        s.points.append(current)
                    } else {
                        // 矩形/圆形/箭头：起点 + 当前点
                        if s.points.count >= 2 {
                            s.points[1] = current
                        } else {
                            s.points.append(current)
                        }
                    }
                    state.drawingShape = s
                }
            }
            .onEnded { value in
                if var s = state.drawingShape {
                    if s.tool != .pen, s.points.count >= 2 {
                        s.points[1] = value.location
                    }
                    state.shapes.append(s)
                    state.drawingShape = nil
                }
            }
    }

    // MARK: - 文本浮层

    private func textOverlay(idx: Int) -> some View {
        let sh = state.shapes[idx]
        let p = sh.points.first ?? .zero
        return TextField("输入文字", text: Binding(
            get: { state.shapes[idx].text ?? "" },
            set: { newVal in
                var n = state.shapes[idx]
                n.text = newVal
                state.shapes[idx] = n
            }
        ), onCommit: {
            if state.shapes[idx].text?.isEmpty ?? true {
                state.shapes.remove(at: idx)
            }
            state.editingTextIndex = nil
            textFocused = false
        })
        .textFieldStyle(.plain)
        .font(.system(size: 18).weight(.medium))
        .foregroundColor(sh.color)
        .frame(width: 220, height: 24)
        .padding(.horizontal, 4)
        .focused($textFocused)
        .position(x: p.x + 114, y: p.y + 12)
    }

    private func drawShape(_ ctx: GraphicsContext, _ shape: AnnotationShape) {
        if shape.tool == .text || shape.tool == .selection { return }
        ctx.stroke(shape.path(),
                   with: .color(shape.color),
                   lineWidth: shape.lineWidth)
    }

    // MARK: - 工具栏位置

    private var toolbarPosition: CGPoint {
        let r = state.selectionRect
        let screenH = NSScreen.main?.frame.height ?? 800
        let screenW = NSScreen.main?.frame.width ?? 1000
        let toolbarW: CGFloat = 380
        let toolbarH: CGFloat = 44
        var x = r.midX
        let y: CGFloat
        if r.minY - toolbarH - 12 > 0 {
            y = r.minY - toolbarH / 2 - 12
        } else {
            y = r.maxY + toolbarH / 2 + 12
        }
        x = max(toolbarW / 2, min(x, screenW - toolbarW / 2))
        let clampedY = max(toolbarH, min(y, screenH - toolbarH))
        return CGPoint(x: x, y: clampedY)
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

// MARK: - 共享状态

final class OverlayState: ObservableObject {
    @Published var selectionRect: CGRect = .zero
    @Published var isRegionConfirmed = false
    @Published var tool: AnnotationTool = .selection
    @Published var shapes: [AnnotationShape] = []
    @Published var drawingShape: AnnotationShape?
    @Published var currentColor: Color = .red
    @Published var lineWidth: CGFloat = 3
    @Published var editingTextIndex: Int? = nil
    @Published var resizeOrigin: CGRect? = nil
    @Published var activeEdge: ResizeEdge? = nil
    @Published var moveOrigin: CGPoint? = nil

    var canUndo: Bool {
        drawingShape != nil || !shapes.isEmpty
    }

    /// 撤销：优先丢弃正在绘制中的标注，否则移除最后一个已完成标注。
    func undo() {
        if drawingShape != nil {
            drawingShape = nil
            return
        }
        if !shapes.isEmpty {
            if shapes.last?.tool == .text, editingTextIndex == shapes.count - 1 {
                editingTextIndex = nil
            }
            shapes.removeLast()
        }
    }
}
