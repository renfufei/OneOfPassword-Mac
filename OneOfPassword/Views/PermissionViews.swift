//
//  PermissionViews.swift
//  OneOfPassword
//
//  权限界面的两块可复用组件（两者共用 `PermissionCenter` 这一份状态）：
//
//  · `PermissionCenterSection` —— 完整管理区块，放在「设置」页。
//    它是**唯一的授权操作入口**（授权 / 打开系统设置 / 重新检测）。
//    区块末尾还有一行 `LaunchAtLoginRow`（开机启动）：它不是 TCC 权限，
//    但同属"应用级 + 系统托管 + 用户能在系统设置里改"，所以视觉上并入同一区块。
//
//  · `PermissionStatusBar` —— 紧凑状态条，放在**使用点**（截屏页、扫码页）。
//    只报「当前状态 + 该去哪里办」，不在这里做授权 —— 同一个权限在多个页面各放一份
//    授权按钮，迟早会出现两份文案与两套判断逻辑。
//
//  IA 决策（2026-09-29）：权限是应用级能力，不是截屏功能的子设置，所以主体放「设置」；
//  使用点只留指路条，保证失败发生在哪就能就近看到状态，不用用户自己去翻菜单。
//

import SwiftUI
import AppKit

// MARK: - 设置页：完整管理区块

struct PermissionCenterSection: View {
    /// 由外部触发的高亮（从别处深链过来时闪一下边框，告诉用户「就是这里」）
    var highlighted: Bool = false

    @ObservedObject private var center = PermissionCenter.shared

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("系统权限", systemImage: "lock.shield.fill")
                        .font(.headline)
                    Spacer()
                    Button {
                        center.refresh()
                    } label: {
                        Label("重新检测", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.secondary())
                    .help("重新读取系统授权状态（在系统设置里改完授权后可点这里刷新）")
                }
                .padding(.bottom, 10)

                Divider()

                // 用 `AppPermission.allCases` 直接驱动（枚举是 Identifiable），
                // 新增权限只需在枚举里加 case，这里自动多一行。
                ForEach(AppPermission.allCases) { permission in
                    if permission != AppPermission.allCases.first { Divider() }
                    PermissionRow(permission: permission)
                }

                Divider()

                // 「开机启动」不是 TCC 权限（没有"允许 / 拒绝"授权弹框），但同属
                // "应用级、由系统托管、用户可以随时在系统设置里改"的能力，
                // 所以排在同一区块里，样式与权限行一致。
                LaunchAtLoginRow()

                Divider()

                Label("权限由 macOS 统一管理，屏幕录制授权后需重启应用生效；以上数据均只在本机处理。",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 10)
            }
            .padding(8)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor, lineWidth: highlighted ? 2 : 0)
        )
        .animation(.easeInOut(duration: 0.25), value: highlighted)
        .onAppear { center.beginObserving() }
        .onDisappear { center.endObserving() }
    }
}

// MARK: - 单行权限

private struct PermissionRow: View {
    let permission: AppPermission

    @ObservedObject private var center = PermissionCenter.shared

    private var status: AppPermissionStatus { center.status(permission) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: permission.systemImage)
                    .foregroundColor(.secondary)
                    .frame(width: 18)

                Text(permission.title)
                    .fontWeight(.medium)

                statusPill

                Spacer()

                actionButton
            }

            Text("用于：\(permission.usedBy)")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 26)

            Text(permission.purpose)
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 26)

            if status.isAuthorized, permission.requiresRelaunch {
                Label("若刚授权，请重启应用后生效", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.leading, 26)
            }
        }
        .padding(.vertical, 10)
    }

    /// 未授权 → 「授权」（唤起系统弹框）+「系统设置」（手动勾选）两个都给；
    /// 已授权 → 只留「系统设置」（用于查看/撤销）。
    ///
    /// 为什么未授权时两个按钮都要有：`CGPreflightScreenCaptureAccess` **无法区分**
    /// 「从未请求过」和「已被用户拒绝」——两者都返回 false。只给一个按钮就必然有一半场景是错的
    /// （要么唤不起弹框、要么让用户白跑一趟系统设置）。两个都给，用户总有一个能走通。
    @ViewBuilder
    private var actionButton: some View {
        HStack(spacing: 8) {
            if !status.isAuthorized {
                Button {
                    center.request(permission)
                } label: {
                    Label("授权", systemImage: "checkmark.shield")
                }
                .buttonStyle(.primary())
                .help("弹出系统授权对话框；若之前已拒绝过，系统不会再弹框，请用右侧「系统设置」")
            }

            Button {
                permission.openSystemSettings()
            } label: {
                Label("系统设置", systemImage: "gearshape")
            }
            .buttonStyle(.secondary())
            .help("打开「系统设置 → 隐私与安全性 → \(permission.title)」，可手动勾选或撤销")
        }
    }

    private var statusPill: some View {
        StatusPill(text: status.label, color: dotColor)
    }

    private var dotColor: Color {
        switch status {
        case .authorized:    return .green
        case .notDetermined: return .secondary
        case .denied:        return .orange
        }
    }
}

// MARK: - 使用点：紧凑状态条

