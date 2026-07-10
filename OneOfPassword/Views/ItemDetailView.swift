//
//  ItemDetailView.swift
//  OneOfPassword
//
//  编辑条目（统一 VaultItem：密码 + TOTP + 自定义字段 + 便签）
//

import SwiftUI

struct ItemDetailView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var vm: VaultListViewModel

    let item: VaultItem?
    var onDismiss: (() -> Void)? = nil
    var onSaved: ((VaultItem) -> Void)? = nil

    // 类型选择
    @State private var itemType: VaultItemType = .password

    // 基本字段（密码）
    @State private var title = ""
    @State private var username = ""
    @State private var password = ""
    @State private var website = ""
    @State private var notes = ""
    @State private var category: ItemCategory? = nil
    @State private var showPassword = false

    // 自定义字段
    @State private var customFields: [CustomField] = []
    @State private var revealedFields: Set<UUID> = []

    // 便签
    @State private var vaultNotes: [VaultNote] = []
    @State private var showAddNote = false
    @State private var editingNote: VaultNote? = nil

    // TOTP 字段（主）
    @State private var totpSecret = ""
    @State private var totpIssuer = ""
    @State private var totpAccountName = ""
    @State private var totpLabel = ""
    @State private var totpDigits = 6
    @State private var totpPeriod = 30
    @State private var showTOTPSecret = false
    @State private var totpSecretCopied = false
    @State private var showScanner = false

    // 额外密码
    @State private var extraPasswords: [ExtraPassword] = []
    @State private var extraPasswordValues: [UUID: String] = [:]
    @State private var revealedPasswords: Set<UUID> = []

    // 额外验证器
    @State private var extraTOTPs: [ExtraTOTP] = []
    @State private var extraTOTPSecrets: [UUID: String] = [:]   // id -> secret（内存中明文）
    @State private var editingExtraTOTP: ExtraTOTP? = nil
    @State private var showAddExtraTOTP = false
    @State private var showEditPrimaryTOTP = false  // 编辑主 TOTP（密码条目）

    private let keychain = KeychainService.shared

    init(vm: VaultListViewModel, item: VaultItem? = nil,
         onDismiss: (() -> Void)? = nil, onSaved: ((VaultItem) -> Void)? = nil) {
        self.vm = vm
        self.item = item
        self.onDismiss = onDismiss
        self.onSaved = onSaved

        if let item = item {
            _itemType     = State(initialValue: item.type)
            _title        = State(initialValue: item.title)
            _username     = State(initialValue: item.username)
            _website      = State(initialValue: item.website ?? "")
            _notes        = State(initialValue: item.notes ?? "")
            _category     = State(initialValue: item.category ?? nil)
            _password     = State(initialValue: vm.getPassword(for: item) ?? "")
            _vaultNotes   = State(initialValue: item.vaultNotes)
            _customFields = State(initialValue: item.customFields.map { cf in
                if cf.isConcealed, let kcId = cf.concealedKeychainId,
                   let val = try? KeychainService.shared.getCustomFieldValue(keychainId: kcId) {
                    return CustomField(id: cf.id, label: cf.label, value: val,
                                       isConcealed: true, concealedKeychainId: cf.concealedKeychainId,
                                       rawType: cf.rawType)
                }
                return cf
            })
            // TOTP（主）
            _totpIssuer       = State(initialValue: item.totpIssuer ?? "")
            _totpAccountName  = State(initialValue: item.totpAccountName)
            _totpLabel        = State(initialValue: item.totpLabel)
            _totpDigits       = State(initialValue: item.totpDigits)
            _totpPeriod       = State(initialValue: item.totpPeriod)
            if let totpId = item.totpKeychainId,
               let secret = try? KeychainService.shared.getTOTPSecret(id: totpId) {
                _totpSecret = State(initialValue: secret)
            }
            // 额外密码
            _extraPasswords = State(initialValue: item.extraPasswords)
            var pwValues: [UUID: String] = [:]
            for ep in item.extraPasswords {
                if let v = try? KeychainService.shared.getPassword(id: ep.keychainId) {
                    pwValues[ep.id] = v
                }
            }
            _extraPasswordValues = State(initialValue: pwValues)
            // 额外验证器
            _extraTOTPs = State(initialValue: item.extraTOTPs)
            var secrets: [UUID: String] = [:]
            for extra in item.extraTOTPs {
                if let s = try? KeychainService.shared.getTOTPSecret(id: extra.keychainId) {
                    secrets[extra.id] = s
                }
            }
            _extraTOTPSecrets = State(initialValue: secrets)
        } else {
            // 新建条目：预填标题，密码留空
            _title    = State(initialValue: "登录信息")
            _password = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 可滚动内容区
            Form {
                if itemType == .password {
                    passwordFields
                } else {
                    totpFields
                }
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            .safeAreaInset(edge: .top) { Color.clear.frame(height: 20) }
        }
        .navigationTitle("编辑")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 12) {
                    Button("取消") {
                        if let onDismiss { onDismiss() } else { dismiss() }
                    }
                    .buttonStyle(.secondary())

                    Button("保存") { saveItem() }
                        .buttonStyle(.primary(disabled: saveDisabled))
                        .disabled(saveDisabled)
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .padding(.top, 20)
                .padding(.trailing, 12)
            }
        }
        .sheet(isPresented: $showAddNote) {
            VaultNoteEditorSheet(title: "新建便签") { note in
                vaultNotes.append(note)
            }
        }
        .sheet(item: $editingNote) { note in
            VaultNoteEditorSheet(title: "编辑便签", existing: note) { updated in
                if let i = vaultNotes.firstIndex(where: { $0.id == updated.id }) {
                    vaultNotes[i] = updated
                }
            }
        }
        .sheet(isPresented: $showEditPrimaryTOTP) {
            let primaryExisting: (ExtraTOTP, String)? = totpSecret.isEmpty ? nil : (
                ExtraTOTP(id: UUID(), label: totpLabel.isEmpty ? totpAccountName : totpLabel,
                          issuer: totpIssuer.isEmpty ? nil : totpIssuer,
                          accountName: totpAccountName, digits: totpDigits, period: totpPeriod,
                          keychainId: item?.totpKeychainId ?? ""),
                totpSecret
            )
            ExtraTOTPEditorSheet(existing: primaryExisting) { updated, secret in
                totpAccountName = updated.accountName
                totpIssuer = updated.issuer ?? ""
                totpLabel = updated.label
                totpDigits = updated.digits
                totpPeriod = updated.period
                totpSecret = secret
                if title.isEmpty { title = updated.issuer ?? updated.accountName }
            }
        }
        .sheet(isPresented: $showAddExtraTOTP) {
            ExtraTOTPEditorSheet(existing: nil) { newExtra, secret in
                extraTOTPs.append(newExtra)
                extraTOTPSecrets[newExtra.id] = secret
            }
        }
        .sheet(item: $editingExtraTOTP) { extra in
            ExtraTOTPEditorSheet(existing: (extra, extraTOTPSecrets[extra.id] ?? "")) { updated, secret in
                if let i = extraTOTPs.firstIndex(where: { $0.id == updated.id }) {
                    extraTOTPs[i] = updated
                }
                extraTOTPSecrets[updated.id] = secret
            }
        }
    }

    // MARK: - 密码字段区块

    @ViewBuilder
    private var passwordFields: some View {
        Section("基本信息") {
            TextField("标题", text: $title)
            TextField("用户名", text: $username)
            TextField("网站", text: $website)
            TextField("备注", text: $notes)
            LabeledContent("分类") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(ItemCategory.allCases, id: \.self) { cat in
                            let selected = category == cat
                            Button(cat.displayName) { category = selected ? nil : cat }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(selected ? Color.accentColor : Color.secondary.opacity(0.12))
                                .foregroundColor(selected ? .white : .primary)
                                .clipShape(Capsule())
                                .font(.subheadline)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }

        Section("密码") {
            HStack {
                if showPassword {
                    TextField("密码", text: $password)
                } else {
                    SecureField("密码", text: $password)
                }
                Button(action: { showPassword.toggle() }) {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                }
                .buttonStyle(.iconCircle(tint: .secondary, size: 26))
            }
            ForEach($extraPasswords) { $ep in
                let isRevealed = revealedPasswords.contains(ep.id)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("密码备注")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("", text: $ep.label)
                        Button(role: .destructive) {
                            extraPasswords.removeAll { $0.id == ep.id }
                            extraPasswordValues.removeValue(forKey: ep.id)
                            revealedPasswords.remove(ep.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.iconCircle(tint: .red, size: 26))
                    }
                    HStack(spacing: 6) {
                        Text("密码")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if isRevealed {
                            TextField("", text: Binding(
                                get: { extraPasswordValues[ep.id] ?? "" },
                                set: { extraPasswordValues[ep.id] = $0 }
                            ))
                        } else {
                            SecureField("", text: Binding(
                                get: { extraPasswordValues[ep.id] ?? "" },
                                set: { extraPasswordValues[ep.id] = $0 }
                            ))
                        }
                        Button {
                            if isRevealed { revealedPasswords.remove(ep.id) }
                            else { revealedPasswords.insert(ep.id) }
                        } label: {
                            Image(systemName: isRevealed ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.iconCircle(tint: .secondary, size: 26))
                    }
                }
                .padding(.vertical, 4)
            }
            if password.isEmpty {
                Button {
                    password = vm.generatePassword()
                    showPassword = true
                } label: {
                    Label("生成随机密码", systemImage: "wand.and.sparkles")
                }
                .buttonStyle(.generate())
            }
        }

        // 验证器列表（主 TOTP + 额外验证器统一展示）
        Section {
            // 主 TOTP 行（有内容时显示）
            if !totpSecret.isEmpty {
                totpRowView(
                    label: totpLabel.isEmpty ? totpAccountName : totpLabel,
                    issuer: totpIssuer.isEmpty ? nil : totpIssuer,
                    onEdit: { showEditPrimaryTOTP = true },
                    onDelete: {
                        totpSecret = ""
                        totpIssuer = ""
                        totpAccountName = ""
                        totpLabel = ""
                        totpDigits = 6
                        totpPeriod = 30
                    }
                )
            }
            // 额外验证器行
            ForEach(extraTOTPs) { extra in
                totpRowView(
                    label: extra.label.isEmpty ? extra.accountName : extra.label,
                    issuer: extra.issuer,
                    onEdit: { editingExtraTOTP = extra },
                    onDelete: {
                        extraTOTPs.removeAll { $0.id == extra.id }
                        extraTOTPSecrets.removeValue(forKey: extra.id)
                    }
                )
            }
        } header: {
            let count = (totpSecret.isEmpty ? 0 : 1) + extraTOTPs.count
            Text("验证器\(count > 0 ? " (\(count))" : "")")
        }

        // 便签
        if !vaultNotes.isEmpty {
            Section {
                ForEach(vaultNotes) { note in
                    VaultNoteEditRow(
                        note: note,
                        onEdit: { editingNote = note },
                        onDelete: { vaultNotes.removeAll { $0.id == note.id } },
                        onTogglePin: {
                            if let i = vaultNotes.firstIndex(where: { $0.id == note.id }) {
                                vaultNotes[i].isPinned.toggle()
                            }
                        }
                    )
                }
            } header: {
                Text("便签 (\(vaultNotes.count))")
            }
        }

        // 自定义字段
        if !customFields.isEmpty {
            Section {
                ForEach(customFields.indices, id: \.self) { i in
                    let cf = customFields[i]
                    let isSpecialType = cf.rawType != nil && cf.rawType != "string" && cf.rawType != "concealed"
                    HStack(spacing: 8) {
                        if isSpecialType {
                            Text(cf.label.isEmpty ? (cf.rawType ?? "字段") : cf.label)
                                .frame(maxWidth: 120, alignment: .leading)
                                .foregroundColor(.secondary)
                            Divider()
                            Text(cf.rawType ?? "")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .italic()
                            Spacer()
                        } else {
                            TextField("标签", text: $customFields[i].label)
                                .frame(maxWidth: 120)
                            Divider()
                            if cf.isConcealed {
                                let isRevealed = revealedFields.contains(cf.id)
                                if isRevealed {
                                    TextField("值", text: $customFields[i].value)
                                } else {
                                    SecureField("值", text: $customFields[i].value)
                                }
                                Button {
                                    if isRevealed { revealedFields.remove(cf.id) }
                                    else { revealedFields.insert(cf.id) }
                                } label: {
                                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                                }
                                .buttonStyle(.iconCircle(tint: .secondary, size: 26))
                            } else {
                                TextField("值", text: $customFields[i].value)
                            }
                        }
                        Button(role: .destructive) {
                            customFields.remove(at: i)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.iconCircle(tint: .red, size: 26))
                    }
                }
            } header: {
                Text("自定义字段")
            }
        }

        Section {
            Menu {
                Button {
                    let ep = ExtraPassword()
                    extraPasswords.append(ep)
                    extraPasswordValues[ep.id] = ""
                } label: {
                    Label("密码", systemImage: "key.fill")
                }
                Button {
                    if totpSecret.isEmpty {
                        showEditPrimaryTOTP = true
                    } else {
                        showAddExtraTOTP = true
                    }
                } label: {
                    Label("验证器", systemImage: "lock.shield.fill")
                }
                Divider()
                Button {
                    showAddNote = true
                } label: {
                    Label("便签", systemImage: "note.text")
                }
                Divider()
                Button {
                    customFields.append(CustomField(label: "", value: "", isConcealed: false))
                } label: {
                    Label("普通字段", systemImage: "text.alignleft")
                }
                Button {
                    customFields.append(CustomField(label: "", value: "", isConcealed: true))
                } label: {
                    Label("加密字段", systemImage: "lock.fill")
                }
            } label: {
                HStack {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.accentColor)
                    Text("添加更多…")
                        .fontWeight(.semibold)
                        .foregroundColor(.accentColor)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 验证器行（密码条目通用）

    @ViewBuilder
    private func totpRowView(label: String, issuer: String?, onEdit: @escaping () -> Void, onDelete: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label.isEmpty ? "验证器" : label)
                    .fontWeight(.medium)
                if let issuer, !issuer.isEmpty {
                    Text(issuer).font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            Button { onEdit() } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.iconCircle(tint: .secondary))
            .help("编辑验证器")
            Button(role: .destructive) { onDelete() } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.iconCircle(tint: .red))
            .help("删除验证器")
        }
    }

    // MARK: - 纯 TOTP 字段区块

    @ViewBuilder
    private var totpFields: some View {
        Section("基本信息") {
            TextField("标题（所属账户）", text: $title)
            TextField("发行者（可选）", text: $totpIssuer)
            TextField("账户名", text: $totpAccountName)
            TextField("标签（如：手机、备用）", text: $totpLabel)
        }
        Section("密钥配置") {
            totpFieldsInline
        }
    }

    // MARK: - TOTP 内联字段

    @ViewBuilder
    private var totpFieldsInline: some View {
        LabeledContent("Secret Key") {
            HStack(spacing: 6) {
                Group {
                    if showTOTPSecret {
                        TextField("", text: $totpSecret)
                    } else {
                        SecureField("", text: $totpSecret)
                    }
                }
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(6)
                .frame(maxWidth: .infinity)

                Button { showTOTPSecret.toggle() } label: {
                    Image(systemName: showTOTPSecret ? "eye.slash" : "eye")
                }
                .buttonStyle(.iconCircle(tint: .secondary, size: 26))
                .help(showTOTPSecret ? "隐藏 Secret Key" : "显示 Secret Key")

                Button {
                    ClipboardManager.shared.copy(totpSecret)
                    totpSecretCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { totpSecretCopied = false }
                } label: {
                    Image(systemName: totpSecretCopied ? "checkmark" : "doc.on.doc")
                        .foregroundColor(totpSecretCopied ? .green : .secondary)
                }
                .buttonStyle(.iconCircle(tint: totpSecretCopied ? .green : .secondary, size: 26))
                .disabled(totpSecret.isEmpty)
            }
        }

        Stepper("验证码位数: \(totpDigits)", value: $totpDigits, in: 6...8)
        Stepper("有效期: \(totpPeriod) 秒", value: $totpPeriod, in: 15...60, step: 15)

        if totpSecret.isEmpty {
            Button {
                showScanner = true
            } label: {
                Label("扫描二维码 / 选择图片", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.addAction())
        }
    }

    // MARK: - 导航标题 / 保存校验

    private var navigationTitle: String {
        guard let item else { return itemType == .totp ? "添加验证器" : "添加密码" }
        return item.type == .totp ? "编辑验证器" : "编辑条目"
    }

    private var saveDisabled: Bool {
        if title.isEmpty { return true }
        if itemType == .totp { return totpAccountName.isEmpty || totpSecret.isEmpty }
        return false
    }

    // MARK: - 保存

    private func saveItem() {
        // --- 处理 custom fields (concealed) ---
        let savedFields: [CustomField] = customFields.map { cf in
            if cf.isConcealed {
                let kcId = cf.concealedKeychainId ?? UUID().uuidString
                keychain.deleteCustomFieldValue(keychainId: kcId)
                keychain.saveCustomFieldValue(keychainId: kcId, value: cf.value)
                return CustomField(id: cf.id, label: cf.label, value: "",
                                   isConcealed: true, concealedKeychainId: kcId, rawType: cf.rawType)
            }
            return cf
        }
        // 清理已删除的 concealed 字段
        if let existing = item {
            let newIds = Set(savedFields.compactMap { $0.concealedKeychainId })
            for old in existing.customFields where old.isConcealed {
                if let kcId = old.concealedKeychainId, !newIds.contains(kcId) {
                    keychain.deleteCustomFieldValue(keychainId: kcId)
                }
            }
        }

        // --- 处理额外密码 ---
        let savedExtraPwds: [ExtraPassword] = extraPasswords.map { ep in
            let kcId = ep.keychainId
            if let val = extraPasswordValues[ep.id], !val.isEmpty {
                try? keychain.savePassword(id: kcId, password: val)
            }
            return ExtraPassword(id: ep.id, label: ep.label, keychainId: kcId)
        }
        // 清理已删除的额外密码
        if let existing = item {
            let newKcIds = Set(savedExtraPwds.map { $0.keychainId })
            for old in existing.extraPasswords where !newKcIds.contains(old.keychainId) {
                try? keychain.deletePassword(id: old.keychainId)
            }
        }

        let sortedNotes = vaultNotes.filter { $0.isPinned } + vaultNotes.filter { !$0.isPinned }

        // --- TOTP keychainId ---
        let hasTOTP = !totpSecret.isEmpty
        let existingTotpId = item?.totpKeychainId
        let totpKeychainId: String? = hasTOTP ? (existingTotpId ?? UUID().uuidString) : nil

        // 如果取消了 TOTP，删除旧的 TOTP secret
        if !hasTOTP, let oldTotpId = item?.totpKeychainId {
            keychain.deleteTOTPSecret(id: oldTotpId)
        }

        let cleanSecret = totpSecret.uppercased().replacingOccurrences(of: " ", with: "")

        // 保存额外验证器的 Keychain
        let savedExtras: [ExtraTOTP] = extraTOTPs.compactMap { extra in
            guard let secret = extraTOTPSecrets[extra.id], !secret.isEmpty else { return nil }
            let kcId = extra.keychainId.isEmpty ? UUID().uuidString : extra.keychainId
            let cleanedSecret = secret.uppercased().replacingOccurrences(of: " ", with: "")
            keychain.saveTOTPSecret(id: kcId, secret: cleanedSecret)
            return ExtraTOTP(id: extra.id, label: extra.label, issuer: extra.issuer,
                             accountName: extra.accountName, digits: extra.digits,
                             period: extra.period, keychainId: kcId)
        }
        // 清理已删除的额外验证器
        if let existing = item {
            let newIds = Set(savedExtras.map { $0.keychainId })
            for old in existing.extraTOTPs where !newIds.contains(old.keychainId) {
                keychain.deleteTOTPSecret(id: old.keychainId)
            }
        }

        let newItem = VaultItem(
            id: item?.id ?? UUID(),
            type: itemType,
            title: title,
            isFavorite: item?.isFavorite ?? false,
            createdAt: item?.createdAt ?? Date(),
            sourceId: item?.sourceId,
            username: itemType == .password ? username : "",
            website: itemType == .password ? (website.isEmpty ? nil : website) : nil,
            notes: itemType == .password ? (notes.isEmpty ? nil : notes) : nil,
            vaultNotes: itemType == .password ? sortedNotes : [],
            category: itemType == .password ? category : nil,
            keychainId: item?.keychainId ?? (itemType == .password ? UUID().uuidString : ""),
            customFields: itemType == .password ? savedFields : [],
            totpIssuer: hasTOTP ? (totpIssuer.isEmpty ? nil : totpIssuer) : nil,
            totpAccountName: hasTOTP ? totpAccountName : "",
            totpLabel: hasTOTP ? totpLabel : "",
            totpDigits: hasTOTP ? totpDigits : 6,
            totpPeriod: hasTOTP ? totpPeriod : 30,
            totpKeychainId: totpKeychainId,
            extraTOTPs: itemType == .password ? savedExtras : [],
            extraPasswords: itemType == .password ? savedExtraPwds : []
        )

        let passwordToSave = itemType == .password ? password : nil
        let totpSecretToSave = hasTOTP ? cleanSecret : nil

        vm.saveItem(newItem, password: passwordToSave, totpSecret: totpSecretToSave)
        if let onSaved { onSaved(newItem) } else if let onDismiss { onDismiss() } else { dismiss() }
    }
}

// MARK: - 便签编辑行（编辑表单内使用）

private struct VaultNoteEditRow: View {
    let note: VaultNote
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onTogglePin: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if note.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2).foregroundColor(.orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(note.displayTitle)
                    .font(.subheadline).fontWeight(.medium)
                    .lineLimit(1)
                if !note.displaySummary.isEmpty {
                    Text(note.displaySummary)
                        .font(.caption).foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button { onEdit() } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.iconCircle(tint: .secondary))
            .help("编辑便签")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(action: onTogglePin) {
                Label(note.isPinned ? "取消置顶" : "置顶",
                      systemImage: note.isPinned ? "pin.slash" : "pin")
            }
            Button(action: onEdit) { Label("编辑", systemImage: "pencil") }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

// MARK: - 额外验证器编辑弹窗

struct ExtraTOTPEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// nil = 新增；otherwise = 编辑
    let existing: (ExtraTOTP, String)?
    let onSave: (ExtraTOTP, String) -> Void

    @State private var label = ""
    @State private var issuer = ""
    @State private var accountName = ""
    @State private var secret = ""
    @State private var digits = 6
    @State private var period = 30
    @State private var showSecret = false
    @State private var showScanner = false

    private let entryId: UUID

    init(existing: (ExtraTOTP, String)?, onSave: @escaping (ExtraTOTP, String) -> Void) {
        self.existing = existing
        self.onSave = onSave
        self.entryId = existing?.0.id ?? UUID()
        if let (extra, sec) = existing {
            _label       = State(initialValue: extra.label)
            _issuer      = State(initialValue: extra.issuer ?? "")
            _accountName = State(initialValue: extra.accountName)
            _secret      = State(initialValue: sec)
            _digits      = State(initialValue: extra.digits)
            _period      = State(initialValue: extra.period)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("标签（如：主账号）", text: $label)
                        .textFieldStyle(.roundedBorder)
                    TextField("发行者（可选）", text: $issuer)
                        .textFieldStyle(.roundedBorder)
                    TextField("账户名", text: $accountName)
                        .textFieldStyle(.roundedBorder)
                }
                Section("密钥") {
                    HStack(spacing: 6) {
                        Group {
                            if showSecret {
                                TextField("Secret Key", text: $secret)
                            } else {
                                SecureField("Secret Key", text: $secret)
                            }
                        }
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(6)
                        Button { showSecret.toggle() } label: {
                            Image(systemName: showSecret ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.iconCircle(tint: .secondary, size: 26))
                    }
                    Stepper("验证码位数: \(digits)", value: $digits, in: 6...8)
                    Stepper("有效期: \(period) 秒", value: $period, in: 15...60, step: 15)
                    if secret.isEmpty {
                        Button {
                            showScanner = true
                        } label: {
                            Label("扫描二维码 / 选择图片", systemImage: "qrcode.viewfinder")
                        }
                        .buttonStyle(.addAction())
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? "添加验证器" : "编辑验证器")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let updated = ExtraTOTP(
                            id: entryId,
                            label: label,
                            issuer: issuer.isEmpty ? nil : issuer,
                            accountName: accountName,
                            digits: digits,
                            period: period,
                            keychainId: existing?.0.keychainId ?? UUID().uuidString
                        )
                        onSave(updated, secret.uppercased().replacingOccurrences(of: " ", with: ""))
                        dismiss()
                    }
                    .disabled(secret.isEmpty)
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView(onParsed: { config in
                    if label.isEmpty { label = config.issuer ?? config.accountName }
                    if accountName.isEmpty { accountName = config.accountName }
                    if issuer.isEmpty { issuer = config.issuer ?? "" }
                    secret = config.secret
                    digits = config.digits
                    period = config.period
                })
            }
        }
        .frame(minWidth: 480, minHeight: 400)
    }
}
