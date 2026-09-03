//
//  ScreenshotHotkeyManager.swift
//  OneOfPassword
//
//  全局快捷键管理：基于 Carbon HIToolbox 的 RegisterEventHotKey 注册系统级热键。
//
//  为什么用 RegisterEventHotKey 而不是 CGEventTap：
//  CGEventTap 监听系统级按键属于"事件拦截/监听"，macOS 强制要求「辅助功能」权限，
// 且授权后常因 tap 在授权前已创建/被系统禁用而静默失效。
//  RegisterEventHotKey 只是向窗口服务器注册一个热键组合，仅在按键真正按下时触发自己的
//  回调，不能观察其他按键、不涉及隐私，因此【无需辅助功能权限】，沙盒内也可用。
//  （钉钉等应用的全局截屏快捷键即采用此机制。）
//

import AppKit
import Carbon

extension Notification.Name {
    static let screenshotTriggered = Notification.Name("screenshotTriggered")
}

final class ScreenshotHotkeyManager: ObservableObject {
    static let shared = ScreenshotHotkeyManager()

    /// 热键签名（4 字符 'OOPk'），用于区分本应用注册的热键。
    private static let hotKeySignature: OSType = 0x4F4F506B

    private enum Keys {
        static let enabled = "screenshotHotkeyEnabled"
        static let keyCode = "screenshotHotkeyCode"
    }

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Keys.enabled); refresh() }
    }
    @Published var keyCode: Int {
        didSet { UserDefaults.standard.set(keyCode, forKey: Keys.keyCode); refresh() }
    }

    // Carbon 热键引用
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    private init() {
        enabled = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true
        keyCode = UserDefaults.standard.object(forKey: Keys.keyCode) as? Int ?? 122 // F1
    }

    // MARK: - Lifecycle（保持与 AppDelegate 的接线不变）

    func start() {
        ScreenshotLogger.log("start() called")
        refresh()
    }

    func stop() {
        ScreenshotLogger.log("stop() called")
        unregister()
    }

    /// 开关切换 / 按键变更 / 应用重新激活时调用：重注册热键。
    func refresh() {
        ScreenshotLogger.log("refresh() enabled=\(enabled) keyCode=\(keyCode)")
        unregister()
        guard enabled else {
            ScreenshotLogger.log("refresh() skipped: disabled")
            return
        }
        register()
    }

    /// 应用窗口重新激活时调用（保持接口；RegisterEventHotKey 无需重检查授权）。
    func recheckOnActivation() {
        ScreenshotLogger.log("recheckOnActivation() — RegisterEventHotKey 无需辅助功能权限")
        refresh()
    }

    // MARK: - 注册 RegisterEventHotKey

    private func register() {
        ScreenshotLogger.log("register() called keyCode=\(keyCode)")
        let code = UInt32(keyCode)
        let id = EventHotKeyID(signature: ScreenshotHotkeyManager.hotKeySignature, id: 1)

        let status = RegisterEventHotKey(
            code,
            0,                 // 无修饰键（纯 F 键）
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr, hotKeyRef != nil else {
            ScreenshotLogger.log("register() FAILED: RegisterEventHotKey status=\(status)")
            return
        }
        ScreenshotLogger.log("register() OK: hotkey registered for keyCode=\(code)")
        installEventHandler()
    }

    private func installEventHandler() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // 只注册了一个热键、且只监听 kEventHotKeyPressed，因此回调命中即本热键。
        let upp: EventHandlerUPP = { _, _, _ -> OSStatus in
            ScreenshotLogger.log("hotkey pressed — posting .screenshotTriggered")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .screenshotTriggered, object: nil)
            }
            return noErr
        }
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            upp,
            1,
            &eventType,
            nil,
            &eventHandler
        )
        if status != noErr {
            ScreenshotLogger.log("installEventHandler() FAILED status=\(status)")
        }
    }

    private func unregister() {
        ScreenshotLogger.log("unregister() called hotKeyRef=\(hotKeyRef != nil)")
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    // MARK: - F 键 key code 映射

    static let fKeys: [(code: Int, name: String)] = [
        (122, "F1"),  (120, "F2"),  (99,  "F3"),  (118, "F4"),
        (96,  "F5"),  (97,  "F6"),  (98,  "F7"),  (100, "F8"),
        (101, "F9"),  (109, "F10"), (103, "F11"), (111, "F12")
    ]
}
