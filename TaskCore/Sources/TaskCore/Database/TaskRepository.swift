import Foundation
import GRDB

// MARK: - 入力型

/// 更新時に「変更しない」と「nil にする」を区別するための型。
public enum Patch<Value: Sendable>: Sendable {
    case unchanged
    case set(Value)

    var value: Value? {
        if case .set(let v) = self { return v }
        return nil
    }
    var isSet: Bool {
        if case .set = self { return true }
        return false
    }
}

public struct NewTask: Sendable {
    public var title: String
    public var notes: String?
    public var projectId: String?
    public var status: TaskStatus
    public var priority: TaskPriority?
    public var dueAt: Date?

    public init(
        title: String,
        notes: String? = nil,
        projectId: String? = nil,
        status: TaskStatus = .todo,
        priority: TaskPriority? = nil,
        dueAt: Date? = nil
    ) {
        self.title = title
        self.notes = notes
        self.projectId = projectId
        self.status = status
        self.priority = priority
        self.dueAt = dueAt
    }
}

public struct TaskChanges: Sendable {
    public var title: Patch<String> = .unchanged
    public var notes: Patch<String?> = .unchanged
    public var projectId: Patch<String?> = .unchanged
    public var status: Patch<TaskStatus> = .unchanged
    public var priority: Patch<TaskPriority?> = .unchanged
    public var dueAt: Patch<Date?> = .unchanged
    public var sortOrder: Patch<Int> = .unchanged

    public init(
        title: Patch<String> = .unchanged,
        notes: Patch<String?> = .unchanged,
        projectId: Patch<String?> = .unchanged,
        status: Patch<TaskStatus> = .unchanged,
        priority: Patch<TaskPriority?> = .unchanged,
        dueAt: Patch<Date?> = .unchanged,
        sortOrder: Patch<Int> = .unchanged
    ) {
        self.title = title
        self.notes = notes
        self.projectId = projectId
        self.status = status
        self.priority = priority
        self.dueAt = dueAt
        self.sortOrder = sortOrder
    }
}

public struct TaskFilter: Sendable {
    public var statuses: Set<TaskStatus>?
    public var projectId: String?
    /// 期限がこの日時以前(境界を含む)のものに絞る。
    public var dueBefore: Date?
    /// 期限がこの日時以降(境界を含む)のものに絞る。
    public var dueAfter: Date?
    /// この優先度以上のものに絞る。
    public var minimumPriority: TaskPriority?
    public var includeArchived: Bool
    public var limit: Int?

    public init(
        statuses: Set<TaskStatus>? = nil,
        projectId: String? = nil,
        dueBefore: Date? = nil,
        dueAfter: Date? = nil,
        minimumPriority: TaskPriority? = nil,
        includeArchived: Bool = false,
        limit: Int? = nil
    ) {
        self.statuses = statuses
        self.projectId = projectId
        self.dueBefore = dueBefore
        self.dueAfter = dueAfter
        self.minimumPriority = minimumPriority
        self.includeArchived = includeArchived
        self.limit = limit
    }

    /// 未完了のタスク。
    public static var open: TaskFilter { TaskFilter(statuses: [.todo, .doing]) }

    /// 「今日のタスク」: 未完了で、期限が今日の終わりまでのもの(期限切れを含む)。
    public static func today(now: Date = Date(), calendar: Calendar = .current) -> TaskFilter {
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        return TaskFilter(statuses: [.todo, .doing], dueBefore: startOfTomorrow.addingTimeInterval(-1))
    }
}

public enum TaskRepositoryError: Error, LocalizedError, Equatable {
    case taskNotFound(String)
    case projectNotFound(String)
    case emptyTitle

    public var errorDescription: String? {
        switch self {
        case .taskNotFound(let id): return "タスクが見つかりません: \(id)"
        case .projectNotFound(let id): return "プロジェクトが見つかりません: \(id)"
        case .emptyTitle: return "タイトルが空です"
        }
    }
}

// MARK: - Repository

/// タスクとプロジェクトの読み書き。書き込みは必ず `activity_log` に記録し、
/// 完了後に `ChangeNotifier` で他プロセスへ変更を知らせる。
public final class TaskRepository: Sendable {
    public let database: AppDatabase
    private let notifier: ChangeNotifier?
    private let now: @Sendable () -> Date

    public init(
        database: AppDatabase,
        notifier: ChangeNotifier? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.notifier = notifier
        self.now = now
    }

    // MARK: 読み取り