/// 放在「用到该权限」的界面上：只报状态 + 指路，**不做授权操作**。
struct PermissionStatusBar: View {
    let permission: AppPermission

    @ObservedObject private var center = PermissionCenter.shared

    private var status: AppPermissionStatus { center.status(permission) }

    var body: some View {
        GroupBox {
            HStack(spacing: 10) {
                Image(systemName: status.isAuthorized
                      ? "checkmark.circle.fill"
                      : "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(status.isAuthorized ? .green : .orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(permission.title)：\(status.label)")
                        .font(.subheadline)
                    Text(status.isAuthorized
                         ? "已可用于「\(permission.usedBy)」。"
                         : "未授权时「\(permission.usedBy)」无法工作，请到「设置 → 系统权限」中开启。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button {
                    // 统一走通知：ContentView 收到后切到「设置」并把系统权限区块滚进视野。
                    NotificationCenter.default.post(name: .openAppPermissions, object: nil)
                } label: {
                    Label("在设置中管理", systemImage: "gearshape")
                }
                .buttonStyle(.secondary())
                .help("到「设置 → 系统权限」查看授权状态，并从那里跳转系统设置")
            }
            .padding(8)
        }
        .onAppear { center.beginObserving() }
        .onDisappear { center.endObserving() }
    }
}

// MARK: - 使用点：不可用占位（权限被拒时替换掉功能本体）

/// 权限没到位时，用它替换掉功能本体（例如扫码页的摄像头预览）。
/// 比「一片黑 + 没有提示」强得多 —— 这也是本次把权限收拢到一处后顺手补上的缺口。
struct PermissionUnavailableView: View {
    let permission: AppPermission
    var onOpenSystemSettings: (() -> Void)? = nil

    @ObservedObject private var center = PermissionCenter.shared

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.slash")
                .font(.system(size: 40))
                .foregroundColor(.secondary)

            Text("需要「\(permission.title)」权限")
                .font(.headline)

            Text(permission.purpose)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            HStack(spacing: 12) {
                if center.status(permission) == .notDetermined {
                    Button {
                        center.request(permission)
                    } label: {
                        Label("授权", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.primary())
                } else {
                    Button {
                        if let onOpenSystemSettings {
                            onOpenSystemSettings()
                        } else {
                            permission.openSystemSettings()
                        }
                    } label: {
                        Label("打开系统设置", systemImage: "gearshape")
                    }
                    .buttonStyle(.primary())
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .onAppear { center.beginObserving() }
        .onDisappear { center.endObserving() }
    }
}

// MARK: - 状态胶囊（权限行 / 开机启动行共用）

/// 「● 已授权」式状态胶囊。抽出来只有一个目的：让**开机启动行**和权限行长得一模一样 ——
/// 两处各写一份，字号、圆点尺寸、底色透明度迟早会飘。
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
        .foregroundColor(color)
    }
}

// MARK: - 开机启动行

/// 「开机启动」：开关 + 状态胶囊 + 跳转系统设置。
///
/// 交互对齐权限行的三条约定：
/// ① 状态**永远以系统为准**（应用激活时重读），开关只是"请求"，失败就回弹并说明原因；
/// ② 状态异常（系统侧禁止 / 状态不可识别）给一行橙色提示，而不是只换个颜色；
/// ③ 一律提供「系统设置」入口 —— 用户可能想自己看/改，而不是被应用的开关绑住。
private struct LaunchAtLoginRow: View {
    @ObservedObject private var service = LaunchAtLoginService.shared

    private var presentation: LaunchAtLoginPresentation { service.presentation }

    /// 开关是只写通道：真实状态由系统决定，不能双向绑定 ——
    /// 否则界面会先跳到新位置、失败后再弹回来，看着像闪了一下。
    private var toggleBinding: Binding<Bool> {
        Binding(get: { presentation.toggleOn },
                set: { service.setEnabled($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "power")
                    .foregroundColor(.secondary)
                    .frame(width: 18)

                Text("开机启动")
                    .fontWeight(.medium)

                StatusPill(text: presentation.label, color: pillColor)

                Spacer()

                Toggle("", isOn: toggleBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .frame(minHeight: AppMetrics.settingRowMinHeight)
                    .help("开启后把本应用加入 macOS「登录项」，下次开机自动启动；默认关闭")

                Button {
                    service.openLoginItemsSettings()
                } label: {
                    Label("系统设置", systemImage: "gearshape")
                }
                .buttonStyle(.secondary())
                .help("打开「系统设置 → 通用 → 登录项」，可查看、允许或移除本应用")
            }

            Text("用于：开机后自动启动本应用（可选，默认关闭）")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 26)

            Text("应用只在打开时工作、不常驻后台；开启后会出现在系统「登录项」里，随时可以关掉。")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 26)

            if let hint = presentation.hint {
                Label(hint, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
            }

            if let error = service.lastError {
                Label(error, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 26)
            }
        }
        .padding(.vertical, 10)
        .onAppear { service.refresh() }
    }

    private var pillColor: Color {
        switch presentation.tone {
        case .on:      return .green
        case .off:     return .secondary
        case .warning: return .orange
        }
    }
}
