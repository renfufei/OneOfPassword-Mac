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
    /// 覆盖层已统一走「非激活面板」流程（任何场景都不激活本应用、不切 Space），
    /// 该标志现在只决定 autoHide 是否必要：全屏 Space 上本应用窗口不在当前 Space，
    /// 不会进快照，无需隐藏。
    private var onFullScreenSpace = false
    /// 覆盖层显示前抓取的全屏快照
    private var snapshot: CGImage?
    /// 截屏前隐藏的应用窗口（恢复时用），按 Z 轴顺序保存
    private var hiddenWindows: [NSWindow] = []
    /// 截屏前的前台应用（若非本应用）。非激活流程下本应用全程不抢前台；
    /// 仅当保存对话框 / 失败弹窗把本应用激活后，用它归还焦点（并切回原 Space）。
    private var previousFrontApp: NSRunningApplication?
    /// autoWindow 开启时，在隐藏本应用窗口之前识别出的鼠标所在窗口 rect
    private var pendingPreferredRect: CGRect?
    /// 保存面板（系统 NSSavePanel，以 sheet 形式挂在覆盖层上）。
    /// 不能 `runModal()`：那会激活本应用 → 切走 Space → 保存框跑到默认桌面。
    /// sheet 跟随父窗口，只出现在用户当前所在的 Space，键盘由 sheet 自己接管。
    private var savePanel: NSSavePanel?
    /// 已合成好、等用户确认保存位置的图片
    private var pendingImage: CGImage?

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

        // 统一记录前台应用：非激活流程下本应用全程不抢前台，焦点天然不动；
        // 只有保存对话框 / 失败弹窗把本应用带前台时，才用它归还焦点。
        let front = NSWorkspace.shared.frontmostApplication
        previousFrontApp = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front

        if onFullScreenSpace {
            // 目标独占一个全屏 Space：本应用窗口在别的 Space，本来就不会进快照，
            // 因此不隐藏也不恢复窗口。
            hiddenWindows = []
            captureAndShowPanel()
            return
        }

        // 自动隐藏本应用窗口（默认开启），避免快照里截到应用自身。
        // orderOut 只影响窗口可见性，不抢前台、不切 Space。
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
        // 面板恒为「非激活面板」：不激活本应用也能成为 key window 接收鼠标/键盘
        //（WindowServer 的 key focus theft）。
        // .nonactivatingPanel 只能在 init 时设：运行期改 styleMask 在部分 macOS 上
        // 不会同步更新 WindowServer 的窗口标签，会出现「看起来是 key、实际收不到按键」。
        let p = ScreenshotOverlayPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        p.level = .screenSaver
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isOpaque = false
        p.ignoresMouseEvents = false
        // Apple DTS 推荐的跨 App 浮层组合（所有场景统一）：
        // canJoinAllSpaces + canJoinAllApplications 让面板出现在「用户当前所在的 Space」
        //（普通桌面 / 最大化窗口所在 Space / 原生全屏 Space 都成立）；
        // fullScreenAuxiliary 允许叠在全屏内容之上；screenSaver level 保证最顶层。
        p.isFloatingPanel = true
        p.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications,
                                .fullScreenAuxiliary, .stationary, .ignoresCycle]
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
        // 关键：全程不调用 NSApp.activate。常规 App 被激活时 macOS 会切换 Space
        //（把用户甩到本应用窗口所在的桌面，甚至为它新建一个 Space），
        // 覆盖层就出现在另一个界面上 —— 这正是「最大化窗口按 F2 无反应、
        // 要左滑才能找到截屏层」的根因。
        // 非激活面板由 WindowServer 以「key focus theft」方式直接拿到键盘事件，
        // 目标 App 保持 frontmost，Space 原地不动。
        p.orderFrontRegardless()
        p.makeKey()
        p.orderFrontRegardless()
        ScreenshotLogger.log("overlay show() non-activating: isKey=\(p.isKeyWindow) isActive=\(NSApp.isActive)")
        // 面板刚上屏时可能还没完成 key focus 交接，补一次保险
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak p] in
            guard let p, p.isVisible, !p.isKeyWindow else { return }
            p.makeKey()
            ScreenshotLogger.log("overlay show() retry makeKey, isKey=\(p.isKeyWindow)")
        }
        ScreenshotLogger.log("overlay show() panel created isVisible=\(p.isVisible) frame=\(p.frame)")
        panel = p
    }

    // MARK: - 应用窗口隐藏/恢复

    private func hideAppWindows() {
        ScreenshotLogger.log("hideAppWindows()")
        // 前台应用已在 show() 开头统一记录（previousFrontApp），这里只负责隐藏窗口。
        // orderOut 只影响窗口可见性，不抢前台、不切 Space。
        ScreenshotLogger.log("hideAppWindows() frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")")
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
        // 非激活流程下本应用从未抢前台，焦点天然留在目标应用 —— 什么都不用做。
        // 例外：保存对话框 / 失败弹窗把本应用激活了 → 把焦点还给原来的前台应用，
        // 让 macOS 切回用户截屏前所在的 Space。
        if NSApp.isActive, let prev = previousFrontApp, !prev.isTerminated {
            let ok = prev.activate()
            ScreenshotLogger.log("restoreAppWindows() 归还焦点给 \(prev.localizedName ?? "?") ok=\(ok)")
        } else {
            ScreenshotLogger.log("restoreAppWindows() 本应用未激活，焦点保持在目标应用")
        }
        previousFrontApp = nil
        onFullScreenSpace = false
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
        if saveToFile {
            // 暂存合成结果，弹出系统保存框（sheet 挂在覆盖层上）。
            // 覆盖层在这期间保持显示：用户点「取消」还能继续标注，不必重新截图。
            pendingImage = out
            ScreenshotLogger.log("captureAndSave 弹出保存面板 size=\(out.width)x\(out.height)")
            presentSaveSheet()
            return
        }
        closePanel()
        ScreenshotCaptureService.copyToPasteboard(image: out)
        restoreAppWindows()
    }

    /// 仅关闭覆盖层 panel，不恢复主窗口。
    private func closePanel() {
        // 保存面板还挂着就先摘掉（endSheet 会触发完成回调，那里 savePanel 已置空，不会重复收尾）
        if let sp = savePanel, let p = panel {
            savePanel = nil
            p.endSheet(sp)
        }
        panel?.orderOut(nil)
        panel = nil
        snapshot = nil
    }

    // MARK: - 保存面板（系统 NSSavePanel）

    /// 弹出系统保存面板，**以 sheet 形式挂在覆盖层 panel 上**。
    ///
    /// 这是「既能用原生保存框、又不切 Space」的唯一组合：
    /// - 不用 `runModal()`：那需要应用激活，激活即切 Space，保存框落到默认桌面（老 bug）；
    /// - 作为 sheet 时，面板与父窗口一起出现在当前 Space，且 `firstResponder` 是
    ///   `openAndSavePanelService` 的远程视图 → 文件名输入、回车保存、Esc 取消全部照常。
    private func presentSaveSheet() {
        guard let p = panel, savePanel == nil else {
            ScreenshotLogger.log("presentSaveSheet 跳过：panel=\(panel != nil) 已有保存面板=\(savePanel != nil)")
            return
        }
        let sp = NSSavePanel()
        sp.allowedContentTypes = [.png]
        sp.allowsOtherFileTypes = false
        sp.canCreateDirectories = true
        sp.isExtensionHidden = false
        sp.title = "保存"
        sp.prompt = "保存"
        sp.nameFieldStringValue = ScreenshotCaptureService.suggestedFileName()
        sp.directoryURL = ScreenshotCaptureService.lastSaveDirectory
        savePanel = sp
        // 面板必须是 key，sheet 才会立刻拿到键盘（正常流程里它一直是 key）
        if !p.isKeyWindow { p.makeKey() }
        ScreenshotLogger.log("presentSaveSheet begin dir=\(sp.directoryURL?.path ?? "nil") name=\(sp.nameFieldStringValue) appActive=\(NSApp.isActive) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil") panelIsKey=\(p.isKeyWindow)")
        sp.beginSheetModal(for: p) { [weak self] response in
            guard let self else { return }
            self.savePanel = nil
            ScreenshotLogger.log("presentSaveSheet completed response=\(response.rawValue) url=\(sp.url?.path ?? "nil") front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")")
            guard response == .OK, let url = sp.url else {
                // 取消：留在截图界面继续标注（不丢标注、不用重截）
                self.pendingImage = nil
                p.makeKey()
                ScreenshotLogger.log("presentSaveSheet 取消 → 回到截图, panelIsKey=\(p.isKeyWindow)")
                return
            }
            self.finishSaving(to: url)
        }
    }

    /// 用户在保存面板里确认：写 PNG → 关覆盖层 → 归还焦点。
    /// 全程不激活本应用，Space 原地不动。
    private func finishSaving(to url: URL) {
        guard let img = pendingImage else {
            ScreenshotLogger.log("finishSaving 无待写图片，直接收尾")
            closePanel()
            restoreAppWindows()
            return
        }
        let ok = ScreenshotCaptureService.writePNG(image: img, to: url)
        ScreenshotLogger.log("finishSaving url=\(url.path) ok=\(ok)")
        guard ok else {
            // 写失败（目录不可写等）：再弹一次保存面板，让用户换位置/文件名
            presentWriteFailureAlert(url: url)
            return
        }
        pendingImage = nil
        ScreenshotCaptureService.rememberSaveDirectory(of: url)
        closePanel()
        restoreAppWindows()
    }

    /// 写文件失败的提示。同样必须走 sheet（NSAlert + runModal 会激活应用、切走 Space）。
    private func presentWriteFailureAlert(url: URL) {
        guard let p = panel else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "保存失败"
        alert.informativeText = "无法写入「\(url.lastPathComponent)」，请选择其他位置或文件名。"
        alert.addButton(withTitle: "重新选择")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: p) { [weak self] resp in
            guard let self else { return }
            ScreenshotLogger.log("presentWriteFailureAlert resp=\(resp.rawValue)")
            if resp == .alertFirstButtonReturn {
                self.presentSaveSheet()
            } else {
                self.pendingImage = nil
                p.makeKey()
            }
        }
    }

    func dismiss() {
        ScreenshotLogger.log("overlay dismiss() called, panel exists=\(panel != nil)")
        pendingImage = nil
        closePanel()
        restoreAppWindows()
    }
}
