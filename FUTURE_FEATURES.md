# 后续优化项

## 多保险库支持

> 已完整实现并验证编译通过（2026-05-05），因故放弃本次提交，保留为后续实现参考。

### 需求背景

当前 app 只有单个保险库（`vault.json`），存储在固定路径。需要支持多个保险库，每个保险库独立存储，可新建、重命名、删除。边栏展示保险库列表，导入/导出选择目标保险库，导出文件名带保险库名称。

### 文件布局

```
~/Library/Application Support/com.oneofpassword.app/
  vaults.json              ← 保险库列表（id + name + createdAt）
  vault-<UUID>.json        ← 每个保险库的条目（原 vault.json 迁移）
  secrets.enc              ← EncryptedStore（共用，keychainId 天然隔离）
```

### 迁移策略

启动时检查：
- `vaults.json` 不存在 + `vault.json` 存在 → 自动创建名为"保险库"的默认保险库，将 `vault.json` 重命名为 `vault-<UUID>.json`
- 两者均不存在（全新安装）→ 自动创建一个名为"保险库"的默认保险库

---

### 修改文件一览

| 文件 | 操作 | 说明 |
|------|------|------|
| `Models/Vault.swift` | **新建** | Vault 模型 |
| `Services/VaultManager.swift` | **新建** | 多保险库管理器 |
| `Services/DataStore.swift` | 修改 | 加 `currentVaultId`；动态 `vaultFile`；`loadVaultItems()` 改 internal；`appSupportDir` 改为 `let`（public） |
| `Views/ContentView.swift` | 修改 | SidebarSection 枚举改为 `.vault(UUID)` / `.settings`；多保险库边栏；重命名 sheet；删除确认框；导入保险库选择 |
| `OneOfPasswordApp.swift` | 修改 | 新增 `.menuNewVault` 通知名 + "新建保险库" 菜单项 |
| `Views/ExportWizardSheet.swift` | 修改 | 保险库 Picker（多于 1 个时显示）；文件名含保险库名 |
| `Services/ImportExportService.swift` | 修改 | `exportData`/`exportCSV`/`buildBundleJSON`/`buildOnePUXZip` 加 `vaultId` 参数；新增 `loadItems(vaultId:)` |

---

### 各文件详细实现

#### `Models/Vault.swift`（新建）

```swift
struct Vault: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var createdAt: Date
    init(id: UUID = UUID(), name: String = "新保险库", createdAt: Date = Date()) {
        self.id = id; self.name = name; self.createdAt = createdAt
    }
}
```

#### `Services/VaultManager.swift`（新建）

```swift
class VaultManager: ObservableObject {
    static let shared = VaultManager()

    @Published var vaults: [Vault] = []
    @Published var selectedVaultId: UUID?

    var selectedVault: Vault? { vaults.first { $0.id == selectedVaultId } }

    // appSupportDir 与 DataStore 共用路径（同一 computed let）
    let appSupportDir: URL = { ... }()
    private var vaultsFile: URL { appSupportDir.appendingPathComponent("vaults.json") }

    private init() {
        migrateIfNeeded()   // vault.json → vault-<UUID>.json
        loadVaults()
        let id = vaults.first?.id
        selectedVaultId = id
        DataStore.shared.currentVaultId = id
    }

    func createVault(name: String = "新保险库") -> Vault { ... }
    func deleteVault(_ vault: Vault) { ... }   // 先清 EncryptedStore，再删文件
    func renameVault(_ vault: Vault, name: String) { ... }
    func selectVault(_ vault: Vault?) { ... }  // 同步更新 DataStore.currentVaultId
    func vaultFileURL(for id: UUID) -> URL { ... }
}
```

关键点：
- `deleteVault` 先临时切换 `DataStore.currentVaultId` 到目标保险库，遍历 `deleteVaultItem` 清理 EncryptedStore，再切回、删文件、从列表移除
- `selectVault(nil)` 时切换到首个保险库

#### `Services/DataStore.swift`（修改）

```swift
// appSupportDir 由 private 改为 let（public），供 VaultManager 和 ImportExportService 复用
let appSupportDir: URL = { ... }()

// 新增：由 VaultManager 驱动，didSet 自动重载条目
var currentVaultId: UUID? {
    didSet { if oldValue != currentVaultId { loadVaultItems() } }
}

private var vaultFile: URL {
    guard let id = currentVaultId else {
        return appSupportDir.appendingPathComponent("vault.json")
    }
    return appSupportDir.appendingPathComponent("vault-\(id.uuidString).json")
}

// private init() 不再调用 loadData()，改为只加载 notes
// VaultManager.init() → selectVault → currentVaultId.didSet → loadVaultItems()
private init() {
    noteItems = load(from: notesFile) ?? []
}

// loadVaultItems 由 private 改为 internal（func，无修饰符）
func loadVaultItems() {
    vaultItems = load(from: vaultFile) ?? []
}
```

