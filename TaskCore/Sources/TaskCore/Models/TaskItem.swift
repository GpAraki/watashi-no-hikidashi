import Foundation
import GRDB

/// タスク 1 件。Swift Concurrency の `Task` と名前が衝突するため `TaskItem` とする。
/// テーブル名は設計どおり `task`。
public struct TaskItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var projectId: String?
    public var title: String
    public var notes: String?
    public var status: TaskStatus
    public var type: TaskType
    public var priority: TaskPriority?
    public var dueAt: Date?
    public var sortOrder: Int
    public var createdBy: TaskCreator
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        projectId: String? = nil,
        title: String,
        notes: String? = nil,
        status: TaskStatus = .todo,
        type: TaskType = .openEnded,
        priority: TaskPriority? = nil,
        dueAt: Date? = nil,
        sortOrder: Int,
        createdBy: TaskCreator,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.notes = notes
        self.status = status
        self.type = type
        self.priority = priority
        self.dueAt = dueAt
        self.sortOrder = sortOrder
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.deletedAt = deletedAt
    }

    public var isArchived: Bool { deletedAt != nil }
    public var isDone: Bool { status == .done }

    /// 期限を過ぎていて未完了か。
    public func isOverdue(now: Date = Date()) -> Bool {
        guard let dueAt, !isDone else { return false }
        return dueAt < now
    }

    /// 期限が `now` と同じ日か(有期限タスクの「今日」バッジ用)。
    public func isDueToday(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let dueAt else { return false }
        return calendar.isDate(dueAt, inSameDayAs: now)
    }
}

extension TaskItem: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "task"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public enum Columns {
        public static let id = Column("id")
        public static let projectId = Column("project_id")
        public static let title = Column("title")
        public static let notes = Column("notes")
        public static let status = Column("status")
        public static let type = Column("type")
        public static let priority = Column("priority")
        public static let dueAt = Column("due_at")
        public static let sortOrder = Column("sort_order")
        public static let createdBy = Column("created_by")
        public static let createdAt = Column("created_at")
        public static let updatedAt = Column("updated_at")
        public static let completedAt = Column("completed_at")
        public static let deletedAt = Column("deleted_at")
    }

    /// 論理削除されていないタスク。
    public static var active: QueryInterfaceRequest<TaskItem> {
        filter(Columns.deletedAt == nil)
    }
}
