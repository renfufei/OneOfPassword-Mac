//
//  VaultPreviewViews.swift
//  OneOfPassword
//
//  统一保险库条目只读预览（第3列）
//

import SwiftUI

// MARK: - 统一预览视图

struct VaultItemPreviewView: View {
    let item: VaultItem
    let onDelete: () -> Void
    let onEdit: () -> Void
    @ObservedObject var vm: VaultListViewModel

    @ObservedObject private var dataStore = DataStore.shared

    @State private var showPassword   = false
    @State private var pwCopied       = false
    @State private var usernameCopied = false

    private let keychain = KeychainService.shared

    private var currentItem: VaultItem {
        dataStore.vaultItems.first(where: { $0.id == item.id }) ?? item
    }

    private var vaultNotes: [VaultNote] {
        let notes = currentItem.vaultNotes
        return notes.filter { $0.isPinned } + notes.filter { !$0.isPinned }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if item.type == .totp {
                    totpSection
                    totpInfoSection
                } else {
                    basicInfoSection
                    passwordSection
                    if currentItem.totpKeychainId != nil {
                        embeddedTOTPSection
                    }
                    if !vaultNotes.isEmpty {
                        notesSection
                    }
                    if !currentItem.customFields.isEmpty {
                        customFieldsSection
                    }
                }
            }
            .formStyle(.grouped)
            .safeAreaInset(edge: .top) { Color.clear.frame(height: 20) }
            timestampSection
        }
        .navigationTitle(item.title)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 8) {
                    Button {
                        vm.toggleFavorite(currentItem)
                    } label: {
                        Image(systemName: currentItem.isFavorite ? "star.fill" : "star")
                            .font(.system(size: 15))
                            .foregroundColor(currentItem.isFavorite ? .yellow : .secondary)
                    }
                    .buttonStyle(.iconCircle(tint: currentItem.isFavorite ? .yellow : .secondary, size: 30))
                    .help(currentItem.isFavorite ? "取消收藏" : "添加收藏")

                    Button { onEdit() } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonStyle(.primary())
                    // 这里原本叠了一个 `.font(.system(size: 19).weight(.medium))`，
                    // 会盖掉统一按钮样式的字号，导致这个按钮比别处大一号（也正是
                    // 「换一台 Mac 按钮变大被遮住」的其中一处来源）。字号一律由
                    // `AppMetrics.buttonFontSize` 决定，不要再在调用点覆写。
                }
                .padding(.trailing, 12)
                .frame(maxHeight: .infinity, alignment: .center)
                .padding(.top, 20)
            }
        }
    }

    // MARK: - TOTP 大码区块

    private var totpSection: some View {
        Section {
            TOTPLiveRow(item: currentItem, vm: vm)
        } header: {
            HStack {
                Text("验证码(GA)")
                Spacer()
                Button("提前刷新") { vm.advanceToNextPeriod() }
                    .font(.caption)
                    .disabled(vm.remainingTime > 10 || vm.isAdvanced)
            }
        }
    }

    private var totpInfoSection: some View {
        Section("基本信息") {
            LabeledRow(label: "标题", value: currentItem.title)
            if let issuer = currentItem.totpIssuer, !issuer.isEmpty {
                LabeledRow(label: "发行者", value: issuer)
            }
            if !currentItem.totpAccountName.isEmpty {
                LabeledRow(label: "账户名", value: currentItem.totpAccountName)
            }
            if !currentItem.totpLabel.isEmpty {
                LabeledRow(label: "标签", value: currentItem.totpLabel)
            }
            LabeledRow(label: "验证码位数", value: "\(currentItem.totpDigits)")
            LabeledRow(label: "有效期", value: "\(currentItem.totpPeriod) 秒")
        }
    }

    // MARK: - 密码基本信息

    private var basicInfoSection: some View {
        Section("基本信息") {
            LabeledRow(label: "标题", value: currentItem.title)
            HStack {
                Text("用户名").foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Text(currentItem.username).textSelection(.enabled)
                    if usernameCopied {
                        Text("已复制").font(.caption).foregroundColor(.green)
                    }
                    IconBtn(icon: usernameCopied ? "checkmark" : "doc.on.doc",
                            tint: usernameCopied ? .green : .secondary) {
                        ClipboardManager.shared.copy(currentItem.username)
                        usernameCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { usernameCopied = false }
                    }
                    .help("复制用户名")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                ClipboardManager.shared.copy(currentItem.username)
                usernameCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { usernameCopied = false }
            }
            if let site = currentItem.website, !site.isEmpty {
                LabeledRow(label: "网站", value: site)
            }
            if let cat = currentItem.category {
                LabeledRow(label: "分类", value: cat.displayName)
            }
            if let notes = currentItem.notes, !notes.isEmpty {
                LabeledContent("备注") {
                    Text(notes)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var passwordSection: some View {
        Section("密码") {
            HStack {
                Text("密码").foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    if showPassword {
                        Text(vm.getPassword(for: currentItem) ?? "")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.primary)
                    } else {
                        Text("••••••••")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    // 眼睛：仅切换显示，不复制
                    IconBtn(icon: showPassword ? "eye.slash" : "eye", tint: .secondary) {
                        showPassword.toggle()
                    }
                    if pwCopied {
                        Text("已复制").font(.caption).foregroundColor(.green)
                    }
                    IconBtn(icon: pwCopied ? "checkmark" : "doc.on.doc",
                            tint: pwCopied ? .green : .secondary) {
                        if let pw = vm.getPassword(for: currentItem) { ClipboardManager.shared.copy(pw) }
                        pwCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { pwCopied = false }
                    }
                    .help("复制密码")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if let pw = vm.getPassword(for: currentItem) { ClipboardManager.shared.copy(pw) }
                pwCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { pwCopied = false }
            }
            ForEach(currentItem.extraPasswords) { ep in
                ExtraPasswordLiveRow(extra: ep)
            }
        }
    }

    private var embeddedTOTPSection: some View {
        Section {
            TOTPLiveRow(item: currentItem, vm: vm)
            ForEach(currentItem.extraTOTPs) { extra in
                ExtraTOTPLiveRow(extra: extra, vm: vm)
            }
        } header: {
            HStack {
                Text("验证器")
                Spacer()
                Button("提前刷新") { vm.advanceToNextPeriod() }
                    .font(.caption)
                    .disabled(vm.remainingTime > 10 || vm.isAdvanced)
            }
        }
    }

    private var notesSection: some View {
        Section("便签 (\(vaultNotes.count))") {
            ForEach(vaultNotes) { note in
                VaultNoteReadRow(note: note)
            }
        }
    }

    private var customFieldsSection: some View {
        Section("自定义字段") {
            ForEach(currentItem.customFields) { field in
                CustomFieldInlineRow(field: field) { getCustomFieldValue(field) }
            }
        }
    }

    private func getCustomFieldValue(_ field: CustomField) -> String? {
        if field.isConcealed, let kcId = field.concealedKeychainId {
            return try? keychain.getCustomFieldValue(keychainId: kcId)
        }
        return field.value.isEmpty ? nil : field.value
    }

    private var timestampSection: some View {
        HStack(spacing: 16) {
            Text("添加于 \(currentItem.createdAt.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))")
            Text("修改于 \(currentItem.updatedAt.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))")
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }
}

// MARK: - TOTP 实时行（大码 + 倒计时圆环）

private struct TOTPLiveRow: View {
    let item: VaultItem
    @ObservedObject var vm: VaultListViewModel

    @State private var codeCopied = false

    private var code: String { vm.getTOTPCode(for: item) }
    private var remaining: Int { vm.remainingTime }
    private var period: Int { item.totpPeriod > 0 ? item.totpPeriod : 30 }
    private var displayRemaining: Int { vm.isAdvanced ? remaining + period : remaining }
    private var progress: Double {
        vm.isAdvanced ? Double(remaining + period) / Double(period * 2) : Double(remaining) / Double(period)
    }
    private var progressColor: Color {
        displayRemaining <= 5 ? .red : displayRemaining <= 10 ? .orange : .green
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.gray.opacity(0.2), lineWidth: 3)
                Circle().trim(from: 0, to: progress)
                    .stroke(progressColor, lineWidth: 3)
                    .rotationEffect(.degrees(-90))
                Text("\(displayRemaining)").font(.caption).fontWeight(.bold)
            }
            .frame(width: 36, height: 36)

            let label = item.totpLabel.isEmpty ? item.totpAccountName : item.totpLabel
            Text(label.isEmpty ? "一次性密码" : label)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()

            HStack(spacing: 4) {
                Text(formatCode(code))
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
                if codeCopied {
                    Text("已复制").font(.caption).foregroundColor(.green)
                }
                IconBtn(icon: codeCopied ? "checkmark" : "doc.on.doc",
                        tint: codeCopied ? .green : .secondary) {
                    ClipboardManager.shared.copy(code)
                    codeCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { codeCopied = false }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            ClipboardManager.shared.copy(code)
            codeCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { codeCopied = false }
        }
        .help("点击复制验证码")
    }

    private func formatCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let i = code.index(code.startIndex, offsetBy: 3)
        return "\(code[..<i]) \(code[i...])"
    }
}

// MARK: - 额外 TOTP 行

private struct ExtraTOTPLiveRow: View {
    let extra: ExtraTOTP
    @ObservedObject var vm: VaultListViewModel

    @State private var codeCopied = false

    private var code: String {
        vm.getTOTPCode(keychainId: extra.keychainId, digits: extra.digits, period: extra.period)
    }
    private var remaining: Int { vm.remainingTime }
    private var period: Int { extra.period > 0 ? extra.period : 30 }
    private var displayRemaining: Int { vm.isAdvanced ? remaining + period : remaining }
    private var progress: Double {
        vm.isAdvanced ? Double(remaining + period) / Double(period * 2) : Double(remaining) / Double(period)
    }
    private var progressColor: Color {
        displayRemaining <= 5 ? .red : displayRemaining <= 10 ? .orange : .green
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.gray.opacity(0.2), lineWidth: 3)
                Circle().trim(from: 0, to: progress)
                    .stroke(progressColor, lineWidth: 3)
                    .rotationEffect(.degrees(-90))
                Text("\(displayRemaining)").font(.caption).fontWeight(.bold)
            }
            .frame(width: 36, height: 36)

            Text(extra.label.isEmpty ? "一次性密码" : extra.label)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()

            HStack(spacing: 4) {
                Text(formatCode(code))
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
                if codeCopied {
                    Text("已复制").font(.caption).foregroundColor(.green)
                }
                IconBtn(icon: codeCopied ? "checkmark" : "doc.on.doc",
                        tint: codeCopied ? .green : .secondary) {
                    ClipboardManager.shared.copy(code)
                    codeCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { codeCopied = false }
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            ClipboardManager.shared.copy(code)
            codeCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { codeCopied = false }
        }
        .help("点击复制验证码")
    }

    private func formatCode(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let i = code.index(code.startIndex, offsetBy: 3)
        return "\(code[..<i]) \(code[i...])"
    }
}

// MARK: - 额外密码行

private struct ExtraPasswordLiveRow: View {
    let extra: ExtraPassword

    @State private var revealed = false
    @State private var copied = false

    private let keychain = KeychainService.shared

    private var password: String {
        (try? keychain.getPassword(id: extra.keychainId)) ?? ""
    }

    var body: some View {
        HStack {
            Text(extra.label.isEmpty ? "密码" : extra.label).foregroundColor(.secondary)
            Spacer()
            HStack(spacing: 4) {
                if revealed {
                    Text(password)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.primary)
                } else {
                    Text("••••••••")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                IconBtn(icon: revealed ? "eye.slash" : "eye", tint: .secondary) {
                    revealed.toggle()
                }
                if copied {
                    Text("已复制").font(.caption).foregroundColor(.green)
                }
                IconBtn(icon: copied ? "checkmark" : "doc.on.doc",
                        tint: copied ? .green : .secondary) {
                    ClipboardManager.shared.copy(password)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .help("复制密码")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            ClipboardManager.shared.copy(password)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
    }
}

// MARK: - 便签只读行

struct VaultNoteReadRow: View {
    let note: VaultNote

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
                Text(note.displayTitle)
                    .font(.subheadline).fontWeight(.medium)
                    .lineLimit(1)
            }
            if !note.displaySummary.isEmpty {
                Text(note.displaySummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 自定义字段内联行

private struct CustomFieldInlineRow: View {
    let field: CustomField
    let getValue: () -> String?

    @State private var revealed = false
    @State private var copied = false

    var body: some View {
        LabeledContent(field.label) {
            HStack(spacing: 4) {
                if field.isConcealed {
                    if revealed {
                        Text(getValue() ?? "")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    } else {
                        Text("••••••")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    IconBtn(icon: revealed ? "eye.slash" : "eye", tint: .secondary) {
                        revealed.toggle()
                    }
                } else {
                    Text(field.value)
                        .textSelection(.enabled)
                }
                if copied {
                    Text("已复制").font(.caption).foregroundColor(.green)
                }
                IconBtn(icon: copied ? "checkmark" : "doc.on.doc",
                        tint: copied ? .green : .secondary) {
                    if let v = getValue() { ClipboardManager.shared.copy(v) }
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .help("复制")
            }
        }
    }
}

// MARK: - 便签编辑 Sheet（供 ItemDetailView 调用）

struct VaultNoteEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onSave: (VaultNote) -> Void

    @State private var noteTitle: String
    @State private var content: String
    @State private var isPinned: Bool
    private let noteId: UUID
    private let createdAt: Date

    init(title: String, existing: VaultNote? = nil, onSave: @escaping (VaultNote) -> Void) {
        self.title = title
        self.onSave = onSave
        self.noteId = existing?.id ?? UUID()
        self.createdAt = existing?.createdAt ?? Date()
        _noteTitle = State(initialValue: existing?.title ?? "")
        _content   = State(initialValue: existing?.content ?? "")
        _isPinned  = State(initialValue: existing?.isPinned ?? false)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("标题（可选）", text: $noteTitle)
                    .font(.title2.bold())
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 8)
                    .background(Color(NSColor.textBackgroundColor))

                Divider()

                TextEditor(text: $content)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color(NSColor.textBackgroundColor))
            }
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { isPinned.toggle() }) {
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                    }
                    .help(isPinned ? "取消置顶" : "置顶")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(noteTitle.isEmpty && content.isEmpty)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 360)
    }

    private func save() {
        let note = VaultNote(
            id: noteId,
            title: noteTitle,
            content: content,
            isPinned: isPinned,
            createdAt: createdAt,
            updatedAt: Date()
        )
        onSave(note)
        dismiss()
    }
}

// MARK: - 辅助组件

struct LabeledRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }
}

struct IconBtn: View {
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
        }
        .buttonStyle(.iconCircle(tint: tint, size: 30))
    }
}
