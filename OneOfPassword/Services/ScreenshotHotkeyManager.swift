//
//  ScreenshotHotkeyManager.swift
//  OneOfPassword
//
//  全局快捷键（CGEventTap）管理：监听 F1-F12，触发截屏。
//

import AppKit
import ApplicationServices
import CoreGraphics

extension Notification.Name {
    static let screenshotTriggered = Notification.Name("screenshotTriggered")
}

final class ScreenshotHotkeyManager: ObservableObject {
    static let shared = ScreenshotHotkeyManager()

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
    @Published var hasAccessibility: Bool = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private init() {
        enabled = UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true
        keyCode = UserDefaults.standard.object(forKey: Keys.keyCode) as? Int ?? 122 // F1
    }

    // MARK: - Lifecycle

    func start() {
        ScreenshotLogger.log("start() called")
        ScreenshotLogger.log("start() screen capture preflight = \(CGPreflightScreenCaptureAccess())")
        refreshAccessibility()
        refresh()
    }

    func stop() {
        ScreenshotLogger.log("stop() called")
        unregister()
    }

    private func refresh() {
        ScreenshotLogger.log("refresh() enabled=\(enabled) hasAccessibility=\(hasAccessibility)")
        unregister()
        guard enabled, hasAccessibility else {
            ScreenshotLogger.log("refresh() skipped (enabled or accessibility false)")
            return
        }
        register()
    }

    // MARK: - Accessibility

    func refreshAccessibility() {
        hasAccessibility = AXIsProcessTrusted()
        ScreenshotLogger.log("refreshAccessibility() hasAccessibility=\(hasAccessibility)")
    }

    /// 检查授权状态；若刚授权则重新注册 event tap。
    /// 授权后系统不会主动通知进程，需在窗口重新激活 / 手动触发时重新检查。
    func requestAccessibility(prompt: Bool) {
        ScreenshotLogger.log("requestAccessibility(prompt:\(prompt)) before hasAccessibility=\(hasAccessibility)")
        if prompt {
            let opts: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true]
            hasAccessibility = AXIsProcessTrustedWithOptions(opts)
        } else {
            hasAccessibility = AXIsProcessTrusted()
        }
        ScreenshotLogger.log("requestAccessibility() after hasAccessibility=\(hasAccessibility)")
        refresh()
    }

    /// 应用窗口重新激活时调用，重新检查授权并重建 tap。
    func recheckOnActivation() {
        let now = AXIsProcessTrusted()
        ScreenshotLogger.log("recheckOnActivation() now=\(now) cached=\(hasAccessibility)")
        if now != hasAccessibility {
            hasAccessibility = now
            refresh()
        }
    }

    /// 打开系统设置 > 隐私与安全 > 辅助功能。
    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        NSWorkspace.shared.open(url ?? URL(fileURLWithPath: "/"))
    }

    // MARK: - CGEventTap 注册

    private func register() {
        ScreenshotLogger.log("register() called")
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        // CGEventTap 回调是 C 函数指针，无法捕获 self；用单例桥接。
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                return ScreenshotHotkeyManager.shared.handle(eventType: type, event: event)
            },
            userInfo: nil
        )
        guard let tap else {
            ScreenshotLogger.log("register() FAILED: CGEvent.tapCreate returned nil (check Accessibility / TCC)")
            return
        }
        eventTap = tap

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        if let src { CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode) }
        CGEvent.tapEnable(tap: tap, enable: true)
        ScreenshotLogger.log("register() OK: event tap created and enabled")
    }

    private func unregister() {
        ScreenshotLogger.log("unregister() called tap=\(eventTap != nil)")
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func handle(eventType: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 事件 tap 被系统禁用（如锁屏）时重新启用
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            ScreenshotLogger.log("handle() tap disabled by \(eventType) — re-enabling")
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passRetained(event)
        }
        guard eventType == .keyDown else { return Unmanaged.passRetained(event) }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        // 仅响应无修饰键（纯 F 键）；cmd/ctrl/option/shift 不拦截，避免影响系统
        let noMods = flags.isEmpty
        // 回调在非主线程，读 keyCode 快照避免竞态
        let targetCode = keyCode
        if Int(code) == targetCode && noMods {
            ScreenshotLogger.log("handle() matched keyCode=\(code) — posting .screenshotTriggered")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .screenshotTriggered, object: nil)
            }
            return nil // 吞掉按键，避免系统 F1 帮助
        }
        return Unmanaged.passRetained(event)
    }
}

// MARK: - F 键 key code 映射

extension ScreenshotHotkeyManager {
    /// F1 ~ F12 的按键码与显示名。
    static let fKeys: [(code: Int, name: String)] = [
        (122, "F1"),  (120, "F2"),  (99,  "F3"),  (118, "F4"),
        (96,  "F5"),  (97,  "F6"),  (98,  "F7"),  (100, "F8"),
        (101, "F9"),  (109, "F10"), (103, "F11"), (111, "F12")
    ]
}
