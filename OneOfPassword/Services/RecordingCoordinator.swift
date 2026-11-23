//
//  RecordingCoordinator.swift
//  OneOfPassword
//
//  录屏流程编排：快捷键/按钮 → 权限 → 选区 → 开始录制 → 悬浮控制条 → 保存/丢弃。
//
//  === 为什么用「自动保存到文件夹」而不是 NSSavePanel ===
//  录完再弹一次保存框是最烦人的一步（而且会让本应用抢前台、切走 Space，
//  截屏那边为此专门写了 sheet 方案）。这里直接写到设置里的目录（默认「影片」），
//  文件名带时间戳，录完给一张结果卡片：「在访达中显示」。
//  想换位置：设置里改目录，或在访达里把文件拖走。
//

import AppKit
import AVFoundation
import SwiftUI

extension Notification.Name {
    /// 全局录屏快捷键（默认 F3）触发
    static let recordingTriggered = Notification.Name("recordingTriggered")
}

final class RecordingCoordinator {

    static let shared = RecordingCoordinator()

    private let recorder = ScreenRecorder.shared
    private let hud = RecordingHUDController.shared

    /// 录制前被隐藏的本应用窗口（避免在画面里留一个「洞」）
    private var hiddenWindows: [NSWindow] = []
    private var recordingStartedAt: Date?
    /// 本次录制的区域与屏幕：停止时要按它关掉「录制区域标记框」
    private var recordingRegion: CGRect?
    private var recordingDisplayID: CGDirectDisplayID?

