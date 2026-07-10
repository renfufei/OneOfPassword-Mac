//
//  NoteItem.swift
//  OneOfPassword
//

import Foundation

struct NoteItem: Identifiable, Codable {
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

    /// 列表里显示的标题：优先用 title，否则取正文第一行
    var displayTitle: String {
        if !title.isEmpty { return title }
        return content.components(separatedBy: .newlines).first(where: { !$0.isEmpty }) ?? "无标题"
    }

    /// 列表里显示的摘要（跳过第一行）
    var displaySummary: String {
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        if title.isEmpty {
            return lines.dropFirst().joined(separator: " ")
        }
        return lines.joined(separator: " ")
    }
}
