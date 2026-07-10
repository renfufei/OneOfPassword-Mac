# OneOfPassword Mac - 项目配置指南

本文档详细说明如何在 Xcode 中设置和构建 OneOfPassword Mac 应用。

## 快速开始

### 步骤 1: 创建 Xcode 项目

1. 打开 Xcode
2. 选择 **File** > **New** > **Project**
3. 在模板选择界面：
   - 选择 **macOS** 标签页
   - 选择 **App** 模板
   - 点击 **Next**

### 步骤 2: 配置项目信息

填写以下信息：

- **Product Name**: `OneOfPassword`
- **Team**: 选择你的开发团队（个人或组织）
- **Organization Identifier**: `com.yourname` (例如: `com.felix`)
- **Bundle Identifier**: 会自动生成为 `com.yourname.OneOfPassword`
- **Interface**: 选择 **SwiftUI**
- **Language**: 选择 **Swift**
- **取消勾选**:
  - ☐ Use Core Data
  - ☐ Include Tests

点击 **Next**，选择保存位置，点击 **Create**。

### 步骤 3: 导入源代码文件

Xcode 会创建默认的项目结构。现在需要替换和添加文件：

#### 3.1 删除默认文件

在 Xcode 项目导航器中，删除以下文件（选中后按 Delete，选择 "Move to Trash"）：
- `ContentView.swift`（我们有自己的版本）
- `OneOfPasswordApp.swift`（如果存在默认版本）

#### 3.2 添加文件夹和文件

方法一：使用 Finder

1. 在 Finder 中打开项目目录下的 `OneOfPassword` 文件夹
2. 将本仓库中的所有文件和文件夹拖拽到 Xcode 项目导航器中
3. 在弹出的对话框中：
   - ✅ 勾选 "Copy items if needed"
   - ✅ 选择 "Create groups"
   - ✅ 确保 Target 勾选了 "OneOfPassword"

方法二：手动添加

1. 在 Xcode 中，右键点击 `OneOfPassword` 文件夹
2. 选择 **Add Files to "OneOfPassword"...**
3. 依次添加以下文件夹：
   - Models/
   - Services/
   - ViewModels/
   - Views/
   - Utils/

最终项目结构应该如下：

```
OneOfPassword/
├── OneOfPasswordApp.swift
├── Models/
│   ├── PasswordItem.swift
│   ├── GAItem.swift
│   └── ItemCategory.swift
├── Services/
│   ├── KeychainService.swift
│   ├── DataStore.swift
│   └── TOTPGenerator.swift
├── ViewModels/
│   ├── PasswordListViewModel.swift
│   └── GAListViewModel.swift
├── Views/
│   ├── ContentView.swift
│   ├── PasswordListView.swift
│   ├── ItemDetailView.swift
│   ├── GAListView.swift
│   ├── GADetailView.swift
│   ├── QRScannerView.swift
│   └── Components/
│       ├── PasswordItemRow.swift
│       ├── GAItemRow.swift
│       └── CopyButton.swift
└── Utils/
    ├── ClipboardManager.swift
    └── Extensions.swift
```

### 步骤 4: 配置 Info.plist

1. 在 Xcode 项目导航器中找到 `Info.plist`
2. 右键点击，选择 **Open As** > **Source Code**
3. 复制本仓库提供的 `Info.plist` 内容并替换
4. 或者手动添加以下权限：
   - 在 Info.plist 中点击 **+** 添加新行
   - 选择 **Privacy - Camera Usage Description**
   - 值设置为：`需要摄像头权限来扫描 GA 二维码`

### 步骤 5: 配置构建设置

#### 5.1 设置最低系统版本

1. 选择项目文件（蓝色图标）
2. 选择 **OneOfPassword** Target
3. 在 **General** 标签页中：
   - 找到 **Minimum Deployments**
   - 将 **macOS** 设置为 `13.0`

#### 5.2 配置 Signing

1. 在 **Signing & Capabilities** 标签页中：
   - 确保 **Automatically manage signing** 已勾选
   - 选择你的 **Team**
   - 确认 **Bundle Identifier** 正确

#### 5.3 添加 Keychain Sharing（可选但推荐）

1. 点击 **+ Capability** 按钮
2. 搜索并添加 **Keychain Sharing**
3. 会自动添加一个 Keychain Group：`$(AppIdentifierPrefix)com.yourname.OneOfPassword`

### 步骤 6: 构建项目

1. 选择运行目标为 **My Mac**
2. 点击 **Product** > **Build** (或按 ⌘B)
3. 等待构建完成，检查是否有错误

#### 可能遇到的错误及解决方案

