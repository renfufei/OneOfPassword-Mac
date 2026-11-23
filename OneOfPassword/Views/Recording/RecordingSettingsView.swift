//
//  RecordingSettingsView.swift
//  OneOfPassword
//
//  录屏设置页：快捷键 + 音频来源 + 帧率 + 保存位置 + 权限 + 日志。
//
//  结构与「截屏」页保持一致（说明 → 快捷键 → 选项 → 权限 → 日志）。
//  下拉一律用 `AppDropdown`、按钮一律走统一按钮样式、高度取自 `AppMetrics` ——
//  这三条是 `AppControls.swift` 开头那段血泪总结，新页面同样适用。
//

import AppKit
import SwiftUI

struct RecordingSettingsView: View {
    @ObservedObject private var hk = ScreenshotHotkeyManager.shared
    @ObservedObject private var recorder = ScreenRecorder.shared

    @State private var audioSource = RecordingPreferences.audioSource
    @State private var frameRate = RecordingPreferences.frameRate
    @State private var showsCursor = RecordingPreferences.showsCursor
    @State private var saveDirectory = RecordingPreferences.saveDirectory
    @State private var showsMark = RecordingPreferences.showsRegionMark
    @State private var markOpacity = RecordingPreferences.regionMarkOpacity
    @State private var remembersRegion = RecordingPreferences.remembersLastRegion
    @State private var usesLastRegion = RecordingPreferences.usesLastRegion
    @State private var logText = ""
    @State private var logExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                introSection
                hotkeySection
                optionsSection
                regionSection
                saveSection
                permissionSection
                logSection
            }
            .padding(28)
        }
        .navigationTitle("录屏")
        .frame(minWidth: 520)
        .onAppear { reloadLog() }
    }

    // MARK: - 说明

    private var introSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("录屏", systemImage: "record.circle")
                    .font(.headline)
                Text("按快捷键（默认 F3）框选要录制的区域并开始录制。录制中屏幕顶部会出现悬浮控制条：可暂停/继续、停止即保存到下面的目录，也可以直接丢弃。控制条与区域标记框都不会出现在录制画面里。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        RecordingCoordinator.shared.presentArea()
                    } label: {
                        Label(recorder.isRecording ? "正在录制…" : "立即录制",
                              systemImage: recorder.isRecording ? "stop.circle" : "record.circle")
                    }
                    .buttonStyle(.primary())
                    .disabled(recorder.isRecording)

                    if recorder.isRecording {
                        Button {
                            RecordingCoordinator.shared.togglePause()
                        } label: {
                            Label(recorder.isPaused ? "继续录制" : "暂停录制",
                                  systemImage: recorder.isPaused ? "play.fill" : "pause.fill")
                        }
                        .buttonStyle(.secondary())

                        Button {
                            RecordingCoordinator.shared.stopAndSave()
                        } label: {
                            Label("停止并保存", systemImage: "stop.fill")
                        }
                        .buttonStyle(.secondary())
                    }
                }
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

                Text("与截屏共用同一套系统级热键（RegisterEventHotKey），不需要「辅助功能」权限。两个热键各占一个 F 键，请不要选同一个。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)

                toggleRow(label: "启用录屏快捷键", isOn: $hk.recordingEnabled)

                Divider()

                HStack {
                    Text("触发按键").font(.subheadline)
                    Spacer()
                    AppDropdown(
                        title: fKeyName(hk.recordingKeyCode),
                        leading: .icon("record.circle"),
                        items: ScreenshotHotkeyManager.fKeys.map(\.code),
                        label: { fKeyName($0) },
                        isCurrent: { $0 == hk.recordingKeyCode },
                        onPick: { hk.recordingKeyCode = $0 },
                        style: .light,
                        help: "录屏触发按键：\(fKeyName(hk.recordingKeyCode))（点击选择）"
                    )
                    .disabled(!hk.recordingEnabled)
                    .opacity(hk.recordingEnabled ? 1 : 0.5)
                }
                .padding(.vertical, 6)

                if hk.recordingEnabled && hk.enabled && hk.recordingKeyCode == hk.keyCode {
                    Label("录屏与截屏用了同一个按键，后注册的会覆盖前一个，请改成别的 F 键。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.vertical, 4)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("按键说明")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    shortcutRow("拖动鼠标", "框选录制范围")
                    shortcutRow("拖动手柄 / 边框", "放大、缩小录制范围")
                    // 用 Return / Esc 而不是 ⏎ / ⎋：那两个符号在中文界面里回退字体很小，
                    // 跟「F2」放一列时高低不齐，读起来像乱码。
                    shortcutRow("Return", "框选整屏（再按一次开始录制）")
                    shortcutRow("Esc", "取消选区")
                    shortcutRow("\(fKeyName(hk.recordingKeyCode))", "录制中再按一次 = 停止并保存")
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
        .frame(minHeight: AppMetrics.settingRowMinHeight)
        .padding(.vertical, 6)
    }

    private func fKeyName(_ code: Int) -> String {
        ScreenshotHotkeyManager.fKeys.first { $0.code == code }?.name ?? "F?"
    }

    // MARK: - 录制选项

    private var optionsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                Label("录制选项", systemImage: "slider.horizontal.3")
                    .font(.headline)
                    .padding(.bottom, 10)

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("音频来源").font(.subheadline)
                        Text(audioSource.detail)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    AppDropdown(
                        title: audioSource.title,
                        leading: .icon(audioSource.systemImage),
                        items: RecordingAudioSource.allCases,
                        label: { $0.title },
                        isCurrent: { $0 == audioSource },
                        onPick: { value in
                            audioSource = value
                            RecordingPreferences.audioSource = value
                        },
                        style: .light,
                        help: "音频来源：\(audioSource.title)"
                    )
                }
                .padding(.vertical, 6)

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("帧率").font(.subheadline)
                        Text("30 fps 文件更小；录动画或快速滚动时用 60 fps")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    AppDropdown(
                        title: "\(frameRate) fps",
                        leading: .icon("speedometer"),
                        items: RecordingPreferences.frameRateOptions,
                        label: { "\($0) fps" },
                        isCurrent: { $0 == frameRate },
                        onPick: { value in
                            frameRate = value
                            RecordingPreferences.frameRate = value
                        },
                        style: .light,
                        help: "录制帧率：\(frameRate) fps"
                    )
                }
                .padding(.vertical, 6)

                Divider()

                toggleRow(label: "录制鼠标指针",
                          isOn: Binding(get: { showsCursor },
                                        set: { showsCursor = $0; RecordingPreferences.showsCursor = $0 }))
            }
            .padding(8)
        }
    }

    // MARK: - 录制区域

    /// 区域框 + 上次区域的记忆策略。
    /// 标记框是本应用自己的窗口，已被 `SCContentFilter` 排除，所以不会进画面。
    private var regionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                Label("录制区域", systemImage: "rectangle.dashed")
                    .font(.headline)
                    .padding(.bottom, 10)

                Divider()

                toggleRow(label: "录制中显示区域标记框",
                          isOn: Binding(get: { showsMark },
                                        set: {
                                            showsMark = $0
                                            RecordingPreferences.showsRegionMark = $0
                                            RecordingCoordinator.shared.refreshRegionMark()
                                        }))

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("标记框透明度").font(.subheadline)
                        Text("只在区域录制时出现；不吃鼠标事件、也不会被录进画面")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Slider(value: Binding(get: { markOpacity },
                                          set: {
                                              markOpacity = $0
                                              RecordingPreferences.regionMarkOpacity = $0
                                              RecordingCoordinator.shared.refreshRegionMark()
                                          }),
                           in: 0.08...0.9)
                        .frame(width: 150)
                    Text(verbatim: "\(Int((markOpacity * 100).rounded()))%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                .padding(.vertical, 6)
                .disabled(!showsMark)
                .opacity(showsMark ? 1 : 0.45)

                Divider()

                toggleRow(label: "记住上次的录制区域",
                          isOn: Binding(get: { remembersRegion },
                                        set: {
                                            remembersRegion = $0
                                            RecordingPreferences.remembersLastRegion = $0
                                            if !$0 { usesLastRegion = RecordingPreferences.usesLastRegion }
                                        }))
                    .help("关掉后不再保存框选位置，也不会再套用")

                toggleRow(label: "打开选区时直接用上次区域",
                          isOn: Binding(get: { usesLastRegion },
                                        set: { usesLastRegion = $0; RecordingPreferences.usesLastRegion = $0 }))
                    .disabled(!remembersRegion)
                    .opacity(remembersRegion ? 1 : 0.45)
                    .help("关掉则每次按快捷键都从空白开始框选（选区面板里也能临时切换）")
            }
            .padding(8)
        }
    }

    // MARK: - 保存位置

    private var saveSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("保存位置", systemImage: "folder")
                    .font(.headline)

                HStack(alignment: .top, spacing: 8) {
                    Text("目录")
                        .foregroundColor(.secondary)
                        .frame(width: AppMetrics.pathLabelWidth, alignment: .leading)
                    Text(saveDirectory.path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 10) {
                    Button {
                        chooseDirectory()
                    } label: {
                        Label("选择…", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.secondary())

                    Button {
                        NSWorkspace.shared.open(saveDirectory)
                    } label: {
                        Label("打开", systemImage: "arrow.right.circle")
                    }
                    .buttonStyle(.secondary())

                    Button {
                        RecordingPreferences.resetSaveDirectory()
                        saveDirectory = RecordingPreferences.saveDirectory
                    } label: {
                        Label("恢复默认", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.secondary())
                }

                Text("录制结束后自动保存到该目录，文件名形如「录屏 2026-11-23 11-21-05.mp4」，重名会自动加序号。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        panel.message = "选择录屏文件的保存目录"
        panel.directoryURL = saveDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // 与「上次保存目录」共用同一个键：用户手选的目录就是录制文件该去的地方
        RecordingPreferences.rememberSaveDirectory(url)
        saveDirectory = RecordingPreferences.saveDirectory
    }

    // MARK: - 权限

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            PermissionStatusBar(permission: .screenRecording)
            if audioSource == .microphone {
                PermissionStatusBar(permission: .microphone)
            }
        }
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

    /// 录屏与截屏共用同一个日志文件：两条链路互相影响（同一个热键管理器、
    /// 同一份屏幕录制权限），分成两个文件反而要在两处对着时间戳猜。
    private var logFileURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/OneOfPassword-screenshot.log")
    }

    private func reloadLog() {
        guard let data = try? Data(contentsOf: logFileURL),
              let text = String(data: data, encoding: .utf8) else {
            logText = "(暂无日志)"
            return
        }
        logText = text.split(separator: "\n").suffix(50).joined(separator: "\n")
    }

    private func openLogFile() {
        NSWorkspace.shared.activateFileViewerSelecting([logFileURL])
    }
}
