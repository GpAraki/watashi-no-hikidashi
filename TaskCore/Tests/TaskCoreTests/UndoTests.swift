import XCTest
@testable import TaskCore

final class UndoTests: XCTestCase {
    private var repo: TaskRepository!
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        let now = fixedNow
        repo = TaskRepository(database: try AppDatabase.inMemory(), now: { now })
    }

    private func latest(_ taskId: String) throws -> ActivityLog {
        try XCTUnwrap(repo.activity(taskId: taskId).first)
    }

    func testUndoCompleteReopens() throws {
        let task = try repo.createTask(NewTask(title: "t"), actor: .user)
        _ = try repo.completeTask(id: task.id, actor: .widget)
        let entry = try latest(task.id)

        let undone = try repo.undo(activityId: entry.id!, actor: .user)
        XCTAssertEqual(undone.status, .todo)
        XCTAssertNil(undone.completedAt)
        let log = try latest(task.id)
        XCTAssertEqual(log.action, .reopen)
        XCTAssertEqual(log.actor, .user)
        XCTAssertEqual(try repo.activity(taskId: task.id).count, 3)
    }

    func testUndoUpdateRestoresOnlyChangedFields() throws {
        let task = try repo.createTask(NewTask(title: "初稿", notes: "メモ", priority: .low), actor: .user)
        _ = try repo.updateTask(id: task.id, changes: TaskChanges(title: .set("改稿"), priority: .set(.high)), actor: .ai)
        let aiEdit = try latest(task.id)
        // その後ユーザーがメモだけ変えた
        _ = try repo.updateTask(id: task.id, changes: TaskChanges(notes: .set("別のメモ")), actor: .user)

        let undone = try repo.undo(activityId: aiEdit.id!, actor: .user)
        XCTAssertEqual(undone.title, "初稿")
        XCTAssertEqual(undone.priority, .low)
        XCTAssertEqual(undone.notes, "別のメモ", "AI の変更に含まれないフィールドは触らない")
        let log = try latest(task.id)
        XCTAssertEqual(log.action, .update)
        XCTAssertEqual(log.decodedDiff()?["title"], FieldChange(from: .string("改稿"), to: .string("初稿")))
        XCTAssertEqual(log.decodedDiff()?["priority"], FieldChange(from: .int(3), to: .int(1)))
    }

    func testUndoDueDateRoundTrips() throws {
        let due = fixedNow.addingTimeInterval(3600)
        let task = try repo.createTask(NewTask(title: "t", dueAt: due), actor: .user)
        _ = try repo.updateTask(id: task.id, changes: TaskChanges(dueAt: .set(nil)), actor: .ai)
        let undone = try repo.undo(activityId: try latest(task.id).id!, actor: .user)
        XCTAssertEqual(undone.dueAt, due)
    }

    func testUndoArchiveRestoresAndUndoCreateArchives() throws {
        let task = try repo.createTask(NewTask(title: "t"), actor: .ai)
        let created = try latest(task.id)
        _ = try repo.archiveTask(id: task.id, actor: .ai)
        let archived = try latest(task.id)

        let restored = try repo.undo(activityId: archived.id!, actor: .user)
        XCTAssertNil(restored.deletedAt)
        XCTAssertEqual(try latest(task.id).action, .restore)

        let gone = try repo.undo(activityId: created.id!, actor: .user)
        XCTAssertNotNil(gone.deletedAt)
        XCTAssertEqual(try latest(task.id).action, .archive)
        XCTAssertTrue(try repo.tasks().isEmpty)
    }

    func testUndoIsNoOpWhenAlreadyReverted() throws {
        let task = try repo.createTask(NewTask(title: "t"), actor: .user)
        _ = try repo.completeTask(id: task.id, actor: .ai)
        let complete = try latest(task.id)
        _ = try repo.reopenTask(id: task.id, actor: .user)
        let count = try repo.activity(taskId: task.id).count

        _ = try repo.undo(activityId: complete.id!, actor: .user)
        XCTAssertEqual(try repo.activity(taskId: task.id).count, count)
    }

    func testUndoUnknownActivityThrows() {
        XCTAssertThrowsError(try repo.undo(activityId: 999, actor: .user)) { error in
            XCTAssertEqual(error as? TaskRepositoryError, .activityNotFound(999))
        }
    }

    func testRecentActivityIncludesTitles() throws {
        let a = try repo.createTask(NewTask(title: "a"), actor: .ai)
        _ = try repo.completeTask(id: a.id, actor: .widget)
        let recent = try repo.recentActivity(limit: 10)
        XCTAssertEqual(recent.map(\.entry.action), [.complete, .create])
        XCTAssertEqual(recent.first?.taskTitle, "a")
    }
}
