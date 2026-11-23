import Foundation
import SQLite3

public struct TeamsMessage: Equatable, Sendable {
    public let recId: Int64
    public let date: Date
    public let title: String
    public let subtitle: String?
    public let body: String

    public var displayLine: String {
        let head = [title, subtitle].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        let text = body.replacingOccurrences(of: "\n", with: " ")
        return head.isEmpty ? text : "\(head): \(text)"
    }
}

public enum TeamsNotificationSourceError: LocalizedError {
    case openFailed(String)
    case queryFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let msg): return "Cannot open notification database (Full Disk Access required?): \(msg)"
        case .queryFailed(let msg): return "Notification database query failed: \(msg)"
        }
    }
}

/// Reads Teams notifications that macOS `usernoted` persists in its SQLite database.
/// The database is opened read-only; access requires Full Disk Access.
public final class TeamsNotificationSource: @unchecked Sendable {
    public static let shared = TeamsNotificationSource()

    static let teamsBundleIds = ["com.microsoft.teams2", "com.microsoft.teams"]
    /// Apple's reference date (2001-01-01) offset from the Unix epoch.
    private static let appleEpochOffset: Double = 978_307_200

    public var databasePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Group Containers/group.com.apple.usernoted/db2/db"
    }

    /// Returns the highest Teams notification record id, used as the starting cursor.
    public func latestRecordId() throws -> Int64 {
        try withDatabase { db in
            let sql = "SELECT IFNULL(MAX(r.rec_id), 0) FROM record r JOIN app a USING(app_id) WHERE a.identifier IN (\(Self.bundlePlaceholders))"
            return try query(db, sql: sql, bindAfter: nil) { stmt in sqlite3_column_int64(stmt, 0) }.first ?? 0
        }
    }

    /// Returns Teams notifications with `rec_id` greater than the given cursor, oldest first.
    public func messages(after recId: Int64) throws -> [TeamsMessage] {
        try withDatabase { db in
            let sql = """
            SELECT r.rec_id, r.delivered_date, r.data FROM record r JOIN app a USING(app_id)
            WHERE a.identifier IN (\(Self.bundlePlaceholders)) AND r.rec_id > ?
            ORDER BY r.rec_id ASC
            """
            return try query(db, sql: sql, bindAfter: recId) { stmt -> TeamsMessage? in
                let id = sqlite3_column_int64(stmt, 0)
                let delivered = sqlite3_column_double(stmt, 1)
                guard let blob = sqlite3_column_blob(stmt, 2) else { return nil }
                let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 2)))
                return Self.parse(recId: id, delivered: delivered, data: data)
            }.compactMap { $0 }
        }
    }

    // MARK: - Private

    private static var bundlePlaceholders: String {
        teamsBundleIds.map { _ in "?" }.joined(separator: ",")
    }

    private static func parse(recId: Int64, delivered: Double, data: Data) -> TeamsMessage? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let req = plist["req"] as? [String: Any] else { return nil }
        return TeamsMessage(
            recId: recId,
            date: Date(timeIntervalSince1970: delivered + appleEpochOffset),
            title: req["titl"] as? String ?? "Teams",
            subtitle: req["subt"] as? String,
            body: req["body"] as? String ?? ""
        )
    }

    private func withDatabase<T>(_ work: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        let uri = "file:\(databasePath)?mode=ro"
        let rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        defer { sqlite3_close(db) }
        guard rc == SQLITE_OK, let db else {
            throw TeamsNotificationSourceError.openFailed(db.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)")
        }
        sqlite3_busy_timeout(db, 2000)
        return try work(db)
    }

    private func query<T>(_ db: OpaquePointer, sql: String, bindAfter: Int64?, row: (OpaquePointer) -> T) throws -> [T] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw TeamsNotificationSourceError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        // SQLITE_TRANSIENT: make SQLite copy the bound string.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var index: Int32 = 1
        for id in Self.teamsBundleIds {
            sqlite3_bind_text(stmt, index, id, -1, transient)
            index += 1
        }
        if let bindAfter {
            sqlite3_bind_int64(stmt, index, bindAfter)
        }

        var rows: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                rows.append(row(stmt))
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw TeamsNotificationSourceError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
        return rows
    }
}
