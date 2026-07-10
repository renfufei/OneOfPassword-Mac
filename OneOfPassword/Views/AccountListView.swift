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
            // 搜索框 + 排序选择器
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
                }
                Menu {
                    ForEach(SortOrder.allCases) { order in
                        Button {
                            listVM.sortOrder = order
                        } label: {
                            if listVM.sortOrder == order {
                                Label(order.rawValue, systemImage: "checkmark")
                            } else {
                                Text(order.rawValue)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
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
