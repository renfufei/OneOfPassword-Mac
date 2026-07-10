//
//  NoteListViewModel.swift
//  OneOfPassword
//

import Foundation
import SwiftUI

@MainActor
class NoteListViewModel: ObservableObject {
    @Published var searchText = ""

    private let dataStore = DataStore.shared

    var filteredItems: [NoteItem] {
        let all = dataStore.noteItems
        let pinned = all.filter { $0.isPinned }
        let unpinned = all.filter { !$0.isPinned }
        let sorted = pinned + unpinned

        if searchText.isEmpty { return sorted }
        return sorted.filter {
            $0.displayTitle.localizedCaseInsensitiveContains(searchText) ||
            $0.content.localizedCaseInsensitiveContains(searchText)
        }
    }

    func save(_ item: NoteItem) {
        var updated = item
        updated.updatedAt = Date()
        dataStore.saveNoteItem(updated)
    }

    func delete(_ item: NoteItem) {
        dataStore.deleteNoteItem(item)
    }

    func togglePin(_ item: NoteItem) {
        var updated = item
        updated.isPinned.toggle()
        updated.updatedAt = Date()
        dataStore.saveNoteItem(updated)
    }
}
