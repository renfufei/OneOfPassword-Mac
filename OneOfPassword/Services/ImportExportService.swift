//
//  ImportExportService.swift
//  OneOfPassword
//
//  导入 / 导出服务（统一 VaultItem）
//  导出格式：JSON，密码和 TOTP Secret 以明文包含其中（文件本身可选密码保护）
//  文件扩展名：.1pwd
//

import Foundation
import CryptoKit

// MARK: - 导出数据包结构（v2）

struct VaultExportItem: Codable {
    var id: UUID
    var type: VaultItemType
    var title: String
    var isFavorite: Bool
    var createdAt: Date
    var updatedAt: Date
    var sourceId: String?

    // Password fields
    var username: String
    var website: String?
    var notes: String?
    var vaultNotes: [VaultNote]
    var category: ItemCategory?
    var customFields: [CustomFieldExportItem]
    var password: String            // 导出时读取明文

    // TOTP fields
    var totpIssuer: String?
    var totpAccountName: String
    var totpLabel: String
    var totpDigits: Int
    var totpPeriod: Int
    var totpSecret: String?         // 导出时读取明文（nil = 无 TOTP）
    var extraTOTPs: [ExtraTOTPExportItem]
    var extraPasswords: [ExtraPasswordExportItem]

    init(id: UUID, type: VaultItemType, title: String, isFavorite: Bool,
         createdAt: Date, updatedAt: Date, sourceId: String?,
         username: String, website: String?, notes: String?,
         vaultNotes: [VaultNote], category: ItemCategory?,
         customFields: [CustomFieldExportItem], password: String,
         totpIssuer: String?, totpAccountName: String, totpLabel: String,
         totpDigits: Int, totpPeriod: Int, totpSecret: String?,
         extraTOTPs: [ExtraTOTPExportItem] = [],
         extraPasswords: [ExtraPasswordExportItem] = []) {
        self.id = id; self.type = type; self.title = title
        self.isFavorite = isFavorite; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.sourceId = sourceId; self.username = username; self.website = website
        self.notes = notes; self.vaultNotes = vaultNotes; self.category = category
        self.customFields = customFields; self.password = password
        self.totpIssuer = totpIssuer; self.totpAccountName = totpAccountName
        self.totpLabel = totpLabel; self.totpDigits = totpDigits; self.totpPeriod = totpPeriod
        self.totpSecret = totpSecret; self.extraTOTPs = extraTOTPs
        self.extraPasswords = extraPasswords
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = try c.decode(UUID.self,                       forKey: .id)
        type            = (try? c.decode(VaultItemType.self,            forKey: .type))          ?? .password
        title           = try c.decode(String.self,                     forKey: .title)
        isFavorite      = (try? c.decode(Bool.self,                     forKey: .isFavorite))    ?? false
        createdAt       = (try? c.decode(Date.self,                     forKey: .createdAt))     ?? Date()
        updatedAt       = (try? c.decode(Date.self,                     forKey: .updatedAt))     ?? Date()
        sourceId        = try? c.decodeIfPresent(String.self,           forKey: .sourceId)
        username        = (try? c.decode(String.self,                   forKey: .username))      ?? ""
        website         = try? c.decodeIfPresent(String.self,           forKey: .website)
        notes           = try? c.decodeIfPresent(String.self,           forKey: .notes)
        vaultNotes      = (try? c.decode([VaultNote].self,              forKey: .vaultNotes))    ?? []
        category        = try? c.decodeIfPresent(ItemCategory.self,      forKey: .category)
        customFields    = (try? c.decode([CustomFieldExportItem].self,  forKey: .customFields))  ?? []
        password        = (try? c.decode(String.self,                   forKey: .password))      ?? ""
        totpIssuer      = try? c.decodeIfPresent(String.self,           forKey: .totpIssuer)
        totpAccountName = (try? c.decode(String.self,                   forKey: .totpAccountName)) ?? ""
        totpLabel       = (try? c.decode(String.self,                   forKey: .totpLabel))     ?? ""
        totpDigits      = (try? c.decode(Int.self,                      forKey: .totpDigits))    ?? 6
        totpPeriod      = (try? c.decode(Int.self,                      forKey: .totpPeriod))    ?? 30
        totpSecret      = try? c.decodeIfPresent(String.self,           forKey: .totpSecret)
        extraTOTPs      = (try? c.decode([ExtraTOTPExportItem].self,    forKey: .extraTOTPs))    ?? []
        extraPasswords  = (try? c.decode([ExtraPasswordExportItem].self, forKey: .extraPasswords)) ?? []
    }
}

