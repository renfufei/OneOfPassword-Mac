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

    private init() {
        let d = UserDefaults.standard
        // 首次启动：导出备份和打开存储位置默认开启
        d.register(defaults: [
            Key.requireAuthForExport.rawValue: true,
            Key.requireAuthForFinder.rawValue: true,
            Key.requireAuthForDelete.rawValue: false,
        ])
        requireAuthForExport = d.bool(forKey: Key.requireAuthForExport.rawValue)
        requireAuthForFinder = d.bool(forKey: Key.requireAuthForFinder.rawValue)
        requireAuthForDelete = d.bool(forKey: Key.requireAuthForDelete.rawValue)
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
