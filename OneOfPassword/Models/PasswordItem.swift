//
//  PasswordItem.swift
//  OneOfPassword
//
//  统一保险库条目数据模型
//

import Foundation

// MARK: - 额外密码（一个条目可有多个密码，各自带标签）

struct ExtraPassword: Identifiable, Codable, Equatable {
    let id: UUID
    var label: String       // 为空时显示"密码"
    var keychainId: String

    init(id: UUID = UUID(), label: String = "密码", keychainId: String = UUID().uuidString) {
        self.id = id
        self.label = label
        self.keychainId = keychainId
    }
}

// MARK: - 额外 TOTP（一个密码条目可关联多个验证器）

struct ExtraTOTP: Identifiable, Codable, Equatable {
    let id: UUID
    var label: String          // 字段名，如 "One-Time Password"
    var issuer: String?
    var accountName: String
    var digits: Int
    var period: Int
    var keychainId: String     // TOTP secret 存储在 Keychain

    init(id: UUID = UUID(), label: String, issuer: String? = nil,
         accountName: String = "", digits: Int = 6, period: Int = 30,
         keychainId: String = UUID().uuidString) {
        self.id = id
        self.label = label
        self.issuer = issuer
        self.accountName = accountName
        self.digits = digits
        self.period = period
        self.keychainId = keychainId
    }
}

// MARK: - 自定义字段

struct CustomField: Identifiable, Codable, Equatable {
    let id: UUID
    var label: String
    var value: String               // 非加密字段的值；isConcealed=true 时存空字符串
    var isConcealed: Bool
    var concealedKeychainId: String? // isConcealed=true 时从 KeychainService 读取
    /// 原始 1pux 字段类型 key（如 "string", "concealed", "date", "address", "phone", "url"）
    /// nil 表示手动新建的字段（无来源类型）
    var rawType: String?

    init(id: UUID = UUID(), label: String, value: String,
         isConcealed: Bool = false, concealedKeychainId: String? = nil, rawType: String? = nil) {
        self.id = id
        self.label = label
        self.value = value
        self.isConcealed = isConcealed
        self.concealedKeychainId = concealedKeychainId
        self.rawType = rawType
    }
}

// MARK: - 内联便签（属于某个保险库条目）

struct VaultNote: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var content: String
    var isPinned: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "",
        content: String = "",
        isPinned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        return content.components(separatedBy: .newlines).first(where: { !$0.isEmpty }) ?? "无标题"
    }

    var displaySummary: String {
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        if title.isEmpty { return lines.dropFirst().joined(separator: " ") }
        return lines.joined(separator: " ")
    }
}

// MARK: - VaultItem 类型

enum VaultItemType: String, Codable {
    case password   // 密码条目
    case totp       // 纯 TOTP 验证器
}

// MARK: - 统一保险库条目

struct VaultItem: Identifiable, Codable, Equatable {
    let id: UUID
    var type: VaultItemType
    var title: String
    var isFavorite: Bool
    var createdAt: Date
    var updatedAt: Date
    var sourceId: String?         // 导入去重

    // .password 字段（type==.totp 时这些字段为空/nil）
    var username: String
    var website: String?
    var notes: String?
    var vaultNotes: [VaultNote]
    var category: ItemCategory?
    var keychainId: String        // 存密码（totp 条目存空字符串）
    var customFields: [CustomField]

    // TOTP 字段（type==.totp 时必填；type==.password 时 totpKeychainId!=nil 表示内嵌 TOTP）
    var totpIssuer: String?
    var totpAccountName: String   // default ""
    var totpLabel: String         // default ""
    var totpDigits: Int           // default 6
    var totpPeriod: Int           // default 30
    var totpKeychainId: String?   // nil = 无 TOTP
    var extraTOTPs: [ExtraTOTP]   // 额外验证器（第2个起）
    var extraPasswords: [ExtraPassword]  // 额外密码（第2个起）

    init(
        id: UUID = UUID(),
        type: VaultItemType = .password,
        title: String,
        isFavorite: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sourceId: String? = nil,
        username: String = "",
        website: String? = nil,
        notes: String? = nil,
        vaultNotes: [VaultNote] = [],
        category: ItemCategory? = nil,
        keychainId: String = UUID().uuidString,
        customFields: [CustomField] = [],
        totpIssuer: String? = nil,
        totpAccountName: String = "",
        totpLabel: String = "",
        totpDigits: Int = 6,
        totpPeriod: Int = 30,
        totpKeychainId: String? = nil,
        extraTOTPs: [ExtraTOTP] = [],
        extraPasswords: [ExtraPassword] = []
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceId = sourceId
        self.username = username
        self.website = website
        self.notes = notes
        self.vaultNotes = vaultNotes
        self.category = category
        self.keychainId = keychainId
        self.customFields = customFields
        self.totpIssuer = totpIssuer
        self.totpAccountName = totpAccountName
        self.totpLabel = totpLabel
        self.totpDigits = totpDigits
        self.totpPeriod = totpPeriod
        self.totpKeychainId = totpKeychainId
        self.extraTOTPs = extraTOTPs
        self.extraPasswords = extraPasswords
    }

    // 兼容旧数据：所有可选字段用 decodeIfPresent，提供合理默认值
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id               = try c.decode(UUID.self,              forKey: .id)
        type             = (try? c.decode(VaultItemType.self,   forKey: .type))           ?? .password
        title            = try c.decode(String.self,            forKey: .title)
        isFavorite       = (try? c.decode(Bool.self,            forKey: .isFavorite))     ?? false
        createdAt        = (try? c.decode(Date.self,            forKey: .createdAt))      ?? Date()
        updatedAt        = (try? c.decode(Date.self,            forKey: .updatedAt))      ?? Date()
        sourceId         = try? c.decodeIfPresent(String.self,  forKey: .sourceId)
        username         = (try? c.decode(String.self,          forKey: .username))       ?? ""
        website          = try? c.decodeIfPresent(String.self,  forKey: .website)
        notes            = try? c.decodeIfPresent(String.self,  forKey: .notes)
        vaultNotes       = (try? c.decode([VaultNote].self,     forKey: .vaultNotes))     ?? []
        category         = try? c.decodeIfPresent(ItemCategory.self, forKey: .category)
        keychainId       = (try? c.decode(String.self,          forKey: .keychainId))     ?? ""
        customFields     = (try? c.decode([CustomField].self,   forKey: .customFields))   ?? []
        totpIssuer       = try? c.decodeIfPresent(String.self,     forKey: .totpIssuer)
        totpAccountName  = (try? c.decode(String.self,             forKey: .totpAccountName)) ?? ""
        totpLabel        = (try? c.decode(String.self,             forKey: .totpLabel))       ?? ""
        totpDigits       = (try? c.decode(Int.self,                forKey: .totpDigits))      ?? 6
        totpPeriod       = (try? c.decode(Int.self,                forKey: .totpPeriod))      ?? 30
        totpKeychainId   = try? c.decodeIfPresent(String.self,     forKey: .totpKeychainId)
        extraTOTPs       = (try? c.decode([ExtraTOTP].self,        forKey: .extraTOTPs))      ?? []
        extraPasswords   = (try? c.decode([ExtraPassword].self,   forKey: .extraPasswords))  ?? []
    }
}
