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
    @State private var hasScreenCapture: Bool = false

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
            refreshScreenCapture()
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

                toggleRow(label: "启用全局快捷键", isOn: $hk.enabled)

                Divider()

                HStack {
                    Text("触发按键")
                        .font(.subheadline)
                    Spacer()
                    Picker("", selection: $hk.keyCode) {
                        ForEach(ScreenshotHotkeyManager.fKeys, id: \.code) { fk in
                            Text(fk.name).tag(fk.code)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    .disabled(!hk.enabled)
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

    // MARK: - 权限

    private var permissionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("录屏权限", systemImage: "lock.shield.fill")
                    .font(.headline)

                HStack(spacing: 8) {
                    Circle()
                        .fill(hasScreenCapture ? .green : .orange)
                        .frame(width: 10, height: 10)
                    Text(hasScreenCapture ? "已授权" : "未授权")
                        .font(.subheadline)
                    Spacer()
                    Button {
                        ScreenshotCaptureService.requestScreenCaptureAccess()
                        refreshScreenCapture()
                    } label: {
                        Label("授权", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.secondary())
                    Button {
                        ScreenshotCaptureService.openScreenCaptureSettings()
                    } label: {
                        Label("打开系统设置", systemImage: "gearshape")
                    }
                    .buttonStyle(.secondary())
                }

                Text("截图功能依赖「屏幕录制」权限。授权后请点「重新检查」，或重启应用。若状态显示已授权但仍无法触发，请查看下方日志。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button {
                    refreshScreenCapture()
                } label: {
                    Label("重新检查权限", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.secondary())
            }
            .padding(8)
        }
    }

    private func refreshScreenCapture() {
        hasScreenCapture = ScreenshotCaptureService.hasScreenCapturePermission
    }

    // MARK: - 日志

    private var logSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("诊断日志", systemImage: "doc.text.magnifyingglass")
                        .font(.headline)
                    Spacer()
                    Button { reloadLog() } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.secondary())
                    Button { openLogFile() } label: {
                        Label("在 Finder 显示", systemImage: "folder")
                    }
                    .buttonStyle(.secondary())
                }

                Text(logText.isEmpty ? "(暂无日志)" : logText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .padding(8)
                    .background(Color.gray.opacity(0.08))
                    .cornerRadius(6)
                    .textSelection(.enabled)
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
