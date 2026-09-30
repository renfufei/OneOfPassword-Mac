//
//  ScreenshotSettingsView.swift
//  OneOfPassword
//
//  截屏功能设置页：快捷键开关 + F1-F12 选择 + 自动窗口识别 + 立即截屏。
//

import SwiftUI
import AppKit

struct ScreenshotSettingsView: View {
    @ObservedObject private var hk = ScreenshotHotkeyManager.shared
    @AppStorage("screenshotAutoWindow") private var autoWindow = false
    @AppStorage("screenshotAutoHide") private var autoHide = true
    @State private var logText: String = ""
    @State private var logExpanded: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                introSection
                hotkeySection
                permissionSection
                logSection
            }
            .padding(28)
        }
        .navigationTitle("截屏")
        .frame(minWidth: 520)
        .onAppear {
            hk.recheckOnActivation()
            reloadLog()
        }
    }

    // MARK: - 说明

    private var introSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("截屏", systemImage: "crop")
                    .font(.headline)
                Text("按下全局快捷键（默认 F1）进入区域截屏，拖动选区后可在选区上方使用矩形、圆形、箭头、画笔、文本进行标注，支持保存为 PNG 或复制到剪贴板。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Button {
                    ScreenshotOverlayController.shared.show()
                } label: {
                    Label("立即截屏", systemImage: "camera.viewfinder")
                }
                .buttonStyle(.primary())
                .padding(.top, 4)
            }
            .padding(8)
        }
    }

    // MARK: - 快捷键

    private var hotkeySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                Label("快捷键", systemImage: "keyboard")
                    .font(.headline)
                    .padding(.bottom, 10)

                Divider()

                Text("全局快捷键通过系统级热键注册（RegisterEventHotKey），无需「辅助功能」权限；钉钉等应用也采用此机制。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 4)

                toggleRow(label: "启用全局快捷键", isOn: $hk.enabled)

                Divider()

                HStack {
                    Text("触发按键")
                        .font(.subheadline)
                    Spacer()
                    // 用统一的 AppDropdown 代替裸 `Picker`。
                    // 两个原因：① `Picker` 在 macOS 上会渲染成长长的一条、字体比周围小一号；
                    // ② 它给了 `.frame(width: 100)` 硬宽度，新系统的弹窗按钮更宽 → 文字被裁切。
                    // 现在宽高由 `AppMetrics` 固定，按钮上直接显示当前按键。
                    AppDropdown(
                        title: fKeyName(hk.keyCode),
                        leading: .icon("keyboard"),
                        items: ScreenshotHotkeyManager.fKeys.map(\.code),
                        label: { fKeyName($0) },
                        isCurrent: { $0 == hk.keyCode },
                        onPick: { hk.keyCode = $0 },
                        style: .light,
                        help: "触发按键：\(fKeyName(hk.keyCode))（点击选择）"
                    )
                    .disabled(!hk.enabled)
                    .opacity(hk.enabled ? 1 : 0.5)
                }
                .padding(.vertical, 6)

                Divider()

                toggleRow(label: "自动识别鼠标所在窗口", isOn: $autoWindow)

                Divider()

                toggleRow(label: "截屏时隐藏本应用窗口", isOn: $autoHide)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("按键说明")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    shortcutRow("⎋ Esc", "取消截屏")
                    shortcutRow("⌘Z / ⌃Z", "撤销上一个标注")
                    shortcutRow("矩形 / 圆形 / 箭头 / 画笔 / 文本", "选区内拖动绘制标注")
                }
                .padding(.vertical, 6)
            }
            .padding(8)
        }
    }

    private func shortcutRow(_ keys: String, _ desc: String) -> some View {
        HStack(alignment: .top) {
            Text(keys)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primary)
                .frame(width: 160, alignment: .leading)
            Text(desc)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private func toggleRow(label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label).font(.subheadline)
            Spacer()
            Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
        .padding(.vertical, 6)
    }

    /// F 键编号 → 显示名（120 → "F2"）。
    /// `ScreenshotHotkeyManager.fKeys` 是元组数组，而元组不满足 `Hashable`，
    /// 无法直接当 `AppDropdown` 的选项类型，所以下拉用编号当选项、这里做名称映射。
    private func fKeyName(_ code: Int) -> String {
        ScreenshotHotkeyManager.fKeys.first { $0.code == code }?.name ?? "F?"
    }

    // MARK: - 权限
    //
    // 只留「状态 + 指路」的紧凑条，完整的授权管理（授权 / 打开系统设置 / 重新检测）
    // 统一在「设置 → 系统权限」—— 屏幕录制是应用级权限，截屏只是它的两个消费者之一
    // （另一个是验证码的「截取屏幕」），管理入口放两处必然出现两份文案、两套判断。

    private var permissionSection: some View {
        PermissionStatusBar(permission: .screenRecording)
    }

    // MARK: - 日志

    private var logSection: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $logExpanded) {
                HStack(spacing: 8) {
                    Button { reloadLog() } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.secondary())
                    Button { openLogFile() } label: {
                        Label("在 Finder 显示", systemImage: "folder")
                    }
                    .buttonStyle(.secondary())
                }
                .padding(.bottom, 4)

                Text(logText.isEmpty ? "(暂无日志)" : logText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .padding(8)
                    .background(Color.gray.opacity(0.08))
                    .cornerRadius(6)
                    .textSelection(.enabled)
            } label: {
                Label("诊断日志", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
            }
            .padding(8)
        }
    }

    private func reloadLog() {
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/OneOfPassword-screenshot.log")
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            logText = "(暂无日志)"
            return
        }
        // 只显示最后 50 行
        let lines = text.split(separator: "\n")
        logText = lines.suffix(50).joined(separator: "\n")
    }

    private func openLogFile() {
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/OneOfPassword-screenshot.log")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
