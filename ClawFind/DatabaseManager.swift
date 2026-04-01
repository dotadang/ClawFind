import Foundation
import SQLite3

/// SQLite SQLITE_TRANSIENT 的 Swift 等价物，告诉 SQLite 立即复制绑定的数据
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class DatabaseManager {
    static let shared = DatabaseManager()

    private var db: OpaquePointer?
    private let dbURL: URL

    /// 当前 schema 版本号，每次变更表结构时递增
    private static let currentSchemaVersion: Int32 = 1

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("ClawFind", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        dbURL = folder.appendingPathComponent("index.sqlite")
        openDatabase()
        migrateIfNeeded()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Database Setup

    private func openDatabase() {
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            print("[ClawFind] Failed to open database at \(dbURL.path)")
        }
    }

    private func migrateIfNeeded() {
        let currentVersion = getUserVersion()

        if currentVersion < 1 {
            createTablesV1()
            setUserVersion(Self.currentSchemaVersion)
        }
    }

    private func getUserVersion() -> Int32 {
        var stmt: OpaquePointer?
        var version: Int32 = 0
        if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                version = sqlite3_column_int(stmt, 0)
            }
        }
        sqlite3_finalize(stmt)
        return version
    }

    private func setUserVersion(_ version: Int32) {
        execute("PRAGMA user_version = \(version);")
    }

    private func createTablesV1() {
        execute("""
        CREATE TABLE IF NOT EXISTS indexed_folders (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT UNIQUE,
            bookmark BLOB,
            last_scan_at DOUBLE
        );
        """)

        execute("""
        CREATE TABLE IF NOT EXISTS indexed_files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT UNIQUE,
            relative_path TEXT,
            name TEXT,
            item_type TEXT,
            modified_at DOUBLE,
            size_bytes INTEGER
        );
        """)

        execute("CREATE INDEX IF NOT EXISTS idx_files_name ON indexed_files(name);")
        execute("CREATE INDEX IF NOT EXISTS idx_files_path ON indexed_files(path);")
        execute("CREATE INDEX IF NOT EXISTS idx_files_relpath ON indexed_files(relative_path);")
        execute("CREATE INDEX IF NOT EXISTS idx_files_type ON indexed_files(item_type);")
        execute("CREATE INDEX IF NOT EXISTS idx_files_modified ON indexed_files(modified_at);")
        execute("CREATE INDEX IF NOT EXISTS idx_files_size ON indexed_files(size_bytes);")
    }

    // MARK: - Index Operations

    func replaceIndex(folderPath: String, bookmarkData: Data?, items: [SearchItem]) throws {
        try executeOrThrow("BEGIN TRANSACTION;")

        do {
            try executeOrThrow("DELETE FROM indexed_files;")
            try executeOrThrow("DELETE FROM indexed_folders;")

            // 插入文件夹记录
            var folderStmt: OpaquePointer?
            let folderSQL = "INSERT INTO indexed_folders (path, bookmark, last_scan_at) VALUES (?, ?, ?);"
            guard sqlite3_prepare_v2(db, folderSQL, -1, &folderStmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(lastErrorMessage)
            }
            defer { sqlite3_finalize(folderStmt) }

            sqlite3_bind_text(folderStmt, 1, folderPath, -1, SQLITE_TRANSIENT)
            if let bookmarkData {
                bookmarkData.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(folderStmt, 2, ptr.baseAddress, Int32(bookmarkData.count), SQLITE_TRANSIENT)
                }
            } else {
                sqlite3_bind_null(folderStmt, 2)
            }
            sqlite3_bind_double(folderStmt, 3, Date().timeIntervalSince1970)

            guard sqlite3_step(folderStmt) == SQLITE_DONE else {
                throw DatabaseError.stepFailed(lastErrorMessage)
            }

            // 插入文件记录
            var fileStmt: OpaquePointer?
            let fileSQL = "INSERT INTO indexed_files (path, relative_path, name, item_type, modified_at, size_bytes) VALUES (?, ?, ?, ?, ?, ?);"
            guard sqlite3_prepare_v2(db, fileSQL, -1, &fileStmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(lastErrorMessage)
            }
            defer { sqlite3_finalize(fileStmt) }

            for item in items {
                sqlite3_reset(fileStmt)
                sqlite3_clear_bindings(fileStmt)
                sqlite3_bind_text(fileStmt, 1, item.path, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(fileStmt, 2, item.relativePath, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(fileStmt, 3, item.name, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(fileStmt, 4, item.type.rawValue, -1, SQLITE_TRANSIENT)
                if let modifiedDate = item.modifiedDate {
                    sqlite3_bind_double(fileStmt, 5, modifiedDate.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(fileStmt, 5)
                }
                if let size = item.sizeInBytes {
                    sqlite3_bind_int64(fileStmt, 6, size)
                } else {
                    sqlite3_bind_null(fileStmt, 6)
                }
                guard sqlite3_step(fileStmt) == SQLITE_DONE else {
                    throw DatabaseError.stepFailed(lastErrorMessage)
                }
            }

            try executeOrThrow("COMMIT;")

            // 回收已删除数据占用的空间
            execute("VACUUM;")
        } catch {
            execute("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Incremental Update

    func incrementalUpdate(folderPath: String, items: [SearchItem]) throws {
        try executeOrThrow("BEGIN TRANSACTION;")

        do {
            // 批量 upsert
            var upsertStmt: OpaquePointer?
            let upsertSQL = """
            INSERT INTO indexed_files (path, relative_path, name, item_type, modified_at, size_bytes)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                relative_path = excluded.relative_path,
                name = excluded.name,
                item_type = excluded.item_type,
                modified_at = excluded.modified_at,
                size_bytes = excluded.size_bytes;
            """
            guard sqlite3_prepare_v2(db, upsertSQL, -1, &upsertStmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(lastErrorMessage)
            }
            defer { sqlite3_finalize(upsertStmt) }

            for item in items {
                sqlite3_reset(upsertStmt)
                sqlite3_clear_bindings(upsertStmt)
                sqlite3_bind_text(upsertStmt, 1, item.path, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(upsertStmt, 2, item.relativePath, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(upsertStmt, 3, item.name, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(upsertStmt, 4, item.type.rawValue, -1, SQLITE_TRANSIENT)
                if let modifiedDate = item.modifiedDate {
                    sqlite3_bind_double(upsertStmt, 5, modifiedDate.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(upsertStmt, 5)
                }
                if let size = item.sizeInBytes {
                    sqlite3_bind_int64(upsertStmt, 6, size)
                } else {
                    sqlite3_bind_null(upsertStmt, 6)
                }
                guard sqlite3_step(upsertStmt) == SQLITE_DONE else {
                    throw DatabaseError.stepFailed(lastErrorMessage)
                }
            }

            // 删除磁盘上已不存在的记录：路径以 folderPath 开头但不在新扫描结果中
            let allCurrentPaths = Set(items.map(\.path))
            var selectStmt: OpaquePointer?
            let selectSQL = "SELECT id, path FROM indexed_files WHERE path LIKE ?;"
            guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(lastErrorMessage)
            }
            defer { sqlite3_finalize(selectStmt) }

            let prefix = folderPath.hasSuffix("/") ? folderPath + "%" : folderPath + "/%"
            sqlite3_bind_text(selectStmt, 1, prefix, -1, SQLITE_TRANSIENT)

            var idsToDelete: [Int64] = []
            while sqlite3_step(selectStmt) == SQLITE_ROW {
                let id = sqlite3_column_int64(selectStmt, 0)
                guard let pathC = sqlite3_column_text(selectStmt, 1) else { continue }
                let path = String(cString: pathC)
                if !allCurrentPaths.contains(path) {
                    idsToDelete.append(id)
                }
            }

            if !idsToDelete.isEmpty {
                let placeholders = idsToDelete.map { _ in "?" }.joined(separator: ",")
                let deleteSQL = "DELETE FROM indexed_files WHERE id IN (\(placeholders));"
                var deleteStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStmt, nil) == SQLITE_OK else {
                    throw DatabaseError.prepareFailed(lastErrorMessage)
                }
                defer { sqlite3_finalize(deleteStmt) }
                for (i, id) in idsToDelete.enumerated() {
                    sqlite3_bind_int64(deleteStmt, Int32(i + 1), id)
                }
                guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
                    throw DatabaseError.stepFailed(lastErrorMessage)
                }
            }

            // 更新文件夹的 last_scan_at
            try executeOrThrow("UPDATE indexed_folders SET last_scan_at = \(Date().timeIntervalSince1970) WHERE path = '\(folderPath)';")

            try executeOrThrow("COMMIT;")
        } catch {
            execute("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Query Operations

    func loadIndexedFolders() -> [String] {
        var results: [String] = []
        let sql = "SELECT path FROM indexed_folders ORDER BY id DESC;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cString = sqlite3_column_text(stmt, 0) {
                    results.append(String(cString: cString))
                }
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    func loadBookmarkDataForFirstFolder() -> Data? {
        let sql = "SELECT bookmark FROM indexed_folders ORDER BY id DESC LIMIT 1;"
        var stmt: OpaquePointer?
        var result: Data?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                let bytes = sqlite3_column_blob(stmt, 0)
                let length = sqlite3_column_bytes(stmt, 0)
                if let bytes, length > 0 {
                    result = Data(bytes: bytes, count: Int(length))
                }
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    func loadItemCount() -> Int {
        let sql = "SELECT COUNT(*) FROM indexed_files;"
        var stmt: OpaquePointer?
        var count = 0
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return count
    }

    func searchItems(query: String, type: SearchItem.ItemType, sort: SortOption, limit: Int) -> [SearchItem] {
        var results: [SearchItem] = []
        var conditions: [String] = []

        if !query.isEmpty {
            conditions.append("name LIKE ?")
        }
        if type != .all {
            conditions.append("item_type = ?")
        }

        let whereSQL = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"

        let orderSQL: String
        switch sort {
        case .name: orderSQL = "ORDER BY name COLLATE NOCASE ASC"
        case .modified: orderSQL = "ORDER BY modified_at DESC"
        case .size: orderSQL = "ORDER BY size_bytes DESC"
        case .path: orderSQL = "ORDER BY path COLLATE NOCASE ASC"
        }

        let sql = "SELECT path, relative_path, name, item_type, modified_at, size_bytes FROM indexed_files \(whereSQL) \(orderSQL) LIMIT ?;"
        var stmt: OpaquePointer?

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return results }
        defer { sqlite3_finalize(stmt) }

        var bindIndex: Int32 = 1
        if !query.isEmpty {
            let pattern = "%\(query)%"
            sqlite3_bind_text(stmt, bindIndex, pattern, -1, SQLITE_TRANSIENT)
            bindIndex += 1
        }
        if type != .all {
            sqlite3_bind_text(stmt, bindIndex, type.rawValue, -1, SQLITE_TRANSIENT)
            bindIndex += 1
        }
        sqlite3_bind_int(stmt, bindIndex, Int32(limit))

        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let pathC = sqlite3_column_text(stmt, 0),
                  let relC = sqlite3_column_text(stmt, 1),
                  let nameC = sqlite3_column_text(stmt, 2),
                  let typeC = sqlite3_column_text(stmt, 3) else { continue }

            let path = String(cString: pathC)
            let relativePath = String(cString: relC)
            let name = String(cString: nameC)
            let typeRaw = String(cString: typeC)
            let modifiedAt = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            let size = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 5)
            let itemType: SearchItem.ItemType = typeRaw == SearchItem.ItemType.folder.rawValue ? .folder : .file

            results.append(SearchItem(name: name, path: path, relativePath: relativePath, type: itemType, modifiedDate: modifiedAt, sizeInBytes: size))
        }

        return results
    }

    func loadLastUpdatedAt() -> Date? {
        let sql = "SELECT last_scan_at FROM indexed_folders ORDER BY id DESC LIMIT 1;"
        var stmt: OpaquePointer?
        var result: Date?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                result = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    // MARK: - Helpers

    private var lastErrorMessage: String {
        String(cString: sqlite3_errmsg(db))
    }

    @discardableResult
    private func execute(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func executeOrThrow(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.executionFailed(sql, lastErrorMessage)
        }
    }
}

// MARK: - Error Types

enum DatabaseError: LocalizedError {
    case prepareFailed(String)
    case stepFailed(String)
    case executionFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .prepareFailed(let msg):
            return "数据库语句准备失败：\(msg)"
        case .stepFailed(let msg):
            return "数据库执行失败：\(msg)"
        case .executionFailed(let sql, let msg):
            return "SQL 执行失败「\(sql)」：\(msg)"
        }
    }
}
