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
    /// タイプ。nil なら期限の有無から推定する(期限あり → 有期限、なし → 無期限)。
    /// `dueAt` が省略されたときの期限はタイプから決まる
    /// (当日 → 今日の終わり、スプリント → 今のスプリントの終わり、無期限 → なし)。有期限は `dueAt` 必須。
    public var type: TaskType?
    public var priority: TaskPriority?
    public var dueAt: Date?

    public init(
        title: String,
        notes: String? = nil,
        projectId: String? = nil,
        status: TaskStatus = .todo,
        type: TaskType? = nil,
        priority: TaskPriority? = nil,
        dueAt: Date? = nil
    ) {
        self.title = title
        self.notes = notes
        self.projectId = projectId
        self.status = status
        self.type = type
        self.priority = priority
        self.dueAt = dueAt
    }
}

public struct TaskChanges: Sendable {
    public var title: Patch<String> = .unchanged
    public var notes: Patch<String?> = .unchanged
    public var projectId: Patch<String?> = .unchanged
    public var status: Patch<TaskStatus> = .unchanged
    /// タイプを変えると、`dueAt` を同時に渡さない限り期限はタイプの既定値に置き直される。
    /// タイプを渡さずに `dueAt` だけ変えた場合、期限を消すと無期限に、無期限に期限を付けると有期限になる。
    public var type: Patch<TaskType> = .unchanged
    public var priority: Patch<TaskPriority?> = .unchanged
    public var dueAt: Patch<Date?> = .unchanged
    public var sortOrder: Patch<Int> = .unchanged

    public init(
        title: Patch<String> = .unchanged,
        notes: Patch<String?> = .unchanged,
        projectId: Patch<String?> = .unchanged,
        status: Patch<TaskStatus> = .unchanged,
        type: Patch<TaskType> = .unchanged,
        priority: Patch<TaskPriority?> = .unchanged,
        dueAt: Patch<Date?> = .unchanged,
        sortOrder: Patch<Int> = .unchanged
    ) {
        self.title = title
        self.notes = notes
        self.projectId = projectId
        self.status = status
        self.type = type
        self.priority = priority
        self.dueAt = dueAt
        self.sortOrder = sortOrder
    }
}

