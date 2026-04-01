import Combine
import SwiftUI
import AppKit

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var query = ""
    @Published var debouncedQuery = ""
    @Published var selectedType: SearchItem.ItemType = .all
    @Published var selectedSort: SortOption = .name
    @Published var indexedFolderPaths: [String] = []
    @Published var displayItems: [SearchItem] = []
    @Published var totalIndexedCount = 0
    @Published var isIndexing = false
    @Published var lastUpdatedAt: Date?
    @Published var scannedCount = 0
    @Published var statusMessage = "准备就绪"
    @Published var folderBookmarkData: Data?
    @Published var errorMessage: String?
    @Published var includeHiddenFiles = false

    private let db = DatabaseManager.shared
    private var debounceTask: Task<Void, Never>?

    init() {
        loadPersistedMeta()
        statusMessage = totalIndexedCount > 0 ? "已加载本地索引，输入关键词开始搜索" : "准备就绪"
    }

    func chooseFolderAndIndex() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择目录"
        panel.message = "选择一个要建立索引的目录"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isIndexing = true
        scannedCount = 0
        errorMessage = nil
        statusMessage = "正在扫描目录…"
        let selectedPath = url.path
        let bookmarkData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)

        Task {
            let scannedItems = await scanFolder(at: url)
            statusMessage = "正在写入索引数据库…"

            do {
                try db.replaceIndex(folderPath: selectedPath, bookmarkData: bookmarkData, items: scannedItems)
                indexedFolderPaths = [selectedPath]
                folderBookmarkData = bookmarkData
                totalIndexedCount = scannedItems.count
                lastUpdatedAt = Date()
                statusMessage = "索引完成，共 \(scannedItems.count) 条。输入关键词开始搜索"
                displayItems = []
            } catch {
                errorMessage = "索引写入失败：\(error.localizedDescription)"
                statusMessage = "索引失败"
            }

            isIndexing = false
        }
    }

    func loadPersistedMeta() {
        indexedFolderPaths = db.loadIndexedFolders()
        folderBookmarkData = db.loadBookmarkDataForFirstFolder()
        totalIndexedCount = db.loadItemCount()
        lastUpdatedAt = db.loadLastUpdatedAt()
    }

    func updateQuery(_ newValue: String) {
        query = newValue
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self.debouncedQuery = newValue
            self.statusMessage = newValue.isEmpty ? "显示全部结果" : "正在搜索：\(newValue)"
            self.runSearch()
        }
    }

    func runSearch() {
        let items = db.searchItems(query: debouncedQuery, type: selectedType, sort: selectedSort, limit: 500)
        displayItems = items
        if !isIndexing {
            statusMessage = debouncedQuery.isEmpty ? "显示全部结果（最多 500 条）" : "找到 \(items.count) 条结果（最多显示 500 条）"
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    func withSecurityScope<T>(for item: SearchItem, _ action: (URL) -> T) -> T? {
        guard let folderBookmarkData else {
            return action(URL(fileURLWithPath: item.path))
        }

        var stale = false
        guard let folderURL = try? URL(
            resolvingBookmarkData: folderBookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return action(URL(fileURLWithPath: item.path))
        }

        let accessed = folderURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { folderURL.stopAccessingSecurityScopedResource() }
        }

        let targetURL = folderURL.appending(path: item.relativePath)
        return action(targetURL)
    }

    private func scanFolder(at rootURL: URL) async -> [SearchItem] {
        let includeHidden = includeHiddenFiles
        return await Task.detached(priority: .userInitiated) { [weak self] in
            var results: [SearchItem] = []
            let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey, .nameKey]
            let rootPath = rootURL.path

            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !includeHidden {
                options.insert(.skipsHiddenFiles)
            }

            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: keys,
                options: options
            ) else {
                return []
            }

            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }
                let isDirectory = values.isDirectory ?? false
                let name = values.name ?? fileURL.lastPathComponent
                let size = values.fileSize.map(Int64.init)
                let fullPath = fileURL.path
                let relativePath = String(fullPath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))

                results.append(
                    SearchItem(
                        name: name,
                        path: fullPath,
                        relativePath: relativePath,
                        type: isDirectory ? .folder : .file,
                        modifiedDate: values.contentModificationDate,
                        sizeInBytes: size
                    )
                )

                if results.count.isMultiple(of: 1000) {
                    let count = results.count
                    Task { @MainActor in
                        self?.scannedCount = count
                    }
                }
            }

            let finalCount = results.count
            Task { @MainActor in
                self?.scannedCount = finalCount
            }
            return results
        }.value
    }
}
