//
//  AccountListView.swift
//  OneOfPassword
//
//  统一保险库列表视图
//

import SwiftUI

// MARK: - VaultListView

struct VaultListView: View {
    @StateObject private var listVM = AccountListViewModel()

    @Binding var selectedItem: VaultItem?
    let onAddItem: () -> Void
    let onDelete: (VaultItem) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 20)

            // 头部拆成两行：搜索（整行）+ 排序（右对齐）。
            // 原因：侧边栏宽度只有 180~220pt，把排序下拉塞进搜索行会把输入框
            // 挤到十几像素宽；而排序按钮本身也需要足够宽度才能显示当前排序名。
            VStack(spacing: 6) {
                searchRow
                HStack {
                    Spacer()
                    sortDropdown
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            if listVM.isEmpty && listVM.searchText.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if listVM.filteredItems.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("无匹配结果")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .navigationTitle("保险库")
        .toolbar { toolbarContent }
        .alert("提示", isPresented: $listVM.showingAlert) {
            Button("确定", role: .cancel) {}
        } message: { Text(listVM.alertMessage) }
    }

    // MARK: - 头部（搜索 / 排序）

    /// 搜索行：整行占满。固定 22pt 高，避免 TextField 高度随系统版本变化把头部撑高。
    private var searchRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 13))
            TextField("搜索…", text: $listVM.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !listVM.searchText.isEmpty {
                Button { listVM.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 13))
                }
                .buttonStyle(.borderless)
                .help("清空搜索")
            }
        }
        .frame(height: 22)
    }

    /// 排序下拉：统一控件（固定 28pt 高 / 13pt 字 / 悬停高亮），
    /// 并把**当前排序名**直接显示在按钮上。
    /// 旧实现是一个裸的 borderless 图标菜单：看不出当前按什么排序，
    /// 而且裸 `Menu` 的尺寸会跟随 macOS 版本变化（新系统的弹窗按钮更高更宽）。
    private var sortDropdown: some View {
        AppDropdown(
            title: listVM.sortOrder.rawValue,
            leading: .icon("arrow.up.arrow.down"),
            items: SortOrder.allCases,
            label: { $0.rawValue },
            isCurrent: { listVM.sortOrder == $0 },
            onPick: { listVM.sortOrder = $0 },
            style: .light,
            help: "排序：\(listVM.sortOrder.rawValue)（点击切换）"
        )
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("+ 添加新条目") { onAddItem() }
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            Text("暂无条目")
                .font(.title2).foregroundColor(.secondary)
            Button {
                onAddItem()
            } label: {
                Label("添加新条目", systemImage: "plus")
            }
            .buttonStyle(.primary())
            Button {
                NotificationCenter.default.post(name: .menuImport, object: nil)
            } label: {
                Label("导入备份", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.secondary())
        }
    }

    // MARK: - 列表

    private var list: some View {
        List {
            ForEach(listVM.filteredItems) { item in
                VaultRow(
                    item: item,
                    isSelected: selectedItem?.id == item.id,
                    onSelect: { selectedItem = item },
                    onDelete: {
                        if selectedItem?.id == item.id { selectedItem = nil }
                        onDelete(item)
                    }
                )
            }
        }
    }
}

// MARK: - VaultRow

private struct VaultRow: View {
    let item: VaultItem
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirm = false
    private let authPolicy = AuthPolicy.shared

    var body: some View {
        HStack(spacing: 12) {
            // 左侧图标
            leadingIcon

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body).fontWeight(.medium)
                    .lineLimit(1)
                if item.type == .password {
                    Text(item.username.isEmpty ? " " : item.username)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    if let site = item.website, !site.isEmpty {
                        Text(site)
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.7))
                            .lineLimit(1)
                    }
                } else {
                    // TOTP
                    let sub = item.totpAccountName.isEmpty ? (item.totpIssuer ?? "") : item.totpAccountName
                    if !sub.isEmpty {
                        Text(sub)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            // 右侧标记
            if item.type == .totp {
                Image(systemName: "lock.shield")
                    .foregroundColor(.green)
                    .font(.system(size: 16))
                    .help("TOTP 验证器")
            } else if item.totpKeychainId != nil {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundColor(.blue.opacity(0.7))
                    .font(.system(size: 13))
                    .help("内嵌 TOTP")
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contextMenu {
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .confirmationDialog("删除「\(item.title)」？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) { authenticatedDelete() }
            Button("取消", role: .cancel) {}
        }
    }

    private func authenticatedDelete() {
        guard !authPolicy.requireAuthForDelete else {
            authPolicy.authenticate(reason: "验证身份后删除条目") { onDelete() }
            return
        }
        onDelete()
    }

    private var leadingIcon: some View {
        Group {
            if item.type == .totp {
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 18))
            } else if item.isFavorite {
                Image(systemName: "star.fill")
                    .foregroundColor(.yellow)
                    .font(.system(size: 18))
            } else {
                Image(systemName: "key.fill")
                    .foregroundColor(.blue)
                    .font(.system(size: 18))
            }
        }
        .frame(width: 28)
    }
}
