# OneOfPassword Mac 开发记录

> AI 辅助开发会话记录

---

## 1. 项目初始化

- 按照预定计划创建完整项目目录结构
- 创建 20 个 Swift 源文件（Models / Services / ViewModels / Views / Utils）
- 使用 `xcodegen` 从 `project.yml` 生成 `.xcodeproj`

---

## 2. 编译修复

- 移除 `GADetailView.swift` 中 iOS 专属的 `.autocapitalization(.allCharacters)`
- 首次编译通过

---

## 3. 二维码扫描修复

- **问题**：`AVCaptureMetadataOutput` 的 `.qr` 类型在 macOS 不支持，运行时 crash
- **修复**：改用 `AVCaptureVideoDataOutput` + `Vision` 框架逐帧识别

---

## 4. 扫描功能扩展

- 新增 `QRCodeDetector.swift`（公共 Vision 识别逻辑）
- 扫描入口扩展为三种方式：
  - **摄像头扫描**（原有）
  - **截取屏幕**：调用系统 `screencapture -i -s` 框选区域
  - **选择图片**：`NSOpenPanel` 选文件，支持 PNG / JPEG / HEIC 等
- 修复 `import ScreenCaptureKit` 导致 sheet 无法显示的问题
- 修复 `showingCamera` 缺少 `.sheet` 绑定导致摄像头入口无响应的问题

---

## 5. 便签功能

- 新增 `NoteItem.swift` 数据模型
- 新增 `NoteListViewModel.swift`（支持置顶、搜索）
- 新增 `NoteListView.swift`（左列表 + 右编辑器 Split 布局）
- 新增 `NoteEditorView.swift`（500ms 防抖自动保存）
- 侧边栏加入「便签」入口

---

## 6. 存储迁移

- **问题**：所有数据存在系统全局 `UserDefaults`（`~/Library/Preferences/`）
- **修复**：迁移到应用专属目录 `~/Library/Application Support/com.oneofpassword.app/`
  - `passwords.json` / `ga.json` / `notes.json` 原子写入
  - 首次启动自动从 UserDefaults 迁移旧数据并清除

---

## 7. 导入 / 导出 + 设置页

- 新增 `ImportExportService.swift`
  - 导出格式：`.1pwd`（JSON，含密码明文）
  - 可选 AES-GCM 256 位加密保护
  - 导入时以 `id` 去重，重复条目自动跳过
- 新增 `SettingsView.swift`，包含：
  - 导入 / 导出操作区
  - 数据统计（密码 / 验证器 / 便签条目数）
  - 存储路径展示（支持 Finder 跳转）
- 侧边栏加入「设置」入口，同时支持 `⌘,` 快捷键

---

## 8. 打包脚本

- 新建 `build.sh`，4 步流程：xcodegen → Release 编译 → ad-hoc 签名 → 打包 DMG
- 支持传入版本号参数：`./build.sh 1.1`
- 编译日志保存至 `build/build.log`
- 完成后在 Finder 中高亮显示 DMG 文件

---

## 9. 账户合并视图

- 新增 `AccountListViewModel.swift`
  - 将密码和 GA 按 `title` 聚合为 `AccountGroup`，同一站点的条目归为一组
  - 合并了原 `PasswordListViewModel` 和 `GAListViewModel` 的全部职责
- 新增 `AccountListView.swift`，替换原来分开的密码列表和 GA 列表
  - 密码行：内联显示「复制用户名」「复制密码」「编辑」三个按钮
  - GA 行：点击验证码数字直接复制，独立「编辑」按钮
  - 复制后图标变绿 ✓，1.5 秒后还原
  - 工具栏 `+` 菜单合并「添加密码」「手动添加验证器」「扫描二维码」三个入口
  - 支持右键菜单和滑动删除
- `ContentView` 侧边栏「密码」+「验证器」两个入口合并为「账户」一个入口

---

## 10. 导出密码字段为空 Bug 修复

- **问题**：导出明文时密码字段全部为空
- **根因**：SwiftUI `fileExporter` 修饰器在渲染时捕获 `document` 绑定，当 `performExport()` 同一调用中同时设置 `exportData` 和 `showExportPanel = true` 时，文档绑定在数据填充前就已评估，导致写出空内容
- **修复**：移除 `fileExporter` 修饰器，改用 `NSSavePanel` 直接写文件
  - `exportData(password:)` 先在内存中生成完整数据
  - 再弹出 `NSSavePanel` 让用户选择保存路径
  - 确认后用 `Data.write(to:options:.atomic)` 原子写入
  - 整个流程同步完成，不存在时序问题

---

## 打包历史

| 版本 | DMG 大小 | 备注 |
|------|---------|------|
| 1.0  | 296 KB  | 初始版本 |
| 1.1  | 632 KB  | 新增便签、设置、导入导出 |
| 1.2  | 632 KB  | 密码与验证器合并为账户视图，新增内联复制按钮 |
| 1.3  | 628 KB  | 修复导出密码字段为空的 Bug |
| 1.4  | 628 KB  | 升级版本号，同步 project.yml 默认版本为 1.4 (build 4) |
