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

    // MARK: - Init

    private init() {
        loadData()
    }

    // MARK: - 加载

    private func loadData() {
        vaultItems = load(from: vaultFile) ?? []
        noteItems  = load(from: notesFile) ?? []
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

    // MARK: - VaultItem

    func saveVaultItem(_ item: VaultItem) {
        if let i = vaultItems.firstIndex(where: { $0.id == item.id }) {
            vaultItems[i] = item
        } else {
            vaultItems.append(item)
        }
        persist(vaultItems, to: vaultFile)
    }

    func deleteVaultItem(_ item: VaultItem) {
        vaultItems.removeAll { $0.id == item.id }
        persist(vaultItems, to: vaultFile)
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
    }

    func deleteNoteItem(_ item: NoteItem) {
        noteItems.removeAll { $0.id == item.id }
        persist(noteItems, to: notesFile)
    }
}
