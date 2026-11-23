//
//  RecordingRegionMark.swift
//  OneOfPassword
//
//  区域录制时的「边界标记框」：一圈近乎透明的边框，告诉你正在录的是哪一块。
//
//  === 为什么用一个独立窗口，而不是在 HUD 里画 ===
//  标记框必须**严格贴合**录制区域（像素级对齐），而 HUD 是可拖动的悬浮条。
//  一个无边框、透明背景、`ignoresMouseEvents = true` 的窗口能精确落在区域上，
//  而且完全不吃鼠标事件 —— 用户照常在区域内点按拖拽，感觉不到它存在。
//
//  === 为什么它不会被录进画面 ===
//  `SCContentFilter` 把本应用整体排除在采集之外（见 ScreenRecorder 头部注释），
//  所以这个窗口和 HUD 一样天然不进画面。反过来说：如果哪天改成「不排除本应用」，
//  这个框就会自己出现在视频里 —— 那时必须改成 `sharingType = .none`。
//
//  === 坐标系 ===
//  对外收 CG 全局坐标（左上原点、点单位），内部换算成 Cocoa 窗口坐标（左下原点）。
//

import AppKit
import SwiftUI

/// 边框本体：两条描边叠在一起，深浅背景上都能看清
struct RecordingRegionMarkView: View {
    var opacity: Double

    var body: some View {
        ZStack {
            // 外侧深色细线：压在亮背景（白底网页）上时不至于「消失」
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.black.opacity(opacity * 0.55), lineWidth: 1)
            // 内侧白色主线：深背景上清晰
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(Color.white.opacity(opacity), lineWidth: 1.5)
                .padding(1)
        }
        .allowsHitTesting(false)
    }
}

final class RecordingRegionMarkController {

    static let shared = RecordingRegionMarkController()

    /// 不可成为 key/main：纯粹一块「画上去的边框」，不该抢焦点
    private final class MarkWindow: NSWindow {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private var window: NSWindow?

    private init() {}

    /// 显示（或更新）标记框。region 为 CG 全局坐标；displayID 用来换算到对应屏幕。
    func show(region: CGRect, displayID: CGDirectDisplayID) {
        guard RecordingPreferences.showsRegionMark,
              region.width >= 8, region.height >= 8 else {
            hide()
            return
        }
        guard let frame = Self.windowFrame(for: region, displayID: displayID) else { return }

        let opacity = RecordingPreferences.regionMarkOpacity

        // 已经显示着：只更新位置与透明度（设置页拖滑块时会高频调用，不要重复建视图）
        if let window {
            window.setFrame(frame, display: true)
            (window.contentView as? NSHostingView<RecordingRegionMarkView>)?.rootView =
                RecordingRegionMarkView(opacity: opacity)
            window.orderFrontRegardless()
            return
        }

        let host = NSHostingView(rootView: RecordingRegionMarkView(opacity: opacity))
        let w = MarkWindow(contentRect: frame,
                           styleMask: [.borderless],
                           backing: .buffered,
                           defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        // 关键：不接收任何鼠标事件，用户的点击/拖拽照常落到下面的应用上
        w.ignoresMouseEvents = true
        // .floating：压住普通窗口；HUD 是 .statusBar，比它更高，所以控制条永远在标记框之上
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications,
                                .fullScreenAuxiliary, .stationary, .ignoresCycle]
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.contentView = host
        w.orderFrontRegardless()
        window = w

        ScreenshotLogger.log("region mark shown frame=\(frame) opacity=\(opacity)")
    }

    /// 设置页改完透明度/开关后即时刷新（录制中才需要）
    func refreshIfVisible(region: CGRect, displayID: CGDirectDisplayID) {
        guard isVisible else { return }
        show(region: region, displayID: displayID)
    }

    func hide() {
        guard let window else { return }
        window.orderOut(nil)
        self.window = nil
        ScreenshotLogger.log("region mark hidden")
    }

    var isVisible: Bool { window?.isVisible ?? false }

    // MARK: - 坐标换算

    /// CG 全局坐标（左上原点）→ Cocoa 窗口 frame（左下原点）。
    /// 用 `CGDisplayBounds` 的 origin 定位到具体屏幕，多屏/副屏在主屏左侧时也不会错。
    static func windowFrame(for region: CGRect, displayID: CGDirectDisplayID) -> CGRect? {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }) ?? NSScreen.main else { return nil }

        let cgBounds = CGDisplayBounds(displayID)
        let localX = region.minX - cgBounds.minX
        let topInset = region.minY - cgBounds.minY
        // Cocoa 的 y 从屏幕底部往上算；屏幕 frame 已经是 Cocoa 坐标
        let cocoaY = screen.frame.maxY - topInset - region.height
        return CGRect(x: screen.frame.minX + localX,
                      y: cocoaY,
                      width: region.width,
                      height: region.height)
    }
}
