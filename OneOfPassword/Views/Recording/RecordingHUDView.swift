//
//  RecordingHUDView.swift
//  OneOfPassword
//
//  录制中的悬浮控制条 + 录完后的结果卡片。
//
//  为什么是「一个窗口两种形态」而不是两个窗口：
//  停止后如果关掉控制条、另开一个结果窗口，用户会感觉界面跳了一下；
//  同一块面板换内容，视觉上是「原地变成结果」，也省一次窗口创建。
//
//  这个面板被 `SCContentFilter` 排除在本应用之外，所以**不会**出现在录制画面里，
//  位置可以放心叠在内容上（也可以拖动，`isMovableByWindowBackground`）。
//

import SwiftUI
import AppKit

/// HUD 的三种形态
enum RecordingHUDPhase: Equatable {
    case recording
    case finished(url: URL, duration: Double)
    case failed(String)
}

struct RecordingHUDView: View {
    var phase: RecordingHUDPhase
    /// 计时基准 = 录制开始时刻 + 累计暂停时长（恢复后计时不留跳变）
    var elapsedBase: Date
    /// 暂停中的冻结时长；nil = 计时继续走
    var frozenElapsed: Double?
    /// 是否暂停中（换图标 + 换指示灯）
    var isPaused: Bool = false
    /// 输出像素尺寸
    var pixelSize: CGSize

    var onStop: () -> Void
    var onDiscard: () -> Void
    var onTogglePause: () -> Void
    var onReveal: (URL) -> Void
    var onClose: () -> Void

    @State private var confirmingDiscard = false

    var body: some View {
        HStack(spacing: 0) {
            switch phase {
            case .recording:                recordingRow
            case .finished(let url, let d): finishedRow(url: url, duration: d)
            case .failed(let message):      failedRow(message)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.82))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.14), lineWidth: 1))
        )
        .fixedSize()
    }

    // MARK: - 录制中

    private var recordingRow: some View {
        HStack(spacing: 10) {
            if confirmingDiscard {
                Text("丢弃这段录制？")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.9))
                pillButton("丢弃", tint: .red, filled: true) {
                    confirmingDiscard = false
                    onDiscard()
                }
                pillButton("继续", tint: .white, filled: false) {
                    confirmingDiscard = false
                }
            } else {
                if isPaused {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.orange)
                        .frame(width: 8, height: 8)
                    elapsedText
                    Text("已暂停")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                } else {
                    BlinkingDot()
                    elapsedText
                }
                if pixelSize.width > 0 {
                    // `Text(verbatim:)`：避免本地化数字格式给分辨率加千分位（1,280×720）
                    Text(verbatim: "\(Int(pixelSize.width))×\(Int(pixelSize.height))")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Rectangle()
                    .fill(.white.opacity(0.18))
                    .frame(width: 1, height: 16)
                    .padding(.horizontal, 2)
                // 暂停/恢复：图标 + 悬停提示，不占宽度
                iconButton(isPaused ? "play.fill" : "pause.fill",
                           help: isPaused ? "继续录制" : "暂停录制",
                           tint: .white,
                           action: onTogglePause)
                iconButton("stop.fill", help: "停止并保存", tint: .white) { onStop() }
                iconButton("trash", help: "丢弃这段录制", tint: .white.opacity(0.7)) {
                    confirmingDiscard = true
                }
            }
        }
    }

    private var elapsedText: some View {
        // 用 TimelineView 走秒：比在 View 里挂 Timer 再 @State 自增省事，
        // 也不会因为面板被遮挡而停止刷新（Timer 在 runloop 模式下会被卡住）。
        // 暂停时直接显示冻结值，恢复后再从 elapsedBase 继续算 —— 计时不会跳。
        TimelineView(.periodic(from: Date(), by: 0.5)) { context in
            Text(Self.format(frozenElapsed ?? max(0, context.date.timeIntervalSince(elapsedBase))))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(minWidth: 52, alignment: .leading)
        }
    }

    // MARK: - 已保存

    private func finishedRow(url: URL, duration: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundColor(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("已保存 · \(Self.format(duration))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(url.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .leading)
            }
            pillButton("在访达中显示", tint: .white, filled: false) { onReveal(url) }
            iconButton("xmark", help: "关闭", tint: .white.opacity(0.7)) { onClose() }
        }
    }

    // MARK: - 失败

    private func failedRow(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .lineLimit(2)
                .frame(maxWidth: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            pillButton("好", tint: .white, filled: false) { onClose() }
        }
    }

    // MARK: - 小控件

    private func iconButton(_ icon: String, help: String, tint: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 26, height: AppMetrics.ghostButtonHeight)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.12)))
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func pillButton(_ title: String, tint: Color, filled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .frame(minHeight: AppMetrics.ghostButtonHeight - 2)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(filled ? tint.opacity(0.9) : Color.white.opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.white.opacity(filled ? 0 : 0.35), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 工具

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }
}

/// 录制指示灯：1 秒一次的呼吸，比常亮更容易被注意到「还在录」
private struct BlinkingDot: View {
    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.5)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.0)
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(phase < 0.5 ? 1 : 0.35)
                .animation(.easeInOut(duration: 0.2), value: phase < 0.5)
        }
        .frame(width: 8, height: 8)
    }
}
