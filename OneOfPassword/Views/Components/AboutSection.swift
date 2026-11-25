//
//  AboutSection.swift
//  OneOfPassword
//
//  设置 → 关于：项目链接 + 二维码分享 + 当前版本信息。
//
//  === 为什么从 SettingsView 里拆出来 ===
//  这段没有依赖 SettingsView 的任何状态，却是唯一带「悬停弹层」的区块；
//  拆成独立 View 后可以拷到临时宿主里直接渲染截图核对布局（SettingsView 太大，编不动）。
//

import SwiftUI
import AppKit

struct AboutSectionView: View {

    /// 项目主页链接的悬停态（下划线 + 小手光标）
    @State private var hoveringLink = false
    /// 「二维码」标签按钮的悬停态
    @State private var hoveringTag = false
    /// 弹层是否显示
    @State private var showQRCode = false
    /// 用户点过按钮 = 钉住（移开鼠标也不关）；再点一次取消
    @State private var pinned = false
    /// 鼠标移出后的延迟关闭任务：给用户一点时间把鼠标移进弹层
    @State private var pendingClose: DispatchWorkItem?
    /// 复制版本信息后的短暂反馈
    @State private var copied = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label("关于", systemImage: "info.circle.fill")
                    .font(.headline)

                HStack(spacing: 10) {
                    githubLink
                    qrCodeTag
                    Text("查看源码、反馈问题与下载新版本")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        // 说明文字允许折行：窗口被拖窄时宁可多占一行，也别截成「下载新…」
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }

                Divider()

                versionInfo
            }
            .padding(8)
        }
    }

    // MARK: - 项目链接

    /// 显式做成「可点击的样子」：主题色 + 悬停加下划线 + 小手光标。
    /// 只靠系统默认的 Link 样式，用户看不出这里能点（原来的问题）。
    private var githubLink: some View {
        Link(destination: AppLinks.githubHomepage) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .semibold))
                Text("GitHub 项目首页")
                    .underline(hoveringLink)
            }
            .font(.system(size: AppMetrics.ghostFontSize, weight: .medium))
            .foregroundColor(.accentColor)
            .lineLimit(1)
            // 透明间隙不参与命中测试，没有它只有文字那几像素能点到
            .contentShape(Rectangle())
        }
        // .plain 去掉系统按钮外观，只留下我们自己的文字与颜色
        .buttonStyle(.plain)
        .pointingHandOnHover()
        .onHover { hoveringLink = $0 }
        .help("在浏览器中打开 \(AppLinks.githubHomepage.absoluteString)")
    }

    // MARK: - 二维码

    private var qrCodeTag: some View {
        Button {
            if pinned {
                pinned = false
                showQRCode = false
            } else {
                // 点一下 = 钉住，鼠标移开也不收，方便腾出手去拿手机
                pinned = true
                openByHover()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "qrcode")
                    .font(.system(size: 11, weight: .semibold))
                Text("二维码")
                    .lineLimit(1)
            }
            .font(.system(size: AppMetrics.ghostFontSize))
            .foregroundColor(.primary)
            .padding(.horizontal, 10)
            // 固定高度 + 单行：与按钮层同一条铁律，避免被外层容器裁掉
            .frame(height: AppMetrics.ghostButtonHeight)
            .background(
                RoundedRectangle(cornerRadius: AppMetrics.dropdownCorner)
                    .fill(hoveringTag || pinned ? DropdownStyle.light.fillHover
                                                : DropdownStyle.light.fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppMetrics.dropdownCorner)
                    .stroke(hoveringTag || pinned ? DropdownStyle.light.borderHover
                                                  : DropdownStyle.light.border,
                            lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppMetrics.dropdownCorner))
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
        .onHover { inside in
            hoveringTag = inside
            if inside { openByHover() } else { scheduleClose() }
        }
        // 不挂 .help：悬停会立刻弹二维码，再叠一个系统气泡只会互相遮挡
        // 弹层被系统关掉（点窗口空白处 / Esc）时自动解除「钉住」，
        // 否则 pinned 会残留成 true，之后每次悬停都不再自动收起。
        .onChange(of: showQRCode) { shown in
            if !shown { pinned = false }
        }
        .popover(isPresented: $showQRCode, arrowEdge: .top) {
            GitHubQRCodeCard()
                // 鼠标移进弹层就取消关闭，否则「从按钮移到二维码」这一步就把弹层收掉了
                .onHover { inside in
                    if inside {
                        pendingClose?.cancel()
                        pendingClose = nil
                    } else if !hoveringTag {
                        scheduleClose()
                    }
                }
        }
    }

    private func openByHover() {
        pendingClose?.cancel()
        pendingClose = nil
        if !showQRCode { showQRCode = true }
    }

    private func scheduleClose() {
        guard !pinned else { return }   // 钉住了就等用户再点一次
        pendingClose?.cancel()
        let work = DispatchWorkItem {
            guard !pinned else { return }
            showQRCode = false
        }
        pendingClose = work
        // 0.25s：够短（不会显得迟钝），够长（鼠标能顺利移进弹层）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    // MARK: - 版本信息

    private var versionInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                infoLabel("当前版本")
                Text(AppVersion.shortVersion)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                Text("构建 \(AppVersion.buildNumber)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                copyButton
            }
            .frame(minHeight: AppMetrics.settingRowMinHeight)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                infoLabel("运行环境")
                Text("\(AppVersion.systemDescription) · \(AppVersion.architectureDescription)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(minHeight: AppMetrics.settingRowMinHeight)
        }
    }

    private func infoLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(width: AppMetrics.pathLabelWidth, alignment: .leading)
            .lineLimit(1)
    }

    /// 图标按钮：反馈问题时一键复制「版本 + 构建 + 系统 + 架构」。
    private var copyButton: some View {
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(AppVersion.diagnosticsText, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .semibold))
                Text(copied ? "已复制" : "复制版本信息")
                    .lineLimit(1)
            }
            .font(.system(size: AppMetrics.ghostFontSize))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .frame(height: AppMetrics.ghostButtonHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandOnHover()
        .help("复制版本、构建号、系统与架构，粘贴到 issue 里")
    }
}

// MARK: - 二维码弹层内容

/// 弹层本体。单独成类型，方便离线宿主直接渲染核对尺寸。
struct GitHubQRCodeCard: View {
    /// 二维码边长（点）。150 在 Retina 上是 300px，手机在 20cm 外可稳定识别。
    private static let qrPointSize: CGFloat = 150
    /// 卡片宽度。窄了二维码占比太大、宽了显得空，240 与弹层默认内边距搭配最顺。
    private static let cardWidth: CGFloat = 240

    var body: some View {
        VStack(spacing: 10) {
            if let image = QRCode.image(for: AppLinks.githubHomepage.absoluteString,
                                        pointSize: Self.qrPointSize) {
                Image(nsImage: image)
                    .accessibilityLabel("GitHub 项目首页二维码")
            } else {
                // 正常不会走到（链接是纯 ASCII），兜底成一行文字，别让弹层变成空白
                Text("二维码生成失败")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: Self.qrPointSize, height: Self.qrPointSize)
            }

            Text("用手机相机扫一扫，打开项目主页")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(16)
        .frame(width: Self.cardWidth)
    }
}

// MARK: - 预览（传统 PreviewProvider：本机的 #Preview 宏不稳定）

struct AboutSectionView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            AboutSectionView()
            GitHubQRCodeCard()
        }
        .padding(24)
        .frame(width: 620)
    }
}