    private init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(hotkeyFired),
            name: .recordingTriggered, object: nil
        )
    }

    // MARK: - 入口

    @objc private func hotkeyFired() {
        ScreenshotLogger.log("recording hotkey fired, isRecording=\(recorder.isRecording)")
        if recorder.isRecording {
            stopAndSave()
        } else {
            presentArea()
        }
    }

    /// 进入选区（设置页「立即录制」也走这里）
    func presentArea() {
        guard !recorder.isRecording else {
            ScreenshotLogger.log("presentArea skipped: already recording")
            return
        }
        guard ensureScreenPermission() else { return }
        guard ensureMicrophonePermission() else { return }

        RecordingAreaController.shared.present { [weak self] region, displayID in
            self?.begin(region: region, displayID: displayID)
        }
    }

    // MARK: - 开始

    private func begin(region: CGRect?, displayID: CGDirectDisplayID) {
        hideAppWindows()
        recordingRegion = region
        recordingDisplayID = displayID

        let options = RecordingOptions(
            displayID: displayID,
            region: region,
            audio: RecordingPreferences.audioSource,
            frameRate: RecordingPreferences.frameRate,
            showsCursor: RecordingPreferences.showsCursor,
            outputURL: RecordingPreferences.makeOutputURL()
        )

        Task {
            do {
                try await recorder.start(options: options)
                await MainActor.run {
                    self.recordingStartedAt = recorder.startedAt ?? Date()
                    self.showRecordingHUD(displayID: displayID)
                    self.showRegionMarkIfNeeded()
                }
            } catch {
                await MainActor.run {
                    self.restoreAppWindows()
                    self.showFailure(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - 停止 / 丢弃

    func stopAndSave() {
        guard recorder.isRecording else { return }
        Task {
            let result = await recorder.stop()
            switch result {
            case .success(let url):
                // 时长从落盘的文件里读：比 `Date()` 差值准（不含收尾耗时）
                let duration = await ScreenRecorder.duration(of: url)
                ScreenshotLogger.log("recording saved: \(url.lastPathComponent) duration=\(duration)")
                await MainActor.run {
                    self.restoreAppWindows()
                    self.showResult(url: url, duration: duration)
                }
            case .failure(let error):
                await MainActor.run {
                    self.restoreAppWindows()
                    self.showFailure(error.localizedDescription)
                }
            }
        }
    }

    /// 暂停 / 恢复。HUD 的按钮与设置页的「暂停」都走这里。
    func togglePause() {
        guard recorder.isRecording else { return }
        if recorder.isPaused {
            recorder.resume()
        } else {
            recorder.pause()
        }
        // 控制条要换成另一个图标（暂停 ⇄ 继续），重新渲染一次即可
        if hud.isVisible {
            hud.present(AnyView(recordingHUDView()), on: nil)
        }
    }

    private func discard() {
        guard recorder.isRecording else { return }
        Task {
            await recorder.cancel()
            await MainActor.run {
                self.restoreAppWindows()
                self.hud.dismiss()
            }
        }
    }

    /// 退出应用时的收尾：把正在录的内容保存好再退，别让用户丢掉整段录制。
    func finishForTermination() async {
        guard recorder.isRecording else {
            restoreAppWindows()
            return
        }
        _ = await recorder.stop()
        await MainActor.run { self.restoreAppWindows() }
    }

    // MARK: - HUD

    private func showRecordingHUD(displayID: CGDirectDisplayID) {
        hud.present(AnyView(recordingHUDView()), on: Self.screen(for: displayID))
    }

    /// 录制中的控制条。计时基准 = 开始时刻 + 已暂停时长，恢复后计时不跳。
    private func recordingHUDView() -> RecordingHUDView {
        let start = recorder.startedAt ?? recordingStartedAt ?? Date()
        let base = start.addingTimeInterval(recorder.pausedTotal)
        let frozen: Double? = recorder.isPaused
            ? max(0, Date().timeIntervalSince(start) - recorder.pausedTotal)
            : nil
        return RecordingHUDView(
            phase: .recording,
            elapsedBase: base,
            frozenElapsed: frozen,
            isPaused: recorder.isPaused,
            pixelSize: recorder.pixelSize,
            onStop: { [weak self] in self?.stopAndSave() },
            onDiscard: { [weak self] in self?.discard() },
            onTogglePause: { [weak self] in self?.togglePause() },
            onReveal: { _ in },
            onClose: {}
        )
    }

    private func showResult(url: URL, duration: Double) {
        let view = RecordingHUDView(
            phase: .finished(url: url, duration: duration),
            elapsedBase: recordingStartedAt ?? Date(),
            frozenElapsed: nil,
            pixelSize: recorder.pixelSize,
            onStop: {},
            onDiscard: {},
            onTogglePause: {},
            onReveal: { [weak self] url in
                // 先关掉浮层再激活 Finder：这张 HUD 是 `.nonactivatingPanel`，
                // 但只要它还挂在屏幕上，本应用就握着激活权，Finder 的新窗口会开在
                // 本应用后面（「我之前那个 Finder 窗口还开着，就怎么点都不出来」）。
                self?.hud.dismiss()
                Self.revealInFinder(url)
            },
            onClose: { [weak self] in self?.hud.dismiss() }
        )
        hud.present(AnyView(view), on: nil)
    }

    private func showFailure(_ message: String) {
        let view = RecordingHUDView(
            phase: .failed(message),
            elapsedBase: recordingStartedAt ?? Date(),
            frozenElapsed: nil,
            pixelSize: .zero,
            onStop: {},
            onDiscard: {},
            onTogglePause: {},
            onReveal: { _ in },
            onClose: { [weak self] in self?.hud.dismiss() }
        )
        hud.present(AnyView(view), on: nil)
    }

    // MARK: - 权限

    /// 返回 false 表示本次不能继续（已经给过提示 / 已经发出系统授权框）
    private func ensureScreenPermission() -> Bool {
        guard !AppPermission.screenRecording.status.isAuthorized else { return true }

        AppPermission.screenRecording.request()
        // 授权是异步写进 TCC 的，弹框关掉的瞬间还读不到结果，稍后再确认一次。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            PermissionCenter.shared.refresh()
            guard let self else { return }
            if AppPermission.screenRecording.status.isAuthorized {
                // 少数系统不要求重启，授权后立刻可用
                self.presentArea()
            } else {
                self.showScreenPermissionAlert()
            }
        }
        return false
    }

    private func showScreenPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "需要「屏幕录制」权限"
        alert.informativeText = """
        录屏依赖系统「屏幕录制」权限。请在「系统设置 → 隐私与安全性 → 屏幕录制」中勾选 OneOfPassword，\
        然后**退出并重新打开本应用**（系统对录屏权限的变更只在应用重启后生效）。
        """
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "好")
        if alert.runModal() == .alertFirstButtonReturn {
            AppPermission.screenRecording.openSystemSettings()
        }
    }

    private func ensureMicrophonePermission() -> Bool {
        guard RecordingPreferences.audioSource == .microphone else { return true }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    PermissionCenter.shared.refresh()
                    if granted {
                        self.presentArea()
                    } else {
                        self.offerSilentRecording()
                    }
                }
            }
            return false
        default:
            offerSilentRecording()
            return false
        }
    }

    /// 麦克风被拒：给两条明确出路，不要「静默录出无声视频」
    private func offerSilentRecording() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "麦克风没有权限"
        alert.informativeText = "当前音频来源是「麦克风」，但没有获得系统授权。可以改为只录画面，或去系统设置开启权限。"
        alert.addButton(withTitle: "只录画面")
        alert.addButton(withTitle: "去系统设置")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            RecordingPreferences.audioSource = .none
            presentArea()
        case .alertSecondButtonReturn:
            AppPermission.microphone.openSystemSettings()
        default:
            break
        }
    }

    // MARK: - 窗口隐藏/恢复

    /// 录制时把本应用窗口藏起来。
    /// 因为 `SCContentFilter` 把本应用整体排除在采集之外，窗口所在位置会露出桌面背景；
    /// 与其在画面里留一个「洞」，不如录的时候干脆不显示（与截屏的「隐藏本应用窗口」同一思路）。
    private func hideAppWindows() {
        hiddenWindows = NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) }
        for window in hiddenWindows {
            window.orderOut(nil)
        }
        ScreenshotLogger.log("recording: hidden app windows=\(hiddenWindows.count)")
    }

    private func restoreAppWindows() {
        for window in hiddenWindows {
            window.setIsVisible(true)
        }
        hiddenWindows = []
        // 区域标记框与窗口一起收：录制已经结束，留着会让人以为还在录
        RecordingRegionMarkController.shared.hide()
        recordingRegion = nil
        recordingDisplayID = nil
    }

    /// 区域录制时在屏幕上画出边界（整屏录制没有意义，不画）
    private func showRegionMarkIfNeeded() {
        guard let region = recordingRegion, let displayID = recordingDisplayID else { return }
        RecordingRegionMarkController.shared.show(region: region, displayID: displayID)
    }

    /// 设置页改了「显示标记框 / 透明度」时调用：录制中即时生效（`show` 内部按开关决定显示或隐藏）
    func refreshRegionMark() {
        guard recorder.isRecording else { return }
        showRegionMarkIfNeeded()
    }

    // MARK: - 工具

    /// 在访达里选中文件，并把前台让给 Finder。
    ///
    /// 只用 `activateFileViewerSelecting` 是不够的：Finder 已经在运行、并且还开着窗口时，
    /// 它会把新窗口开出来，但**激活权仍留在本应用**（HUD 面板是 nonactivating，
    /// 可出现结果卡片这段时间用户很可能就是从本应用点的），于是「新窗口开在别人后面」。
    /// 这里显式把激活权让出去，再让 Finder 把所有窗口提上来。
    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])

        guard let finder = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.finder").first else { return }

        // macOS 14 起有协作式激活：先声明「我让给你」，对方再激活才不会互相盖回去
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: finder)
        }
        // activateAllWindows：用户之前开着的 Finder 窗口也一并提到前面，
        // 而不是只把新窗口浮上来、旧窗口还压在本应用下面
        finder.activate(options: [.activateAllWindows])

        // Finder 处理激活是异步的，实测偶发「刚 activate 完本应用又抢回前台」，
        // 稍后再补一次；此时用户已经看到 Finder 起来了，补这一次不会造成可见跳动。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.finder" {
                finder.activate(options: [.activateAllWindows])
            }
        }
        ScreenshotLogger.log("reveal in finder: \(url.lastPathComponent)")
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        } ?? NSScreen.main
    }
}