**错误 1: "Cannot find type 'X' in scope"**
- 确保所有文件都已添加到项目
- 确保文件的 Target Membership 包含了 OneOfPassword

**错误 2: "Module 'CommonCrypto' not found"**
- CommonCrypto 是系统框架，应该自动可用
- 检查 Build Phases > Link Binary With Libraries 中是否有冲突

**错误 3: 相机权限相关错误**
- 确保 Info.plist 中添加了 `NSCameraUsageDescription`

### 步骤 7: 运行应用

1. 点击 **Product** > **Run** (或按 ⌘R)
2. 应用会在 Mac 上启动
3. 首次运行时，扫描二维码功能会请求摄像头权限

## 测试功能

### 测试密码管理

1. 点击左侧 "密码"
2. 点击 "+" 添加新密码
3. 填写信息并保存
4. 右键点击密码项，测试复制功能

### 测试 GA 验证器

#### 方法 1: 手动添加测试

使用以下测试数据：

- **标题**: `Test Account`
- **账户名**: `test@example.com`
- **Secret**: `JBSWY3DPEHPK3PXP`

保存后应该能看到 6 位验证码和倒计时。

#### 方法 2: 扫描二维码

1. 在手机或另一台设备上打开 [Google Authenticator Demo](https://rootprojects.org/authenticator/)
2. 生成一个测试二维码
3. 在应用中点击 "扫描二维码"
4. 允许摄像头权限
5. 扫描二维码

### 验证 Keychain 存储

1. 打开 **Keychain Access** 应用（在 Applications/Utilities）
2. 选择 **login** keychain
3. 搜索 `oneofpassword`
4. 应该能看到存储的密码和 GA secret

## 调试技巧

### 查看日志

在代码中添加打印语句：

```swift
print("Debug: \(variableName)")
```

在 Xcode 底部的 Console 中查看输出。

### 断点调试

1. 在代码行号左侧点击添加断点（蓝色标记）
2. 运行应用，执行到断点时会暂停
3. 使用调试工具栏检查变量值

### 清除数据

如果需要清除所有数据重新测试：

```swift
// 在 DataStore 初始化时添加：
UserDefaults.standard.removeObject(forKey: "passwordItems")
UserDefaults.standard.removeObject(forKey: "gaItems")
```

## 发布应用

### 创建 Archive

1. 选择 **Product** > **Archive**
2. 等待构建完成
3. 在 Organizer 中选择 Archive
4. 点击 **Distribute App**
5. 选择分发方式：
   - **Copy App**: 直接导出应用
   - **Developer ID**: 用于分发给其他 Mac 用户
   - **Mac App Store**: 提交到 App Store

### 导出可执行文件

1. Archive 完成后，选择 **Distribute App**
2. 选择 **Copy App**
3. 选择导出位置
4. 生成的 `.app` 文件可以直接运行

## 常见问题

### Q: 应用无法启动或崩溃

**A**: 检查以下内容：
- 确保最低系统版本设置正确（macOS 13.0）
- 检查 Console 中的崩溃日志
- 确保所有必需的文件都已添加

### Q: 无法访问摄像头

**A**:
- 检查 Info.plist 中的摄像头权限描述
- 在系统偏好设置 > 安全性与隐私 > 摄像头 中检查权限

### Q: Keychain 存储失败

**A**:
- 检查 Keychain Access 应用中是否有权限问题
- 尝试删除旧的 Keychain 条目后重试

### Q: TOTP 验证码不正确

**A**:
- 确保 Secret 格式正确（Base32 编码）
- 检查系统时间是否准确（TOTP 依赖时间）
- 验证 Secret 是否去除了空格

## 性能优化

### 减少内存占用

- 使用 `@StateObject` 而非 `@ObservedObject` 创建 ViewModel
- 及时释放不需要的资源

### 优化列表性能

- GA 列表使用 `LazyVStack` 处理大量数据
- 避免在 `body` 中进行复杂计算

## 扩展开发

### 添加新功能

1. 在相应的文件夹中创建新文件
2. 遵循现有的代码结构和命名规范
3. 更新 ViewModel 添加业务逻辑
4. 在 View 中集成新功能

### 自定义主题

在 `Utils/Extensions.swift` 中修改颜色定义：

```swift
extension Color {
    static let primaryAccent = Color.purple  // 修改主色调
}
```

## 获取帮助

- 查看 [README.md](README.md) 了解功能说明
- 查看代码注释了解实现细节
- 参考 [Apple Developer Documentation](https://developer.apple.com/documentation/)

## 许可证

MIT License - 详见 README.md
