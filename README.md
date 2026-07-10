# OneOfPassword for Mac

原生 macOS 密码与两步验证管理应用，使用 Swift + SwiftUI 开发。当前版本：**1.16**

---

## 功能概览

### 保险库（密码管理）
- 密码条目的增删改查，支持标题、用户名、密码、网站、分类字段
- 随机密码生成器
- 自定义字段：支持普通（string）和加密（concealed）两种类型
- 内联便签：每个密码条目可附加多条便签，支持置顶
- 关联验证器：密码条目详情页直接展示同名 TOTP 验证器
- 收藏星标：在详情页一键收藏，收藏条目始终置顶显示
- 第二列顶部内联搜索框（实时过滤）+ 排序选择器（修改时间 / 创建时间 / 名称）

### 两步验证（TOTP）
- 兼容 Google Authenticator / 1Password / Authy 等标准 TOTP
- 二维码扫描添加（摄像头）
- 手动输入 Secret 添加
- 解析 `otpauth://` URI（含 issuer、digits、period 参数）
- 实时倒计时圆环，剩余 ≤10 秒变色提示
- 一键复制验证码

### 导入 / 导出（设置页）

| 操作 | 格式 | 说明 |
|------|------|------|
| 导出（不加密） | `.1pux` | 标准 1Password 导出格式（ZIP + export.data），可直接导入 1Password |
| 导出（加密） | `.1pwd` | AES-GCM 加密 JSON，需导入密码解密 |
| 导入备份 | `.1pwd` | 支持有密码 / 无密码，重复条目自动跳过 |
| 从 1Password 导入 | `.1pux` | 解析 accounts/vaults/items 层级，支持所有已知 categoryUuid |

导出功能采用向导式交互（三步：选格式 → 加密设置 → 确认导出）。

**1pux 导入细节：**
- loginFields → 用户名 / 密码
- sections.totp → GAItem（解析 `otpauth://` URI 或直接 secret）
- sections.concealed → 加密自定义字段（存入 EncryptedStore）
- sections.string → 普通自定义字段
- sections.date / address / phone / url 等未知类型 → 静默忽略，汇总提示「忽略未知字段 N 个」
- 单条解析失败不中断整体导入


### 安全存储
- 所有敏感数据（密码、GA Secret、concealed 自定义字段）使用 AES-GCM 加密存储到本地文件（`EncryptedStore`），彻底规避 macOS Keychain 权限弹窗
- 元数据（标题、用户名、网站等）明文存储为 JSON
- 无网络请求，完全本地运行

---

## 界面布局

三列 `NavigationSplitView`：

| 列 | 内容 | 宽度 |
|----|------|------|
| 第一列 | 侧边栏（保险库 / 设置） | 160–200px |
| 第二列 | 保险库列表（含搜索框）；设置时隐藏 | 200–392px |
| 第三列 | 条目详情预览 / 设置页 | 剩余空间 |

- 窗口最小尺寸：1250 × 780
- 选中设置时第二列自动折叠，设置页占满第三列

---

## 项目结构

```
OneOfPassword/
├── Models/
│   ├── PasswordItem.swift         # 密码条目（含 CustomField、VaultNote）
│   ├── GAItem.swift               # TOTP 验证器条目
│   ├── NoteItem.swift             # 独立便签条目
│   └── ItemCategory.swift         # 分类枚举
├── Services/
│   ├── EncryptedStore.swift       # AES-GCM 本地加密存储（替代 Keychain）
│   ├── KeychainService.swift      # 加密存储统一接口（password / ga / customfield）
│   ├── DataStore.swift            # 元数据持久化（JSON）
│   ├── TOTPGenerator.swift        # TOTP 算法（HMAC-SHA1 + Base32）
│   ├── ImportExportService.swift  # .1pwd 导入导出 / .1pux 导出
│   ├── OnePUXImporter.swift       # .1pux 导入解析
│   └── QRCodeDetector.swift       # 二维码识别
├── ViewModels/
│   ├── PasswordListViewModel.swift
│   ├── GAListViewModel.swift
│   ├── NoteListViewModel.swift
│   └── AccountListViewModel.swift
└── Views/
    ├── ContentView.swift           # 三列 NavigationSplitView 主框架
    ├── AccountListView.swift       # 保险库列表（含内联搜索框）
    ├── VaultPreviewViews.swift     # 密码/GA 只读预览（含 CustomFieldInlineRow）
    ├── ItemDetailView.swift        # 编辑条目（密码 + 自定义字段 + 便签 + 验证器）
    ├── ExportWizardSheet.swift     # 导出向导（三步）
    ├── GADetailView.swift          # 验证器编辑表单
    ├── GAListView.swift            # 验证器列表
    ├── NoteListView.swift          # 便签列表
    ├── NoteEditorView.swift        # 便签编辑器
    ├── QRScannerView.swift         # 摄像头二维码扫描
    ├── SettingsView.swift          # 设置（导入导出、数据统计）
    └── Components/                 # 公共 UI 组件
```

---

## 数据模型

### PasswordItem
```
id, title, username, website, notes, category
keychainId          → EncryptedStore 中密码的 key
vaultNotes[]        → 内联便签列表
customFields[]      → 自定义字段（CustomField）
isFavorite          → 收藏标记，收藏条目在列表中始终置顶
```

### CustomField
```
id, label
value               → 普通字段的值；concealed 字段存空字符串
isConcealed         → true = 值存在 EncryptedStore
concealedKeychainId → EncryptedStore 中的 key
```

### GAItem
```
id, title, label, issuer, accountName, digits, period
keychainId          → EncryptedStore 中 secret 的 key
```

---

## 构建

### 前置要求
- macOS 13.0+
- Xcode 16.0+
- [xcodegen](https://github.com/yonaskolb/XcodeGen)

### 步骤

```bash
git clone <repo>
cd OneOfPassword-Mac

# 安装 xcodegen（如未安装）
brew install xcodegen

# 生成 Xcode 项目并编译
xcodegen generate
xcodebuild -scheme OneOfPassword -configuration Release -quiet

# 或使用打包脚本（生成含安装说明的 DMG）
./build.sh 1.16
```

打包脚本会生成 `build/OneOfPassword-1.15.dmg`，DMG 内含：
- `OneOfPassword.app`
- `Applications` 快捷方式
- `安装说明.txt`（含 Gatekeeper 绕过说明）

---

## 安装（分发包）

1. 打开 DMG，将 `OneOfPassword.app` 拖入 `Applications`
2. 首次打开若提示「无法验证开发者」：
   - **方法一（推荐）**：右键点击 app → 选择「打开」→ 点击弹窗中的「打开」
   - **方法二（终端）**：`xattr -dr com.apple.quarantine /Applications/OneOfPassword.app`

---

## 系统要求

- macOS 13.0 Ventura 或更高版本
- 摄像头权限（仅二维码扫描功能需要）

---

## 已知限制

- 不支持主密码 / Touch ID 保护（计划中）
- 不支持 iCloud / 云同步
- 不支持 HOTP（仅 TOTP）
- 1pux 导入：date / address / phone / url 类型自定义字段忽略不导入
- 1pux导入的一次性密码，还有问题，每个GA在1Password都有自定义的备注，但是导入之后都变成 "1Password导入"
- 系统菜单中, 增加 文件 菜单， 作为 导入和导出相关的 备用入口
- 请用提供的示例 1pux 文件, 执行导入， 然后再执行导出, 比对两者的差异
