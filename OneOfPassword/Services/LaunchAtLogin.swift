//
//  LaunchAtLogin.swift
//  OneOfPassword
//
//  「开机启动」的唯一真相 + 界面展示映射。
//
//  === 为什么不像别的权限那样塞进 `AppPermission` 枚举 ===
//  `AppPermission` 里的两项都是 TCC 权限：查询走 `CGPreflight…` / `AVCaptureDevice…`，
//  操作是「申请授权」，系统侧只有「允许 / 拒绝」一种语义，所以那一行右侧放的是「授权」按钮。
//  开机启动是 ServiceManagement 的托管项，语义是两层：
//    · 应用侧 —— 用户自己的开关（要不要把本应用登记进登录项）；
//    · 系统侧 —— 用户还能在系统设置里单独把它关掉（此时状态是 `requiresApproval`）。
//  界面要的是 `Toggle` 而不是「授权」，所以数据层独立；只在**视觉上**与权限行排在一起。
//
//  === 本机实测（macOS 15.7.7，ad-hoc 签名，2026-09-30）===
//  特意用最小 .app（同 bundle id、ad-hoc 签名、非 /Applications 路径）验证过三件事，
//  结论决定这里不需要写「签名不支持就降级」那套悲观分支：
//   ① ad-hoc（TeamIdentifier not set）下 `register()` 成功，status 0 → 1；
//   ② 重新编译 + 重签名（cdhash 变化，等同每次 devbuild）后 status 仍为 1，登录项不失效；
//   ③ 换路径运行同一 bundle id，status 仍为 1（系统按 bundle id 记账）。
//

import Foundation
import ServiceManagement
import AppKit

// MARK: - 展示状态（可离线校验的纯数据）

/// 界面要展示的一切。由 `SMAppService.Status` 的 rawValue 纯映射而来 ——
/// 做成"输入 Int、输出结构体"是为了能在没有真机注册的情况下离线逐值校验。
struct LaunchAtLoginPresentation: Equatable {
    enum Tone: Equatable {
        case on       // 绿色：已开启
        case off      // 灰色：未开启
        case warning  // 橙色：开着但系统侧有问题 / 状态不可识别
    }

    let label: String       // 状态胶囊文案
    let tone: Tone
    let toggleOn: Bool      // 开关位置
    let hint: String?       // 异常状态时的一行提示（正常态为 nil）
}

extension LaunchAtLoginPresentation {
    /// 纯映射：`SMAppService.Status.rawValue` → 展示。
    /// 0=notRegistered 1=enabled 2=requiresApproval 3=notFound
    static func from(rawStatus: Int) -> LaunchAtLoginPresentation {
        guard let status = SMAppService.Status(rawValue: rawStatus) else {
            return LaunchAtLoginPresentation(
                label: "未知",
                tone: .warning,
                toggleOn: false,
                hint: "系统返回了未识别的登录项状态（\(rawStatus)）。可尝试开关一次，或到「系统设置 → 通用 → 登录项」查看。"
            )
        }
        switch status {
        case .enabled:
            return LaunchAtLoginPresentation(label: "已开启", tone: .on, toggleOn: true, hint: nil)
        case .requiresApproval:
            // 已经被登记，但用户在系统设置里把它关掉了 —— 开关本身仍是开的，
            // 否则用户会以为"应用没登记"，而实际上需要的是去系统设置里允许。
            return LaunchAtLoginPresentation(
                label: "待批准",
                tone: .warning,
                toggleOn: true,
                hint: "已登记在「登录项」中，但系统当前禁止它自启。点右侧「系统设置」，在「登录项」里允许本应用。"
            )
        case .notRegistered:
            return LaunchAtLoginPresentation(label: "未开启", tone: .off, toggleOn: false, hint: nil)
        case .notFound:
            // 系统里还没有这个应用的登录项记录（首次运行常见），对用户而言就是"未开启"
            return LaunchAtLoginPresentation(label: "未开启", tone: .off, toggleOn: false, hint: nil)
        @unknown default:
            return LaunchAtLoginPresentation(
                label: "未知",
                tone: .warning,
                toggleOn: false,
                hint: "系统返回了未识别的登录项状态（\(rawStatus)）。可尝试开关一次，或到「系统设置 → 通用 → 登录项」查看。"
            )
        }
    }
}

// MARK: - 服务

/// 开机启动状态中心。查询/注册/跳转都走这里，界面只读它。
final class LaunchAtLoginService: ObservableObject {
    static let shared = LaunchAtLoginService()

    /// 状态的原始值（`SMAppService.Status.rawValue`）。只在有变化时发布，避免无谓重绘。
    @Published private(set) var rawStatus: Int
    /// 上一次注册/注销失败的原因（成功即清空）
    @Published private(set) var lastError: String?

    private var activationObserver: NSObjectProtocol?

    private init() {
        rawStatus = SMAppService.mainApp.status.rawValue
        // 用户去系统设置里允许/禁止了登录项，切回应用时状态要立刻更新 ——
        // 与 `PermissionCenter` 用的是同一个时机（激活通知），行为保持一致。
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    var presentation: LaunchAtLoginPresentation {
        LaunchAtLoginPresentation.from(rawStatus: rawStatus)
    }

    // MARK: 操作

    /// 打开 / 关闭开机启动。失败不抛给界面，而是记在 `lastError` 里由界面显示 ——
    /// 开关要回弹到真实状态，不能让用户以为设置成功了。
    func setEnabled(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on {
                try service.register()
            } else {
                try service.unregister()
            }
            lastError = nil
        } catch {
            lastError = Self.describe(error)
        }
        refresh()
    }

    /// 重新读取真实状态（只在不同时才发布）
    func refresh() {
        let next = SMAppService.mainApp.status.rawValue
        if next != rawStatus { rawStatus = next }
    }

    /// 打开「系统设置 → 通用 → 登录项」，用户可在那里允许 / 移除本应用
    func openLoginItemsSettings() {
        let raw = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        NSWorkspace.shared.open(URL(string: raw) ?? URL(fileURLWithPath: "/"))
    }

    // MARK: 错误文案

    /// 把 `NSError` 翻译成人话，并**保留 domain / code** ——
    /// 注册失败最容易被当成"开关坏了"，把系统给的原因原样印出来，用户反馈时能直接对上号。
    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        let reason: String
        if ns.domain == "SMAppServiceErrorDomain" {
            reason = "系统拒绝了这次登录项注册（常见原因是应用签名或系统策略不允许）。"
        } else {
            reason = ns.localizedDescription
        }
        return "\(reason)（\(ns.domain) \(ns.code)）反复失败时，可到「系统设置 → 通用 → 登录项」点 ＋ 手动添加本应用。"
    }
}
