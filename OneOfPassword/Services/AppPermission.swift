//
//  AppPermission.swift
//  OneOfPassword
//
//  应用级系统权限：统一的状态真相 + 申请/跳转入口。
//
//  为什么要单独抽一层：
//  「屏幕录制」不是「截屏功能」的私有设置，它是**应用级**能力（每个 App 在 TCC 里只有一条记录）。
//  目前它有两个消费者 —— ① 截屏 / 标注；② 扫描 GA 验证码时的「截取屏幕」。
//  过去两处各自调 `CGPreflightScreenCaptureAccess()`、各自写一份引导文案：
//    · 状态口径容易漂移（一处改了另一处忘）；
//    · GA 那条路径直接跳 macOS 系统设置，用户永远看不到应用内的状态与诊断日志；
//    · 摄像头权限则完全没人管（未授权时二维码预览只是一片黑，没有任何提示）。
//  现在查询走这里，展示走 `PermissionViews.swift`，授权动作只在「设置 → 系统权限」发生。
//

import AppKit
import AVFoundation
import CoreGraphics
import Foundation

// MARK: - 权限清单

/// 应用需要向系统申请的权限。新增一种权限时，只需在这里加一个 case ——
/// 设置页的「系统权限」区块会自动多出一行（UI 完全由 `AppPermission.allCases` 驱动）。
enum AppPermission: String, CaseIterable, Identifiable {
    /// 屏幕录制：截屏标注 + 验证码「截取屏幕」
    case screenRecording
    /// 摄像头：验证码「摄像头扫描」
    case camera

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: return "屏幕录制"
        case .camera:          return "摄像头"
        }
    }

    var systemImage: String {
        switch self {
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .camera:          return "camera.fill"
        }
    }

    /// 谁在用它 —— 直接印在界面上，用户一眼知道「不给会怎样」
    var usedBy: String {
        switch self {
        case .screenRecording: return "截屏标注 · 验证码截取屏幕"
        case .camera:          return "验证码摄像头扫描"
        }
    }

    /// 为什么要它 —— 隐私说明写得越具体，用户越敢授权
    var purpose: String {
        switch self {
        case .screenRecording:
            return "截取屏幕内容用于标注，或识别屏幕上的验证码二维码。画面只在本机处理，不上传、不留存。"
        case .camera:
            return "扫描 Google Authenticator 等验证器出示的二维码。画面只在本机实时解析，不录制、不外传。"
        }
    }

    /// 授权后是否需要重启应用才生效。屏幕录制是典型（TCC 对本进程不即时生效）。
    var requiresRelaunch: Bool { self == .screenRecording }

    /// 系统设置里对应的锚点（隐私与安全性 → 具体分类）
    private var settingsAnchor: String {
        switch self {
        case .screenRecording: return "Privacy_ScreenCapture"
        case .camera:          return "Privacy_Camera"
        }
    }

    // MARK: 查询

    /// 当前授权状态。
    /// 注意：屏幕录制只能区分「已授权 / 未授权」（`CGPreflightScreenCaptureAccess` 不暴露
    /// 「从未请求过」这个中间态），所以它永远不会返回 `.notDetermined`。
    var status: AppPermissionStatus {
        switch self {
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .authorized : .denied
        case .camera:
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:          return .authorized
            case .notDetermined:       return .notDetermined
            case .denied, .restricted: return .denied
            @unknown default:          return .denied
            }
        }
    }

    // MARK: 申请 / 跳转

    /// 触发系统授权弹框。
    /// **不要采信返回值** —— 授权是异步生效的，弹框关掉的瞬间 `CGPreflight…` 往往还是 false。
    /// 统一交给 `PermissionCenter.refresh()` 稍后再读。`.denied` 时系统不会再弹框，只能送用户去系统设置。
    func request() {
        switch self {
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .camera:
            if status == .notDetermined {
                AVCaptureDevice.requestAccess(for: .video) { _ in }
            } else {
                openSystemSettings()
            }
        }
    }

    /// 打开「系统设置 → 隐私与安全性 → 对应分类」
    func openSystemSettings() {
        let raw = "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)"
        NSWorkspace.shared.open(URL(string: raw) ?? URL(fileURLWithPath: "/"))
    }

    /// 申请**摄像头**权限，并在主线程回调「最终是否可用」。
    ///
    /// 摄像头和屏幕录制不一样：系统弹框由 completion 明确告知结果，所以可以同步拿到答案。
    /// 屏幕录制没有这个能力（授权结果异步写入 TCC），只能靠 `PermissionCenter` 轮询。
    /// `.denied`（用户已拒过）时不会再弹框，回调直接返回 false，由调用方引导去系统设置。
    static func requestCamera(_ completion: @escaping (Bool) -> Void) {
        let current = AVCaptureDevice.authorizationStatus(for: .video)
        guard current == .notDetermined else {
            completion(current == .authorized)
            return
        }
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}

// MARK: - 授权状态

enum AppPermissionStatus: String {
    case authorized
    case denied
    case notDetermined

    var isAuthorized: Bool { self == .authorized }

    var label: String {
        switch self {
        case .authorized:    return "已授权"
        case .denied:        return "未授权"
        case .notDetermined: return "未请求"
        }
    }
}

// MARK: - 状态中心

/// 权限状态的唯一真相 + 刷新时机管理。
///
/// 刷新时机：
/// ① 权限界面出现时（`beginObserving`）；
/// ② 应用重新激活时 —— 覆盖「去系统设置授权完再切回来」这个主流程；
/// ③ 界面可见期间每 2 秒轮询 —— 屏幕录制授权是异步写入 TCC 的，激活通知可能早于落库。
///
/// 轮询用引用计数控制生命周期：没有界面在看的时候不空转。
final class PermissionCenter: ObservableObject {
    static let shared = PermissionCenter()

    /// 状态快照。`AppPermission: Hashable`，可直接做字典键。
    @Published private(set) var statuses: [AppPermission: AppPermissionStatus] = [:]

    private var timer: Timer?
    private var visibleViewCount = 0
    private var activationObserver: NSObjectProtocol?

    private init() {
        refresh()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    func status(_ permission: AppPermission) -> AppPermissionStatus {
        statuses[permission] ?? permission.status
    }

    /// 读取真实状态。**只在有变化时发布**，避免每 2 秒无谓地重绘整个设置页。
    func refresh() {
        var next: [AppPermission: AppPermissionStatus] = [:]
        for permission in AppPermission.allCases {
            next[permission] = permission.status
        }
        if next != statuses { statuses = next }
    }

    /// 权限相关界面出现时调用，开始轮询。
    func beginObserving() {
        visibleViewCount += 1
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// 界面消失时调用（与 `beginObserving` 成对），最后一个界面关掉就停掉轮询。
    func endObserving() {
        visibleViewCount = max(0, visibleViewCount - 1)
        guard visibleViewCount == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    /// 申请授权。系统弹框（若有）关掉后再补读一次状态。
    func request(_ permission: AppPermission) {
        permission.request()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.refresh()
        }
    }
}

extension Notification.Name {
    /// 请求把主窗口切到「设置 → 系统权限」。
    /// 用通知而不是逐层传闭包：调用点分散在 QRScannerView（sheet 深处）、ScreenshotSettingsView 等处。
    static let openAppPermissions = Notification.Name("openAppPermissions")
}
