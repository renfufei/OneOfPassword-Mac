//
//  ScreenshotOverlayController.swift
//  OneOfPassword
//
//  截屏覆盖层控制器。
//  架构：显示覆盖层前先抓全屏快照（此时屏幕是目标内容），
//  覆盖层基于快照裁剪选区 + 合成标注，不再在保存时调截图 API。
//

import AppKit
import SwiftUI

/// 截屏覆盖层专用面板。
/// 为什么需要子类：无边框 `NSPanel` 在某些情况下不会成为 key window，
/// 那样即使 SwiftUI 里 `.focused($textFocused) = true` 生效，`TextField` 也拿不到
/// 第一响应者 —— 表现就是「文本框画出来了，但敲键盘没反应」。
/// 这里显式放开 canBecomeKey，保证文本标注一定能输入。
private final class ScreenshotOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class ScreenshotOverlayController {
    static let shared = ScreenshotOverlayController()

    private var panel: NSPanel?
    /// 覆盖层显示前抓取的全屏快照
    private var snapshot: CGImage?
    /// 截屏前隐藏的应用窗口（恢复时用），按 Z 轴顺序保存
    private var hiddenWindows: [NSWindow] = []
    /// 截屏前的前台应用（若非本应用）。覆盖层显示期间本应用会被强制激活，
    /// 恢复时必须主动把焦点还给这个应用，否则会一直抢着前台。
    private var previousFrontApp: NSRunningApplication?
    /// autoWindow 开启时，在隐藏本应用窗口之前识别出的鼠标所在窗口 rect
    private var pendingPreferredRect: CGRect?

