//
//  KeychainService.swift
//  OneOfPassword
//
//  接口层保持不变；底层改为 EncryptedStore（AES-GCM 加密本地文件），
//  彻底消除 macOS Keychain 权限弹窗问题。
//  首次读取时自动尝试从旧 Keychain 迁移数据。
//

import Foundation
import Security

enum KeychainError: Error {
    case duplicateItem
    case itemNotFound
    case invalidData
    case unexpectedStatus(OSStatus)
}

class KeychainService {
    static let shared = KeychainService()

    private let passwordService    = "com.oneofpassword.password"
    private let gaService          = "com.oneofpassword.ga"
    private let customFieldService = "com.oneofpassword.customfield"
    private let store           = EncryptedStore.shared

    private init() {}

    // MARK: - Password

    func savePassword(id: String, password: String) throws {
        store.set(password, service: passwordService, id: id)
    }

    func getPassword(id: String) throws -> String {
        return try store.get(service: passwordService, id: id)
    }

    func updatePassword(id: String, password: String) throws {
        store.set(password, service: passwordService, id: id)
    }

    func deletePassword(id: String) throws {
        store.delete(service: passwordService, id: id)
    }

    // MARK: - GA Secret

    func saveGASecret(id: String, secret: String) throws {
        store.set(secret, service: gaService, id: id)
    }

    func getGASecret(id: String) throws -> String {
        return try store.get(service: gaService, id: id)
    }

    func updateGASecret(id: String, secret: String) throws {
        store.set(secret, service: gaService, id: id)
    }

    func deleteGASecret(id: String) throws {
        store.delete(service: gaService, id: id)
    }

    // MARK: - TOTP Secret (aliases over GA methods)

    func saveTOTPSecret(id: String, secret: String) {
        store.set(secret, service: gaService, id: id)
    }

    func getTOTPSecret(id: String) throws -> String {
        return try store.get(service: gaService, id: id)
    }

    func deleteTOTPSecret(id: String) {
        store.delete(service: gaService, id: id)
    }

    // MARK: - Custom Field (Concealed)

    func saveCustomFieldValue(keychainId: String, value: String) {
        store.set(value, service: customFieldService, id: keychainId)
    }

    func getCustomFieldValue(keychainId: String) throws -> String {
        return try store.get(service: customFieldService, id: keychainId)
    }

    func deleteCustomFieldValue(keychainId: String) {
        store.delete(service: customFieldService, id: keychainId)
    }
}
