//
//  ExportWizardSheet.swift
//  OneOfPassword
//
//  导出向导（三步）：选格式 → 加密设置 → 确认导出
//

import SwiftUI
import UniformTypeIdentifiers

struct ExportWizardSheet: View {
    var onDone: ((String) -> Void)?  // 传回结果描述（成功/失败），nil = 取消

    @Environment(\.dismiss) private var dismiss

    // 向导步骤（1pux 跳过 encryption）
    private enum Step { case format, encryption, confirm }
    @State private var step: Step = .format

    private func nextStep(after current: Step) -> Step {
        switch current {
        case .format:     return format == .onePWD ? .encryption : .confirm
        case .encryption: return .confirm
        case .confirm:    return .confirm
        }
    }

    private func prevStep(before current: Step) -> Step {
        switch current {
        case .format:     return .format
        case .encryption: return .format
        case .confirm:    return format == .onePWD ? .encryption : .format
        }
    }

    private var needsEncryptionStep: Bool { format == .onePWD }

    // 步骤1：格式
    private enum ExportFormat: String, CaseIterable, Identifiable {
        case onePUX = "1pux"
        case onePWD = "1pwd"
        case csv    = "csv"
        var id: String { rawValue }
    }
    @State private var format: ExportFormat = .onePUX

    // 步骤2：加密
    @State private var usePassword = false
    @State private var password    = ""
    @State private var confirm     = ""
    @State private var showPwd     = false
    @State private var showConfirm = false

    private let service = ImportExportService.shared
    private let dataStore = DataStore.shared
    private let authPolicy = AuthPolicy.shared

    // 数据摘要（用于步骤3展示）。口径统一走 `VaultStatistics`（唯一真相）：
    // 原先就地写 `filter { $0.type == .totp }`，漏掉了"密码条目内嵌的验证器"，
    // 于是导出摘要里的验证器数量恒为 0（与设置页同一个 bug）。
    private var stats: VaultStatistics { dataStore.statistics }

