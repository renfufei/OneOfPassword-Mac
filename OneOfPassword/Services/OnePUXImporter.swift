//
//  OnePUXImporter.swift
//  OneOfPassword
//
//  解析 1Password .1pux 导出格式（ZIP + export.data JSON）
//

import Foundation

// MARK: - 1pux JSON 结构（部分解析）

private struct PUXExport: Decodable {
    var accounts: [PUXAccount]
}

private struct PUXAccount: Decodable {
    var vaults: [PUXVault]
}

private struct PUXVault: Decodable {
    var items: [PUXItem]
}

private struct PUXItem: Decodable {
    var uuid: String
    var categoryUuid: String
    var favIndex: Int?
    var createdAt: Int
    var updatedAt: Int
    var trashed: Bool?
    var overview: PUXOverview
    var details: PUXDetails

    enum CodingKeys: String, CodingKey {
        case uuid, categoryUuid, favIndex, createdAt, updatedAt, trashed, overview, details
    }

    var createdDate: Date { Date(timeIntervalSince1970: TimeInterval(createdAt)) }
    var updatedDate: Date { Date(timeIntervalSince1970: TimeInterval(updatedAt)) }
    var isTrashed: Bool { trashed == true }
    var isFavorite: Bool { (favIndex ?? 0) > 0 }
}

private struct PUXOverview: Decodable {
    var title: String
    var url: String?
    var tags: [String]?
}

private struct PUXDetails: Decodable {
    var loginFields: [PUXLoginField]?
    var password: String?
    var notesPlain: String?
    var sections: [PUXSection]?
    var passwordHistory: [PUXPasswordHistory]?
}

private struct PUXLoginField: Decodable {
    var value: String?
    var id: String?
    var name: String?
    var fieldType: String?
    var designation: String?
}

private struct PUXSection: Decodable {
    var title: String?
    var name: String?
    var fields: [PUXField]?
}

private struct PUXField: Decodable {
    var title: String?
    var id: String?
    var value: PUXFieldValue?
    var guarded: Bool?
}

private struct PUXFieldValue: Decodable {
    var totp: String?
    var string: String?
    var concealed: String?
    /// 原始类型 key（如 "totp", "string", "concealed", "date", "address", "phone", "url" 等）
    var rawTypeKey: String?
    /// 原始 value 对象序列化后的 JSON 字符串（用于无损保存 date/address/phone/url 等复杂类型）
    var rawValueJSON: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        totp      = try? c.decode(String.self, forKey: DynamicKey("totp"))
        string    = try? c.decode(String.self, forKey: DynamicKey("string"))
        concealed = try? c.decode(String.self, forKey: DynamicKey("concealed"))
        rawTypeKey = c.allKeys.first?.stringValue

        // 把整个 value 对象序列化为 JSON 字符串，保留原始结构
        // 将 {key: value} 整体序列化存储，例如 {"date": 1234567890} 或 {"address": {...}}
        if let key = rawTypeKey,
           let raw = try? c.decode(SafeJSON.self, forKey: DynamicKey(key)) {
            // JSONSerialization 要求顶层是 dict/array；将值包装为 {key: value}
            let wrapper: [String: Any] = [key: raw.jsonObject]
            if let data = try? JSONSerialization.data(withJSONObject: wrapper),
               let str = String(data: data, encoding: .utf8) {
                rawValueJSON = str
            }
        }
    }
}

