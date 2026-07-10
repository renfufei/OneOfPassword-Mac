//
//  AppDelegate.swift
//  OneOfPassword
//

import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard EditingState.shared.isEditing else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "有未保存的编辑"
        alert.informativeText = "当前有未保存的修改，退出后将丢失这些内容。"
        alert.addButton(withTitle: "放弃编辑并退出")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning

        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