public struct TaskFilter: Sendable {
    public var statuses: Set<TaskStatus>?
    public var types: Set<TaskType>?
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
        types: Set<TaskType>? = nil,
        projectId: String? = nil,
        dueBefore: Date? = nil,
        dueAfter: Date? = nil,
        minimumPriority: TaskPriority? = nil,
        includeArchived: Bool = false,
        limit: Int? = nil
    ) {
        self.statuses = statuses
        self.types = types
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

/// 操作履歴 1 件とその対象タスクのタイトル。一覧表示用。
public struct ActivityEntry: Identifiable, Hashable, Sendable {
    public var entry: ActivityLog
    public var taskTitle: String

    public var id: Int64 { entry.id ?? -1 }

    public init(entry: ActivityLog, taskTitle: String) {
        self.entry = entry
        self.taskTitle = taskTitle
    }
}

public enum TaskRepositoryError: Error, LocalizedError, Equatable {
    case taskNotFound(String)
    case projectNotFound(String)
    case emptyTitle
    case activityNotFound(Int64)
    /// 取り消そうとした操作の差分が壊れていて解釈できない。
    case activityNotUndoable(Int64)
    /// 有期限タスクに期限がない。
    case dueDateRequired
    case commentNotFound(Int64)
    case emptyComment
    case linkNotFound(Int64)
    case invalidURL(String)

    public var errorDescription: String? {
        switch self {
        case .taskNotFound(let id): return "タスクが見つかりません: \(id)"
        case .projectNotFound(let id): return "プロジェクトが見つかりません: \(id)"
        case .emptyTitle: return "タイトルが空です"
        case .activityNotFound(let id): return "操作履歴が見つかりません: \(id)"
        case .activityNotUndoable(let id): return "この操作は取り消せません: \(id)"
        case .dueDateRequired: return "有期限のタスクには期限が必要です"
        case .commentNotFound(let id): return "コメントが見つかりません: \(id)"
        case .emptyComment: return "コメントが空です"
        case .linkNotFound(let id): return "リンクが見つかりません: \(id)"
        case .invalidURL(let s): return "URL として解釈できません: \(s)"
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
            if let types = filter.types {
                request = request.filter(types.map(\.rawValue).contains(TaskItem.Columns.type))
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

    /// 直近の操作履歴を、対象タスクのタイトル付きで返す(アーカイブ済みタスクの操作も含む)。
    public func recentActivity(limit: Int = 20) throws -> [ActivityEntry] {
        try database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT l.id, l.task_id, l.actor, l.action, l.diff, l.created_at, t.title
                FROM activity_log l JOIN task t ON t.id = l.task_id
                ORDER BY l.created_at DESC, l.id DESC
                LIMIT ?
                """, arguments: [limit])
            return try rows.map { row in
                ActivityEntry(
                    entry: try ActivityLog(row: row),
                    taskTitle: row["title"]
                )
            }
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
            let type = new.type ?? (new.dueAt == nil ? .openEnded : .deadline)
            let dueAt = try Self.resolveDueDate(type: type, dueAt: new.dueAt, now: now, schedule: try Self.sprintSchedule(db))
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
                type: type,
                priority: new.priority,
                dueAt: dueAt,
                sortOrder: nextOrder,
                createdBy: actor.creator,
                createdAt: now,
                updatedAt: now,
                completedAt: new.status == .done ? now : nil
            )
            try task.insert(db)
            var diff: TaskDiff = [
                "title": FieldChange(from: .null, to: .string(task.title)),
                "status": FieldChange(from: .null, to: .string(task.status.rawValue)),
                "type": FieldChange(from: .null, to: .string(task.type.rawValue)),
            ]
            if let dueAt { diff["due_at"] = FieldChange(from: .null, to: JSONValue(dueAt)) }
            try log(db, task: task.id, actor: actor, action: .create, diff: diff, at: now)
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
            if changes.type.isSet || changes.dueAt.isSet {
                var newType = changes.type.value ?? task.type
                if !changes.type.isSet, case .set(let due) = changes.dueAt {
                    // タイプを指定せず期限だけ変えたとき: 消せば無期限、無期限に付ければ有期限。
                    if due == nil { newType = .openEnded }
                    else if task.type == .openEnded { newType = .deadline }
                }
                // タイプだけ変えたときは期限をタイプの既定値に置き直す。期限も渡されたらそれを優先する。
                let requestedDue: Date? = changes.dueAt.isSet ? changes.dueAt.value.flatMap { $0 } : (newType == task.type ? task.dueAt : nil)
                let newDue = try Self.resolveDueDate(type: newType, dueAt: requestedDue, now: now, schedule: try Self.sprintSchedule(db))
                if newType != task.type {
                    diff["type"] = FieldChange(from: JSONValue(task.type), to: JSONValue(newType))
                    task.type = newType
                }
                if newDue != task.dueAt {
                    diff["due_at"] = FieldChange(from: JSONValue(task.dueAt), to: JSONValue(newDue))
                    task.dueAt = newDue
                }
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

    // MARK: コメント

    /// タスクのコメント(削除済みを除く)。古い順。
    public func comments(taskId: String, includeDeleted: Bool = false) throws -> [Comment] {
        try database.reader.read { db in
            var request = Comment.filter(Comment.Columns.taskId == taskId)
            if !includeDeleted { request = request.filter(Comment.Columns.deletedAt == nil) }
            return try request.order(Comment.Columns.createdAt, Comment.Columns.id).fetchAll(db)
        }
    }

    /// 削除済みを除いたコメント件数を、タスク id ごとに返す(一覧の表示用)。
    public func commentCounts() throws -> [String: Int] {
        try database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT task_id, COUNT(*) AS n FROM comment WHERE deleted_at IS NULL GROUP BY task_id")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["task_id"] as String, $0["n"] as Int) })
        }
    }

    /// コメントを追加する。`activity_log` に action = comment で残る。
    @discardableResult
    public func addComment(taskId: String, body: String, actor: ChangeActor) throws -> Comment {
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw TaskRepositoryError.emptyComment }
        let now = now()
        return try write { db in
            _ = try fetchTask(db, id: taskId)
            var comment = Comment(taskId: taskId, author: actor, body: body, createdAt: now)
            try comment.insert(db)
            try log(db, task: taskId, actor: actor, action: .comment, diff: [
                "comment_id": FieldChange(from: .null, to: .int(Int(comment.id!))),
                "comment": FieldChange(from: .null, to: .string(body)),
            ], at: now)
            return comment
        }
    }

    /// コメントを論理削除する。
    @discardableResult
    public func deleteComment(id: Int64, actor: ChangeActor) throws -> Comment {
        let now = now()
        return try write { db in try Self.setCommentDeleted(db, id: id, deleted: true, actor: actor, at: now) }
    }

    private static func setCommentDeleted(_ db: Database, id: Int64, deleted: Bool, actor: ChangeActor, at now: Date) throws -> Comment {
        guard var comment = try Comment.fetchOne(db, key: id) else { throw TaskRepositoryError.commentNotFound(id) }
        guard comment.isDeleted != deleted else { return comment }
        comment.deletedAt = deleted ? now : nil
        try comment.update(db)
        let change = deleted
            ? FieldChange(from: .string(comment.body), to: .null)
            : FieldChange(from: .null, to: .string(comment.body))
        var entry = ActivityLog(taskId: comment.taskId, actor: actor, action: deleted ? .deleteComment : .comment, diff: [
            "comment_id": FieldChange(from: .int(Int(id)), to: .int(Int(id))),
            "comment": change,
        ], createdAt: now)
        try entry.insert(db)
        return comment
    }

    // MARK: リンク

    /// タスクのリンク(削除済みを除く)。追加順。
    public func links(taskId: String) throws -> [TaskLink] {
        try database.reader.read { db in
            try TaskLink.filter(TaskLink.Columns.taskId == taskId).filter(TaskLink.Columns.deletedAt == nil)
                .order(TaskLink.Columns.createdAt, TaskLink.Columns.id).fetchAll(db)
        }
    }

    /// 全タスクのリンクをタスク id ごとにまとめて返す(一覧・ウィジェット用)。
    public func linksByTask() throws -> [String: [TaskLink]] {
        try database.reader.read { db in
            let all = try TaskLink.filter(TaskLink.Columns.deletedAt == nil)
                .order(TaskLink.Columns.createdAt, TaskLink.Columns.id).fetchAll(db)
            return Dictionary(grouping: all, by: \.taskId)
        }
    }

    /// リンクを追加する。http(s) か、スキーム付きの URL を受け付ける。同じ URL が既にあればそれを返す。
    @discardableResult
    public func addLink(taskId: String, url rawURL: String, label: String? = nil, actor: ChangeActor) throws -> TaskLink {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, !trimmed.isEmpty else {
            throw TaskRepositoryError.invalidURL(rawURL)
        }
        let label = label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let now = now()
        return try write { db in
            _ = try fetchTask(db, id: taskId)
            if let existing = try TaskLink.filter(TaskLink.Columns.taskId == taskId)
                .filter(TaskLink.Columns.url == url.absoluteString).filter(TaskLink.Columns.deletedAt == nil).fetchOne(db) {
                return existing
            }
            var link = TaskLink(taskId: taskId, url: url, label: label, createdBy: actor, createdAt: now)
            try link.insert(db)
            try log(db, task: taskId, actor: actor, action: .link, diff: [
                "link_id": FieldChange(from: .null, to: .int(Int(link.id!))),
                "url": FieldChange(from: .null, to: .string(url.absoluteString)),
                "label": FieldChange(from: .null, to: JSONValue(label)),
            ], at: now)
            return link
        }
    }

    /// リンクを論理削除する。
    @discardableResult
    public func removeLink(id: Int64, actor: ChangeActor) throws -> TaskLink {
        let now = now()
        return try write { db in try Self.setLinkDeleted(db, id: id, deleted: true, actor: actor, at: now) }
    }

    private static func setLinkDeleted(_ db: Database, id: Int64, deleted: Bool, actor: ChangeActor, at now: Date) throws -> TaskLink {
        guard var link = try TaskLink.fetchOne(db, key: id) else { throw TaskRepositoryError.linkNotFound(id) }
        guard link.isDeleted != deleted else { return link }
        link.deletedAt = deleted ? now : nil
        try link.update(db)
        let change = deleted
            ? FieldChange(from: .string(link.url.absoluteString), to: .null)
            : FieldChange(from: .null, to: .string(link.url.absoluteString))
        var entry = ActivityLog(taskId: link.taskId, actor: actor, action: deleted ? .deleteLink : .link, diff: [
            "link_id": FieldChange(from: .int(Int(id)), to: .int(Int(id))),
            "url": change,
        ], createdAt: now)
        try entry.insert(db)
        return link
    }

    // MARK: 設定

    private static let sprintScheduleKey = "sprint_schedule"

    /// スプリントの区切り方。未設定なら水曜開始・7 日。
    public func sprintSchedule() throws -> SprintSchedule {
        try database.reader.read { db in try Self.sprintSchedule(db) }
    }

    /// スプリントの区切り方を保存し、他プロセスに知らせる。
    public func setSprintSchedule(_ schedule: SprintSchedule) throws {
        try write { db in
            let data = try JSONEncoder().encode(schedule)
            try db.execute(
                sql: "INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [Self.sprintScheduleKey, String(decoding: data, as: UTF8.self)]
            )
        }
    }

    static func sprintSchedule(_ db: Database) throws -> SprintSchedule {
        guard let raw = try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [sprintScheduleKey]),
              let schedule = try? JSONDecoder().decode(SprintSchedule.self, from: Data(raw.utf8))
        else { return .default() }
        return schedule
    }

    /// タイプに応じて期限を決める。
    /// - 無期限: 常に nil。
    /// - 有期限: 渡された期限が必須。
    /// - 当日: 渡されなければ今日の終わり。
    /// - スプリント: 渡されなければ今のスプリントの終わり。
    static func resolveDueDate(type: TaskType, dueAt: Date?, now: Date, schedule: SprintSchedule, calendar: Calendar = .current) throws -> Date? {
        switch type {
        case .openEnded: return nil
        case .deadline:
            guard let dueAt else { throw TaskRepositoryError.dueDateRequired }
            return dueAt
        case .today: return dueAt ?? calendar.endOfDay(for: now)
        case .sprint: return dueAt ?? schedule.dueDate(forSprintContaining: now, calendar: calendar)
        }
    }

    // MARK: 取り消し

    /// `activity_log` の 1 件を取り消す。diff の `from` 側の値をタスクに書き戻し、
    /// その結果を通常の操作(reopen / restore / update など)として新たにログに残す。
    /// 取り消し自体も履歴に残るので、取り消しの取り消しもできる。
    ///
    /// 対象のタスクがその後さらに変更されていても、diff に含まれるフィールドだけを戻す。
    /// 戻した結果が現在の値と同じなら何もせず、ログも増えない。
    @discardableResult
    public func undo(activityId: Int64, actor: ChangeActor) throws -> TaskItem {
        let now = now()
        return try write { db in
            guard let entry = try ActivityLog.fetchOne(db, key: activityId) else {
                throw TaskRepositoryError.activityNotFound(activityId)
            }
            guard let diff = entry.decodedDiff(), !diff.isEmpty else {
                throw TaskRepositoryError.activityNotUndoable(activityId)
            }
            if entry.action == .link || entry.action == .deleteLink {
                guard let linkId = diff["link_id"]?.to.intValue else {
                    throw TaskRepositoryError.activityNotUndoable(activityId)
                }
                _ = try Self.setLinkDeleted(db, id: Int64(linkId), deleted: entry.action == .link, actor: actor, at: now)
                return try fetchTask(db, id: entry.taskId)
            }
            if entry.action == .comment || entry.action == .deleteComment {
                // コメントの追加は論理削除で、削除は復元で取り消す。
                guard let commentId = diff["comment_id"]?.to.intValue else {
                    throw TaskRepositoryError.activityNotUndoable(activityId)
                }
                _ = try Self.setCommentDeleted(db, id: Int64(commentId), deleted: entry.action == .comment, actor: actor, at: now)
                return try fetchTask(db, id: entry.taskId)
            }
            let current = try fetchTask(db, id: entry.taskId)
            var reverted = current
            if entry.action == .create {
                // 作成の取り消しは論理削除。物理削除はしない。
                guard current.deletedAt == nil else { return current }
                reverted.deletedAt = now
            } else {
                do {
                    try Self.apply(diff, to: &reverted, side: \.from)
                } catch {
                    throw TaskRepositoryError.activityNotUndoable(activityId)
                }
            }
            if let projectId = reverted.projectId, projectId != current.projectId {
                guard try Project.exists(db, key: projectId) else {
                    throw TaskRepositoryError.projectNotFound(projectId)
                }
            }

            let actual = Self.diff(from: current, to: reverted)
            guard !actual.isEmpty else { return current }

            reverted.updatedAt = now
            try reverted.update(db)
            try log(db, task: reverted.id, actor: actor, action: Self.inverseAction(of: entry.action, resulting: actual), diff: actual, at: now)
            return reverted
        }
    }

    /// diff の片側(`from` か `to`)の値をタスクに適用する。
    static func apply(_ diff: TaskDiff, to task: inout TaskItem, side: KeyPath<FieldChange, JSONValue>) throws {
        for (column, change) in diff {
            let value = change[keyPath: side]
            switch column {
            case "title":
                guard let title = value.stringValue, !title.isEmpty else { throw TaskRepositoryError.emptyTitle }
                task.title = title
            case "notes": task.notes = value.stringValue
            case "project_id": task.projectId = value.stringValue
            case "status":
                guard let raw = value.stringValue, let status = TaskStatus(rawValue: raw) else { throw UndoFieldError() }
                task.status = status
            case "type":
                guard let raw = value.stringValue, let type = TaskType(rawValue: raw) else { throw UndoFieldError() }
                task.type = type
            case "priority":
                if case .null = value { task.priority = nil }
                else {
                    guard let raw = value.intValue, let priority = TaskPriority(rawValue: raw) else { throw UndoFieldError() }
                    task.priority = priority
                }
            case "due_at": task.dueAt = try value.dateValue()
            case "completed_at": task.completedAt = try value.dateValue()
            case "deleted_at": task.deletedAt = try value.dateValue()
            case "sort_order":
                guard let order = value.intValue else { throw UndoFieldError() }
                task.sortOrder = order
            default:
                throw UndoFieldError()
            }
        }
    }

    struct UndoFieldError: Error {}

    /// 2 つのタスクの差分(ログに記録する形)。
    static func diff(from a: TaskItem, to b: TaskItem) -> TaskDiff {
        var d = TaskDiff()
        if a.title != b.title { d["title"] = FieldChange(from: .string(a.title), to: .string(b.title)) }
        if a.notes != b.notes { d["notes"] = FieldChange(from: JSONValue(a.notes), to: JSONValue(b.notes)) }
        if a.projectId != b.projectId { d["project_id"] = FieldChange(from: JSONValue(a.projectId), to: JSONValue(b.projectId)) }
        if a.status != b.status { d["status"] = FieldChange(from: JSONValue(a.status), to: JSONValue(b.status)) }
        if a.type != b.type { d["type"] = FieldChange(from: JSONValue(a.type), to: JSONValue(b.type)) }
        if a.priority != b.priority { d["priority"] = FieldChange(from: JSONValue(a.priority), to: JSONValue(b.priority)) }
        if a.dueAt != b.dueAt { d["due_at"] = FieldChange(from: JSONValue(a.dueAt), to: JSONValue(b.dueAt)) }
        if a.completedAt != b.completedAt { d["completed_at"] = FieldChange(from: JSONValue(a.completedAt), to: JSONValue(b.completedAt)) }
        if a.deletedAt != b.deletedAt { d["deleted_at"] = FieldChange(from: JSONValue(a.deletedAt), to: JSONValue(b.deletedAt)) }
        if a.sortOrder != b.sortOrder { d["sort_order"] = FieldChange(from: .int(a.sortOrder), to: .int(b.sortOrder)) }
        return d
    }

    /// 取り消しをどの操作としてログに残すか。
    static func inverseAction(of action: ActivityAction, resulting diff: TaskDiff) -> ActivityAction {
        switch action {
        case .complete: return .reopen
        case .reopen: return .complete
        case .archive: return .restore
        case .restore: return .archive
        case .create: return .archive
        case .comment: return .deleteComment
        case .deleteComment: return .comment
        case .link: return .deleteLink
        case .deleteLink: return .link
        case .update:
            if let status = diff["status"]?.to.stringValue {
                if status == TaskStatus.done.rawValue { return .complete }
                if diff["status"]?.from.stringValue == TaskStatus.done.rawValue { return .reopen }
            }
            return .update
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

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
