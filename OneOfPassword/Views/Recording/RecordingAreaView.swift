//
//  RecordingAreaView.swift
//  OneOfPassword
//
//  录屏选区覆盖层：拖动框选录制范围 → 就地开始录制。
//
//  === 为什么不复用截屏覆盖层 ===
//  截屏覆盖层（`ScreenshotOverlayView`，1400 行）的一切都围绕「快照 + 标注」：
//  它的选区状态里缠着标注选中、重画机会、手柄命中、文本编辑…… 录屏只需要「一块矩形」。
//  强行加一个 mode 开关，等于给那条已经很脆的手势链路再挂一个分支，
//  而截屏的交互规则（笔画容差带、选中态唯一真相 etc.）本来就不适用于录屏。
//  这里另起一份极简实现：语义清楚、互不牵连，两边改坏了也互不影响。
//
//  === 坐标 ===
//  视图内坐标 = 覆盖层局部坐标（左上原点、点单位）；
//  对外交给录制器的一律是 **CG 全局坐标**（左上原点），由 `screenOrigin` 平移得到。
//  `screenOrigin` 取 `CGDisplayBounds(screenID).origin`，多屏下也不会错位。
//
//  === 手势分层（与截屏同一套思路）===
//  手柄只是**展示**（`.allowsHitTesting(false)`），命中判定统一放在下面那层全屏手势里，
//  按下瞬间按位置决定模式：近角/近边 → 缩放，框内 → 平移，框外 → 重新框选。
//  这样只有一条 DragGesture，不存在「手柄手势 vs 背景手势」互相抢事件的死结，
//  也不会踩到「手势默认坐标空间是手柄自身」那个坑。
//

import AppKit
import SwiftUI

/// 工具栏实测尺寸上报（贴屏幕边缘时按真实宽度钳制，避免露到屏幕外）
private struct RecordingToolbarSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// 八个缩放手柄的位置
fileprivate enum ResizeAnchor: Hashable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

/// 按下瞬间判定的拖拽模式（一次拖拽内不变，避免中途换模式导致跳跃）
fileprivate enum DragMode {
    case none
    case newSelection
    case move
    case resize(ResizeAnchor)
}

struct RecordingAreaView: View {
    /// 本屏尺寸（点）
    var screenSize: CGSize
    /// 本屏在 CG 全局坐标系里的原点
    var screenOrigin: CGPoint
    /// 本屏的缩放因子（显示像素尺寸用）
    var scale: CGFloat
    /// 上次录制区域（CG 全局坐标），进来先摆好，省得每次重框
    var preferred: CGRect?
    /// 是否存有上次区域（决定「上次区域」开关显不显示）
    var hasLastRegion: Bool
    /// 打开时是否直接就用了上次区域（与设置页共用同一个偏好）
    var initialUseLast: Bool
    /// 用户在本面板里切换「上次区域」时回调，用来持久化偏好
    var onUseLastChanged: (Bool) -> Void

    /// 交给录制器的区域（CG 全局坐标）；nil = 整块屏幕
    var onStart: (CGRect?) -> Void
    var onCancel: () -> Void

    @State private var selection: CGRect?
    @State private var dragMode: DragMode = .none
    /// 本次拖拽开始时的选区（缩放/平移都以它为基准，避免累积误差）
    @State private var dragOrigin: CGRect?
    @State private var dragStart: CGPoint?
    @State private var toolbarSize: CGSize = .zero
    @State private var keyMonitor: Any?
    /// 面板内的「上次区域」开关状态；进面板时按偏好初始化
    @State private var useLast = true

    private var bounds: CGRect { CGRect(origin: .zero, size: screenSize) }

    /// 选区最小边长：比这更小的框没有录制价值，直接夹住
    private let minSelection: CGFloat = 32
    /// 手柄命中半径（手指没那么准，比视觉尺寸 14 略大）
    private let handleHitRadius: CGFloat = 11
    /// 边框命中容差
    private let edgeHitTolerance: CGFloat = 9

