//
//  AppDelegate.swift
//  OneOfPassword
//

import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ScreenshotHotkeyManager.shared.start()
        // 触发 OverlayController 单例初始化，确保 .screenshotTriggered 监听者注册
        _ = ScreenshotOverlayController.shared
        // 应用重新激活时重新检查辅助功能权限（授权后系统不会主动通知进程）
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBecameActive),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
    }

    @objc private func appBecameActive() {
        ScreenshotHotkeyManager.shared.recheckOnActivation()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ScreenshotHotkeyManager.shared.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard EditingState.shared.isEditing else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "有未保存的编辑"
        alert.informativeText = "当前有未保存的修改，退出后将丢失这些内容。"
        alert.addButton(withTitle: "放弃编辑并退出")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning

        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