struct ExtraPasswordExportItem: Codable {
    var label: String
    var password: String
}

struct ExtraTOTPExportItem: Codable {
    var id: UUID
    var label: String
    var issuer: String?
    var accountName: String
    var digits: Int
    var period: Int
    var secret: String
}

struct CustomFieldExportItem: Codable {
    var label: String
    var value: String
    var isConcealed: Bool
    var rawType: String?    // 原始 1pux 类型 key，用于导出时还原字段格式
}

struct ExportBundle: Codable {
    var version: Int = 2
    var exportedAt: Date = Date()
    var items: [VaultExportItem]
}

// MARK: - 导入结果

struct ImportResult {
    var importedCount: Int = 0
    var skippedCount: Int = 0
}

// MARK: - 错误

enum ImportExportError: LocalizedError {
    case wrongPassword
    case invalidFormat
    case keychainReadFailed(String)

    var errorDescription: String? {
        switch self {
        case .wrongPassword:       return "密码错误，无法解密文件"
        case .invalidFormat:       return "文件格式无效或已损坏"
        case .keychainReadFailed(let t): return "读取「\(t)」的密码失败，已跳过"
        }
    }
}

// MARK: - 服务

class ImportExportService {
    static let shared = ImportExportService()
    private init() {}

    private let keychain = KeychainService.shared
    private let dataStore = DataStore.shared

    // MARK: - 导出

    func exportData(password: String?) throws -> (data: Data, fileExt: String) {
        guard let pwd = password, !pwd.isEmpty else {
            let zipData = try buildOnePUXZip()
            return (zipData, "1pux")
        }
        let plainData = try buildBundleJSON()
        let encrypted = try encrypt(plainData, password: pwd)
        return (encrypted, "1pwd")
    }

    func exportCSV() throws -> Data {
        var lines: [String] = ["Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes"]
        for item in dataStore.vaultItems {
            let pwd = item.type == .password && !item.keychainId.isEmpty
                ? ((try? keychain.getPassword(id: item.keychainId)) ?? "") : ""
            var otpAuth = ""
            if let totpId = item.totpKeychainId,
               let secret = try? keychain.getTOTPSecret(id: totpId) {
                let account = item.totpAccountName.isEmpty ? item.title : item.totpAccountName
                let issuer  = item.totpIssuer ?? item.title
                otpAuth = "otpauth://totp/\(account.urlEncoded)?secret=\(secret)&issuer=\(issuer.urlEncoded)&digits=\(item.totpDigits)&period=\(item.totpPeriod)"
            }
            let cols: [String] = [
                item.title.csvEscaped,
                (item.website ?? "").csvEscaped,
                item.username.csvEscaped,
                pwd.csvEscaped,
                otpAuth.csvEscaped,
                item.isFavorite ? "true" : "false",
                "false",
                "",
                (item.notes ?? "").csvEscaped
            ]
            lines.append(cols.joined(separator: ","))
            // 额外密码各自导出为独立行（标题加标签后缀以区分）
            for ep in item.extraPasswords {
                let epPwd = (try? keychain.getPassword(id: ep.keychainId)) ?? ""
                guard !epPwd.isEmpty else { continue }
                let suffix = ep.label.isEmpty ? "" : " (\(ep.label))"
                let epCols: [String] = [
                    "\(item.title)\(suffix)".csvEscaped,
                    (item.website ?? "").csvEscaped,
                    item.username.csvEscaped,
                    epPwd.csvEscaped,
                    "",
                    item.isFavorite ? "true" : "false",
                    "false",
                    "",
                    ""
                ]
                lines.append(epCols.joined(separator: ","))
            }
        }
        guard let data = lines.joined(separator: "\n").data(using: .utf8) else {
            throw ImportExportError.invalidFormat
        }
        return data
    }

