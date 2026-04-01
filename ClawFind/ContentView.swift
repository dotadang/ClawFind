import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var viewModel = SearchViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color.blue.opacity(0.10), Color.purple.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 20) {
                    headerView
                    searchBarView
                    filterBarView
                    contentView
                }
                .padding(24)
            }
            .navigationTitle("ClawFind")
        }
        .frame(minWidth: 980, minHeight: 680)
        .onChange(of: viewModel.selectedType) { _, _ in viewModel.runSearch() }
        .onChange(of: viewModel.selectedSort) { _, _ in viewModel.runSearch() }
        .alert("出错了", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.dismissError() } }
        )) {
            Button("好的") { viewModel.dismissError() }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var headerView: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ClawFind")
                    .font(.system(size: 32, weight: .bold))

                Text("一个更现代的 macOS 极速文件搜索器雏形")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Label("已索引目录：\(viewModel.indexedFolderPaths.count) 个", systemImage: "externaldrive")
                Label("索引条目：\(viewModel.totalIndexedCount)", systemImage: "shippingbox")
                Label(lastUpdatedLabel, systemImage: "clock")
            }
            .font(.footnote)
            .padding(12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private var lastUpdatedLabel: String {
        if viewModel.isIndexing {
            return "索引中… 已扫描 \(viewModel.scannedCount) 条"
        }
        guard let lastUpdatedAt = viewModel.lastUpdatedAt else {
            return "尚未建立索引"
        }
        return "上次更新：\(lastUpdatedAt.formatted(date: .omitted, time: .shortened))"
    }

    private var searchBarView: some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("搜索文件名、路径…", text: Binding(get: { viewModel.query }, set: { viewModel.updateQuery($0) }))
                    .textFieldStyle(.plain)

                if !viewModel.query.isEmpty {
                    Button {
                        viewModel.updateQuery("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Toggle("包含隐藏文件", isOn: $viewModel.includeHiddenFiles)
                .toggleStyle(.checkbox)

            Button {
                viewModel.chooseFolderAndIndex()
            } label: {
                Label(viewModel.isIndexing ? "索引中（\(viewModel.scannedCount)）" : "选择目录并索引", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isIndexing)
        }
    }

    private var filterBarView: some View {
        HStack {
            HStack(spacing: 8) {
                ForEach(SearchItem.ItemType.allCases, id: \.rawValue) { type in
                    Button {
                        viewModel.selectedType = type
                    } label: {
                        Label(type.rawValue, systemImage: type.icon)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(viewModel.selectedType == type ? Color.accentColor.opacity(0.16) : Color.clear)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()

            Picker("排序", selection: $viewModel.selectedSort) {
                ForEach(SortOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var contentView: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("搜索结果")
                        .font(.headline)
                    Spacer()
                    Text("显示 \(viewModel.displayItems.count) 项（最多 500）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(16)

                Divider()

                if viewModel.displayItems.isEmpty {
                    emptyStateView
                } else {
                    List(viewModel.displayItems) { item in
                        HStack(spacing: 14) {
                            Image(systemName: item.type == .folder ? "folder.fill" : "doc.text.fill")
                                .font(.title3)
                                .foregroundStyle(item.type == .folder ? .yellow : .blue)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name)
                                    .font(.headline)

                                Text(item.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer()

                            VStack(alignment: .trailing, spacing: 4) {
                                Text(item.modifiedText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(item.sizeText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        .contextMenu {
                            Button("打开") { openItem(item) }
                            Button("在 Finder 中显示") { revealInFinder(item) }
                            Button("复制路径") { copyPath(item) }
                        }
                        .onTapGesture(count: 2) {
                            openItem(item)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            VStack(alignment: .leading, spacing: 16) {
                Text("索引状态")
                    .font(.headline)

                statusCard(title: "扫描范围", value: viewModel.indexedFolderPaths.isEmpty ? "尚未选择目录" : viewModel.indexedFolderPaths.joined(separator: "\n"), icon: "folder.badge.plus")
                statusCard(title: "文件监控", value: viewModel.isMonitoring ? "正在监控文件变化" : "未启动监控", icon: viewModel.isMonitoring ? "eye" : "eye.slash")
                statusCard(title: "当前状态", value: viewModel.statusMessage, icon: "bolt.horizontal")

                Spacer()
            }
            .padding(18)
            .frame(width: 300)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var emptyStateDescription: String {
        if viewModel.totalIndexedCount == 0 {
            return "点击右上角\u{201C}选择目录并索引\u{201D}，先建立第一批文件索引。"
        }
        if viewModel.query.isEmpty {
            return "索引已加载完成。为了加快启动速度，应用现在不会在启动时自动加载结果列表。"
        }
        return "试试更短的关键词，或者切换筛选条件。"
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: viewModel.totalIndexedCount == 0 ? "folder.badge.questionmark" : "tray")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(viewModel.totalIndexedCount == 0 ? "还没有索引任何目录" : (viewModel.query.isEmpty ? "输入关键词开始搜索" : "没有找到结果"))
                .font(.headline)
            Text(emptyStateDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func statusCard(title: String, value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body)
                    .lineLimit(4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func openItem(_ item: SearchItem) {
        _ = viewModel.withSecurityScope(for: item) { url in
            NSWorkspace.shared.open(url)
        }
    }

    private func revealInFinder(_ item: SearchItem) {
        _ = viewModel.withSecurityScope(for: item) { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func copyPath(_ item: SearchItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.path, forType: .string)
    }
}

#Preview {
    ContentView()
}
