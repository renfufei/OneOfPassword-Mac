# OneOfPassword Mac - 开发文档

本文档面向开发者，详细说明项目架构、核心实现和扩展指南。

## 架构概览

### MVVM 架构

项目采用 MVVM (Model-View-ViewModel) 架构：

```
┌─────────────┐
│    View     │ ← SwiftUI Views
└──────┬──────┘
       │ binds to
       ↓
┌─────────────┐
│  ViewModel  │ ← Business Logic
└──────┬──────┘
       │ uses
       ↓
┌─────────────┐
│   Model     │ ← Data Models
└──────┬──────┘
       │ uses
       ↓
┌─────────────┐
│  Services   │ ← Keychain, Storage, TOTP
└─────────────┘
```

### 数据流

```
User Interaction → View → ViewModel → Service → Storage (Keychain/UserDefaults)
                     ↑        ↓
                     └────────┘
                   @Published updates
```

## 核心模块详解

### 1. Models (数据模型)

#### PasswordItem.swift

```swift
struct PasswordItem: Identifiable, Codable {
    let id: UUID                    // 唯一标识
    var title: String               // 显示标题
    var username: String            // 用户名
    var website: String?            // 网站（可选）
    var notes: String?              // 备注（可选）
    var category: ItemCategory      // 分类
    var createdAt: Date             // 创建时间
    var updatedAt: Date             // 更新时间
    var keychainId: String          // Keychain 关联 ID
}
```

**设计要点**:
- `keychainId` 用于关联 Keychain 中的实际密码
- 元数据存储在 UserDefaults，敏感数据在 Keychain
- `Codable` 支持 JSON 序列化

#### GAItem.swift

```swift
struct GAItem: Identifiable, Codable {
    let id: UUID                    // 唯一标识
    var title: String               // 显示标题
    var issuer: String?             // 发行者（如 Google、GitHub）
    var accountName: String         // 账户名
    var digits: Int                 // 验证码位数（通常为 6）
    var period: Int                 // 有效期（秒，通常为 30）
    var createdAt: Date             // 创建时间
    var keychainId: String          // Keychain 关联 ID
}
```

**设计要点**:
- `digits` 和 `period` 可配置，支持非标准 TOTP
- Secret 存储在 Keychain，不在此模型中

### 2. Services (服务层)

#### KeychainService.swift

**核心实现**:

```swift
private func save(id: String, value: String, service: String) throws {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: id,
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    // 错误处理...
}
```

**安全特性**:
- 使用 `kSecAttrAccessibleWhenUnlocked`：仅在设备解锁时可访问
- 每个密码/Secret 有独立的 `account` 标识
- 通过 `service` 区分密码和 GA Secret

**Keychain 结构**:

```
Service: com.oneofpassword.password
├── Account: UUID-1 → Password Data
├── Account: UUID-2 → Password Data
└── ...

Service: com.oneofpassword.ga
├── Account: UUID-1 → Secret Data
├── Account: UUID-2 → Secret Data
└── ...
```

#### TOTPGenerator.swift

**TOTP 算法实现**:

```swift
func generateTOTP(secret: String, digits: Int = 6, period: Int = 30) -> String? {
    // 1. Base32 解码 secret
    guard let keyData = base32Decode(secret) else { return nil }

    // 2. 计算时间计数器（当前时间 / period）
    let counter = UInt64(Date().timeIntervalSince1970 / Double(period))

    // 3. HMAC-SHA1 计算
    let hash = hmacSHA1(key: keyData, data: counterData)

    // 4. Dynamic Truncation
    let offset = Int(hash[hash.count - 1] & 0x0f)
    let truncatedHash = hash.subdata(in: offset..<offset + 4)

    // 5. 生成验证码
    let otp = (value & 0x7fffffff) % UInt32(pow(10, Double(digits)))
    return String(format: "%0*d", digits, otp)
}
```

**TOTP 原理**:

