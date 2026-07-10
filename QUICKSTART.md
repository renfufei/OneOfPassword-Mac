# OneOfPassword Mac - 快速开始指南

这是一个 5 分钟快速启动指南，帮助你快速运行 OneOfPassword 应用。

## 前置要求

- macOS 13.0 或更高版本
- Xcode 15.0 或更高版本
- Apple 开发者账号（免费账号即可）

## 快速启动步骤

### 1. 创建 Xcode 项目 (2 分钟)

打开终端，执行以下命令：

```bash
cd /path/to/OneOfPassword-Mac
open -a Xcode
```

在 Xcode 中：

1. **File** → **New** → **Project**
2. 选择 **macOS** → **App**
3. 填写信息：
   - Product Name: `OneOfPassword`
   - Interface: **SwiftUI**
   - Language: **Swift**
   - 取消勾选 Core Data 和 Tests
4. 保存到当前目录（与源代码同级）

### 2. 导入源代码 (1 分钟)

在 Xcode 项目导航器中：

1. 删除默认的 `ContentView.swift` 和 `OneOfPasswordApp.swift`
2. 将本仓库的 `OneOfPassword` 文件夹拖拽到 Xcode 中
3. 确保勾选：
   - ✅ Copy items if needed
   - ✅ Create groups
   - ✅ Target: OneOfPassword

### 3. 配置权限 (1 分钟)

在 `Info.plist` 中添加摄像头权限：

1. 右键点击 `Info.plist` → **Open As** → **Source Code**
2. 在 `<dict>` 标签内添加：

```xml
<key>NSCameraUsageDescription</key>
<string>需要摄像头权限来扫描 GA 二维码</string>
```

或者在 Xcode 中：

1. 选择项目 → Target → Info
2. 点击 **+** 添加 **Privacy - Camera Usage Description**
3. 值设置为：`需要摄像头权限来扫描 GA 二维码`

### 4. 配置最低系统版本 (30 秒)

1. 选择项目（蓝色图标）
2. 选择 **OneOfPassword** Target
3. **General** 标签页
4. **Minimum Deployments** → macOS 设置为 `13.0`

### 5. 运行应用 (30 秒)

1. 选择 **My Mac** 作为运行目标
2. 点击 **▶️ 按钮**或按 **⌘R**
3. 等待编译完成（首次编译约 30 秒）
4. 应用启动！🎉

## 快速测试

### 测试密码管理

1. 点击左侧 **"密码"**
2. 点击右上角 **"+"**
3. 填写表单：
   - 标题：`测试账号`
   - 用户名：`test@example.com`
   - 点击 **"生成随机密码"**
4. 点击 **"保存"**
5. 右键点击密码项 → **"复制密码"**

✅ 成功！密码已复制到剪贴板。

### 测试 GA 验证器

使用测试数据手动添加：

1. 点击左侧 **"验证器"**
2. 点击右上角 **"+"** → **"手动添加"**
3. 填写：
   - 标题：`Test Account`
   - 账户名：`test@example.com`
   - Secret Key：`JBSWY3DPEHPK3PXP`
4. 点击 **"保存"**

✅ 成功！你应该看到一个 6 位验证码和倒计时进度条。

### 验证 TOTP 正确性

1. 打开浏览器访问：https://rootprojects.org/authenticator/
2. 输入 Secret：`JBSWY3DPEHPK3PXP`
3. 对比生成的验证码与应用中显示的验证码

✅ 如果一致，说明 TOTP 实现正确！

### 测试二维码扫描

1. 在手机上打开：https://rootprojects.org/authenticator/
2. 点击 **"Show QR Code"**
3. 在应用中点击 **"+"** → **"扫描二维码"**
4. 允许摄像头权限
5. 对准手机屏幕扫描

✅ 成功！验证器自动添加。

## 常见问题

### Q: 编译失败，提示 "Cannot find 'X' in scope"

**A**: 确保所有文件都已添加到项目。检查方法：

1. 在 Xcode 中，点击项目 → Build Phases → Compile Sources
2. 应该看到所有 `.swift` 文件
3. 如果缺少文件，点击 **+** 添加

### Q: 运行时崩溃

**A**: 检查以下内容：

1. 确认最低系统版本设置为 macOS 13.0
2. 在 Xcode Console 中查看错误信息
3. 尝试 **Product** → **Clean Build Folder** (⇧⌘K) 后重新编译

### Q: 无法访问摄像头

**A**:

1. 确认 Info.plist 中有 `NSCameraUsageDescription`
2. 检查系统偏好设置 → 安全性与隐私 → 摄像头
3. 确保 OneOfPassword 有摄像头权限

### Q: TOTP 验证码不正确

**A**:

1. 检查系统时间是否准确（TOTP 依赖时间同步）
2. 确认 Secret 输入正确（大写，无空格）
3. 重启应用后重试

## 验证 Keychain 存储

1. 打开 **Keychain Access** 应用（在 `/Applications/Utilities/`）
2. 选择 **login** keychain
3. 搜索 `oneofpassword`
4. 应该能看到存储的密码和 GA secret

✅ 敏感数据已安全存储在 Keychain 中！

## 项目文件结构

运行成功后，你的项目结构应该是：

```
OneOfPassword-Mac/
├── OneOfPassword.xcodeproj           # Xcode 项目文件
├── OneOfPassword/
│   ├── OneOfPasswordApp.swift        # ✅ 应用入口
│   ├── Models/                       # ✅ 3 个文件
│   ├── Services/                     # ✅ 3 个文件
│   ├── ViewModels/                   # ✅ 2 个文件
│   ├── Views/                        # ✅ 7 个文件
│   │   └── Components/               # ✅ 3 个文件
│   ├── Utils/                        # ✅ 2 个文件
│   └── Assets.xcassets               # Xcode 自动生成
├── Info.plist
├── README.md
├── PROJECT_SETUP.md                  # 详细配置指南
├── DEVELOPMENT.md                    # 开发文档
└── QUICKSTART.md                     # 本文件
```

## 下一步

### 阅读文档

- 📖 [README.md](README.md) - 功能说明和使用指南
- 🛠 [PROJECT_SETUP.md](PROJECT_SETUP.md) - 详细配置说明
- 💻 [DEVELOPMENT.md](DEVELOPMENT.md) - 架构和开发指南

### 自定义应用

- 修改应用图标（Assets.xcassets）
- 调整 UI 颜色和样式（Utils/Extensions.swift）
- 添加新功能（参考 DEVELOPMENT.md）

### 发布应用

1. **Product** → **Archive**
2. **Distribute App** → **Copy App**
3. 导出 `.app` 文件

## 需要帮助？

- 🐛 遇到问题？查看 [PROJECT_SETUP.md](PROJECT_SETUP.md) 的常见问题部分
- 💡 想要了解实现细节？阅读 [DEVELOPMENT.md](DEVELOPMENT.md)
- 📝 想要扩展功能？参考 DEVELOPMENT.md 的扩展指南

## 成功检查清单

完成以下测试即表示应用运行正常：

- [ ] 应用成功编译并运行
- [ ] 能够添加密码项
- [ ] 能够添加 GA 验证器
- [ ] TOTP 验证码与在线工具一致
- [ ] 复制功能正常工作
- [ ] 倒计时每秒更新
- [ ] 重启应用后数据仍然存在
- [ ] 在 Keychain Access 中能看到存储的数据

如果以上全部通过，恭喜你！OneOfPassword 已成功运行！🎉

---

**享受使用 OneOfPassword 管理你的密码和验证器吧！** 🔐
