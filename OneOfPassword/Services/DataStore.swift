//
//  DataStore.swift
//  OneOfPassword
//
//  所有元数据持久化到应用专属目录：
//  ~/Library/Application Support/com.oneofpassword.app/
//  （密码和 TOTP Secret 的敏感内容仍存于 EncryptedStore，与本文件无关）
//

import Foundation

class DataStore: ObservableObject {
    static let shared = DataStore()

    @Published var vaultItems: [VaultItem] = []
    @Published var noteItems: [NoteItem] = []

    /// 统计快照。口径定义在 `VaultStatistics`（唯一真相），这里只负责在数据变化后重算。
    ///
    /// 为什么不做成计算属性：统计要读磁盘（三个文件的字节数），如果每渲染一个格子算一次，
    /// 设置页一次刷新就是十几次 `stat` 系统调用。改成"写完就重算一次"的缓存，
    /// 既保证数字实时（任何 save / delete 都会刷新），也不会把 IO 带进视图 body。
    @Published private(set) var statistics = VaultStatistics.empty

    // MARK: - 存储路径

    /// ~/Library/Application Support/com.oneofpassword.app/
    private let appSupportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir  = base.appendingPathComponent("com.oneofpassword.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var vaultFile: URL { appSupportDir.appendingPathComponent("vault.json") }
    private var notesFile: URL { appSupportDir.appendingPathComponent("notes.json") }

    /// 参与"存储占用"统计的文件：条目、便签、加密密钥库。
    /// 不含 .device_id / 旧版遗留的 passwords.json、ga.json（迁移后不再写入）。
    private var storageFileNames: [String] { ["vault.json", "notes.json", "secrets.enc"] }

    // MARK: - Init

    private init() {
        loadData()
    }

    // MARK: - 加载

    private func loadData() {
        vaultItems = load(from: vaultFile) ?? []
        noteItems  = load(from: notesFile) ?? []
        refreshStatistics()
    }

    private func load<T: Decodable>(from url: URL) -> [T]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([T].self, from: data)
    }

    // MARK: - 持久化

    private func persist<T: Encodable>(_ items: [T], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - 统计

    /// 重算统计快照。所有会改变数据量的入口结束时都要调用。
    private func refreshStatistics() {
        statistics = VaultStatistics.compute(items: vaultItems,
                                            notes: noteItems,
                                            storageBytes: storageBytes())
    }

    /// 数据目录里三个数据文件的合计字节数（文件不存在按 0 计）。
    private func storageBytes() -> Int64 {
        storageFileNames.reduce(0) { sum, name in
            let url = appSupportDir.appendingPathComponent(name)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            return sum + size
        }
    }

    // MARK: - VaultItem

    func saveVaultItem(_ item: VaultItem) {
        if let i = vaultItems.firstIndex(where: { $0.id == item.id }) {
            vaultItems[i] = item
        } else {
            vaultItems.append(item)
        }
        persist(vaultItems, to: vaultFile)
        refreshStatistics()
    }

    func deleteVaultItem(_ item: VaultItem) {
        vaultItems.removeAll { $0.id == item.id }
        persist(vaultItems, to: vaultFile)
        refreshStatistics()
        // Keychain cleanup
        if !item.keychainId.isEmpty {
            try? KeychainService.shared.deletePassword(id: item.keychainId)
        }
        if let totpId = item.totpKeychainId {
            KeychainService.shared.deleteTOTPSecret(id: totpId)
        }
        // Custom concealed fields
        for cf in item.customFields where cf.isConcealed {
            if let kcId = cf.concealedKeychainId {
                KeychainService.shared.deleteCustomFieldValue(keychainId: kcId)
            }
        }
        // Extra passwords
        for ep in item.extraPasswords {
            try? KeychainService.shared.deletePassword(id: ep.keychainId)
        }
        // Extra TOTPs
        for extra in item.extraTOTPs {
            KeychainService.shared.deleteTOTPSecret(id: extra.keychainId)
        }
    }

    // MARK: - Note Items

    func saveNoteItem(_ item: NoteItem) {
        if let i = noteItems.firstIndex(where: { $0.id == item.id }) {
            noteItems[i] = item
        } else {
            noteItems.insert(item, at: 0)
        }
        persist(noteItems, to: notesFile)
        refreshStatistics()
    }

    func deleteNoteItem(_ item: NoteItem) {
        noteItems.removeAll { $0.id == item.id }
        persist(noteItems, to: notesFile)
        refreshStatistics()
    }
}