```
Secret (Base32) → Decode → Key
                            ↓
Time → Counter (T/30) → HMAC-SHA1(Key, Counter) → Truncate → OTP
```

**Base32 解码**:
- 标准 Base32 字母表: `ABCDEFGHIJKLMNOPQRSTUVWXYZ234567`
- 每个字符编码 5 bits
- 8 个字符 = 40 bits = 5 bytes

**otpauth:// URL 格式**:

```
otpauth://totp/Google:user@gmail.com?secret=JBSWY3DPEHPK3PXP&issuer=Google
         │     │                       │                      │
         │     │                       │                      └─ 发行者
         │     │                       └─ Secret Key
         │     └─ 账户名（可能包含发行者前缀）
         └─ 类型（totp/hotp）
```

#### DataStore.swift

**数据管理**:

```swift
class DataStore: ObservableObject {
    @Published var passwordItems: [PasswordItem] = []
    @Published var gaItems: [GAItem] = []

    // 持久化到 UserDefaults
    private func persistPasswordItems() {
        if let data = try? JSONEncoder().encode(passwordItems) {
            UserDefaults.standard.set(data, forKey: "passwordItems")
        }
    }
}
```

**设计决策**:
- 使用 UserDefaults 而非 Core Data：简化实现，数据量小
- `@Published` 自动通知 UI 更新
- Singleton 模式确保数据一致性

### 3. ViewModels (视图模型)

#### PasswordListViewModel.swift

**职责**:
- 管理密码列表状态
- 协调 Keychain 和 DataStore 操作
- 提供搜索过滤功能
- 生成随机密码

**关键方法**:

```swift
func savePassword(item: PasswordItem, password: String) {
    // 1. 保存密码到 Keychain
    try keychainService.savePassword(id: item.keychainId, password: password)

    // 2. 更新元数据
    var updatedItem = item
    updatedItem.updatedAt = Date()
    dataStore.savePasswordItem(updatedItem)
}
```

#### GAListViewModel.swift

**职责**:
- 管理 GA 列表状态
- 实时生成 TOTP 验证码
- 管理倒计时定时器
- 解析二维码

**定时器机制**:

```swift
private func startTimer() {
    timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
        Task { @MainActor in
            self?.updateTimer()
        }
    }
}

private func updateTimer() {
    remainingTime = totpGenerator.getRemainingTime()

    // 当倒计时归零时重新生成验证码
    if remainingTime == 30 || remainingTime == 29 {
        updateAllTOTPCodes()
    }
}
```

**性能优化**:
- 每秒只更新倒计时，不重新计算验证码
- 仅在新周期开始时重新生成验证码
- 使用字典缓存验证码：`[UUID: String]`

### 4. Views (视图)

#### ContentView.swift

**主界面结构**:

```swift
NavigationSplitView {
    // 左侧边栏
    List {
        NavigationLink(destination: PasswordListView()) {
            Label("密码", systemImage: "key.fill")
        }
        NavigationLink(destination: GAListView()) {
            Label("验证器", systemImage: "shield.checkered")
        }
    }
} detail: {
    // 右侧详情（默认空状态）
    EmptyView()
}
```

**macOS 特性**:
- `NavigationSplitView` 提供原生侧边栏体验
- 支持键盘导航
- 自动保存侧边栏宽度

#### GAItemRow.swift

**倒计时进度条**:

```swift
ZStack {
    // 背景圆环
    Circle()
        .stroke(Color.gray.opacity(0.2), lineWidth: 3)

    // 进度圆环
    Circle()
        .trim(from: 0, to: progress)  // progress = remainingTime / period
        .stroke(progressColor, lineWidth: 3)
        .rotationEffect(.degrees(-90))  // 从顶部开始

    // 倒计时数字
    Text("\(remainingTime)")
}
```

**颜色指示**:
- 剩余 > 10 秒：蓝色
- 剩余 6-10 秒：橙色
- 剩余 ≤ 5 秒：红色

#### QRScannerView.swift

**摄像头集成**:

