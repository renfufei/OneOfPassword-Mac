//
//  NoteEditorView.swift
//  OneOfPassword
//

import SwiftUI

struct NoteEditorView: View {
    @State private var item: NoteItem
    @State private var isSaved = false
    let viewModel: NoteListViewModel

    // 用于防抖自动保存的 task
    @State private var saveTask: Task<Void, Never>?

    init(item: NoteItem, viewModel: NoteListViewModel) {
        _item = State(initialValue: item)
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            TextField("标题（可选）", text: $item.title)
                .font(.title2.bold())
                .textFieldStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)
                .onChange(of: item.title) { _ in scheduleSave() }

            Divider()

            // 正文编辑器
            TextEditor(text: $item.content)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .onChange(of: item.content) { _ in scheduleSave() }
        }
        .toolbar {
            ToolbarItem(placement: .status) {
                Text(isSaved ? "已保存" : "编辑中…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: { viewModel.togglePin(item) }) {
                    Image(systemName: item.isPinned ? "pin.fill" : "pin")
                }
                .help(item.isPinned ? "取消置顶" : "置顶")
            }
        }
        // 切换到其他便签时立刻保存
        .onDisappear { saveNow() }
    }

    // MARK: - 防抖自动保存（500 ms 无操作后保存）

    private func scheduleSave() {
        isSaved = false
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        viewModel.save(item)
        isSaved = true
    }
}
