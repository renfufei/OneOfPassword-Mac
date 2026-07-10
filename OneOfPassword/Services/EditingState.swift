//
//  EditingState.swift
//  OneOfPassword
//
//  全局编辑状态，供 AppDelegate 在退出前检查
//

import Foundation

class EditingState {
    static let shared = EditingState()
    private init() {}

    var isEditing = false
}
