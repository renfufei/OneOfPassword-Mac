//
//  ContentView.swift
//  OneOfPassword
//
//  3 列式主视图
//

import SwiftUI
import UniformTypeIdentifiers

enum SidebarSection: String, Hashable {
    case vault, settings, screenshot
}

struct ContentView: View {
    @State private var selectedSection: SidebarSection? = .vault
    @State private var selectedItem: VaultItem?
    /// 第三列模式：nil = 占位符，true = 编辑/新增（item==nil 为新增）
    @State private var isEditing = false
    @StateObject private var vm = VaultListViewModel()

    // 菜单触发的导入/导出动作（传递给 SettingsView）
    @State private var menuTrigger: SettingsAction? = nil

    // 菜单导出
    @State private var showExportWizard   = false

    // 菜单导入（直接在主窗口处理，无需跳转设置页）
    @State private var importAlertTitle   = ""
    @State private var importAlertMessage = ""
    @State private var showImportAlert    = false
    @State private var importPassword     = ""
    @State private var pendingImportURL: URL?
    @State private var showImportPasswordPrompt = false

    private let importService   = ImportExportService.shared
    private let onePUXService   = OnePUXImporter.shared

    enum SettingsAction { case export, importBackup, import1PUX }

    var body: some View {
        Group {
            if selectedSection == .settings {
                NavigationSplitView {
                    sidebar
                } detail: {
                    SettingsView(
                        onNavigateToVault: { selectedSection = .vault },
                        pendingAction: $menuTrigger
                    )
                }
            } else if selectedSection == .screenshot {
                NavigationSplitView {
                    sidebar
                } detail: {
                    ScreenshotSettingsView()
                }
            } else {
                NavigationSplitView {
                    sidebar
                } content: {
                    VaultListView(
                        selectedItem: $selectedItem,
                        onAddItem: {
                            selectedItem = nil
                            DispatchQueue.main.async { isEditing = true }
                        },
                        onDelete: { item in
                            if selectedItem?.id == item.id { selectedItem = nil }
                            vm.deleteItem(item)
                        }
                    )
                    .navigationSplitViewColumnWidth(min: 200, ideal: 308, max: 392)
                } detail: {
                    detailColumn
                }
            }
        }
        .frame(minWidth: 1250, minHeight: 780)
        .onChange(of: selectedSection) { _ in
            selectedItem = nil
            isEditing = false
        }
        .onChange(of: selectedItem) { _ in
            isEditing = false
        }
        .onChange(of: isEditing) { newValue in
            EditingState.shared.isEditing = newValue
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuExport)) { _ in
            showExportWizard = true
        }
        .sheet(isPresented: $showExportWizard) {
            ExportWizardSheet { _ in }
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuImport)) { _ in
            openImportPanel()
        }
        .sheet(isPresented: $showImportPasswordPrompt) {
            importPasswordSheet
        }
        .alert(importAlertTitle, isPresented: $showImportAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(importAlertMessage)
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuNewItem)) { _ in
            selectedSection = .vault
            selectedItem = nil
            DispatchQueue.main.async { isEditing = true }
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if isEditing {
            ItemDetailView(
                vm: vm,
                item: selectedItem,
                onDismiss: {
                    isEditing = false
                    // 如果是新增，取消后回到占位符
                    if selectedItem == nil { }
                },
                onSaved: { savedItem in
                    isEditing = false
                    selectedItem = savedItem
                }
            )
        } else if let item = selectedItem {
            VaultItemPreviewView(
                item: item,
                onDelete: { selectedItem = nil; vm.deleteItem(item) },
                onEdit: { isEditing = true },
                vm: vm
            )
            .id(item.id)
        } else {
            vaultPlaceholder
        }
    }

    private var sidebar: some View {
        List(selection: $selectedSection) {
            Label("保险库", systemImage: "person.badge.key.fill").tag(SidebarSection.vault)
            Label("截屏",   systemImage: "crop").tag(SidebarSection.screenshot)
            Label("设置",   systemImage: "gearshape.fill").tag(SidebarSection.settings)
        }
        .navigationTitle("OneOfPassword")
        .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 200)
    }

    private var vaultPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 56))
                .foregroundColor(.secondary)
            Text("选择条目查看详情")
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 导入逻辑

    private func openImportPanel() {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.allowedContentTypes = [
                .commaSeparatedText,
                UTType(filenameExtension: "1pux") ?? .data,
                UTType(filenameExtension: "1pwd") ?? .data,
                .json
            ]
            panel.message = "选择要导入的文件（.1pux、.1pwd、.json 或 .csv）"
            panel.prompt = "导入"
            if panel.runModal() == .OK, let url = panel.url {
                handleImportAny(url)
            }
        }
    }

    private func handleImportAny(_ url: URL) {
        switch url.pathExtension.lowercased() {
        case "1pux": handleImport1PUX(url)
        case "csv":  handleImportCSV(url)
        default:     handleImportBackup(url)
        }
    }

    private func handleImportCSV(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            showImportError("导入失败", "无法读取文件"); return
        }
        do {
            let result = try importService.importCSV(data)
            var lines: [String] = []
            if result.importedCount > 0 { lines.append("导入条目：\(result.importedCount) 条") }
            if result.skippedCount > 0  { lines.append("跳过重复：\(result.skippedCount) 条") }
            importAlertTitle   = "导入成功"
            importAlertMessage = lines.isEmpty ? "没有新数据" : lines.joined(separator: "\n")
            showImportAlert    = true
        } catch {
            showImportError("导入失败", error.localizedDescription)
        }
    }

    private func handleImport1PUX(_ url: URL) {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: tmpURL)
        do { try FileManager.default.copyItem(at: url, to: tmpURL) } catch {
            showImportError("导入失败", "无法读取文件：\(error.localizedDescription)"); return
        }
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        do {
            let result = try onePUXService.importFile(tmpURL)
            var lines: [String] = []
            if result.importedCount > 0 { lines.append("导入条目：\(result.importedCount) 条") }
            if result.skippedCount > 0  { lines.append("跳过重复：\(result.skippedCount) 条") }
            importAlertTitle   = "导入成功"
            importAlertMessage = lines.isEmpty ? "没有新数据" : lines.joined(separator: "\n")
            showImportAlert    = true
        } catch {
            showImportError("导入失败", error.localizedDescription)
        }
    }

    private func handleImportBackup(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            showImportError("导入失败", "无法读取文件"); return
        }
        struct Probe: Decodable { var encrypted: Bool }
        if (try? JSONDecoder().decode(Probe.self, from: data))?.encrypted == true {
            pendingImportURL = url
            importPassword = ""
            showImportPasswordPrompt = true
        } else {
            performImportBackup(url: url, password: nil)
        }
    }

    private func performImportBackup(url: URL, password: String?) {
        guard let data = try? Data(contentsOf: url) else {
            showImportError("导入失败", "无法读取文件"); return
        }
        do {
            let result = try importService.importData(data, password: password)
            pendingImportURL = nil
            var lines: [String] = []
            if result.importedCount > 0 { lines.append("导入条目：\(result.importedCount) 条") }
            if result.skippedCount > 0  { lines.append("跳过重复：\(result.skippedCount) 条") }
            importAlertTitle   = "导入成功"
            importAlertMessage = lines.isEmpty ? "没有新数据" : lines.joined(separator: "\n")
            showImportAlert    = true
        } catch ImportExportError.wrongPassword {
            showImportError("密码错误", "请检查导入密码后重试")
        } catch {
            showImportError("导入失败", error.localizedDescription)
        }
    }

    private func showImportError(_ title: String, _ message: String) {
        importAlertTitle   = title
        importAlertMessage = message
        showImportAlert    = true
    }

    private var importPasswordSheet: some View {
        VStack(spacing: 20) {
            Text("文件已加密").font(.title2).fontWeight(.semibold)
            Text("此备份文件设置了密码，请输入密码后导入。")
                .font(.subheadline).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            SecureField("导入密码", text: $importPassword)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                Button("取消") {
                    showImportPasswordPrompt = false
                    pendingImportURL = nil
                }
                .buttonStyle(.secondary())
                Button("导入") {
                    showImportPasswordPrompt = false
                    if let url = pendingImportURL {
                        performImportBackup(url: url, password: importPassword)
                    }
                }
                .buttonStyle(.primary(disabled: importPassword.isEmpty))
                .disabled(importPassword.isEmpty)
            }
        }
        .padding(28)
        .frame(width: 320)
    }
}

#if DEBUG
/// 用传统 PreviewProvider 代替 #Preview 宏：
/// Xcode 26 的 swift-plugin-server 宏展开在本地环境不稳定（malformed response），会阻塞构建。
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
#endif
