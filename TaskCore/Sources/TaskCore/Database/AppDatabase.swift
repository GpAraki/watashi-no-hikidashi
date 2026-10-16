import Foundation
import GRDB

/// SQLite への接続と、スキーママイグレーションの管理。
///
/// 本体・ウィジェット・MCP サーバーの 3 プロセスが同じファイルを同時に
/// 読み書きするため、`DatabasePool`(WAL モード)と busy timeout を使う。
public struct AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// 共有コンテナ内のファイルを開く。親ディレクトリがなければ作る。
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var config = Configuration()
        config.busyMode = .timeout(5)
        config.label = "TaskCore"
        // DatabasePool は WAL モードを自動で有効にする。
        let pool = try DatabasePool(path: url.path, configuration: config)
        return try AppDatabase(writer: pool)
    }

    /// テストや一時的な用途向けのメモリ内 DB。
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(writer: DatabaseQueue())
    }

    public var reader: any DatabaseReader { writer }

    // MARK: - Migrations

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "project") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("sort_order", .integer).notNull()
            }

            try db.create(table: "task") { t in
                t.primaryKey("id", .text)
                t.column("project_id", .text)
                    .references("project", onDelete: .setNull)
                t.column("title", .text).notNull()
                t.column("notes", .text)
                t.column("status", .text).notNull()
                    .check { ["todo", "doing", "done"].contains($0) }
                t.column("priority", .integer)
                t.column("due_at", .datetime)
                t.column("sort_order", .integer).notNull()
                t.column("created_by", .text).notNull()
                    .check { ["user", "ai"].contains($0) }
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("completed_at", .datetime)
                t.column("deleted_at", .datetime)
            }
            try db.create(index: "task_status", on: "task", columns: ["status"])
            try db.create(index: "task_project", on: "task", columns: ["project_id"])
            try db.create(index: "task_due", on: "task", columns: ["due_at"])
            try db.create(index: "task_deleted", on: "task", columns: ["deleted_at"])

            try db.create(table: "activity_log") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("task_id", .text).notNull()
                t.column("actor", .text).notNull()
                t.column("action", .text).notNull()
                t.column("diff", .text)
                t.column("created_at", .datetime).notNull()
            }
            try db.create(index: "activity_task", on: "activity_log", columns: ["task_id"])
            try db.create(index: "activity_created", on: "activity_log", columns: ["created_at"])
        }

        return migrator
    }
}
