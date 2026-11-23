//
//  RecordingHUDController.swift
//  OneOfPassword
//
//  控制条面板：悬浮在录制画面之上（但被排除在录制内容之外），
//  非激活面板 + 可拖动 + 跟随用户在任意 Space（含其他应用的原生全屏 Space）。
//

import AppKit
import SwiftUI

final class RecordingHUDController {

    static let shared = RecordingHUDController()

    private var panel: NSPanel?
    private var host: NSHostingController<AnyView>?
    /// 首次定位用的屏幕（录制目标屏）
    private var anchorScreen: NSScreen?
    private var hasPositioned = false

    private init() {}

    /// 显示/更新 HUD 内容。`screen` 只在首次定位时使用。
    func present(_ view: AnyView, on screen: NSScreen?) {
        if panel == nil {
            anchorScreen = screen ?? NSScreen.main
            hasPositioned = false
            createPanel()
        }
        host?.rootView = view
        layout()
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        host = nil
        anchorScreen = nil
        hasPositioned = false
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: - 面板

    private func createPanel() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        // .statusBar 级别：比普通窗口高，能压在别的应用全屏内容之上；
        // 又低于 .screenSaver，不会盖住系统弹窗
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications,
                                .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        // 背景可拖：用户觉得挡视线时可以把它拽到一边（拖动不会激活本应用）
        p.isMovableByWindowBackground = true
        p.becomesKeyOnlyIfNeeded = false

        let hosting = NSHostingController(rootView: AnyView(EmptyView()))
        p.contentViewController = hosting
        host = hosting
        panel = p
    }

    /// 按内容实际尺寸重排，保持「顶边位置不变、水平居中不变」，
    /// 这样从「录制中」变成「已保存」（高度可能变化）时不会跳一下。
    private func layout() {
        guard let panel, let host else { return }
        host.view.layoutSubtreeIfNeeded()
        var size = host.view.fittingSize
        if size.width < 80 || size.height < 24 {
            size = CGSize(width: 320, height: 44)
        }

        var frame = panel.frame
        if !hasPositioned {
            let screen = anchorScreen ?? NSScreen.main
            let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
            frame = CGRect(x: visible.midX - size.width / 2,
                           y: visible.maxY - size.height - 8,
                           width: size.width, height: size.height)
            hasPositioned = true
        } else {
            let midX = frame.midX
            let top = frame.maxY
            frame = CGRect(x: midX - size.width / 2,
                           y: top - size.height,
                           width: size.width, height: size.height)
        }
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            // 不激活本应用，直接浮现
            panel.orderFrontRegardless()
        }
    }
}
