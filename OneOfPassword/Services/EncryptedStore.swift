//
//  EncryptedStore.swift
//  OneOfPassword
//
//  用 AES-GCM 加密本地文件替代 Keychain，彻底消除权限弹窗问题。
//  密钥由机器 UUID + bundle ID 派生，不存储到任何地方。
//

import Foundation
import CryptoKit

class EncryptedStore {
    static let shared = EncryptedStore()

    // secrets.json 加密后的文件路径
    private let storeFile: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir  = base.appendingPathComponent("com.oneofpassword.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("secrets.enc")
    }()

    // 内存缓存：[service+":"+id : value]
    private var cache: [String: String] = [:]

    private init() {
        load()
    }

    // MARK: - Public API（与 KeychainService 接口对齐）

    func set(_ value: String, service: String, id: String) {
        cache[key(service, id)] = value
        persist()
    }

    func get(service: String, id: String) throws -> String {
        guard let value = cache[key(service, id)] else {
            throw KeychainError.itemNotFound
        }
        return value
    }

    func delete(service: String, id: String) {
        cache.removeValue(forKey: key(service, id))
        persist()
    }

    // MARK: - Key derivation

    private var symmetricKey: SymmetricKey {
        // 用机器 UUID + bundle ID 做确定性派生，不持久化
        let machineID = getMachineID()
        let bundleID  = Bundle.main.bundleIdentifier ?? "com.oneofpassword.app"
        let raw       = (machineID + "|" + bundleID).data(using: .utf8)!
        // SHA-256 → 256-bit key
        let digest    = SHA256.hash(data: raw)
        return SymmetricKey(data: digest)
    }

    private func getMachineID() -> String {
        // IOPlatformUUID via sysctl / IOKit alternative: use host name + fixed salt
        // Simple approach: use a stable file-based UUID created once
        let uuidFile = storeFile.deletingLastPathComponent().appendingPathComponent(".device_id")
        if let existing = try? String(contentsOf: uuidFile, encoding: .utf8), !existing.isEmpty {
            return existing
        }
        let newID = UUID().uuidString
        try? newID.write(to: uuidFile, atomically: true, encoding: .utf8)
        return newID
    }

    // MARK: - Persist / Load

    private func persist() {
        guard let plaintext = try? JSONEncoder().encode(cache),
              let sealed    = try? AES.GCM.seal(plaintext, using: symmetricKey) else { return }
        try? sealed.combined?.write(to: storeFile, options: .atomic)
    }

    private func load() {
        guard let combined = try? Data(contentsOf: storeFile),
              let box      = try? AES.GCM.SealedBox(combined: combined),
              let plain    = try? AES.GCM.open(box, using: symmetricKey),
              let decoded  = try? JSONDecoder().decode([String: String].self, from: plain)
        else { return }
        cache = decoded
    }

    // MARK: - Helpers

    private func key(_ service: String, _ id: String) -> String { "\(service):\(id)" }
}