    var body: some View {
        ZStack {
            maskLayer
            interactionLayer
            if let rect = selection {
                selectionChrome(rect)
                toolbar(rect)
            } else {
                emptyHint
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .onAppear {
            useLast = initialUseLast && hasLastRegion
            selection = useLast ? initialSelection() : nil
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                switch event.keyCode {
                case 53:                    // Esc
                    onCancel()
                    return nil
                case 36, 76:                // Return / 小键盘 Enter
                    start()
                    return nil
                default:
                    return event
                }
            }
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            NSCursor.arrow.set()
        }
    }

    // MARK: - 蒙版

    /// 全屏半透明黑 + 把选区挖空（even-odd 填充），让用户看清将要录制的内容
    private var maskLayer: some View {
        Canvas { ctx, _ in
            var path = Path(bounds)
            if let r = selection { path.addRect(r) }
            ctx.fill(path,
                     with: .color(.black.opacity(0.42)),
                     style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
    }

    // MARK: - 交互层

    private var interactionLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if case .none = dragMode {
                            dragOrigin = selection
                            dragStart = value.startLocation
                            dragMode = Self.hitTest(value.startLocation,
                                                    selection: selection,
                                                    handleHitRadius: handleHitRadius,
                                                    edgeHitTolerance: edgeHitTolerance)
                            if case .newSelection = dragMode {
                                selection = CGRect(origin: value.startLocation, size: .zero)
                            }
                        }
                        switch dragMode {
                        case .newSelection:
                            guard let start = dragStart else { return }
                            selection = rect(from: start, to: value.location)
                        case .move:
                            guard let origin = dragOrigin else { return }
                            selection = Self.moved(origin, by: value.translation, bounds: bounds)
                        case .resize(let anchor):
                            guard let origin = dragOrigin else { return }
                            selection = Self.resized(anchor: anchor, from: origin,
                                                     to: value.location, bounds: bounds,
                                                     minSelection: minSelection)
                        case .none:
                            break
                        }
                    }
                    .onEnded { _ in
                        let wasNewSelection: Bool
                        if case .newSelection = dragMode { wasNewSelection = true } else { wasNewSelection = false }
                        dragMode = .none
                        dragStart = nil
                        dragOrigin = nil
                        // 手抖点一下得到的小框没有意义：只有「重新框选」才允许把它丢掉
                        if wasNewSelection, let r = selection,
                           r.width < minSelection || r.height < minSelection {
                            selection = nil
                        }
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    cursor(for: Self.hitTest(point,
                                             selection: selection,
                                             handleHitRadius: handleHitRadius,
                                             edgeHitTolerance: edgeHitTolerance)).set()
                case .ended:
                    NSCursor.arrow.set()
                }
            }
    }

    /// 按下点属于哪种操作。优先级：角 → 边 → 框内 → 框外。
    /// 做成 `static` 纯函数是为了能离线逐值校验（见 `.workbuddy/memory` 里的验证方法）。
    fileprivate static func hitTest(_ point: CGPoint, selection: CGRect?,
                                    handleHitRadius hr: CGFloat,
                                    edgeHitTolerance et: CGFloat) -> DragMode {
        guard let r = selection else { return .newSelection }
        let insideY = point.y >= r.minY && point.y <= r.maxY
        let insideX = point.x >= r.minX && point.x <= r.maxX
        let nearLeft   = abs(point.x - r.minX) <= (insideY ? et : hr)
        let nearRight  = abs(point.x - r.maxX) <= (insideY ? et : hr)
        let nearTop    = abs(point.y - r.minY) <= (insideX ? et : hr)
        let nearBottom = abs(point.y - r.maxY) <= (insideX ? et : hr)

        if nearLeft && nearTop { return .resize(.topLeft) }
        if nearRight && nearTop { return .resize(.topRight) }
        if nearLeft && nearBottom { return .resize(.bottomLeft) }
        if nearRight && nearBottom { return .resize(.bottomRight) }
        if nearTop    { return .resize(.top) }
        if nearBottom { return .resize(.bottom) }
        if nearLeft   { return .resize(.left) }
        if nearRight  { return .resize(.right) }
        if r.contains(point) { return .move }
        return .newSelection
    }

    // MARK: - 选区外观

