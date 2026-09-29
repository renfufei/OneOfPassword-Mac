//
//  AuthPolicy.swift
//  OneOfPassword
//
//  操作系统密码验证策略（LocalAuthentication）
//

import Foundation
import LocalAuthentication

class AuthPolicy: ObservableObject {
    static let shared = AuthPolicy()

    // UserDefaults 键
    private enum Key: String {
        case requireAuthForExport   = "requireAuthForExport"
        case requireAuthForFinder   = "requireAuthForFinder"
        case requireAuthForDelete   = "requireAuthForDelete"
        case requireAuthForVault    = "requireAuthForVault"
    }

    @Published var requireAuthForExport: Bool {
        didSet { UserDefaults.standard.set(requireAuthForExport, forKey: Key.requireAuthForExport.rawValue) }
    }
    @Published var requireAuthForFinder: Bool {
        didSet { UserDefaults.standard.set(requireAuthForFinder, forKey: Key.requireAuthForFinder.rawValue) }
    }
    @Published var requireAuthForDelete: Bool {
        didSet { UserDefaults.standard.set(requireAuthForDelete, forKey: Key.requireAuthForDelete.rawValue) }
    }
    /// 打开保险库是否需要验证操作系统密码。
    /// 语义是「进入保险库（查看密码 / 验证器）之前先验证」，默认关闭
    /// —— 打开应用就被拦一道属于用户明确选择后才开启的行为。
    /// 频率：**每次启动应用只验证一次**，通过后本次运行内来回切页面不再重复询问。
    @Published var requireAuthForVault: Bool {
        didSet { UserDefaults.standard.set(requireAuthForVault, forKey: Key.requireAuthForVault.rawValue) }
    }

    private init() {
        let d = UserDefaults.standard
        // 首次启动：导出备份和打开存储位置默认开启；
        // 「打开保险库」默认**关闭** —— 它会让每次启动应用都先弹一次系统验证，
        // 属于用户主动开启才有的行为，不能默认强加。
        d.register(defaults: [
            Key.requireAuthForExport.rawValue: true,
            Key.requireAuthForFinder.rawValue: true,
            Key.requireAuthForDelete.rawValue: false,
            Key.requireAuthForVault.rawValue: false,
        ])
        // 注：init 中的赋值不会触发 didSet，所以这里直接写回显式值即可。
        // 老版本用户没有这个键，register 的默认值保证升级后是「关闭」。
        requireAuthForExport = d.bool(forKey: Key.requireAuthForExport.rawValue)
        requireAuthForFinder = d.bool(forKey: Key.requireAuthForFinder.rawValue)
        requireAuthForDelete = d.bool(forKey: Key.requireAuthForDelete.rawValue)
        requireAuthForVault  = d.bool(forKey: Key.requireAuthForVault.rawValue)
    }

    /// 执行身份验证，通过后调用 `then`，失败则调用 `onFailure`（可选）
    func authenticate(reason: String, then: @escaping () -> Void, onFailure: (() -> Void)? = nil) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // 设备不支持验证（如无密码），直接放行
            DispatchQueue.main.async { then() }
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
            DispatchQueue.main.async {
                if success { then() } else { onFailure?() }
            }
        }
    }
}
