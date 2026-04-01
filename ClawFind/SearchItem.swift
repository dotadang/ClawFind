import Foundation

struct SearchItem: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let relativePath: String
    let type: ItemType
    let modifiedDate: Date?
    let sizeInBytes: Int64?

    enum ItemType: String, CaseIterable {
        case all = "全部"
        case file = "文件"
        case folder = "文件夹"

        var icon: String {
            switch self {
            case .all: return "line.3.horizontal.decrease.circle"
            case .file: return "doc"
            case .folder: return "folder"
            }
        }
    }

    var modifiedText: String {
        guard let modifiedDate else { return "—" }
        return modifiedDate.formatted(date: .abbreviated, time: .shortened)
    }

    var sizeText: String {
        guard let sizeInBytes, type == .file else { return "—" }
        return ByteCountFormatter.string(fromByteCount: sizeInBytes, countStyle: .file)
    }
}

enum SortOption: String, CaseIterable, Identifiable {
    case name = "名称"
    case modified = "时间"
    case size = "大小"
    case path = "路径"

    var id: String { rawValue }
}
