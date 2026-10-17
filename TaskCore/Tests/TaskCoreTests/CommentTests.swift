import XCTest
@testable import TaskCore

final class CommentTests: XCTestCase {
    private var repo: TaskRepository!
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        let now = fixedNow
        repo = TaskRepository(database: try AppDatabase.inMemory(), now: { now })
    }

    func testAddAndListComments() throws {
        let task = try repo.createTask(NewTask(title: "t"), actor: .user)
        let c1 = try repo.addComment(taskId: task.id, body: "  着手した  ", actor: .user)
        let c2 = try repo.addComment(taskId: task.id, body: "設計書を更新。レビュー待ち", actor: .ai)

        XCTAssertEqual(c1.body, "着手した")
        XCTAssertEqual(c1.author, .user)
        XCTAssertEqual(c2.author, .ai)
        XCTAssertEqual(try repo.comments(taskId: task.id).map(\.id), [c1.id, c2.id])
        XCTAssertEqual(try repo.commentCounts()[task.id], 2)

        let log = try XCTUnwrap(repo.activity(taskId: task.id).first)
        XCTAssertEqual(log.action, .comment)
        XCTAssertEqual(log.actor, .ai)
        XCTAssertEqual(log.decodedDiff()?["comment"]?.to, .string("設計書を更新。レビュー待ち"))
        XCTAssertEqual(log.decodedDiff()?["comment_id"]?.to, .int(Int(c2.id!)))
    }

    func testEmptyAndUnknownTaskAreRejected() throws {
        let task = try repo.createTask(NewTask(title: "t"), actor: .user)
        XCTAssertThrowsError(try repo.addComment(taskId: task.id, body: "   ", actor: .user)) {
            XCTAssertEqual($0 as? TaskRepositoryError, .emptyComment)
        }
        XCTAssertThrowsError(try repo.addComment(taskId: "nope", body: "x", actor: .ai)) {
            XCTAssertEqual($0 as? TaskRepositoryError, .taskNotFound("nope"))
        }
    }

    func testDeleteIsLogicalAndUndoable() throws {
        let task = try repo.createTask(NewTask(title: "t"), actor: .user)
        let c = try repo.addComment(taskId: task.id, body: "AI の推測", actor: .ai)
        let added = try XCTUnwrap(repo.activity(taskId: task.id).first)

        // AI のコメントを取り消す → 論理削除
        _ = try repo.undo(activityId: added.id!, actor: .user)
        XCTAssertTrue(try repo.comments(taskId: task.id).isEmpty)
        XCTAssertEqual(try repo.comments(taskId: task.id, includeDeleted: true).first?.isDeleted, true)
        let deleted = try XCTUnwrap(repo.activity(taskId: task.id).first)
        XCTAssertEqual(deleted.action, .deleteComment)
        XCTAssertEqual(deleted.actor, .user)
        XCTAssertNil(try repo.commentCounts()[task.id])

        // 削除の取り消し → 復元
        _ = try repo.undo(activityId: deleted.id!, actor: .user)
        XCTAssertEqual(try repo.comments(taskId: task.id).map(\.id), [c.id])
        XCTAssertEqual(try repo.activity(taskId: task.id).first?.action, .comment)

        // 直接削除も同じ
        _ = try repo.deleteComment(id: c.id!, actor: .user)
        XCTAssertTrue(try repo.comments(taskId: task.id).isEmpty)
        XCTAssertThrowsError(try repo.deleteComment(id: 999, actor: .user))
    }

    func testCommentsAppearInRecentActivity() throws {
        let task = try repo.createTask(NewTask(title: "t"), actor: .user)
        _ = try repo.addComment(taskId: task.id, body: "hi", actor: .widget)
        XCTAssertEqual(try repo.recentActivity(limit: 1).first?.entry.action, .comment)
    }
}
