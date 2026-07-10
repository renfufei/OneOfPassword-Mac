//
//  PasswordListViewModel.swift
//  OneOfPassword
//
//  统一保险库列表视图模型（替换 PasswordListViewModel + GAListViewModel）
//

import Foundation
import SwiftUI
import Combine

@MainActor
class VaultListViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var totpCodes: [UUID: String] = [:]
    @Published var remainingTime: Int = 30
    @Published var isAdvanced: Bool = false

    private let dataStore = DataStore.shared
    private let keychain = KeychainService.shared
    private let totpGenerator = TOTPGenerator.shared
    private var timer: Timer?
    private var itemsCancellable: AnyCancellable?

    // MARK: - Init / Deinit

    init() {
        startTimer()
        // DataStore 条目变化时（导入、新建、编辑）立即刷新验证码
        itemsCancellable = dataStore.$vaultItems
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateAllTOTPCodes() }
    }

    deinit {
        timer?.invalidate()
        itemsCancellable?.cancel()
    }

    // MARK: - TOTP Timer

    private func startTimer() {
        updateAllTOTPCodes()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.tick() }
        }
    }

    private func tick() {
        remainingTime = totpGenerator.getRemainingTime()
        if isAdvanced && remainingTime >= 29 {
            // 进入新周期，advanced 码变成当前码，恢复正常
            isAdvanced = false
            updateAllTOTPCodes()
        } else if !isAdvanced && remainingTime >= 29 {
            updateAllTOTPCodes()
        }
    }

    func advanceToNextPeriod() {
        isAdvanced = true
        updateAllTOTPCodes()
    }

    private func updateAllTOTPCodes() {
        let offset = isAdvanced ? 1 : 0
        for item in dataStore.vaultItems {
            guard let totpId = item.totpKeychainId,
                  let secret = try? keychain.getTOTPSecret(id: totpId),
                  let code = totpGenerator.generateTOTP(secret: secret, digits: item.totpDigits, period: item.totpPeriod, counterOffset: offset)
            else { continue }
            if totpCodes[item.id] != code {
                totpCodes[item.id] = code
            }
        }
    }

    // MARK: - TOTP

    func getTOTPCode(for item: VaultItem) -> String {
        totpCodes[item.id] ?? "------"
    }

    func getTOTPCode(keychainId: String, digits: Int, period: Int) -> String {
        let offset = isAdvanced ? 1 : 0
        guard let secret = try? keychain.getTOTPSecret(id: keychainId),
              let code = totpGenerator.generateTOTP(secret: secret, digits: digits, period: period, counterOffset: offset)
        else { return "------" }
        return code
    }

    // MARK: - Password

    func getPassword(for item: VaultItem) -> String? {
        guard !item.keychainId.isEmpty else { return nil }
        return try? keychain.getPassword(id: item.keychainId)
    }

    // MARK: - Save / Delete

    func saveItem(_ item: VaultItem, password: String?, totpSecret: String?) {
        var updated = item
        updated.updatedAt = Date()

        let isNew = !dataStore.vaultItems.contains(where: { $0.id == item.id })

        // Save password to keychain
        if let pw = password, !item.keychainId.isEmpty {
            if isNew {
                try? keychain.savePassword(id: item.keychainId, password: pw)
            } else {
                try? keychain.updatePassword(id: item.keychainId, password: pw)
            }
        }

        // Save TOTP secret to keychain
        if let secret = totpSecret, let totpId = item.totpKeychainId {
            keychain.saveTOTPSecret(id: totpId, secret: secret)
            if let code = totpGenerator.generateTOTP(secret: secret, digits: item.totpDigits, period: item.totpPeriod) {
                totpCodes[item.id] = code
            }
        }

        dataStore.saveVaultItem(updated)
    }

    func deleteItem(_ item: VaultItem) {
        dataStore.deleteVaultItem(item)
        totpCodes.removeValue(forKey: item.id)
    }

    func toggleFavorite(_ item: VaultItem) {
        var updated = item
        updated.isFavorite = !item.isFavorite
        dataStore.saveVaultItem(updated)
    }

    // MARK: - QR Parsing

    func parseQRCode(_ urlString: String) -> TOTPConfig? {
        totpGenerator.parseOTPAuthURL(urlString)
    }

    // MARK: - Password Generation

    func generatePassword(length: Int = 16) -> String {
        Self.generatePasswordStatic(length: length)
    }

    static func generatePasswordStatic(length: Int = 16) -> String {
        let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+-=[]{}|;:,.<>?"
        return String((0..<length).compactMap { _ in chars.randomElement() })
    }
}