    public func tasks(matching filter: TaskFilter = TaskFilter()) throws -> [TaskItem] {
        try database.reader.read { db in
            var request = filter.includeArchived ? TaskItem.all() : TaskItem.active
            if let statuses = filter.statuses {
                request = request.filter(statuses.map(\.rawValue).contains(TaskItem.Columns.status))
            }
            if let projectId = filter.projectId {
                request = request.filter(TaskItem.Columns.projectId == projectId)
            }
            if let dueBefore = filter.dueBefore {
                request = request.filter(TaskItem.Columns.dueAt != nil && TaskItem.Columns.dueAt <= dueBefore)
            }
            if let dueAfter = filter.dueAfter {
                request = request.filter(TaskItem.Columns.dueAt != nil && TaskItem.Columns.dueAt >= dueAfter)
            }
            if let minimumPriority = filter.minimumPriority {
                request = request.filter(TaskItem.Columns.priority >= minimumPriority.rawValue)
            }
            request = request.order(TaskItem.Columns.sortOrder, TaskItem.Columns.createdAt)
            if let limit = filter.limit {
                request = request.limit(limit)
            }
            return try request.fetchAll(db)
        }
    }

    public func task(id: String) throws -> TaskItem? {
        try database.reader.read { db in try TaskItem.fetchOne(db, key: id) }
    }

    public func projects() throws -> [Project] {
        try database.reader.read { db in
            try Project.order(Project.Columns.sortOrder, Project.Columns.name).fetchAll(db)
        }
    }

    public func activity(taskId: String? = nil, limit: Int = 100) throws -> [ActivityLog] {
        try database.reader.read { db in
            var request = ActivityLog.order(ActivityLog.Columns.createdAt.desc, ActivityLog.Columns.id.desc).limit(limit)
            if let taskId {
                request = request.filter(ActivityLog.Columns.taskId == taskId)
            }
            return try request.fetchAll(db)
        }
    }

    // MARK: タスクの書き込み

    @discardableResult
    public func createTask(_ new: NewTask, actor: ChangeActor) throws -> TaskItem {
        let title = new.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw TaskRepositoryError.emptyTitle }
        let now = now()

