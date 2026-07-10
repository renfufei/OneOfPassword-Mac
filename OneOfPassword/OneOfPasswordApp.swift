//
//  OneOfPasswordApp.swift
//  OneOfPassword
//

import SwiftUI

extension Notification.Name {
    static let menuExport    = Notification.Name("menuExport")
    static let menuImport    = Notification.Name("menuImport")
    static let menuNewItem   = Notification.Name("menuNewItem")
}

@main
struct OneOfPasswordApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    // 禁用系统自动添加的新建标签页按钮
                    NSWindow.allowsAutomaticWindowTabbing = false
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // 替换系统"新建"位置，插入自定义条目，使"文件"菜单靠前
            CommandGroup(replacing: .newItem) {
                Button("添加新条目") {
                    NotificationCenter.default.post(name: .menuNewItem, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Divider()

                Button("导入…") {
                    NotificationCenter.default.post(name: .menuImport, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button("导出备份…") {
                    NotificationCenter.default.post(name: .menuExport, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }

        // ⌘, 打开设置窗口
        Settings {
            SettingsView()
                .frame(minWidth: 520, minHeight: 400)
        }
    }
}