    private init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(triggered),
            name: .screenshotTriggered, object: nil
        )
    }

    @objc private func triggered() {
        ScreenshotLogger.log("overlay triggered() — received .screenshotTriggered")
        show()
    }

    func show() {
        ScreenshotLogger.log("overlay show() called, panel exists=\(panel != nil)")
        guard panel == nil else {
            ScreenshotLogger.log("overlay show() aborted: panel already exists")
            return
        }

        // 先检查屏幕录制权限；未授权时请求系统弹框，不再叠加自定义 alert，避免双弹窗。
        // 注意：CGRequestScreenCaptureAccess 的返回值在请求瞬间不可靠（授权异步生效），
        // 因此不依据返回值决定是否弹自定义框——交给系统框引导即可。
        if !CGPreflightScreenCaptureAccess() {
            ScreenshotLogger.log("overlay show() no screen capture permission — requesting (system prompt only)")
            _ = CGRequestScreenCaptureAccess()
            return
        }

        // 自动识别鼠标所在窗口：必须在隐藏本应用窗口之前取，否则顶层会变
        let autoWindow = UserDefaults.standard.object(forKey: "screenshotAutoWindow") as? Bool ?? false
        ScreenshotLogger.log("overlay show() autoWindow=\(autoWindow) (key=screenshotAutoWindow)")
        pendingPreferredRect = autoWindow ? ScreenshotCaptureService.windowAtMouse() : nil
        ScreenshotLogger.log("overlay show() pendingPreferredRect=\(String(describing: pendingPreferredRect))")

        // 自动隐藏本应用窗口（默认开启），避免快照里截到应用自身
        let autoHide = UserDefaults.standard.object(forKey: "screenshotAutoHide") as? Bool ?? true
        if autoHide {
            hideAppWindows()
            // 延迟等隐藏动画完成后再抓快照
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.captureAndShowPanel()
            }
        } else {
            captureAndShowPanel()
        }
    }

    private func captureAndShowPanel() {
        // 抓全屏快照，此时屏幕显示的是目标内容（应用窗口已隐藏）
        let snap = ScreenshotCaptureService.captureFullScreen()
        guard let snap else {
            ScreenshotLogger.log("overlay show() full screen capture failed — abort")
            let alert = NSAlert()
            alert.messageText = "截图失败"
            alert.informativeText = "无法抓取屏幕快照，请重试。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            restoreAppWindows()
            return
        }
        snapshot = snap

        guard let screen = NSScreen.main else {
            ScreenshotLogger.log("overlay show() no main screen")
            restoreAppWindows()
            return
        }
        ScreenshotLogger.log("overlay show() creating panel on screen \(screen.frame)")
        let p = ScreenshotOverlayPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        p.level = .screenSaver
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isOpaque = false
        p.ignoresMouseEvents = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false

        let host = NSHostingController(rootView: ScreenshotOverlayView(
            snapshot: snap,
            onDismiss: { [weak self] in
                ScreenshotLogger.log("overlay onDismiss called from SwiftUI view")
                self?.dismiss()
            },
            onCapture: { [weak self] selectionRect, shapes, saveToFile in
                self?.captureAndSave(selectionRect: selectionRect, shapes: shapes, saveToFile: saveToFile)
            },
            preferredRect: pendingPreferredRect
        ))
        p.contentViewController = host
        p.setFrame(screen.frame, display: true)
        host.view.frame = p.contentView?.bounds ?? screen.frame
        host.view.autoresizingMask = [.width, .height]
        // 应用窗口已 orderOut，需重新激活应用让 panel 成为 key window 接收鼠标事件
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        p.orderFrontRegardless()
        // 确认 panel 成为 key
        p.makeKey()
        p.orderFrontRegardless()
        ScreenshotLogger.log("overlay show() panel created isVisible=\(p.isVisible) frame=\(p.frame)")
        panel = p
    }

    // MARK: - 应用窗口隐藏/恢复

    private func hideAppWindows() {
        ScreenshotLogger.log("hideAppWindows()")
        // 记录当前桌面的前台应用：若不由本应用占据，恢复时需把焦点还给它
        let front = NSWorkspace.shared.frontmostApplication
        let isSelf = front?.bundleIdentifier == Bundle.main.bundleIdentifier
        previousFrontApp = isSelf ? nil : front
        ScreenshotLogger.log("hideAppWindows() frontmost=\(front?.localizedName ?? "nil") isSelf=\(isSelf) 需归还焦点=\(previousFrontApp != nil)")
        hiddenWindows = []
        for window in NSApp.windows where window.isVisible && !(window is NSPanel) {
            hiddenWindows.append(window)
            window.orderOut(nil)
        }
    }

    private func restoreAppWindows() {
        ScreenshotLogger.log("restoreAppWindows() count=\(hiddenWindows.count) prevApp=\(previousFrontApp?.localizedName ?? "nil")")
        for window in hiddenWindows {
            // 仅恢复可见性，不打乱窗口 Z 轴顺序
            window.setIsVisible(true)
        }
        hiddenWindows = []
        // 覆盖层显示期间本应用被 activate 成前台；若截屏前焦点在别的应用，
        // 必须主动把那个应用重新激活，否则本应用会一直赖在最前面。
        if let prev = previousFrontApp, !prev.isTerminated {
            let ok = prev.activate()
            ScreenshotLogger.log("restoreAppWindows() 归还焦点给 \(prev.localizedName ?? "?") ok=\(ok)")
        } else {
            NSApp.activate(ignoringOtherApps: false)
            ScreenshotLogger.log("restoreAppWindows() 保持本应用前台")
        }
        previousFrontApp = nil
    }

    /// 从快照裁剪选区 + 合成标注，不再调截图 API。
    private func captureAndSave(selectionRect: CGRect, shapes: [AnnotationShape], saveToFile: Bool) {
        // 记住本次框选区域，供下次截屏自动定位
        ScreenshotCaptureService.saveLastSelection(selectionRect)
        ScreenshotLogger.log("captureAndSave saveToFile=\(saveToFile) rect=\(selectionRect)")
        guard let snap = snapshot else {
            ScreenshotLogger.log("captureAndSave no snapshot")
            dismiss()
            return
        }
        guard let base = ScreenshotCaptureService.crop(from: snap, rect: selectionRect) else {
            ScreenshotLogger.log("captureAndSave crop failed")
            dismiss()
            return
        }
        // 标注 points 为全屏视图坐标（左上原点、点单位）。合成前转到底图像素坐标（左下原点）：
        // 1) 减选区 origin → 选区局部左上坐标（点）
        // 2) 乘 backingScaleFactor → 像素坐标（点）
        // 3) y 翻转（视图左上 → CG 底图左下）
        let scale = CGFloat(NSScreen.main?.backingScaleFactor ?? 1)
        let baseH = CGFloat(base.height)
        let localShapes = shapes.map { s -> AnnotationShape in
            var n = s
            n.points = s.points.map { p in
                let lx = p.x - selectionRect.origin.x
                let ly = p.y - selectionRect.origin.y
                return CGPoint(x: lx * scale, y: baseH - ly * scale)
            }
            n.lineWidth = s.lineWidth * scale
            // 文本样式里的字号 / 边框线宽同样是「点」单位，必须一起缩放，
            // 否则 Retina 下保存出来的文字仍是 18pt、而底图已放大 2 倍，字会明显偏小。
            // 内边距由 paddingH/paddingV 按 fontSize 等比推出，会自动跟着一起放大。
            n.style.fontSize = s.style.fontSize * scale
            n.style.borderWidth = s.style.borderWidth * scale
            return n
        }
        guard let out = ScreenshotCaptureService.composite(base: base, shapes: localShapes) else {
            ScreenshotLogger.log("captureAndSave composite failed")
            dismiss()
            return
        }
        // 先只关 panel，把「恢复主窗口 + 归还焦点」放到最后：
        // 保存对话框期间主窗口保持隐藏，避免还在选保存位置时界面就跳回最前；
        // 复制到剪贴板则立刻恢复。
        closePanel()
        if saveToFile {
            ScreenshotCaptureService.savePanel(image: out)
        } else {
            ScreenshotCaptureService.copyToPasteboard(image: out)
        }
        restoreAppWindows()
    }

    /// 仅关闭覆盖层 panel，不恢复主窗口。
    /// 保存流程会先把 panel 关掉、弹出保存对话框，等用户选完再 restoreAppWindows，
    /// 避免「刚弹出保存框，主窗口就先跳回最前」。
    private func closePanel() {
        panel?.orderOut(nil)
        panel = nil
        snapshot = nil
    }

    func dismiss() {
        ScreenshotLogger.log("overlay dismiss() called, panel exists=\(panel != nil)")
        closePanel()
        restoreAppWindows()
    }
}