```swift
class CameraPreview: NSView, AVCaptureMetadataOutputObjectsDelegate {
    private var captureSession: AVCaptureSession?

    private func setupCamera() {
        let session = AVCaptureSession()

        // 1. 添加视频输入
        let videoInput = try? AVCaptureDeviceInput(device: videoCaptureDevice)
        session.addInput(videoInput)

        // 2. 添加元数据输出
        let metadataOutput = AVCaptureMetadataOutput()
        metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
        metadataOutput.metadataObjectTypes = [.qr]
        session.addOutput(metadataOutput)

        // 3. 创建预览图层
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        self.layer?.addSublayer(previewLayer)

        // 4. 启动会话
        session.startRunning()
    }

    // 二维码识别回调
    func metadataOutput(...) {
        if let stringValue = metadataObject.stringValue {
            delegate?.didDetectQRCode(stringValue)
        }
    }
}
```

### 5. Utils (工具类)

#### ClipboardManager.swift

**自动清空机制**:

```swift
func copy(_ text: String, autoClearAfter seconds: TimeInterval = 30) {
    // 1. 复制到剪贴板
    NSPasteboard.general.setString(text, forType: .string)

    // 2. 设置定时器
    clearTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) {
        self?.clearIfMatches(text)
    }
}

private func clearIfMatches(_ originalText: String) {
    // 只有剪贴板内容未被修改时才清空
    if NSPasteboard.general.string(forType: .string) == originalText {
        NSPasteboard.general.clearContents()
    }
}
```

**安全考虑**:
- 防止清空用户后续复制的其他内容
- 可配置清空时间（默认 30 秒）

## 数据安全

### 安全存储策略

```
┌─────────────────────────────────┐
│   UserDefaults (不安全)          │
│   ├─ 标题、用户名、网站          │
│   ├─ 分类、备注                  │
│   └─ 时间戳、keychainId         │
└─────────────────────────────────┘
              │
              ↓ keychainId 关联
┌─────────────────────────────────┐
│   Keychain (硬件加密)            │
│   ├─ 密码 (Password)             │
│   └─ GA Secret                   │
└─────────────────────────────────┘
```

### Keychain 访问控制

- `kSecAttrAccessibleWhenUnlocked`: 设备锁定时无法访问
- 可选：启用 Keychain Sharing 用于应用组共享
- 未来：可添加 Touch ID / Face ID 保护

## 性能优化

### 1. 列表性能

**问题**: 大量密码项时滚动卡顿

**解决方案**:
- SwiftUI `List` 已自动懒加载
- 避免在 `body` 中进行复杂计算
- 使用 `@StateObject` 避免重复创建 ViewModel

### 2. TOTP 计算

**优化策略**:
- 缓存当前周期的验证码
- 仅在新周期开始时重新计算
- 使用字典存储：O(1) 查找

### 3. 内存管理

**注意事项**:
- Timer 使用 `[weak self]` 避免循环引用
- Camera Session 在 `deinit` 中停止
- 及时释放不需要的资源

## 测试

### 单元测试建议

```swift
// 测试 TOTP 生成
func testTOTPGeneration() {
    let generator = TOTPGenerator.shared
    let secret = "JBSWY3DPEHPK3PXP"
    let code = generator.generateTOTP(secret: secret, digits: 6, period: 30)
    XCTAssertEqual(code?.count, 6)
}

// 测试 Keychain 存储
func testKeychainStorage() throws {
    let service = KeychainService.shared
    let testID = "test-123"
    let testPassword = "password123"

    try service.savePassword(id: testID, password: testPassword)
    let retrieved = try service.getPassword(id: testID)
    XCTAssertEqual(retrieved, testPassword)

    try service.deletePassword(id: testID)
}
```

### 手动测试清单

