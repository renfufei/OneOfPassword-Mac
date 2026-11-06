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
    override var canBecomeMain: Bool { false }
}

final class ScreenshotOverlayController {
    static let shared = ScreenshotOverlayController()

    private var panel: NSPanel?
    /// 本次截屏是否发生在「原生全屏 Space」上。
    /// 全屏 Space 由别的 App 独占，本应用一旦 activate，macOS 就会离开该 Space
    /// （甩回桌面、甚至新建一个 Space），覆盖层因此出现在错误的界面上。
    /// 该标志决定覆盖层走「非激活面板」还是原来的「激活应用」流程。
    private var onFullScreenSpace = false
    /// 覆盖层显示前抓取的全屏快照
    private var snapshot: CGImage?
    /// 截屏前隐藏的应用窗口（恢复时用），按 Z 轴顺序保存
    private var hiddenWindows: [NSWindow] = []
    /// 截屏前的前台应用（若非本应用）。普通桌面流程会激活本应用，恢复时必须把焦点还回去；
    /// 全屏 Space 流程不激活本应用，只在保存对话框/弹窗意外激活后用它归还焦点。
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
        // 状态统一取 `AppPermission`（与「设置 → 系统权限」同一份真相，别再自己调 CGPreflight）。
        // 注意：`request()` 的返回值在请求瞬间不可靠（授权异步生效），
        // 因此不依据返回值决定是否弹自定义框——交给系统框引导即可。
        if !AppPermission.screenRecording.status.isAuthorized {
            ScreenshotLogger.log("overlay show() no screen capture permission — requesting (system prompt only)")
            AppPermission.screenRecording.request()
            PermissionCenter.shared.refresh()
            return
        }

        // 必须在隐藏窗口 / 激活应用之前判断：当前 Space 是不是原生全屏 Space。
        onFullScreenSpace = ScreenshotCaptureService.isFullScreenSpaceActive()
        ScreenshotLogger.log("overlay show() onFullScreenSpace=\(onFullScreenSpace)")

        // 自动识别鼠标所在窗口：必须在隐藏本应用窗口之前取，否则顶层会变
        let autoWindow = UserDefaults.standard.object(forKey: "screenshotAutoWindow") as? Bool ?? false
        ScreenshotLogger.log("overlay show() autoWindow=\(autoWindow) (key=screenshotAutoWindow)")
        pendingPreferredRect = autoWindow ? ScreenshotCaptureService.windowAtMouse() : nil
        ScreenshotLogger.log("overlay show() pendingPreferredRect=\(String(describing: pendingPreferredRect))")

        if onFullScreenSpace {
            // 目标独占一个全屏 Space：本应用窗口在别的 Space，本来就不会进快照，
            // 因此既不隐藏也不恢复窗口；更重要的是全程不激活本应用，避免 Space 被切换。
            let front = NSWorkspace.shared.frontmostApplication
            previousFrontApp = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
            hiddenWindows = []
            captureAndShowPanel()
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
            // 全屏 Space 下本应用未激活，先激活才能让系统弹框出现在前台；
            // 随后的 restoreAppWindows() 会把焦点还给原全屏应用。
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
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
        ScreenshotLogger.log("overlay show() creating panel on screen \(screen.frame) onFullScreenSpace=\(onFullScreenSpace)")
        // .nonactivatingPanel 只能在 init 时设：运行期改 styleMask 在部分 macOS 上
        // 不会同步更新 WindowServer 的窗口标签，会出现「看起来是 key、实际收不到按键」。
        var styleMask: NSWindow.StyleMask = [.borderless, .fullSizeContentView]
        if onFullScreenSpace { styleMask.insert(.nonactivatingPanel) }
        let p = ScreenshotOverlayPanel(
            contentRect: screen.frame,
            styleMask: styleMask,
            backing: .buffered,
            defer: false,
            screen: screen
        )
        p.level = .screenSaver
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isOpaque = false
        p.ignoresMouseEvents = false
        if onFullScreenSpace {
            // 跨 App 全屏 Space 的浮层：非激活面板 + Apple DTS 推荐的组合。
            // canJoinAllApplications 负责跨进别的 App 的 Space，
            // fullScreenAuxiliary 负责叠在全屏内容之上，screenSaver level 保证在最顶层。
            p.isFloatingPanel = true
            p.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications,
                                    .fullScreenAuxiliary, .stationary, .ignoresCycle]
        } else {
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
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
        if onFullScreenSpace {
            // 关键：绝不调用 NSApp.activate。常规 App 被激活时 macOS 会离开当前全屏 Space，
            // 把用户甩到桌面（或为它新建一个 Space），覆盖层就跑到另一个界面上了。
            // 非激活面板由 WindowServer 以「key focus theft」方式直接拿到键盘事件，
            // 全屏目标 App 仍是 frontmost，Space 原地不动。
            p.orderFrontRegardless()
            p.makeKey()
            p.orderFrontRegardless()
            ScreenshotLogger.log("overlay show() fullscreen-space: no activation, isKey=\(p.isKeyWindow) isActive=\(NSApp.isActive)")
            // 面板刚上屏时可能还没完成 key focus 交接，补一次保险
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak p] in
                guard let p, p.isVisible, !p.isKeyWindow else { return }
                p.makeKey()
                ScreenshotLogger.log("overlay show() fullscreen-space retry makeKey, isKey=\(p.isKeyWindow)")
            }
        } else {
            // 应用窗口已 orderOut，需重新激活应用让 panel 成为 key window 接收鼠标事件
            NSApp.activate(ignoringOtherApps: true)
            p.makeKeyAndOrderFront(nil)
            p.orderFrontRegardless()
            // 确认 panel 成为 key
            p.makeKey()
            p.orderFrontRegardless()
        }
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
        ScreenshotLogger.log("restoreAppWindows() count=\(hiddenWindows.count) onFullScreenSpace=\(onFullScreenSpace) prevApp=\(previousFrontApp?.localizedName ?? "nil")")
        if onFullScreenSpace {
            // 覆盖层没抢前台、也没隐藏窗口，正常情况下什么都不用做。
            // 例外：保存对话框 / 失败弹窗期间系统把本应用激活了 → 把焦点还给原全屏应用。
            if NSApp.isActive, let prev = previousFrontApp, !prev.isTerminated {
                prev.activate()
                ScreenshotLogger.log("restoreAppWindows() 归还焦点给全屏应用 \(prev.localizedName ?? "?")")
            }
            hiddenWindows = []
            previousFrontApp = nil
            onFullScreenSpace = false
            return
        }
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