    // MARK: - 1pux ZIP 构建

    private func buildOnePUXZip() throws -> Data {
        var items: [[String: Any]] = []

        for item in dataStore.vaultItems {
            if item.type == .totp {
                // 纯 TOTP 条目：作为独立的 TOTP only 条目导出
                guard let totpId = item.totpKeychainId else { continue }
                let secret = (try? keychain.getTOTPSecret(id: totpId)) ?? ""
                let account = item.totpAccountName.isEmpty ? item.title : item.totpAccountName
                let issuer  = (item.totpIssuer ?? item.title)
                let otpURI = "otpauth://totp/\(account.urlEncoded)?secret=\(secret)&issuer=\(issuer.urlEncoded)&digits=\(item.totpDigits)&period=\(item.totpPeriod)"
                let totpField: [String: Any] = [
                    "title": item.totpLabel.isEmpty ? item.totpAccountName : item.totpLabel,
                    "id": item.id.uuidString,
                    "value": ["totp": otpURI]
                ]
                let puxItem: [String: Any] = [
                    "uuid": item.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                    "categoryUuid": "001",
                    "createdAt": Int(item.createdAt.timeIntervalSince1970),
                    "updatedAt": Int(item.updatedAt.timeIntervalSince1970),
                    "state": "active",
                    "overview": ["title": item.title, "url": ""],
                    "details": [
                        "loginFields": [],
                        "notesPlain": "",
                        "sections": [[
                            "title": "One-Time Password",
                            "name": "otp",
                            "fields": [totpField]
                        ]]
                    ]
                ]
                items.append(puxItem)
                continue
            }

            // 密码条目
            let pwd = (try? keychain.getPassword(id: item.keychainId)) ?? ""
            let loginFields: [[String: Any]] = [
                ["value": item.username, "fieldType": "T", "designation": "username"],
                ["value": pwd,           "fieldType": "P", "designation": "password"]
            ]

            var sections: [[String: Any]] = []

            // 内嵌 TOTP（主 + 额外）
            var totpFields: [[String: Any]] = []
            if let totpId = item.totpKeychainId {
                let secret = (try? keychain.getTOTPSecret(id: totpId)) ?? ""
                let totpAccount = item.totpAccountName.isEmpty ? item.title : item.totpAccountName
                let totpIssuer  = (item.totpIssuer ?? item.title)
                let otpURI = "otpauth://totp/\(totpAccount.urlEncoded)?secret=\(secret)&issuer=\(totpIssuer.urlEncoded)&digits=\(item.totpDigits)&period=\(item.totpPeriod)"
                totpFields.append([
                    "title": item.totpLabel.isEmpty ? item.totpAccountName : item.totpLabel,
                    "id": item.id.uuidString,
                    "value": ["totp": otpURI]
                ])
            }
            for extra in item.extraTOTPs {
                let secret = (try? keychain.getTOTPSecret(id: extra.keychainId)) ?? ""
                let extraIssuer = extra.issuer ?? extra.label
                let otpURI = "otpauth://totp/\(extra.accountName.urlEncoded)?secret=\(secret)&issuer=\(extraIssuer.urlEncoded)&digits=\(extra.digits)&period=\(extra.period)"
                totpFields.append([
                    "title": extra.label,
                    "id": extra.id.uuidString,
                    "value": ["totp": otpURI]
                ])
            }
            if !totpFields.isEmpty {
                sections.append(["title": "One-Time Password", "name": "otp", "fields": totpFields])
            }

            // 额外密码作为 concealed section 字段
            var extraPwdSectionFields: [[String: Any]] = []
            for ep in item.extraPasswords {
                let pw = (try? keychain.getPassword(id: ep.keychainId)) ?? ""
                guard !pw.isEmpty else { continue }
                let label = ep.label.isEmpty ? "密码" : ep.label
                extraPwdSectionFields.append([
                    "title": label,
                    "id": ep.id.uuidString,
                    "value": ["concealed": pw]
                ])
            }
            if !extraPwdSectionFields.isEmpty {
                sections.append(["title": "额外密码", "name": "extra_passwords", "fields": extraPwdSectionFields])
            }

            // Custom fields
            var customSectionFields: [[String: Any]] = []
            for cf in item.customFields {
                let typeKey = cf.rawType ?? (cf.isConcealed ? "concealed" : "string")
                let valueObj: [String: Any]

                if typeKey == "concealed" {
                    let rawValue: String
                    if let kcId = cf.concealedKeychainId {
                        rawValue = (try? keychain.getCustomFieldValue(keychainId: kcId)) ?? ""
                    } else {
                        rawValue = cf.value
                    }
                    guard !rawValue.isEmpty else { continue }
                    valueObj = ["concealed": rawValue]
                } else if typeKey == "string" {
                    valueObj = ["string": cf.value]
                } else {
                    // date/address/phone/url 等原始类型：value 字段存储了 {key: value} 格式的 JSON 字符串
                    if let jsonData = cf.value.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       let innerValue = parsed[typeKey] {
                        valueObj = [typeKey: innerValue]
                    } else {
                        // 退化：当作 string 导出
                        valueObj = ["string": cf.value]
                    }
                }
                customSectionFields.append(["title": cf.label, "id": cf.id.uuidString, "value": valueObj])
            }
            if !customSectionFields.isEmpty {
                sections.append(["title": "自定义字段", "name": "custom", "fields": customSectionFields])
            }

            let notesPlain = item.vaultNotes.map { $0.content }.joined(separator: "\n\n")

            var details: [String: Any] = [
                "loginFields": loginFields,
                "notesPlain": notesPlain
            ]
            if !sections.isEmpty { details["sections"] = sections }

            let puxItem: [String: Any] = [
                "uuid": item.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                "categoryUuid": "001",
                "createdAt": Int(item.createdAt.timeIntervalSince1970),
                "updatedAt": Int(item.updatedAt.timeIntervalSince1970),
                "state": "active",
                "overview": ["title": item.title, "url": item.website ?? ""],
                "details": details
            ]
            items.append(puxItem)
        }

        let exportObj: [String: Any] = [
            "accounts": [[
                "attrs": ["name": "OneOfPassword"],
                "vaults": [[
                    "attrs": ["name": "Personal"],
                    "items": items
                ]]
            ]]
        ]

        let exportData = try JSONSerialization.data(withJSONObject: exportObj, options: [.prettyPrinted])

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("1pux_export_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let exportDataFile = tmpDir.appendingPathComponent("export.data")
        try exportData.write(to: exportDataFile)

        let zipURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("export_\(UUID().uuidString).1pux")
        defer { try? FileManager.default.removeItem(at: zipURL) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.arguments = ["-j", zipURL.path, exportDataFile.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw ImportExportError.invalidFormat
        }

        return try Data(contentsOf: zipURL)
    }

    // MARK: - .1pwd JSON 构建

    private func buildBundleJSON() throws -> Data {
        let exportItems: [VaultExportItem] = dataStore.vaultItems.map { item in
            let pwd = item.type == .password && !item.keychainId.isEmpty
                ? ((try? keychain.getPassword(id: item.keychainId)) ?? "")
                : ""
            let totpSecret: String? = item.totpKeychainId.flatMap { id in
                try? keychain.getTOTPSecret(id: id)
            }
            let cfExports: [CustomFieldExportItem] = item.customFields.map { cf in
                let rawValue: String
                if cf.isConcealed, let kcId = cf.concealedKeychainId {
                    rawValue = (try? keychain.getCustomFieldValue(keychainId: kcId)) ?? ""
                } else {
                    rawValue = cf.value
                }
                return CustomFieldExportItem(label: cf.label, value: rawValue, isConcealed: cf.isConcealed, rawType: cf.rawType)
            }
            let extraTOTPExports: [ExtraTOTPExportItem] = item.extraTOTPs.map { extra in
                let secret = (try? keychain.getTOTPSecret(id: extra.keychainId)) ?? ""
                return ExtraTOTPExportItem(id: extra.id, label: extra.label, issuer: extra.issuer,
                                           accountName: extra.accountName, digits: extra.digits,
                                           period: extra.period, secret: secret)
            }
            let extraPwdExports: [ExtraPasswordExportItem] = item.extraPasswords.map { ep in
                let pw = (try? keychain.getPassword(id: ep.keychainId)) ?? ""
                return ExtraPasswordExportItem(label: ep.label, password: pw)
            }
            return VaultExportItem(
                id: item.id, type: item.type, title: item.title,
                isFavorite: item.isFavorite, createdAt: item.createdAt, updatedAt: item.updatedAt,
                sourceId: item.sourceId, username: item.username, website: item.website,
                notes: item.notes, vaultNotes: item.vaultNotes, category: item.category,
                customFields: cfExports, password: pwd,
                totpIssuer: item.totpIssuer, totpAccountName: item.totpAccountName,
                totpLabel: item.totpLabel, totpDigits: item.totpDigits, totpPeriod: item.totpPeriod,
                totpSecret: totpSecret, extraTOTPs: extraTOTPExports, extraPasswords: extraPwdExports
            )
        }

        let bundle = ExportBundle(items: exportItems)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(bundle)
    }

    // MARK: - CSV 导入

    @discardableResult
    func importCSV(_ data: Data) throws -> ImportResult {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportExportError.invalidFormat
        }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count > 1 else { return ImportResult() }

        // 解析 header
        let header = parseCSVRow(lines[0])
        func col(_ name: String) -> Int? { header.firstIndex(of: name) }
        guard let titleIdx = col("Title") else { throw ImportExportError.invalidFormat }
        let urlIdx      = col("Url")
        let userIdx     = col("Username")
        let pwdIdx      = col("Password")
        let otpIdx      = col("OTPAuth")
        let favIdx      = col("Favorite")
        let notesIdx    = col("Notes")

        // 以 Title 查重
        let existingTitles = Set(dataStore.vaultItems.map { $0.title.lowercased() })

        var result = ImportResult()
        for line in lines.dropFirst() {
            let cols = parseCSVRow(line)
            guard cols.count > titleIdx else { continue }
            let title = cols[titleIdx]
            guard !title.isEmpty else { continue }

            if existingTitles.contains(title.lowercased()) {
                result.skippedCount += 1
                continue
            }

            let url      = urlIdx.flatMap   { $0 < cols.count ? cols[$0] : nil } ?? ""
            let username = userIdx.flatMap  { $0 < cols.count ? cols[$0] : nil } ?? ""
            let password = pwdIdx.flatMap   { $0 < cols.count ? cols[$0] : nil } ?? ""
            let otpAuth  = otpIdx.flatMap   { $0 < cols.count ? cols[$0] : nil } ?? ""
            let favorite = favIdx.flatMap   { $0 < cols.count ? cols[$0] : nil } ?? "false"
            let notes    = notesIdx.flatMap { $0 < cols.count ? cols[$0] : nil } ?? ""

            // 解析 OTPAuth
            var totpAccountName = ""
            var totpIssuer: String? = nil
            var totpDigits = 6
            var totpPeriod = 30
            var totpKeychainId: String? = nil

            if !otpAuth.isEmpty, let config = TOTPGenerator.shared.parseOTPAuthURL(otpAuth) {
                totpAccountName = config.accountName
                totpIssuer      = config.issuer
                totpDigits      = config.digits
                totpPeriod      = config.period
                let kcId        = UUID().uuidString
                keychain.saveTOTPSecret(id: kcId, secret: config.secret)
                totpKeychainId  = kcId
            }

            let keychainId = UUID().uuidString
            if !password.isEmpty {
                try? keychain.savePassword(id: keychainId, password: password)
            }

            let item = VaultItem(
                type: .password,
                title: title,
                isFavorite: favorite.lowercased() == "true",
                username: username,
                website: url.isEmpty ? nil : url,
                notes: notes.isEmpty ? nil : notes,
                keychainId: keychainId,
                totpIssuer: totpIssuer,
                totpAccountName: totpAccountName,
                totpDigits: totpDigits,
                totpPeriod: totpPeriod,
                totpKeychainId: totpKeychainId
            )
            dataStore.saveVaultItem(item)
            result.importedCount += 1
        }
        return result
    }

    /// RFC 4180 CSV 行解析（支持引号转义）
    private func parseCSVRow(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\"" {
                let next = line.index(after: i)
                if inQuotes && next < line.endIndex && line[next] == "\"" {
                    current.append("\"")
                    i = line.index(after: next)
                    continue
                }
                inQuotes.toggle()
            } else if ch == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
            i = line.index(after: i)
        }
        fields.append(current)
        return fields
    }

