//
//  RecordingAreaController.swift
//  OneOfPassword
//
//  录屏选区覆盖层的窗口管理：建面板 → 收结果 → 关面板。
//  面板配置与截屏覆盖层完全一致，理由也一样（非激活面板 + canJoinAllSpaces），
//  详见 `ScreenshotOverlayController.captureAndShowPanel` 上的长注释。
//

import AppKit
import SwiftUI

/// 选区面板：无边框 + 非激活。
/// `canBecomeKey` 必须为 true —— 否则 Esc / ⏎ 收不到（键盘进不来，快捷键就等于没有）。
private final class RecordingAreaPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class RecordingAreaController {

    static let shared = RecordingAreaController()

    private var panel: NSPanel?
    private var onStart: ((CGRect?, CGDirectDisplayID) -> Void)?
    private var displayID: CGDirectDisplayID?

    private init() {}

    /// 显示选区。`onStart` 的 region 为 CG 全局坐标；nil 表示整屏。
    func present(onStart: @escaping (CGRect?, CGDirectDisplayID) -> Void) {
        guard panel == nil else { return }
        guard let screen = Self.targetScreen(),
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return }

        self.onStart = onStart
        self.displayID = id

        let cgOrigin = CGDisplayBounds(id).origin
        let p = RecordingAreaPanel(
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
        p.isFloatingPanel = true
        // 与截屏一致：出现在用户当前所在的 Space（含原生全屏 Space），并且永远在最上层
        p.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications,
                                .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false

        let host = NSHostingController(rootView: RecordingAreaView(
            screenSize: screen.frame.size,
            screenOrigin: cgOrigin,
            scale: screen.backingScaleFactor,
            preferred: RecordingPreferences.lastRegion,
            hasLastRegion: RecordingPreferences.lastRegion != nil,
            initialUseLast: RecordingPreferences.usesLastRegion,
            onUseLastChanged: { RecordingPreferences.usesLastRegion = $0 },
            onStart: { [weak self] region in
                guard let self else { return }
                self.finish(region: region, start: true)
            },
            onCancel: { [weak self] in
                self?.finish(region: nil, start: false)
            }
        ))
        p.contentViewController = host
        p.setFrame(screen.frame, display: true)
        host.view.frame = p.contentView?.bounds ?? screen.frame
        host.view.autoresizingMask = [.width, .height]

        // 全程不调 NSApp.activate：激活会切 Space，覆盖层就跑到另一个桌面上去了
        p.orderFrontRegardless()
        p.makeKey()
        p.orderFrontRegardless()
        panel = p

        ScreenshotLogger.log("recording area presented on display=\(id) frame=\(screen.frame) scale=\(screen.backingScaleFactor) preferred=\(String(describing: RecordingPreferences.lastRegion))")
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        onStart = nil
        displayID = nil
    }

    private func finish(region: CGRect?, start: Bool) {
        let callback = onStart
        let id = displayID
        // 先记住选区（下次进来直接摆好），再关面板，最后回调 —— 回调里要建录制流，
        // 覆盖层必须先消失，否则第一帧会录到蒙版
        // 只记「框选」的区域：选「录制整屏」不该把用户记过的框选位置抹掉，
        // 否则下次按快捷键就没有预选框了。
        if start, let region, RecordingPreferences.remembersLastRegion {
            RecordingPreferences.lastRegion = region
        }
        dismiss()
        guard start, let callback, let id else { return }
        callback(region, id)
    }

    /// 用「鼠标所在屏幕」：录屏通常是为了录用户正在看的那块屏，
    /// 主屏可能是副显示器。找不到就退回主屏。
    private static func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation   // NSScreen 坐标（左下原点）
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return hit
        }
        return NSScreen.main ?? NSScreen.screens.first
    }
}
