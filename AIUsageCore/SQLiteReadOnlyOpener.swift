import Foundation
import SQLite3

public enum SQLiteReadOnlyOpener {
    private static func probeReadable(_ db: OpaquePointer) -> Int32 {
        var statement: OpaquePointer?
        defer { if let statement { sqlite3_finalize(statement) } }
        let rc = sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master LIMIT 1;", -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else { return rc }
        let step = sqlite3_step(statement)
        return step == SQLITE_ROW || step == SQLITE_DONE ? SQLITE_OK : step
    }

    public static func open(path: String, busyTimeoutMs: Int32 = 500) -> OpaquePointer? {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        var failureRC = rc
        if rc == SQLITE_OK, let openDB = db {
            sqlite3_busy_timeout(openDB, busyTimeoutMs)
            failureRC = probeReadable(openDB)
            if failureRC == SQLITE_OK { return openDB }
        }
        if let db { sqlite3_close(db) }
        db = nil
        let baseRC = failureRC & 0xFF
        guard baseRC == SQLITE_CANTOPEN || baseRC == SQLITE_READONLY || baseRC == SQLITE_IOERR else { return nil }
        let escaped = path.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "?", with: "%3f")
            .replacingOccurrences(of: "#", with: "%23")
            .replacingOccurrences(of: " ", with: "%20")
        db = nil
        let retry = sqlite3_open_v2("file:\(escaped)?immutable=1", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil)
        if retry == SQLITE_OK, let retryDB = db {
            sqlite3_busy_timeout(retryDB, busyTimeoutMs)
            if probeReadable(retryDB) == SQLITE_OK { return retryDB }
        }
        if let db { sqlite3_close(db) }
        return nil
    }
}