    // MARK: - 导入

    @discardableResult
    func importData(_ data: Data, password: String?) throws -> ImportResult {
        let plainData: Data
        if isEncrypted(data) {
            guard let pwd = password, !pwd.isEmpty else { throw ImportExportError.wrongPassword }
            plainData = try decrypt(data, password: pwd)
        } else {
            plainData = data
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let bundle = try? decoder.decode(ExportBundle.self, from: plainData) else {
            throw ImportExportError.invalidFormat
        }

        var result = ImportResult()
        let existingIds = Set(dataStore.vaultItems.map { $0.id })

        for exportItem in bundle.items {
            if existingIds.contains(exportItem.id) {
                result.skippedCount += 1
                continue
            }

            do {
                let newKeychainId = exportItem.type == .password ? UUID().uuidString : ""
                let newTotpId: String? = exportItem.totpSecret != nil ? UUID().uuidString : nil

                let restoredCF: [CustomField] = exportItem.customFields.map { cf in
                    if cf.isConcealed {
                        let kcId = UUID().uuidString
                        keychain.saveCustomFieldValue(keychainId: kcId, value: cf.value)
                        return CustomField(label: cf.label, value: "", isConcealed: true, concealedKeychainId: kcId, rawType: cf.rawType)
                    } else {
                        return CustomField(label: cf.label, value: cf.value, isConcealed: false, rawType: cf.rawType)
                    }
                }

                let restoredExtras: [ExtraTOTP] = exportItem.extraTOTPs.map { extra in
                    let kcId = UUID().uuidString
                    keychain.saveTOTPSecret(id: kcId, secret: extra.secret)
                    return ExtraTOTP(id: extra.id, label: extra.label, issuer: extra.issuer,
                                     accountName: extra.accountName, digits: extra.digits,
                                     period: extra.period, keychainId: kcId)
                }

                let restoredExtraPwds: [ExtraPassword] = exportItem.extraPasswords.map { ep in
                    let kcId = UUID().uuidString
                    try? keychain.savePassword(id: kcId, password: ep.password)
                    return ExtraPassword(label: ep.label, keychainId: kcId)
                }

                let vaultItem = VaultItem(
                    id: exportItem.id,
                    type: exportItem.type,
                    title: exportItem.title,
                    isFavorite: exportItem.isFavorite,
                    createdAt: exportItem.createdAt,
                    updatedAt: exportItem.updatedAt,
                    sourceId: exportItem.sourceId,
                    username: exportItem.username,
                    website: exportItem.website,
                    notes: exportItem.notes,
                    vaultNotes: exportItem.vaultNotes,
                    category: exportItem.category,
                    keychainId: newKeychainId,
                    customFields: restoredCF,
                    totpIssuer: exportItem.totpIssuer,
                    totpAccountName: exportItem.totpAccountName,
                    totpLabel: exportItem.totpLabel,
                    totpDigits: exportItem.totpDigits,
                    totpPeriod: exportItem.totpPeriod,
                    totpKeychainId: newTotpId,
                    extraTOTPs: restoredExtras,
                    extraPasswords: restoredExtraPwds
                )

                if !newKeychainId.isEmpty {
                    try? keychain.savePassword(id: newKeychainId, password: exportItem.password)
                }
                if let totpId = newTotpId, let secret = exportItem.totpSecret {
                    keychain.saveTOTPSecret(id: totpId, secret: secret)
                }

                dataStore.saveVaultItem(vaultItem)
                result.importedCount += 1
            } catch {
                result.skippedCount += 1
            }
        }

        return result
    }

    // MARK: - AES-GCM 加密 / 解密

    private struct EncryptedEnvelope: Codable {
        var encrypted: Bool = true
        var salt: String        // Base64
        var nonce: String       // Base64
        var ciphertext: String  // Base64
    }

    private func deriveKey(password: String, salt: Data) -> SymmetricKey {
        let pwData = Data(password.utf8)
        let inputKey = SymmetricKey(data: SHA256.hash(data: pwData + salt))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            outputByteCount: 32
        )
    }

