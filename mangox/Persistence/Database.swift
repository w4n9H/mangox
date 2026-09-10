//
//  Database.swift
//  系统 libsqlite3 薄封装 (零 SPM 依赖, 保住 swiftc typecheck 门禁)。
//  只做 open / prepare / bind / step / 事务, 不做 ORM。
//

import Foundation
import SQLite3

enum DBValue {
    case text(String)
    case int(Int64)
    case real(Double)
    case null
}

enum DatabaseError: Error {
    case open(String)
    case prepare(String, String)
    case step(String)
    case bind(String)
}

final class Database {
    private var handle: OpaquePointer?
    /// SQLITE_TRANSIENT: 让 sqlite 自己拷贝绑定字符串
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db,
                                 SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let db else {
            throw DatabaseError.open("sqlite3_open_v2 rc=\(rc)")
        }
        handle = db
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
    }

    deinit { sqlite3_close(handle) }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.prepare(sql, String(cString: sqlite3_errmsg(handle)))
        }
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ params: [DBValue], sql: String) throws {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch p {
            case .text(let s):  rc = sqlite3_bind_text(stmt, idx, s, -1, transient)
            case .int(let v):   rc = sqlite3_bind_int64(stmt, idx, v)
            case .real(let v):  rc = sqlite3_bind_double(stmt, idx, v)
            case .null:         rc = sqlite3_bind_null(stmt, idx)
            }
            guard rc == SQLITE_OK else { throw DatabaseError.bind(sql) }
        }
    }

    func run(_ sql: String, _ params: [DBValue] = []) throws {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params, sql: sql)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DatabaseError.step(sql) }
    }

    /// 返回按列名取值的行 (单语句; prepare 不支持多语句拼接)。
    func query(_ sql: String, _ params: [DBValue] = []) throws -> [[String: DBValue]] {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, params, sql: sql)
        var rows: [[String: DBValue]] = []
        let columnCount = sqlite3_column_count(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: DBValue] = [:]
            for c in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_TEXT:    row[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT:   row[name] = .real(sqlite3_column_double(stmt, c))
                default:             row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    func transaction(_ body: () throws -> Void) throws {
        try run("BEGIN IMMEDIATE")
        do {
            try body()
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    /// WAL → 主文件落盘 (TRUNCATE: checkpoint 后 wal 清零)。
    /// 进程被 SIGKILL/exit() 时 deinit 不跑、sqlite3_close 不执行,
    /// 已 commit 的数据会滞留在 -wal; 不 checkpoint 就删库 = 数据全丢 (P3.4 W5 事故根因)。
    func checkpoint() {
        sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }
}