/// 辅助：解码任意 JSON 值，确保结果对 JSONSerialization 安全（用 NSNull 替代 nil）
private struct SafeJSON: Decodable {
    let jsonObject: Any  // 始终是 String / NSNumber / NSNull / [Any] / [String:Any]

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            jsonObject = NSNull()
        } else if let b = try? c.decode(Bool.self) {
            jsonObject = NSNumber(value: b)
        } else if let i = try? c.decode(Int.self) {
            jsonObject = NSNumber(value: i)
        } else if let d = try? c.decode(Double.self) {
            jsonObject = NSNumber(value: d)
        } else if let s = try? c.decode(String.self) {
            jsonObject = s
        } else if let a = try? c.decode([SafeJSON].self) {
            jsonObject = a.map { $0.jsonObject }
        } else if let o = try? c.decode([String: SafeJSON].self) {
            jsonObject = o.mapValues { $0.jsonObject }
        } else {
            jsonObject = NSNull()
        }
    }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { self.stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private struct PUXPasswordHistory: Decodable {
    var value: String
    var time: Int
}

// MARK: - 类别映射

private func mapCategory(_ uuid: String) -> ItemCategory {
    switch uuid {
    case "001", "005": return .general
    case "002": return .finance
    default:    return .general
    }
}

// MARK: - 导入服务

class OnePUXImporter {
    static let shared = OnePUXImporter()
    private init() {}

    private let keychain  = KeychainService.shared
    private let dataStore = DataStore.shared

    @discardableResult
    func importFile(_ url: URL) throws -> ImportResult {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("1pux_import_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try unzip(url, to: tmpDir)

        let exportDataURL = tmpDir.appendingPathComponent("export.data")
        guard let data = try? Data(contentsOf: exportDataURL) else {
            throw OnePUXError.exportDataNotFound
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let export = try? decoder.decode(PUXExport.self, from: data) else {
            throw OnePUXError.invalidFormat
        }

        return try merge(export)
    }

    // MARK: - 私有：解压

    private func unzip(_ src: URL, to dst: URL) throws {
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-qq", "-o", src.path, "-d", dst.path]

        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()

        if proc.terminationStatus != 0 {
            let errMsg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw OnePUXError.unzipFailed(errMsg)
        }
    }

    // MARK: - 私有：合并数据

    private func merge(_ export: PUXExport) throws -> ImportResult {
        var result = ImportResult()
        let existingSourceIds = Set(dataStore.vaultItems.compactMap { $0.sourceId })

        for account in export.accounts {
            for vault in account.vaults {
                for item in vault.items {
                    if item.isTrashed { continue }

                    if existingSourceIds.contains(item.uuid) {
                        result.skippedCount += 1; continue
                    }

                    do {
                        switch item.categoryUuid {
                        case "003":
                            importNoteItem(item, result: &result)
                        default:
                            importPasswordItem(item, existingSourceIds: existingSourceIds, result: &result)
                        }
                    } catch {
                        result.skippedCount += 1
                    }
                }
            }
        }
        return result
    }

    private func importPasswordItem(_ item: PUXItem, existingSourceIds: Set<String>, result: inout ImportResult) {
        let id = UUID()

        let username = item.details.loginFields?.first(where: { $0.designation == "username" })?.value
            ?? item.details.loginFields?.first(where: { $0.fieldType == "T" })?.value
            ?? ""

        let password = item.details.loginFields?.first(where: { $0.designation == "password" })?.value
            ?? item.details.loginFields?.first(where: { $0.fieldType == "P" })?.value
            ?? item.details.password
            ?? ""

        var vaultNotes: [VaultNote] = []
        if let notes = item.details.notesPlain, !notes.isEmpty {
            vaultNotes.append(VaultNote(title: "备注", content: notes))
        }

        var customFields: [CustomField] = []

        // 第一个 TOTP 嵌入密码条目；额外的 TOTP 收集起来之后单独建条目
        struct TOTPEntry {
            var secret: String
            var issuer: String?
            var accountName: String
            var digits: Int
            var period: Int
        }
        var totpEntries: [TOTPEntry] = []

        if let sections = item.details.sections {
            for section in sections {
                for field in section.fields ?? [] {
                    guard let fv = field.value, let typeKey = fv.rawTypeKey else { continue }

                    if typeKey == "totp" {
                        guard let rawTOTP = fv.totp, !rawTOTP.isEmpty else { continue }
                        let fieldLabel = (field.title?.isEmpty == false) ? field.title! : item.overview.title
                        let (secret, issuer, accountName, digits, period) = parseTOTPField(rawTOTP, fallbackTitle: fieldLabel)
                        let effectiveAccountName = rawTOTP.lowercased().hasPrefix("otpauth://") ? accountName : fieldLabel
                        totpEntries.append(TOTPEntry(secret: secret, issuer: issuer,
                                                     accountName: effectiveAccountName,
                                                     digits: digits, period: period))
                        continue
                    }

                    let label = (field.title?.isEmpty == false) ? field.title! : (section.title ?? "字段")

                    if typeKey == "concealed" {
                        let rawValue = fv.concealed ?? ""
                        guard !rawValue.isEmpty else { continue }
                        let kcId = UUID().uuidString
                        keychain.saveCustomFieldValue(keychainId: kcId, value: rawValue)
                        customFields.append(CustomField(label: label, value: "", isConcealed: true, concealedKeychainId: kcId, rawType: "concealed"))
                    } else if typeKey == "string" {
                        let rawValue = fv.string ?? ""
                        customFields.append(CustomField(label: label, value: rawValue, isConcealed: false, rawType: "string"))
                    } else {
                        // date / address / phone / url / monthYear 等：序列化原始 JSON value 字符串保存
                        let storedValue = fv.rawValueJSON ?? ""
                        customFields.append(CustomField(label: label, value: storedValue, isConcealed: false, rawType: typeKey))
                    }
                }
            }
        }

        // 第一个 TOTP 嵌入密码条目
        let firstTOTP = totpEntries.first
        let newKeychainId = UUID().uuidString
        let totpKeychainId: String? = firstTOTP != nil ? UUID().uuidString : nil

        // 额外 TOTP（第2个起）存入 extraTOTPs，不再创建独立条目
        var extraTOTPs: [ExtraTOTP] = []
        for entry in totpEntries.dropFirst() {
            let kcId = UUID().uuidString
            keychain.saveTOTPSecret(id: kcId, secret: entry.secret)
            extraTOTPs.append(ExtraTOTP(
                label: entry.accountName,
                issuer: entry.issuer,
                accountName: entry.accountName,
                digits: entry.digits,
                period: entry.period,
                keychainId: kcId
            ))
        }

        let vaultItem = VaultItem(
            id: id,
            type: .password,
            title: item.overview.title,
            isFavorite: item.isFavorite,
            createdAt: item.createdDate,
            updatedAt: item.updatedDate,
            sourceId: item.uuid,
            username: username,
            website: item.overview.url,
            vaultNotes: vaultNotes,
            category: mapCategory(item.categoryUuid),
            keychainId: newKeychainId,
            customFields: customFields,
            totpIssuer: firstTOTP?.issuer,
            totpAccountName: firstTOTP?.accountName ?? item.overview.title,
            totpDigits: firstTOTP?.digits ?? 6,
            totpPeriod: firstTOTP?.period ?? 30,
            totpKeychainId: totpKeychainId,
            extraTOTPs: extraTOTPs
        )

        try? keychain.savePassword(id: newKeychainId, password: password)
        if let totpId = totpKeychainId, let secret = firstTOTP?.secret {
            keychain.saveTOTPSecret(id: totpId, secret: secret)
        }
        dataStore.saveVaultItem(vaultItem)
        result.importedCount += 1
    }

    private func importNoteItem(_ item: PUXItem, result: inout ImportResult) {
        var vaultNotes: [VaultNote] = []
        if let notes = item.details.notesPlain, !notes.isEmpty {
            vaultNotes.append(VaultNote(title: "内容", content: notes))
        }

        let vaultItem = VaultItem(
            id: UUID(),
            type: .password,
            title: item.overview.title,
            isFavorite: item.isFavorite,
            createdAt: item.createdDate,
            updatedAt: item.updatedDate,
            sourceId: item.uuid,
            vaultNotes: vaultNotes,
            category: .other,
            keychainId: ""
        )
        dataStore.saveVaultItem(vaultItem)
        result.importedCount += 1
    }

    // MARK: - 工具：解析 TOTP 字段

    private func parseTOTPField(_ secret: String, fallbackTitle: String)
        -> (secret: String, issuer: String?, accountName: String, digits: Int, period: Int) {
        if secret.lowercased().hasPrefix("otpauth://"),
           let config = TOTPGenerator.shared.parseOTPAuthURL(secret) {
            return (config.secret, config.issuer, config.accountName, config.digits, config.period)
        }
        return (secret, nil, fallbackTitle, 6, 30)
    }
}

// MARK: - 错误

enum OnePUXError: LocalizedError {
    case exportDataNotFound
    case invalidFormat
    case unzipFailed(String)

    var errorDescription: String? {
        switch self {
        case .exportDataNotFound: return "未找到 export.data，请确认文件为有效的 .1pux 格式"
        case .invalidFormat:     return "1pux 文件格式无效或已损坏"
        case .unzipFailed(let m): return "解压失败：\(m)"
        }
    }
}
