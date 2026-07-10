//
//  NoteListView.swift
//  OneOfPassword
//

import SwiftUI

struct NoteListColumn: View {
    @Binding var selectedNoteID: UUID?
    @ObservedObject var viewModel: NoteListViewModel
    @ObservedObject private var dataStore = DataStore.shared

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedNoteID) {
                ForEach(viewModel.filteredItems) { item in
                    NoteRow(item: item)
                        .tag(item.id)
                        .contextMenu { contextMenu(for: item) }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $viewModel.searchText, prompt: "搜索便签")
        }
        .navigationTitle("便签")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: createNote) {
                    Label("新建便签", systemImage: "square.and.pencil")
                }
            }
        }
        .frame(minWidth: 220)
    }

    // MARK: - 上下文菜单

    @ViewBuilder
    private func contextMenu(for item: NoteItem) -> some View {
        Button(action: { viewModel.togglePin(item) }) {
            Label(item.isPinned ? "取消置顶" : "置顶", systemImage: item.isPinned ? "pin.slash" : "pin")
        }
        Divider()
        Button(role: .destructive, action: {
            if selectedNoteID == item.id { selectedNoteID = nil }
            viewModel.delete(item)
        }) {
            Label("删除", systemImage: "trash")
        }
    }

    // MARK: - 新建

    private func createNote() {
        let item = NoteItem()
        viewModel.save(item)
        selectedNoteID = item.id
    }
}

// MARK: - 列表行

private struct NoteRow: View {
    let item: NoteItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
                Text(item.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
            }
            if !item.displaySummary.isEmpty {
                Text(item.displaySummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Text(item.updatedAt.formatted(.relative(presentation: .named)))
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.6))
        }
        .padding(.vertical, 4)
    }
}