    private var passwordMismatch: Bool {
        !password.isEmpty && !confirm.isEmpty && password != confirm
    }
    private var encryptionReady: Bool {
        !usePassword || (!password.isEmpty && password == confirm)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部进度指示
            stepIndicator
                .padding(.top, 24)
                .padding(.bottom, 20)

            Divider()

            // 步骤内容
            Group {
                switch step {
                case .format:     formatStep
                case .encryption: encryptionStep
                case .confirm:    confirmStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // 底部导航按钮
            navigationBar
                .padding(20)
        }
        .frame(width: 480)
        .frame(minHeight: 420)
    }

    // MARK: - 进度指示器

    private var stepIndicator: some View {
        let steps = needsEncryptionStep
            ? [(1, "格式"), (2, "加密"), (3, "导出")]
            : [(1, "格式"), (2, "导出")]
        return HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.0) { idx, item in
                let (num, label) = item
                let isActive  = stepIndex >= num - 1
                let isCurrent = stepIndex == num - 1

                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.2))
                            .frame(width: 26, height: 26)
                        Text("\(num)")
                            .font(.caption.bold())
                            .foregroundColor(isActive ? .white : .secondary)
                    }
                    Text(label)
                        .font(.subheadline)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .foregroundColor(isCurrent ? .primary : .secondary)
                }

                if idx < steps.count - 1 {
                    Rectangle()
                        .fill(stepIndex > idx ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(height: 1.5)
                        .padding(.horizontal, 8)
                }
            }
        }
        .padding(.horizontal, 40)
    }

    private var stepIndex: Int {
        if needsEncryptionStep {
            switch step {
            case .format:     return 0
            case .encryption: return 1
            case .confirm:    return 2
            }
        }
        return step == .format ? 0 : 1
    }

    // MARK: - 步骤1：选择格式

    private var formatStep: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("选择导出格式").font(.title3).fontWeight(.semibold)
                .padding(.top, 4)

            ForEach(ExportFormat.allCases) { fmt in
                Button { format = fmt } label: {
                    HStack(spacing: 14) {
                        Image(systemName: format == fmt ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundColor(format == fmt ? .accentColor : .secondary)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(fmt == .onePUX ? ".1pux" : fmt == .onePWD ? ".1pwd" : ".csv")
                                    .font(.headline)
                                if fmt == .onePUX {
                                    Text("推荐").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.15))
                                        .foregroundColor(.accentColor)
                                        .cornerRadius(4)
                                }
                            }
                            Text(fmt == .onePUX
                                 ? "1Password 兼容格式（ZIP），可直接导入 1Password。文件内容为明文。"
                                 : fmt == .onePWD
                                     ? "OneOfPassword 专有格式，AES-GCM 加密保护，需密码才能导入。"
                                     : "通用 CSV 格式，兼容 1Password 等密码管理器。文件内容为明文。")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(format == fmt
                                  ? Color.accentColor.opacity(0.08)
                                  : Color.secondary.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(format == fmt ? Color.accentColor : Color.clear, lineWidth: 1.5)
                            )
                    )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(24)
    }

    // MARK: - 步骤2：加密设置

    private var encryptionStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("加密设置").font(.title3).fontWeight(.semibold)
                .padding(.top, 4)

            if format == .onePWD {
                // .1pwd 必须加密
                Label(".1pwd 格式采用 AES-GCM 强制加密，必须设置密码。", systemImage: "lock.fill")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(10)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(8)
                encryptionFields
            } else {
                // .1pux 加密可选
                Toggle(isOn: $usePassword) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("加密保护（可选）")
                        Text("关闭则导出明文 .1pux，任何人均可直接读取")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(12)
                .background(Color.secondary.opacity(0.06))
                .cornerRadius(8)

                if usePassword {
                    encryptionFields
                } else {
                    Label("不加密：文件内容为明文，与 1Password 导出格式一致。", systemImage: "lock.open")
                        .font(.caption).foregroundColor(.secondary)
                        .padding(.top, 4)
                }
            }

            Spacer()
        }
        .padding(24)
        .onAppear {
            // .1pwd 强制开启加密
            if format == .onePWD { usePassword = true }
        }
    }

    @ViewBuilder
    private var encryptionFields: some View {
        VStack(spacing: 10) {
            HStack {
                Group {
                    if showPwd { TextField("密码", text: $password) }
                    else       { SecureField("密码", text: $password) }
                }
                .textFieldStyle(.roundedBorder)
                Button { showPwd.toggle() } label: {
                    Image(systemName: showPwd ? "eye.slash" : "eye")
                }
                .buttonStyle(.iconCircle(tint: .secondary, size: 26))
            }
            HStack {
                Group {
                    if showConfirm { TextField("确认密码", text: $confirm) }
                    else           { SecureField("确认密码", text: $confirm) }
                }
                .textFieldStyle(.roundedBorder)
                Button { showConfirm.toggle() } label: {
                    Image(systemName: showConfirm ? "eye.slash" : "eye")
                }
                .buttonStyle(.iconCircle(tint: .secondary, size: 26))
            }
            if passwordMismatch {
                Label("两次密码不一致", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.red)
            }
        }
    }

    // MARK: - 步骤3：确认

    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("确认导出").font(.title3).fontWeight(.semibold)
                .padding(.top, 4)

            // 摘要卡片
            VStack(spacing: 0) {
                summaryRow(icon: "doc.badge.arrow.up", label: "格式",
                           value: format == .onePUX ? ".1pux（1Password 兼容）"
                               : format == .onePWD ? ".1pwd（专有加密）"
                               : ".csv（通用表格）")
                Divider().padding(.leading, 36)
                summaryRow(icon: (format == .onePWD) ? "lock.fill" : "lock.open",
                           label: "加密",
                           value: (format == .onePWD) ? "已加密（AES-GCM）" : "未加密")
                Divider().padding(.leading, 36)
                summaryRow(icon: "key.fill", label: "密码条目", value: "\(stats.loginCount) 条")
                Divider().padding(.leading, 36)
                summaryRow(icon: "shield.checkered", label: "验证器", value: "\(stats.totpCount) 条")
            }
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(10)

            if format == .onePWD {
                Label("文件已使用您设置的密码加密，妥善保管该密码，丢失后将无法恢复。",
                      systemImage: "lock.shield")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Label("导出文件未加密，任何人均可直接读取其中的密码，请妥善保管。",
                      systemImage: "exclamationmark.shield")
                    .font(.caption).foregroundColor(.orange)
            }

            Spacer()
        }
        .padding(24)
    }

    private func summaryRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundColor(.accentColor)
                .padding(.leading, 12)
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
                .padding(.trailing, 12)
        }
        .padding(.vertical, 10)
    }

    // MARK: - 导航栏

    private var navigationBar: some View {
        HStack(spacing: 10) {
            Button("取消") { dismiss() }
                .buttonStyle(.secondaryDestructive())
                .frame(maxWidth: .infinity)

            if step != .format {
                Button("上一步") { goBack() }
                    .buttonStyle(.secondary())
                    .frame(maxWidth: .infinity)
            }

            if step == .confirm {
                Button {
                    runExport()
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.primary())
                .frame(maxWidth: .infinity)
            } else {
                let nextDisabled = step == .encryption && !encryptionReady
                Button("下一步 →") { goNext() }
                    .buttonStyle(.primary(disabled: nextDisabled))
                    .disabled(nextDisabled)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - 步骤导航

    private func goNext() {
        step = nextStep(after: step)
    }

    private func goBack() {
        let prev = prevStep(before: step)
        if prev == .format { password = ""; confirm = "" }
        step = prev
    }

    // MARK: - 执行导出

    private func runExport() {
        guard !authPolicy.requireAuthForExport else {
            authPolicy.authenticate(reason: "验证身份后导出备份") { runExportCore() }
            return
        }
        runExportCore()
    }

    private func runExportCore() {
        let data: Data
        let fileExt: String
        do {
            switch format {
            case .onePUX:
                (data, fileExt) = try service.exportData(password: nil) // → .1pux
            case .onePWD:
                let pwd = password.isEmpty ? nil : password
                (data, fileExt) = try service.exportData(password: pwd) // → .1pwd
            case .csv:
                data = try service.exportCSV()
                fileExt = "csv"
            }
        } catch {
            dismiss()
            onDone?("导出失败：\(error.localizedDescription)")
            return
        }

        // NSSavePanel
        let panel = NSSavePanel()
        panel.message = "选择保存位置"
        let fmt = DateFormatter(); fmt.dateFormat = "yyyyMMdd-HHmm"
        switch fileExt {
        case "1pux":
            panel.allowedFileTypes = ["1pux"]
            panel.nameFieldStringValue = "OneOfPassword-\(fmt.string(from: Date())).1pux"
        case "csv":
            panel.allowedFileTypes = ["csv"]
            panel.nameFieldStringValue = "OneOfPassword-\(fmt.string(from: Date())).csv"
        default:
            panel.allowedContentTypes = [.onePasswordBackup]
            panel.nameFieldStringValue = "OneOfPassword-\(fmt.string(from: Date())).1pwd"
        }

        guard panel.runModal() == .OK, let url = panel.url else {
            dismiss(); return
        }

        do {
            try data.write(to: url, options: .atomic)
            dismiss()
            onDone?("已保存至：\(url.lastPathComponent)")
        } catch {
            dismiss()
            onDone?("导出失败：\(error.localizedDescription)")
        }
    }
}