    private func selectionChrome(_ rect: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            // 8 个手柄：四角 + 四边中点。只显示，不接事件（命中在下面的统一手势里判）
            handleView(at: CGPoint(x: rect.minX, y: rect.minY))
            handleView(at: CGPoint(x: rect.midX, y: rect.minY))
            handleView(at: CGPoint(x: rect.maxX, y: rect.minY))
            handleView(at: CGPoint(x: rect.maxX, y: rect.midY))
            handleView(at: CGPoint(x: rect.maxX, y: rect.maxY))
            handleView(at: CGPoint(x: rect.midX, y: rect.maxY))
            handleView(at: CGPoint(x: rect.minX, y: rect.maxY))
            handleView(at: CGPoint(x: rect.minX, y: rect.midY))

            // 像素尺寸（用户真正关心的是输出分辨率，不是点数）。
            // 必须用 `Text(verbatim:)`：`Text("\(Int(x))")` 走的是本地化数字格式，
            // 会输出带千分位的「1,320 × 760」，分辨率不该有分隔符。
            Text(verbatim: "\(Int(rect.width * scale)) × \(Int(rect.height * scale))")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.65)))
                .fixedSize()
                .position(x: rect.minX + 42, y: max(12, rect.minY - 12))
        }
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

    // MARK: - 工具栏

    private func toolbar(_ rect: CGRect) -> some View {
        let size = toolbarSize == .zero ? CGSize(width: 360, height: 44) : toolbarSize
        // 优先放在选区下方；下方放不下就翻到上方；都放不下（整屏选区）就摆进框内底部，
        // 避开边缘的中点手柄 —— 否则控制条会压住手柄，想缩回来还点不到。
        // 16 而不是 12：手柄半径 7，留 9pt 空隙，视觉上不会和手柄粘在一起。
        let gap: CGFloat = 16
        let below = rect.maxY + gap + size.height / 2
        let above = rect.minY - gap - size.height / 2
        let centerY: CGFloat
        if below + size.height / 2 <= screenSize.height - 8 {
            centerY = below
        } else if above - size.height / 2 >= 8 {
            centerY = above
        } else {
            centerY = rect.maxY - gap - size.height / 2
        }
        let clampedY = min(max(centerY, size.height / 2 + 8), screenSize.height - size.height / 2 - 8)
        let clampedX = min(max(rect.midX, size.width / 2 + 8), screenSize.width - size.width / 2 - 8)

        return HStack(spacing: 8) {
            if hasLastRegion {
                overlayChip("上次区域", icon: "rectangle.on.rectangle", isOn: useLast) {
                    toggleUseLast()
                }
            }
            // 选项类在左，"取消 / 开始录制"在右（开始录制是最右的主操作，与 macOS 惯例一致）
            overlayButton("录制整屏", icon: "rectangle.dashed", tint: .white, filled: false) {
                selectFullScreen()
            }
            overlayButton("取消", icon: "xmark", tint: .white, filled: false) { onCancel() }
            overlayButton("开始录制", icon: "record.circle.fill", tint: .red, filled: true) { start() }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black.opacity(0.72))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.12), lineWidth: 1))
        )
        .fixedSize()
        .background(
            GeometryReader { g in
                Color.clear.preference(key: RecordingToolbarSizeKey.self, value: g.size)
            }
        )
        .position(x: clampedX, y: clampedY)
        .onPreferenceChange(RecordingToolbarSizeKey.self) { value in
            guard value.width > 0, value != toolbarSize else { return }
            toolbarSize = value
        }
    }

    /// 覆盖层上的按钮：不用 .primary()/.secondary()（那两套是浅色界面配色，
    /// 压在深色蒙版上对比度不够），这里固定「深底白字 / 红底白字」。
    private func overlayButton(_ title: String, icon: String, tint: Color,
                               filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .frame(minHeight: AppMetrics.ghostButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(filled ? tint.opacity(0.92) : Color.white.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(.white.opacity(filled ? 0 : 0.40), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    /// 「上次区域」开关：带勾选圈的小胶囊，点一下套用/取消上次的框
    private func overlayChip(_ title: String, icon: String, isOn: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isOn ? Color.green : Color.white.opacity(0.45))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .frame(minHeight: AppMetrics.ghostButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(isOn ? 0.24 : 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(.white.opacity(isOn ? 0.45 : 0.25), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(isOn ? "已套用上次的录制区域（点一下取消并重新框选）" : "套用上次的录制区域")
    }

    /// 切换「上次区域」：立刻把选框摆上 / 清空，并把选择记进偏好
    private func toggleUseLast() {
        useLast.toggle()
        onUseLastChanged(useLast)
        selection = useLast ? initialSelection() : nil
    }

    // MARK: - 没有选区时的提示

    private var emptyHint: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 15, weight: .semibold))
                Text("拖动鼠标框选要录制的区域")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundColor(.white)

            HStack(spacing: 8) {
                if hasLastRegion && !useLast {
                    overlayButton("用上次区域", icon: "rectangle.on.rectangle", tint: .white, filled: false) {
                        toggleUseLast()
                    }
                }
                overlayButton("框选整屏", icon: "rectangle.dashed", tint: .white, filled: false) {
                    selectFullScreen()
                }
                overlayButton("取消", icon: "xmark", tint: .white, filled: false) { onCancel() }
            }

            Text("按 Return 框选整屏 · 按 Esc 取消")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.65))
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.75))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.12), lineWidth: 1))
        )
        .fixedSize()
        .position(x: screenSize.width / 2, y: screenSize.height / 2)
    }

    // MARK: - 逻辑

    /// 开始录制。没有选区时（只可能来自 Return）先框住整屏，让用户再确认一次 ——
    /// 「录制整屏」也走同一条路：只摆框，不自动开始。
    private func start() {
        guard let rect = selection else {
            selectFullScreen()
            return
        }
        // 整屏（含"点整屏按钮后没再动过"的情况）传 nil：走「整个 display」分支，
        // 不经过点坐标换算，避免亚像素误差把输出少算一两个像素。
        if abs(rect.minX) < 0.5, abs(rect.minY) < 0.5,
           abs(rect.width - bounds.width) < 0.5, abs(rect.height - bounds.height) < 0.5 {
            onStart(nil)
            return
        }
        onStart(CGRect(x: rect.minX + screenOrigin.x,
                       y: rect.minY + screenOrigin.y,
                       width: rect.width,
                       height: rect.height))
    }

    /// 把选区设成整块屏幕（不开始录制）。顺手把「上次区域」标记取消，
    /// 但不写回偏好：下次按快捷键仍按设置里的选择走。
    private func selectFullScreen() {
        useLast = false
        selection = bounds
    }

    private func initialSelection() -> CGRect? {
        guard let preferred else { return nil }
        let local = CGRect(x: preferred.minX - screenOrigin.x,
                           y: preferred.minY - screenOrigin.y,
                           width: preferred.width,
                           height: preferred.height)
        let clipped = local.intersection(bounds)
        guard !clipped.isNull, clipped.width >= minSelection, clipped.height >= minSelection else { return nil }
        return clipped
    }

    /// 两点之间标准化 + 夹进屏幕范围
    private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                          width: abs(b.x - a.x), height: abs(b.y - a.y))
        return rect.intersection(bounds)
    }

    /// 平移：整块位移，并夹住不让它跑出屏幕
    fileprivate static func moved(_ origin: CGRect, by translation: CGSize,
                                  bounds: CGRect) -> CGRect {
        var r = origin.offsetBy(dx: translation.width, dy: translation.height)
        r.origin.x = min(max(r.minX, 0), bounds.width - r.width)
        r.origin.y = min(max(r.minY, 0), bounds.height - r.height)
        return r
    }

    /// 缩放：拖哪条边就动哪条边，对角/对边保持不动；
    /// 拖过对边时钳在最小边长上（不翻转），最后整体夹进屏幕。
    fileprivate static func resized(anchor: ResizeAnchor, from origin: CGRect,
                                    to point: CGPoint, bounds: CGRect,
                                    minSelection: CGFloat) -> CGRect {
        let p = CGPoint(x: min(max(point.x, 0), bounds.width),
                        y: min(max(point.y, 0), bounds.height))
        var minX = origin.minX, maxX = origin.maxX
        var minY = origin.minY, maxY = origin.maxY

        switch anchor {
        case .topLeft:
            minX = min(p.x, maxX - minSelection); minY = min(p.y, maxY - minSelection)
        case .top:
            minY = min(p.y, maxY - minSelection)
        case .topRight:
            maxX = max(p.x, minX + minSelection); minY = min(p.y, maxY - minSelection)
        case .right:
            maxX = max(p.x, minX + minSelection)
        case .bottomRight:
            maxX = max(p.x, minX + minSelection); maxY = max(p.y, minY + minSelection)
        case .bottom:
            maxY = max(p.y, minY + minSelection)
        case .bottomLeft:
            minX = min(p.x, maxX - minSelection); maxY = max(p.y, minY + minSelection)
        case .left:
            minX = min(p.x, maxX - minSelection)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .intersection(bounds)
    }

    // MARK: - 光标

    private func cursor(for mode: DragMode) -> NSCursor {
        switch mode {
        case .resize(let anchor): return Self.resizeCursors[anchor] ?? .crosshair
        case .move:               return .openHand
        case .newSelection, .none: return .crosshair
        }
    }

    /// 缩放光标表（建一次）。macOS 15 起有官方斜向双箭头，之前公开 API 没有斜向，
    /// 角上退化为十字、四条边仍用系统双箭头。
    private static let resizeCursors: [ResizeAnchor: NSCursor] = {
        func make(_ anchor: ResizeAnchor) -> NSCursor {
            if #available(macOS 15.0, *) {
                let position: NSCursor.FrameResizePosition
                switch anchor {
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
            switch anchor {
            case .top, .bottom: return .resizeUpDown
            case .left, .right: return .resizeLeftRight
            default:            return .crosshair
            }
        }
        var table: [ResizeAnchor: NSCursor] = [:]
        for anchor in [ResizeAnchor.topLeft, .top, .topRight, .right,
                       .bottomRight, .bottom, .bottomLeft, .left] {
            table[anchor] = make(anchor)
        }
        return table
    }()
}
