//
//  ItemCategory.swift
//  OneOfPassword
//
//  分类枚举
//

import Foundation

enum ItemCategory: String, Codable, CaseIterable {
    case general = "通用"
    case work = "工作"
    case personal = "个人"
    case finance = "金融"
    case social = "社交"
    case shopping = "购物"
    case other = "其他"

    var displayName: String {
        return self.rawValue
    }
}
