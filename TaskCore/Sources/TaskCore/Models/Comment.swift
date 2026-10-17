import Foundation
import GRDB

/// タスクへのコメント。人も AI も書ける。状況の共有や判断理由のメモに使う。削除は論理削除。
public struct Comment: Codable, Identifiable, Hashable, Sendable {
    public var id: Int64?
    public var taskId: String
    public var author: ChangeActor
    public var body: String
    public var createdAt: Date
    public var deletedAt: Date?

    public init(id: Int64? = nil, taskId: String, author: ChangeActor, body: String, createdAt: Date, deletedAt: Date? = nil) {
        self.id = id
        self.taskId = taskId
        self.author = author
        self.body = body
        self.createdAt = createdAt
        self.deletedAt = deletedAt
    }

    public var isDeleted: Bool { deletedAt != nil }
}

extension Comment: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "comment"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public enum Columns {
        public static let id = Column("id")
        public static let taskId = Column("task_id")
        public static let author = Column("author")
        public static let createdAt = Column("created_at")
        public static let deletedAt = Column("deleted_at")
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
