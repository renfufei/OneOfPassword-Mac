//
//  SettingsView.swift
//  OneOfPassword
//
//  设置页：导入 / 导出 / 数据信息
//

import SwiftUI
import UniformTypeIdentifiers

// .1pwd 文件类型
extension UTType {
    static let onePasswordBackup = UTType(exportedAs: "com.oneofpassword.backup")
}

struct SettingsView: View {
    var onNavigateToVault: (() -> Void)? = nil
    /// 从系统菜单触发的操作（由 ContentView 注入）
    var pendingAction: Binding<ContentView.SettingsAction?>? = nil

    @ObservedObject private var dataStore = DataStore.shared
    @ObservedObject private var authPolicy = AuthPolicy.shared

    // 导出
    @State private var showExportWizard = false

    // 导入
    @State private var showImportPanel          = false
    @State private var importPassword           = ""
    @State private var pendingImportURL: URL?
    @State private var showImportPasswordPrompt = false

    // 结果 / 错误提示
    @State private var alertTitle   = ""
    @State private var alertMessage = ""
    @State private var showAlert    = false

    private let service       = ImportExportService.shared
    private let onePUXService = OnePUXImporter.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                importExportSection
                dataInfoSection
                authSection
                storageSection
            }
            .padding(28)
        }
        .navigationTitle("设置")
        .frame(minWidth: 520)

        // ── 统一导入文件面板（自动识别 .1pux / .1pwd / .json）──
        .onChange(of: showImportPanel) { show in
            guard show else { return }
            showImportPanel = false
            DispatchQueue.main.async {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = false
                panel.canChooseDirectories = false
                panel.allowedFileTypes = ["1pux", "1pwd", "json"]
                panel.message = "选择要导入的文件（.1pux、.1pwd 或 .json）"
                panel.prompt = "导入"
                if panel.runModal() == .OK, let url = panel.url {
                    handleImportAny(url)
                }
            }
        }

        // ── 导出向导 ──
        .sheet(isPresented: $showExportWizard) {
            ExportWizardSheet { msg in
                alertTitle   = msg.hasPrefix("已保存") ? "导出成功" : "导出失败"
                alertMessage = msg
                showAlert    = true
            }
        }

        // ── 导入密码弹窗 ──
        .sheet(isPresented: $showImportPasswordPrompt) {
            importPasswordSheet
        }

        .alert(alertTitle, isPresented: $showAlert) {
            Button("确定", role: .cancel) {
                if alertTitle.contains("成功") {
                    onNavigateToVault?()
                }
            }
        } message: {
            Text(alertMessage)
        }
        .onChange(of: pendingAction?.wrappedValue) { action in
            guard let action else { return }
            pendingAction?.wrappedValue = nil
            switch action {
            case .export:                showExportWizard = true
            case .importBackup, .import1PUX: showImportPanel  = true
            }
        }
    }

    // MARK: - 导入 / 导出区块

    private var importExportSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Label("导入 / 导出", systemImage: "arrow.up.arrow.down.circle.fill")
                    .font(.headline)

                Text("导出文件完整包含所有密码和验证器（含明文密码），建议加密保存。导入时自动识别格式，重复条目自动跳过。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                // 导出
                importExportRow(
                    title: "导出备份",
                    subtitle: ".1pux 可导回 1Password；.1pwd 为加密私有格式",
                    buttonLabel: "导出…",
                    prominent: true
                ) { showExportWizard = true }

                Divider()

                // 导入（统一）
                importExportRow(
                    title: "导入",
                    subtitle: "支持 .1pux（1Password）、.1pwd（本应用备份）格式",
                    buttonLabel: "导入…"
                ) { showImportPanel = true }
            }
            .padding(8)
        }
    }

    private func importExportRow(title: String, subtitle: String,
                                 buttonLabel: String, prominent: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if prominent {
                Button(buttonLabel, action: action)
                    .buttonStyle(.primary())
            } else {
                Button(buttonLabel, action: action)
                    .buttonStyle(.secondary())
            }
        }
    }

    // MARK: - 数据统计区块

    private var dataInfoSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Label("数据统计", systemImage: "chart.bar.fill")
                    .font(.headline)

                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    GridRow {
                        statCell(icon: "key.fill",         color: .blue,   label: "密码",  count: dataStore.vaultItems.filter { $0.type == .password }.count)
                        statCell(icon: "shield.checkered", color: .green,  label: "验证器", count: dataStore.vaultItems.filter { $0.type == .totp }.count)
                        statCell(icon: "note.text",        color: .orange, label: "便签",  count: dataStore.noteItems.count)
                    }
                }
            }
            .padding(8)
        }
    }

    private func statCell(icon: String, color: Color, label: String, count: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count)").font(.title2.bold())
                Text(label).font(.caption).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.gray.opacity(0.07))
        .cornerRadius(8)
    }

    // MARK: - 安全验证区块

    private var authSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                Label("需要验证操作系统密码", systemImage: "lock.shield.fill")
                    .font(.headline)
                    .padding(.bottom, 10)

                Divider()
                authToggleRow(label: "导出备份",    isOn: $authPolicy.requireAuthForExport)
                Divider()
                authToggleRow(label: "打开存储位置", isOn: $authPolicy.requireAuthForFinder)
                Divider()
                authToggleRow(label: "删除条目",    isOn: $authPolicy.requireAuthForDelete)
            }
            .padding(8)
        }
    }

    private func authToggleRow(label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Toggle("", isOn: Binding(
                get: { isOn.wrappedValue },
                set: { newValue in
                    if newValue {
                        // 开启：直接设置，无需验证
                        isOn.wrappedValue = true
                    } else {
                        // 关闭：需要验证
                        authPolicy.authenticate(reason: "验证身份后关闭安全验证") {
                            isOn.wrappedValue = false
                        }
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(.vertical, 6)
    }

    // MARK: - 存储路径区块

    private var storageSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("存储位置", systemImage: "folder.fill")
                    .font(.headline)

                let dir = appSupportPath()
                pathRow(label: "数据目录",   path: dir,
                        subtitle: "vault.json · notes.json")
                pathRow(label: "密钥文件",   path: dir + "/secrets.enc",
                        subtitle: "加密存储的 Keychain 密钥")
            }
            .padding(8)
        }
    }

    private func pathRow(label: String, path: String, subtitle: String = "") -> some View {
        PathRow(label: label, path: path, subtitle: subtitle)
    }

    // MARK: - 导入密码 Sheet

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

    // MARK: - 动作

    /// 统一导入入口：按文件扩展名自动路由
    private func handleImportAny(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "1pux" {
            handleImport1PUX(url)
        } else {
            handleImportBackup(url)
        }
    }

    private func handleImport1PUX(_ url: URL) {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: tmpURL)
        do {
            try FileManager.default.copyItem(at: url, to: tmpURL)
        } catch {
            showError("导入失败", "无法读取文件：\(error.localizedDescription)"); return
        }
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            let result = try onePUXService.importFile(tmpURL)
            var lines: [String] = []
            if result.importedCount > 0 { lines.append("导入条目：\(result.importedCount) 条") }
            if result.skippedCount > 0  { lines.append("跳过重复：\(result.skippedCount) 条") }
            alertTitle   = "导入成功"
            alertMessage = lines.isEmpty ? "没有新数据" : lines.joined(separator: "\n")
            showAlert    = true
        } catch {
            showError("导入失败", error.localizedDescription)
        }
    }

    private func handleImportBackup(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            showError("导入失败", "无法读取文件"); return
        }
        if isEncryptedData(data) {
            pendingImportURL = url
            importPassword = ""
            showImportPasswordPrompt = true
        } else {
            performImportBackup(url: url, password: nil)
        }
    }

    private func performImportBackup(url: URL, password: String?) {
        guard let data = try? Data(contentsOf: url) else {
            showError("导入失败", "无法读取文件"); return
        }
        do {
            let result = try service.importData(data, password: password)
            pendingImportURL = nil
            var lines: [String] = []
            if result.importedCount > 0 { lines.append("导入条目：\(result.importedCount) 条") }
            if result.skippedCount > 0  { lines.append("跳过重复：\(result.skippedCount) 条") }
            alertTitle   = "导入成功"
            alertMessage = lines.isEmpty ? "没有新数据" : lines.joined(separator: "\n")
            showAlert    = true
        } catch ImportExportError.wrongPassword {
            showError("密码错误", "请检查导入密码后重试")
        } catch {
            showError("导入失败", error.localizedDescription)
        }
    }

    // MARK: - 工具方法

    private func isEncryptedData(_ data: Data) -> Bool {
        struct Probe: Decodable { var encrypted: Bool }
        return (try? JSONDecoder().decode(Probe.self, from: data))?.encrypted == true
    }

    private func showError(_ title: String, _ message: String) {
        alertTitle   = title
        alertMessage = message
        showAlert    = true
    }

    private func appSupportPath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("com.oneofpassword.app").path
    }
}

// MARK: - PathRow

private struct PathRow: View {
    let label: String
    let path: String
    let subtitle: String

    @State private var showWarning = false
    private let authPolicy = AuthPolicy.shared

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .foregroundColor(.secondary)
                    .frame(width: 100, alignment: .leading)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                        .frame(width: 100, alignment: .leading)
                }
            }
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            Spacer()
            Button {
                showWarning = true
            } label: {
                Image(systemName: "arrow.right.circle")
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示")
            .confirmationDialog(
                "打开存储位置",
                isPresented: $showWarning,
                titleVisibility: .visible
            ) {
                Button("继续打开") { authenticatedOpen() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此目录包含应用的所有数据文件。请勿删除或修改其中的文件，否则可能导致数据丢失。")
            }
        }
    }

    private func authenticatedOpen() {
        guard !authPolicy.requireAuthForFinder else {
            authPolicy.authenticate(reason: "验证身份后打开存储位置") { openInFinder() }
            return
        }
        openInFinder()
    }

    private func openInFinder() {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}

// MARK: - FileDocument（用于 fileExporter）

struct JSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.onePasswordBackup, .json] }

    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
