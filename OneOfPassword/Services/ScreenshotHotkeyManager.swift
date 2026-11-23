//
//  ScreenshotHotkeyManager.swift
//  OneOfPassword
//
//  全局快捷键管理：基于 Carbon HIToolbox 的 RegisterEventHotKey 注册系统级热键。
//
//  现在同时管理**两个**热键：截屏（默认 F1）与录屏（默认 F3）。
//  两个都注册在同一个 application event target 上，靠 `EventHotKeyID.id` 区分：
//      id = 1 → 截屏（.screenshotTriggered）
//      id = 2 → 录屏（.recordingTriggered）
//  回调里必须读 `kEventParamDirectObject` 拿到是哪一个被按下 ——
//  早先只注册了一个热键，所以直接「收到回调就发截屏通知」；两个热键之后那样写会互相串味。
//
//  为什么用 RegisterEventHotKey 而不是 CGEventTap：
//  CGEventTap 监听系统级按键属于"事件拦截/监听"，macOS 强制要求「辅助功能」权限，
//  且授权后常因 tap 在授权前已创建/被系统禁用而静默失效。
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
        static let enabled            = "screenshotHotkeyEnabled"
        static let keyCode            = "screenshotHotkeyCode"
        static let recordingEnabled   = "recordingHotkeyEnabled"
        static let recordingKeyCode   = "recordingHotkeyCode"
    }

    /// 热键 id：与 `EventHotKeyID.id` 对应
    private enum HotKeyID: UInt32 {
        case screenshot = 1
        case recording = 2
    }

    // MARK: 截屏热键

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Keys.enabled); refresh() }
    }
    @Published var keyCode: Int {
        didSet { UserDefaults.standard.set(keyCode, forKey: Keys.keyCode); refresh() }
    }

    // MARK: 录屏热键

    @Published var recordingEnabled: Bool {
        didSet { UserDefaults.standard.set(recordingEnabled, forKey: Keys.recordingEnabled); refresh() }
    }
    @Published var recordingKeyCode: Int {
        didSet { UserDefaults.standard.set(recordingKeyCode, forKey: Keys.recordingKeyCode); refresh() }
    }

    // Carbon 热键引用
    private var screenshotHotKeyRef: EventHotKeyRef?
    private var recordingHotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    private init() {
        enabled = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true
        keyCode = UserDefaults.standard.object(forKey: Keys.keyCode) as? Int ?? 122        // F1
        recordingEnabled = UserDefaults.standard.object(forKey: Keys.recordingEnabled) as? Bool ?? true
        // 录屏默认 F3（99）：截屏的默认/常用键是 F1/F2，录屏用 F3 才不会撞车。
        recordingKeyCode = UserDefaults.standard.object(forKey: Keys.recordingKeyCode) as? Int ?? 99 // F3
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
        ScreenshotLogger.log("refresh() screenshot=\(enabled)/\(keyCode) recording=\(recordingEnabled)/\(recordingKeyCode)")
        unregister()
        installEventHandlerIfNeeded()
        // 两个热键选了同一个 F 键时，后注册的会被系统忽略、行为不可预期 ——
        // 这里明确让截屏优先，录屏不注册（设置页会给出橙色提示让用户改）。
        let conflict = enabled && recordingEnabled && keyCode == recordingKeyCode
        if conflict {
            ScreenshotLogger.log("refresh() 热键冲突：截屏与录屏都是 \(keyCode)，只注册截屏")
        }
        if enabled { register(.screenshot, keyCode: keyCode) }
        if recordingEnabled && !conflict { register(.recording, keyCode: recordingKeyCode) }
    }

    /// 应用窗口重新激活时调用（保持接口；RegisterEventHotKey 无需重检查授权）。
    func recheckOnActivation() {
        ScreenshotLogger.log("recheckOnActivation() — RegisterEventHotKey 无需辅助功能权限")
        refresh()
    }

    // MARK: - 注册 RegisterEventHotKey

    private func register(_ name: HotKeyID, keyCode: Int) {
        let code = UInt32(keyCode)
        let id = EventHotKeyID(signature: ScreenshotHotkeyManager.hotKeySignature, id: name.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            code,
            0,                 // 无修饰键（纯 F 键）
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            ScreenshotLogger.log("register(\(name), \(code)) FAILED: status=\(status)")
            return
        }
        switch name {
        case .screenshot: screenshotHotKeyRef = ref
        case .recording:  recordingHotKeyRef = ref
        }
        ScreenshotLogger.log("register(\(name), \(code)) OK")
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // 事件里带 `kEventParamDirectObject`（EventHotKeyID），用它区分是哪个热键。
        let upp: EventHandlerUPP = { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            let isRecording = (err == noErr && hotKeyID.id == HotKeyID.recording.rawValue)
            ScreenshotLogger.log("hotkey pressed id=\(hotKeyID.id) err=\(err) → \(isRecording ? "recording" : "screenshot")")
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: isRecording ? .recordingTriggered : .screenshotTriggered,
                    object: nil
                )
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
        if let ref = screenshotHotKeyRef {
            UnregisterEventHotKey(ref)
            screenshotHotKeyRef = nil
        }
        if let ref = recordingHotKeyRef {
            UnregisterEventHotKey(ref)
            recordingHotKeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }

    // MARK: - F 键 key code 映射

    static let fKeys: [(code: Int, name: String)] = [
        (122, "F1"), (120, "F2"), (99,  "F3"), (118, "F4"),
        (96,  "F5"), (97,  "F6"), (98,  "F7"), (100, "F8"),
        (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12")
    ]
}