    private func encrypt(_ data: Data, password: String) throws -> Data {
        let salt  = generateRandom(bytes: 32)
        let key   = deriveKey(password: password, salt: salt)
        let sealed = try AES.GCM.seal(data, using: key)
        let envelope = EncryptedEnvelope(
            salt:       salt.base64EncodedString(),
            nonce:      sealed.nonce.withUnsafeBytes { Data($0) }.base64EncodedString(),
            ciphertext: sealed.ciphertext.base64EncodedString() + "." +
                        sealed.tag.base64EncodedString()
        )
        return try JSONEncoder().encode(envelope)
    }

    private func decrypt(_ data: Data, password: String) throws -> Data {
        guard let envelope = try? JSONDecoder().decode(EncryptedEnvelope.self, from: data),
              envelope.encrypted else { throw ImportExportError.invalidFormat }

        guard let salt      = Data(base64Encoded: envelope.salt),
              let nonceData = Data(base64Encoded: envelope.nonce) else {
            throw ImportExportError.invalidFormat
        }

        let parts = envelope.ciphertext.components(separatedBy: ".")
        guard parts.count == 2,
              let ciphertext = Data(base64Encoded: parts[0]),
              let tag        = Data(base64Encoded: parts[1]) else {
            throw ImportExportError.invalidFormat
        }

        let key   = deriveKey(password: password, salt: salt)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let box   = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)

        do {
            return try AES.GCM.open(box, using: key)
        } catch {
            throw ImportExportError.wrongPassword
        }
    }

    private func isEncrypted(_ data: Data) -> Bool {
        guard let envelope = try? JSONDecoder().decode(EncryptedEnvelope.self, from: data) else {
            return false
        }
        return envelope.encrypted
    }

    private func generateRandom(bytes count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }
}

// MARK: - CSV / URL 辅助

private extension String {
    var csvEscaped: String {
        if self.contains(",") || self.contains("\"") || self.contains("\n") {
            return "\"" + self.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return self
    }
    var urlEncoded: String {
        self.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}
