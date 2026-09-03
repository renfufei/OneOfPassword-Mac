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

final class ScreenshotOverlayController {
    static let shared = ScreenshotOverlayController()

    private var panel: NSPanel?
    /// 覆盖层显示前抓取的全屏快照
    private var snapshot: CGImage?
    /// 截屏前隐藏的应用窗口（恢复时用）
    private var hiddenWindows: [NSWindow] = []

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
        let p = NSPanel(
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
            }
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
        hiddenWindows = []
        for window in NSApp.windows where window.isVisible && !(window is NSPanel) {
            hiddenWindows.append(window)
            window.orderOut(nil)
        }
    }

    private func restoreAppWindows() {
        ScreenshotLogger.log("restoreAppWindows() count=\(hiddenWindows.count)")
        for window in hiddenWindows {
            window.orderFront(nil)
        }
        hiddenWindows = []
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 从快照裁剪选区 + 合成标注，不再调截图 API。
    private func captureAndSave(selectionRect: CGRect, shapes: [AnnotationShape], saveToFile: Bool) {
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
            return n
        }
        guard let out = ScreenshotCaptureService.composite(base: base, shapes: localShapes) else {
            ScreenshotLogger.log("captureAndSave composite failed")
            dismiss()
            return
        }
        dismiss()
        if saveToFile {
            ScreenshotCaptureService.savePanel(image: out)
        } else {
            ScreenshotCaptureService.copyToPasteboard(image: out)
        }
    }

    func dismiss() {
        ScreenshotLogger.log("overlay dismiss() called, panel exists=\(panel != nil)")
        panel?.orderOut(nil)
        panel = nil
        snapshot = nil
        restoreAppWindows()
    }
}
