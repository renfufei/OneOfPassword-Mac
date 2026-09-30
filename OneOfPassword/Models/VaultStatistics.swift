//
//  VaultStatistics.swift
//  OneOfPassword
//
//  保险库统计的**唯一口径**。设置页「数据统计」与导出向导共用同一份计算，
//  避免同一个数字在两处各算一遍、口径还不一致。
//
//  === 为什么单独抽出来（2026-09-30）===
//  设置页此前各自就地写过滤条件：
//      dataStore.vaultItems.filter { $0.type == .totp }.count   // 当作「验证器」
//      dataStore.noteItems.count                                // 当作「便签」
//  结果两者在真实数据上都恒为 0，被用户指出「没有进行真正的统计」。根因不是显示，
//  而是**口径残缺** —— 本应用的 TOTP 与便签各有多种存在形式：
//
//    TOTP：① 独立验证器条目（type == .totp）
//          ② 密码条目内嵌的主验证器（totpKeychainId != nil）
//          ③ 密码条目的额外验证器（extraTOTPs，一个条目可挂多个）
//    便签：① 独立便签（noteItems / notes.json）
//          ② 挂在条目下的内联便签（VaultItem.vaultNotes）
//
//  用户库里实际有 9 个内嵌验证器 + 7 个额外验证器 + 4 条内联便签，
//  只数 ① 这一种，于是「验证器 0、便签 0」。
//
//  === 一个必须互斥的坑 ===
//  纯 `.totp` 条目的 `totpKeychainId` **同样非 nil**：`ItemDetailView.save()`
//  对两种类型都写这个字段（`totpKeychainId: hasTOTP ? ... : nil`）。
//  所以主验证器只能按「type == .totp ? 1 : (totpKeychainId != nil ? 1 : 0)」二选一计数，
//  写成 `type == .totp` 与 `totpKeychainId != nil` 两次累加，纯验证器条目会被算两遍。
//

import Foundation

struct VaultStatistics {
    /// 条目总数 = 密码条目 + 纯验证器条目
    let itemCount: Int
    /// 密码条目数（type == .password）
    let loginCount: Int
    /// 纯验证器条目数（type == .totp）
    let totpItemCount: Int
    /// 验证器密钥总数 = 独立验证器 + 内嵌主验证器 + 额外验证器
    let totpCount: Int
    /// 内嵌主验证器个数（密码条目上的 totpKeychainId）
    let embeddedTotpCount: Int
    /// 额外验证器个数（extraTOTPs 合计）
    let extraTotpCount: Int
    /// 含验证器的条目数（与 totpCount 不同：一个条目可能挂多个验证器）
    let totpHostCount: Int
    /// 便签总数 = 独立便签 + 条目内联便签
    let noteCount: Int
    /// 独立便签数
    let standaloneNoteCount: Int
    /// 条目内联便签数
    let inlineNoteCount: Int
    /// 收藏条目数
    let favoriteCount: Int
    /// 数据目录占用字节数（vault.json + notes.json + secrets.enc）
    let storageBytes: Int64
    /// 最近一次修改时间（条目与便签的 updatedAt 取最大）
    let lastUpdated: Date?

    static let empty = VaultStatistics(
        itemCount: 0, loginCount: 0, totpItemCount: 0, totpCount: 0,
        embeddedTotpCount: 0, extraTotpCount: 0, totpHostCount: 0,
        noteCount: 0, standaloneNoteCount: 0, inlineNoteCount: 0, favoriteCount: 0,
        storageBytes: 0, lastUpdated: nil
    )

    // MARK: - 计算

    /// 唯一的统计入口。纯函数，便于离线逐值校验。
    static func compute(items: [VaultItem],
                        notes: [NoteItem],
                        storageBytes: Int64) -> VaultStatistics {
        var loginCount    = 0
        var totpItems     = 0
        var embeddedTOTPs = 0
        var extraTOTPs    = 0
        var totpHosts     = 0
        var inlineNotes   = 0
        var favorites     = 0
        var lastUpdated: Date?

        for item in items {
            if item.type == .totp {
                totpItems += 1
            } else {
                loginCount += 1
                if item.totpKeychainId != nil { embeddedTOTPs += 1 }
            }
            if item.isFavorite { favorites += 1 }
            inlineNotes += item.vaultNotes.count

            // 一个条目上的验证器密钥数：纯验证器条目算 1，密码条目看内嵌 + 额外
            let onThisItem = (item.type == .totp ? 1 : (item.totpKeychainId != nil ? 1 : 0))
                + item.extraTOTPs.count
            if onThisItem > 0 { totpHosts += 1 }
            extraTOTPs += item.extraTOTPs.count

            lastUpdated = max(lastUpdated ?? item.updatedAt, item.updatedAt)
        }

        for note in notes {
            lastUpdated = max(lastUpdated ?? note.updatedAt, note.updatedAt)
        }

        return VaultStatistics(
            itemCount: items.count,
            loginCount: loginCount,
            totpItemCount: totpItems,
            totpCount: totpItems + embeddedTOTPs + extraTOTPs,
            embeddedTotpCount: embeddedTOTPs,
            extraTotpCount: extraTOTPs,
            totpHostCount: totpHosts,
            noteCount: notes.count + inlineNotes,
            standaloneNoteCount: notes.count,
            inlineNoteCount: inlineNotes,
            favoriteCount: favorites,
            storageBytes: storageBytes,
            lastUpdated: lastUpdated
        )
    }

    // MARK: - 文案

    /// 「验证器」格子的口径说明：数字和条目数对不上时，用户最容易怀疑统计错了，
    /// 所以直接把构成写出来。
    var totpBreakdownText: String {
        var parts: [String] = []
        if totpItemCount > 0      { parts.append("独立验证器条目 \(totpItemCount) 个") }
        if embeddedTotpCount > 0  { parts.append("条目内嵌 \(embeddedTotpCount) 个") }
        if extraTotpCount > 0     { parts.append("额外验证器 \(extraTotpCount) 个") }
        guard !parts.isEmpty else { return "暂无验证器。" }
        return "验证器密钥总数：\(parts.joined(separator: " + "))，分布在 \(totpHostCount) 个条目里。"
    }

    /// 便签格子的口径说明
    var noteBreakdownText: String {
        if inlineNoteCount == 0 { return "独立便签 \(standaloneNoteCount) 条。" }
        return "独立便签 \(standaloneNoteCount) 条 + 条目内便签 \(inlineNoteCount) 条。"
    }

    /// 存储占用的可读文本（KB / MB 自动切换）。
    /// 0 字节要特判：`ByteCountFormatter` 对 0 会输出英文 "Zero KB"，中文界面里很突兀。
    var storageText: String {
        guard storageBytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file)
    }
}
