//
//  AccountListViewModel.swift
//  OneOfPassword
//
//  保险库列表视图模型（按 title 分组）
//

import Foundation
import SwiftUI
import Combine

enum SortOrder: String, CaseIterable, Identifiable {
    case updatedDesc = "修改时间"
    case createdDesc = "创建时间"
    case nameAsc     = "名称"
    var id: String { rawValue }
}

@MainActor
class AccountListViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var sortOrder: SortOrder = .updatedDesc
    @Published var showingAlert = false
    @Published var alertMessage = ""

    private let dataStore = DataStore.shared
    private var cancellable: AnyCancellable?

    init() {
        // Re-publish whenever vaultItems changes so filteredItems recomputes
        cancellable = dataStore.$vaultItems
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    // MARK: - Filtered items

    var filteredItems: [VaultItem] {
        let sorted = sortedItems
        guard !searchText.isEmpty else { return sorted }
        return sorted.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            $0.username.localizedCaseInsensitiveContains(searchText) ||
            ($0.website?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            $0.totpAccountName.localizedCaseInsensitiveContains(searchText) ||
            ($0.totpIssuer?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var isEmpty: Bool {
        dataStore.vaultItems.isEmpty
    }

    private var sortedItems: [VaultItem] {
        dataStore.vaultItems.sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            switch sortOrder {
            case .updatedDesc: return a.updatedAt > b.updatedAt
            case .createdDesc: return a.createdAt > b.createdAt
            case .nameAsc:     return a.title.localizedCompare(b.title) == .orderedAscending
            }
        }
    }
}
