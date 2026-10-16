import XCTest
@testable import TaskCore

final class TaskRepositoryTests: XCTestCase {
    private var repo: TaskRepository!
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        let now = fixedNow
        repo = TaskRepository(database: try AppDatabase.inMemory(), now: { now })
    }

    func testMigrationCreatesTables() throws {
        let tables = try repo.database.reader.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        }
        XCTAssertTrue(tables.contains("project"))
        XCTAssertTrue(tables.contains("task"))
        XCTAssertTrue(tables.contains("activity_log"))
    }

    func testCreateTaskRecordsCreatorAndLog() throws {
        let byUser = try repo.createTask(NewTask(title: "  牛乳を買う  "), actor: .user)
        let byAI = try repo.createTask(NewTask(title: "資料をまとめる"), actor: .ai)
        let byWidget = try repo.createTask(NewTask(title: "ウィジェット"), actor: .widget)

        XCTAssertEqual(byUser.title, "牛乳を買う")
        XCTAssertEqual(byUser.createdBy, .user)
        XCTAssertEqual(byAI.createdBy, .ai)
        XCTAssertEqual(byWidget.createdBy, .user)
        XCTAssertEqual(byUser.status, .todo)
        XCTAssertEqual([byUser.sortOrder, byAI.sortOrder, byWidget.sortOrder], [1, 2, 3])

        let logs = try repo.activity(taskId: byAI.id)
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs[0].actor, .ai)
        XCTAssertEqual(logs[0].action, .create)
        XCTAssertEqual(logs[0].decodedDiff()?["title"]?.to, .string("資料をまとめる"))
    }

    func testEmptyTitleIsRejected() {
        XCTAssertThrowsError(try repo.createTask(NewTask(title: "   "), actor: .user)) { error in
            XCTAssertEqual(error as? TaskRepositoryError, .emptyTitle)
        }
    }

    func testUpdateTaskWritesDiff() throws {
        let task = try repo.createTask(NewTask(title: "初稿"), actor: .user)
        let due = fixedNow.addingTimeInterval(3600)

        let updated = try repo.updateTask(
            id: task.id,
            changes: TaskChanges(title: .set("改稿"), priority: .set(.high), dueAt: .set(due)),
            actor: .ai
        )
        XCTAssertEqual(updated.title, "改稿")
        XCTAssertEqual(updated.priority, .high)
        XCTAssertEqual(updated.dueAt, due)

        let log = try XCTUnwrap(repo.activity(taskId: task.id).first)
        XCTAssertEqual(log.action, .update)
        XCTAssertEqual(log.actor, .ai)
        let diff = try XCTUnwrap(log.decodedDiff())
        XCTAssertEqual(diff["title"], FieldChange(from: .string("初稿"), to: .string("改稿")))
        XCTAssertEqual(diff["priority"], FieldChange(from: .null, to: .int(3)))
        XCTAssertEqual(diff["due_at"]?.from, .null)
        XCTAssertNil(diff["notes"])

        // 変更がなければログも増えない
        _ = try repo.updateTask(id: task.id, changes: TaskChanges(title: .set("改稿")), actor: .ai)
        XCTAssertEqual(try repo.activity(taskId: task.id).count, 2)
    }

    func testClearingOptionalFieldViaPatch() throws {
        let task = try repo.createTask(NewTask(title: "t", notes: "メモ"), actor: .user)
        let updated = try repo.updateTask(id: task.id, changes: TaskChanges(notes: .set(nil)), actor: .user)
        XCTAssertNil(updated.notes)
        let diff = try XCTUnwrap(repo.activity(taskId: task.id).first?.decodedDiff())
        XCTAssertEqual(diff["notes"], FieldChange(from: .string("メモ"), to: .null))
    }

    func testCompleteAndReopen() throws {
        let task = try repo.createTask(NewTask(title: "t"), actor: .user)

        let done = try repo.completeTask(id: task.id, actor: .widget)
        XCTAssertEqual(done.status, .done)
        XCTAssertEqual(done.completedAt, fixedNow)
        XCTAssertEqual(try repo.activity(taskId: task.id).first?.actor, .widget)
        XCTAssertEqual(try repo.activity(taskId: task.id).first?.action, .complete)

        // 二重完了は no-op
        _ = try repo.completeTask(id: task.id, actor: .widget)
        XCTAssertEqual(try repo.activity(taskId: task.id).count, 2)

        let reopened = try repo.reopenTask(id: task.id, actor: .user)
        XCTAssertEqual(reopened.status, .todo)
        XCTAssertNil(reopened.completedAt)
        XCTAssertEqual(try repo.activity(taskId: task.id).first?.action, .reopen)
    }

    func testArchiveHidesTaskByDefault() throws {
        let task = try repo.createTask(NewTask(title: "t"), actor: .user)
        _ = try repo.archiveTask(id: task.id, actor: .ai)

        XCTAssertTrue(try repo.tasks().isEmpty)
        XCTAssertEqual(try repo.tasks(matching: TaskFilter(includeArchived: true)).count, 1)
        XCTAssertNotNil(try repo.task(id: task.id)?.deletedAt)

        _ = try repo.restoreTask(id: task.id, actor: .user)
        XCTAssertEqual(try repo.tasks().count, 1)
        XCTAssertEqual(try repo.activity(taskId: task.id).map(\.action), [.restore, .archive, .create])
    }

    func testFilters() throws {
        let work = try repo.createProject(name: "仕事")
        let home = try repo.createProject(name: "家")
        let today = fixedNow.addingTimeInterval(60)
        let nextWeek = fixedNow.addingTimeInterval(7 * 86400)

        let a = try repo.createTask(NewTask(title: "a", projectId: work.id, priority: .high, dueAt: today), actor: .user)
        let b = try repo.createTask(NewTask(title: "b", projectId: work.id, priority: .low, dueAt: nextWeek), actor: .user)
        let c = try repo.createTask(NewTask(title: "c", projectId: home.id), actor: .user)
        _ = try repo.completeTask(id: c.id, actor: .user)

        XCTAssertEqual(try repo.tasks(matching: TaskFilter(projectId: work.id)).map(\.id), [a.id, b.id])
        XCTAssertEqual(try repo.tasks(matching: .open).map(\.id), [a.id, b.id])
        XCTAssertEqual(try repo.tasks(matching: TaskFilter(statuses: [.done])).map(\.id), [c.id])
        XCTAssertEqual(try repo.tasks(matching: TaskFilter(dueBefore: fixedNow.addingTimeInterval(86400))).map(\.id), [a.id])
        XCTAssertEqual(try repo.tasks(matching: TaskFilter(minimumPriority: .medium)).map(\.id), [a.id])
        XCTAssertEqual(try repo.tasks(matching: TaskFilter(limit: 1)).count, 1)
        XCTAssertEqual(try repo.tasks(matching: .today(now: fixedNow)).map(\.id), [a.id])
    }

    func testSortOrderIsPerProject() throws {
        let p = try repo.createProject(name: "p")
        let inbox1 = try repo.createTask(NewTask(title: "i1"), actor: .user)
        let proj1 = try repo.createTask(NewTask(title: "p1", projectId: p.id), actor: .user)
        let inbox2 = try repo.createTask(NewTask(title: "i2"), actor: .user)
        XCTAssertEqual([inbox1.sortOrder, proj1.sortOrder, inbox2.sortOrder], [1, 1, 2])
    }

    func testDeletingProjectDetachesTasks() throws {
        let p = try repo.createProject(name: "p")
        let task = try repo.createTask(NewTask(title: "t", projectId: p.id), actor: .user)
        try repo.deleteProject(id: p.id)
        XCTAssertNil(try repo.task(id: task.id)?.projectId)
        XCTAssertTrue(try repo.projects().isEmpty)
    }

    func testUnknownProjectIsRejected() {
        XCTAssertThrowsError(try repo.createTask(NewTask(title: "t", projectId: "nope"), actor: .user)) { error in
            XCTAssertEqual(error as? TaskRepositoryError, .projectNotFound("nope"))
        }
        XCTAssertThrowsError(try repo.completeTask(id: "missing", actor: .user)) { error in
            XCTAssertEqual(error as? TaskRepositoryError, .taskNotFound("missing"))
        }
    }

    func testFileBackedDatabaseUsesWAL() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try AppDatabase.open(at: dir.appendingPathComponent("tasks.sqlite"))
        let mode = try db.reader.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }
        XCTAssertEqual(mode, "wal")

        // 別の接続から同じファイルを開いても読める(マルチプロセスの代わり)
        let repo1 = TaskRepository(database: db)
        _ = try repo1.createTask(NewTask(title: "shared"), actor: .user)
        let db2 = try AppDatabase.open(at: dir.appendingPathComponent("tasks.sqlite"))
        XCTAssertEqual(try TaskRepository(database: db2).tasks().count, 1)
    }
}