- [ ] 添加密码并重启应用，验证持久化
- [ ] 添加 GA 项，验证验证码正确性（使用在线工具对比）
- [ ] 测试倒计时在归零时自动刷新验证码
- [ ] 测试搜索功能
- [ ] 测试复制功能和自动清空
- [ ] 测试二维码扫描（使用 Google Authenticator 生成的二维码）
- [ ] 测试删除功能，验证 Keychain 同步删除
- [ ] 在 Keychain Access 应用中验证数据存储

## 扩展指南

### 添加新的密码分类

1. 修改 `ItemCategory.swift`:

```swift
enum ItemCategory: String, Codable, CaseIterable {
    case general = "通用"
    case work = "工作"
    case newCategory = "新分类"  // 添加这里
    // ...
}
```

2. UI 会自动更新（因为使用了 `allCases`）

### 添加主密码保护

1. 创建 `MasterPasswordService.swift`:

```swift
class MasterPasswordService {
    func verifyMasterPassword(_ password: String) -> Bool
    func setMasterPassword(_ password: String)
    func isLocked() -> Bool
}
```

2. 在 `OneOfPasswordApp.swift` 中添加锁屏检查:

```swift
@main
struct OneOfPasswordApp: App {
    @State private var isUnlocked = false

    var body: some Scene {
        WindowGroup {
            if isUnlocked {
                ContentView()
            } else {
                MasterPasswordView(isUnlocked: $isUnlocked)
            }
        }
    }
}
```

### 添加 iCloud 同步

1. 启用 iCloud Capability
2. 使用 `NSUbiquitousKeyValueStore` 同步元数据
3. Keychain 自动支持 iCloud 同步（需配置）

### 添加密码强度检测

```swift
func checkPasswordStrength(_ password: String) -> PasswordStrength {
    var score = 0
    if password.count >= 8 { score += 1 }
    if password.rangeOfCharacter(from: .uppercaseLetters) != nil { score += 1 }
    if password.rangeOfCharacter(from: .lowercaseLetters) != nil { score += 1 }
    if password.rangeOfCharacter(from: .decimalDigits) != nil { score += 1 }
    if password.rangeOfCharacter(from: CharacterSet(charactersIn: "!@#$%^&*")) != nil { score += 1 }

    switch score {
    case 0...2: return .weak
    case 3: return .medium
    case 4...5: return .strong
    default: return .weak
    }
}
```

## 贡献指南

### 代码规范

- 使用 Swift 标准命名规范
- 每个文件顶部添加注释说明用途
- 复杂逻辑添加注释
- 使用 `// MARK: -` 分隔代码块

### Git 提交信息

```
feat: 添加新功能
fix: 修复 Bug
docs: 更新文档
refactor: 重构代码
perf: 性能优化
test: 添加测试
```

### Pull Request 流程

1. Fork 项目
2. 创建 feature 分支
3. 提交代码
4. 编写测试（如适用）
5. 提交 PR 并描述改动

## 参考资料

### Apple 官方文档

- [Keychain Services](https://developer.apple.com/documentation/security/keychain_services)
- [SwiftUI](https://developer.apple.com/documentation/swiftui)
- [AVFoundation](https://developer.apple.com/documentation/avfoundation)

### TOTP 标准

- [RFC 6238 - TOTP: Time-Based One-Time Password Algorithm](https://tools.ietf.org/html/rfc6238)
- [RFC 4226 - HOTP: An HMAC-Based One-Time Password Algorithm](https://tools.ietf.org/html/rfc4226)

### Base32 编码

- [RFC 4648 - The Base16, Base32, and Base64 Data Encodings](https://tools.ietf.org/html/rfc4648)

## 常见问题排查

### TOTP 验证码不匹配

1. 检查系统时间是否准确
2. 验证 Secret 格式（去除空格，大写）
3. 确认 `digits` 和 `period` 参数正确

### Keychain 访问失败

1. 检查 Code Signing 配置
2. 验证 Bundle Identifier
3. 尝试删除旧的 Keychain 条目

### 摄像头无法访问

1. 检查 Info.plist 权限配置
2. 在系统偏好设置中检查权限
3. 重启应用

## 许可证

MIT License - 详见 README.md