#### `Views/ContentView.swift`（修改）

```swift
// SidebarSection 由 String enum 改为关联值 enum
enum SidebarSection: Hashable {
    case vault(UUID)
    case settings
}

// 新增状态
@StateObject private var vaultManager = VaultManager.shared
@State private var selectedSection: SidebarSection? = nil   // onAppear 初始化
@State private var confirmDeleteVault: Vault? = nil
@State private var showDeleteVaultConfirm = false
@State private var renamingVault: Vault? = nil
@State private var showRenameSheet = false
@State private var showImportVaultPicker = false
@State private var importVaultPickerId: UUID = UUID()

// onAppear 初始化
.onAppear {
    if selectedSection == nil {
        selectedSection = vaultManager.vaults.first.map { .vault($0.id) }
    }
}

// onChange 同步 VaultManager
.onChange(of: selectedSection) { newSection in
    selectedItem = nil; isEditing = false
    if case .vault(let id) = newSection {
        vaultManager.selectVault(vaultManager.vaults.first { $0.id == id })
    }
}

// 边栏
Section header: { HStack { Text("保险库"); Spacer(); Button("+") { addNewVault() } } }
ForEach(vaultManager.vaults) { vault in
    Label(vault.name, systemImage: "lock.rectangle.stack.fill")
        .tag(SidebarSection.vault(vault.id))
        .contextMenu {
            Button("重命名") { renamingVault = vault; showRenameSheet = true }
            Button("删除保险库", role: .destructive) { confirmDeleteVault = vault; showDeleteVaultConfirm = true }
        }
}
Label("设置", systemImage: "gearshape.fill").tag(SidebarSection.settings)

// addNewVault
func addNewVault() {
    let v = vaultManager.createVault()
    vaultManager.selectVault(v)
    selectedSection = .vault(v.id)
}
```

辅助私有 struct：
- `VaultRenameSheet` — TextField + 取消/保存
- `ImportVaultPickerSheet` — Picker + 取消/确认，确认后切换目标保险库再执行导入

#### `Services/ImportExportService.swift`（修改）

```swift
// 新增：读取指定保险库文件，不改 DataStore 状态
private func loadItems(vaultId: UUID) -> [VaultItem] {
    let file = dataStore.appSupportDir.appendingPathComponent("vault-\(vaultId.uuidString).json")
    guard let data = try? Data(contentsOf: file) else { return [] }
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode([VaultItem].self, from: data)) ?? []
}

// exportData / exportCSV / buildBundleJSON / buildOnePUXZip 均加 vaultId: UUID? = nil
// vaultId != nil 时调用 loadItems(vaultId:)，否则用 dataStore.vaultItems
func exportData(password: String?, vaultId: UUID? = nil) throws -> (data: Data, fileExt: String)
func exportCSV(vaultId: UUID? = nil) throws -> Data
private func buildBundleJSON(vaultId: UUID? = nil) throws -> Data
private func buildOnePUXZip(vaultId: UUID? = nil) throws -> Data
```

#### `Views/ExportWizardSheet.swift`（修改）

```swift
@StateObject private var vaultManager = VaultManager.shared
@State private var selectedVaultId: UUID = VaultManager.shared.selectedVaultId ?? UUID()

// 格式选择步骤顶部，vaults.count > 1 时显示
if vaultManager.vaults.count > 1 {
    Picker("保险库", selection: $selectedVaultId) {
        ForEach(vaultManager.vaults) { v in Text(v.name).tag(v.id) }
    }.pickerStyle(.menu)
}

// runExport 中
let exportVaultId = vaultManager.vaults.count > 1 ? selectedVaultId : vaultManager.selectedVaultId
let vaultName = vaultManager.vaults.first { $0.id == exportVaultId }?.name ?? "保险库"
// 文件名：OneOfPassword-<vaultName>-<yyyyMMdd-HHmm>.<ext>
service.exportData(password: pwd, vaultId: exportVaultId)
service.exportCSV(vaultId: exportVaultId)
```

---

### 验证步骤

1. `xcodebuild` 编译无错误 ✅（已验证）
2. 首次启动：自动迁移旧 `vault.json`，边栏显示"保险库"
3. 新建保险库 → 边栏出现新条目，切换后列表为空，条目独立
4. 重命名 → 边栏名称和 `vaults.json` 更新
5. 删除非空保险库 → 弹确认框 → 删除后切换保险库，EncryptedStore 对应条目清理
6. 导出选择非默认保险库 → 文件名含保险库名 → 内容正确
7. 导入多保险库时弹选择框，导入到选定保险库
8. 重启 app，保险库列表和条目均正确恢复

---

## 其他待办

<!-- 后续新增优化项可追加在此 -->