        let task = try write { db in
            if let projectId = new.projectId {
                guard try Project.exists(db, key: projectId) else {
                    throw TaskRepositoryError.projectNotFound(projectId)
                }
            }
            let nextOrder = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sort_order), 0) + 1 FROM task WHERE deleted_at IS NULL AND project_id IS ?",
                arguments: [new.projectId]
            ) ?? 1

            let task = TaskItem(
                projectId: new.projectId,
                title: title,
                notes: new.notes,
                status: new.status,
                priority: new.priority,
                dueAt: new.dueAt,
                sortOrder: nextOrder,
                createdBy: actor.creator,
                createdAt: now,
                updatedAt: now,
                completedAt: new.status == .done ? now : nil
            )
            try task.insert(db)
            try log(db, task: task.id, actor: actor, action: .create, diff: [
                "title": FieldChange(from: .null, to: .string(task.title)),
                "status": FieldChange(from: .null, to: .string(task.status.rawValue)),
            ], at: now)
            return task
        }
        return task
    }

    @discardableResult
    public func updateTask(id: String, changes: TaskChanges, actor: ChangeActor) throws -> TaskItem {
        let now = now()
        return try write { db in
            var task = try fetchTask(db, id: id)
            var diff = TaskDiff()

            if case .set(let value) = changes.title {
                let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { throw TaskRepositoryError.emptyTitle }
                if title != task.title {
                    diff["title"] = FieldChange(from: .string(task.title), to: .string(title))
                    task.title = title
                }
            }
            if case .set(let value) = changes.notes, value != task.notes {
                diff["notes"] = FieldChange(from: JSONValue(task.notes), to: JSONValue(value))
                task.notes = value
            }
            if case .set(let value) = changes.projectId, value != task.projectId {
                if let value {
                    guard try Project.exists(db, key: value) else {
                        throw TaskRepositoryError.projectNotFound(value)
                    }
                }
                diff["project_id"] = FieldChange(from: JSONValue(task.projectId), to: JSONValue(value))
                task.projectId = value
            }
            if case .set(let value) = changes.priority, value != task.priority {
                diff["priority"] = FieldChange(from: JSONValue(task.priority), to: JSONValue(value))
                task.priority = value
            }
            if case .set(let value) = changes.dueAt, value != task.dueAt {
                diff["due_at"] = FieldChange(from: JSONValue(task.dueAt), to: JSONValue(value))
                task.dueAt = value
            }
            if case .set(let value) = changes.sortOrder, value != task.sortOrder {
                diff["sort_order"] = FieldChange(from: .int(task.sortOrder), to: .int(value))
                task.sortOrder = value
            }
            if case .set(let value) = changes.status, value != task.status {
                diff["status"] = FieldChange(from: JSONValue(task.status), to: JSONValue(value))
                let newCompletedAt: Date? = value == .done ? now : nil
                if newCompletedAt != task.completedAt {
                    diff["completed_at"] = FieldChange(from: JSONValue(task.completedAt), to: JSONValue(newCompletedAt))
                    task.completedAt = newCompletedAt
                }
                task.status = value
            }

            guard !diff.isEmpty else { return task }
            task.updatedAt = now
            try task.update(db)
            try log(db, task: task.id, actor: actor, action: .update, diff: diff, at: now)
            return task
        }
    }

    @discardableResult
    public func completeTask(id: String, actor: ChangeActor) throws -> TaskItem {
        try transition(id: id, to: .done, action: .complete, actor: actor)
    }

    /// 完了したタスクを todo に戻す。
    @discardableResult
    public func reopenTask(id: String, actor: ChangeActor) throws -> TaskItem {
        try transition(id: id, to: .todo, action: .reopen, actor: actor)
    }

    /// 論理削除。物理削除は提供しない。
    @discardableResult
    public func archiveTask(id: String, actor: ChangeActor) throws -> TaskItem {
        let now = now()
        return try write { db in
            var task = try fetchTask(db, id: id)
            guard task.deletedAt == nil else { return task }
            let diff: TaskDiff = ["deleted_at": FieldChange(from: .null, to: JSONValue(now))]
            task.deletedAt = now
            task.updatedAt = now
            try task.update(db)
            try log(db, task: task.id, actor: actor, action: .archive, diff: diff, at: now)
            return task
        }
    }

    @discardableResult
    public func restoreTask(id: String, actor: ChangeActor) throws -> TaskItem {
        let now = now()
        return try write { db in
            var task = try fetchTask(db, id: id)
            guard let deletedAt = task.deletedAt else { return task }
            let diff: TaskDiff = ["deleted_at": FieldChange(from: JSONValue(deletedAt), to: .null)]
            task.deletedAt = nil
            task.updatedAt = now
            try task.update(db)
            try log(db, task: task.id, actor: actor, action: .restore, diff: diff, at: now)
            return task
        }
    }

    // MARK: プロジェクト

    @discardableResult
    public func createProject(name: String) throws -> Project {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TaskRepositoryError.emptyTitle }
        return try write { db in
            let nextOrder = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sort_order), 0) + 1 FROM project") ?? 1
            let project = Project(name: name, sortOrder: nextOrder)
            try project.insert(db)
            return project
        }
    }

    public func renameProject(id: String, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw TaskRepositoryError.emptyTitle }
        try write { db in
            guard var project = try Project.fetchOne(db, key: id) else {
                throw TaskRepositoryError.projectNotFound(id)
            }
            project.name = name
            try project.update(db)
        }
    }

    /// プロジェクトを削除する。所属タスクは残り、`project_id` が NULL になる。
    public func deleteProject(id: String) throws {
        try write { db in
            guard try Project.deleteOne(db, key: id) else {
                throw TaskRepositoryError.projectNotFound(id)
            }
        }
    }

    // MARK: - 内部

    private func transition(id: String, to status: TaskStatus, action: ActivityAction, actor: ChangeActor) throws -> TaskItem {
        let now = now()
        return try write { db in
            var task = try fetchTask(db, id: id)
            guard task.status != status else { return task }
            var diff: TaskDiff = ["status": FieldChange(from: JSONValue(task.status), to: JSONValue(status))]
            let newCompletedAt: Date? = status == .done ? now : nil
            if newCompletedAt != task.completedAt {
                diff["completed_at"] = FieldChange(from: JSONValue(task.completedAt), to: JSONValue(newCompletedAt))
                task.completedAt = newCompletedAt
            }
            task.status = status
            task.updatedAt = now
            try task.update(db)
            try log(db, task: task.id, actor: actor, action: action, diff: diff, at: now)
            return task
        }
    }

    private func fetchTask(_ db: Database, id: String) throws -> TaskItem {
        guard let task = try TaskItem.fetchOne(db, key: id) else {
            throw TaskRepositoryError.taskNotFound(id)
        }
        return task
    }

    private func log(_ db: Database, task: String, actor: ChangeActor, action: ActivityAction, diff: TaskDiff, at date: Date) throws {
        var entry = ActivityLog(taskId: task, actor: actor, action: action, diff: diff, createdAt: date)
        try entry.insert(db)
    }

    /// 短いトランザクションで書き込み、成功したら変更通知を投げる。
    private func write<T>(_ updates: (Database) throws -> T) throws -> T {
        let result = try database.writer.write(updates)
        notifier?.post()
        return result
    }
}
