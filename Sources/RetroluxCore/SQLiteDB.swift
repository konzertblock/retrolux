import Foundation
import SQLite3

public enum SQLValue { case null, int(Int64), double(Double), text(String), blob(Data) }

public final class SQLiteDB {
    var h: OpaquePointer?
    public let path: String
    public init(path: String, readOnly: Bool = false, immutable: Bool = false) throws {
        self.path = path
        var flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        var target = path
        if immutable { target = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?immutable=1"; flags |= SQLITE_OPEN_URI }
        guard sqlite3_open_v2(target, &h, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: 1, userInfo: [NSLocalizedDescriptionKey: "open failed: \(path)"])
        }
        if !readOnly { try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;") }
    }
    deinit { sqlite3_close(h) }

    var lastError: String { String(cString: sqlite3_errmsg(h)) }

    @discardableResult public func exec(_ sql: String) throws -> Void {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(h, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "?"; sqlite3_free(err)
            throw NSError(domain: "SQLite", code: 2, userInfo: [NSLocalizedDescriptionKey: m])
        }
    }

    @discardableResult public func run(_ sql: String, _ binds: [SQLValue] = []) throws -> Int64 {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK else { throw NSError(domain: "SQLite", code: 3, userInfo: [NSLocalizedDescriptionKey: lastError + " in " + sql]) }
        defer { sqlite3_finalize(st) }
        bind(st, binds)
        let rc = sqlite3_step(st)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw NSError(domain: "SQLite", code: 4, userInfo: [NSLocalizedDescriptionKey: lastError]) }
        return sqlite3_last_insert_rowid(h)
    }

    public func query(_ sql: String, _ binds: [SQLValue] = []) throws -> [[SQLValue]] {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK else { throw NSError(domain: "SQLite", code: 3, userInfo: [NSLocalizedDescriptionKey: lastError + " in " + sql]) }
        defer { sqlite3_finalize(st) }
        bind(st, binds)
        var rows: [[SQLValue]] = []
        let n = sqlite3_column_count(st)
        while sqlite3_step(st) == SQLITE_ROW {
            var r: [SQLValue] = []
            for i in 0..<n {
                switch sqlite3_column_type(st, i) {
                case SQLITE_INTEGER: r.append(.int(sqlite3_column_int64(st, i)))
                case SQLITE_FLOAT: r.append(.double(sqlite3_column_double(st, i)))
                case SQLITE_TEXT: r.append(.text(String(cString: sqlite3_column_text(st, i))))
                case SQLITE_BLOB:
                    let len = Int(sqlite3_column_bytes(st, i)); if let p = sqlite3_column_blob(st, i) { r.append(.blob(Data(bytes: p, count: len))) } else { r.append(.blob(Data())) }
                default: r.append(.null)
                }
            }
            rows.append(r)
        }
        return rows
    }

    public func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do { try body(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }

    private func bind(_ st: OpaquePointer?, _ binds: [SQLValue]) {
        let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)   // SQLITE_TRANSIENT
        for (i, b) in binds.enumerated() {
            let p = Int32(i + 1)
            switch b {
            case .null: sqlite3_bind_null(st, p)
            case .int(let v): sqlite3_bind_int64(st, p, v)
            case .double(let v): sqlite3_bind_double(st, p, v)
            case .text(let v): sqlite3_bind_text(st, p, v, -1, T)
            case .blob(let v): v.withUnsafeBytes { _ = sqlite3_bind_blob(st, p, $0.baseAddress, Int32(v.count), T) }
            }
        }
    }
}

public extension SQLValue {
    var int: Int64? { switch self { case .int(let v): return v; case .double(let v): return Int64(v); case .text(let s): return Int64(s); default: return nil } }
    var dbl: Double? { switch self { case .double(let v): return v; case .int(let v): return Double(v); case .text(let s): return Double(s); default: return nil } }
    var str: String? { switch self { case .text(let v): return v; case .int(let v): return String(v); case .double(let v): return String(v); default: return nil } }
    var data: Data? { if case .blob(let d) = self { return d }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }
}
func opt(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
func opt(_ d: Double?) -> SQLValue { d.map { .double($0) } ?? .null }
