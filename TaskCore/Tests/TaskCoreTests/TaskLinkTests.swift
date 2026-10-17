import XCTest
@testable import TaskCore

final class TaskLinkTests: XCTestCase {
    private var repo: TaskRepository!
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        let now = fixedNow
        repo = TaskRepository(database: try AppDatabase.inMemory(), now: { now })
    }

    func testAddListAndDedupe() throws {
        let task = try repo.createTask(NewTask(title: "t"), actor: .user)
        let notion = try repo.addLink(taskId: task.id, url: " https://www.notion.so/team/Spec-abc123 ", actor: .ai)
        let jira = try repo.addLink(taskId: task.id, url: "https://redesigner.atlassian.net/browse/RFSSN-1", label: "チケット", actor: .user)
        let again = try repo.addLink(taskId: task.id, url: "https://www.notion.so/team/Spec-abc123", actor: .user)

        XCTAssertEqual(again.id, notion.id, "同じ URL は二重に登録しない")
        XCTAssertEqual(try repo.links(taskId: task.id).map(\.id), [notion.id, jira.id])
        XCTAssertEqual(notion.displayLabel, "Notion")
        XCTAssertEqual(jira.displayLabel, "チケット")
        XCTAssertEqual(try repo.linksByTask()[task.id]?.count, 2)

        let log = try XCTUnwrap(repo.activity(taskId: task.id).first)
        XCTAssertEqual(log.action, .link)
        XCTAssertEqual(log.decodedDiff()?["url"]?.to, .string("https://redesigner.atlassian.net/browse/RFSSN-1"))
        XCTAssertEqual(try repo.activity(taskId: task.id).count, 3, "重複追加はログに残らない")
    }

    func testInvalidURLIsRejected() throws {
        let task = try repo.createTask(NewTask(title: "t"), actor: .user)
        XCTAssertThrowsError(try repo.addLink(taskId: task.id, url: "   ", actor: .user))
        XCTAssertThrowsError(try repo.addLink(taskId: task.id, url: "notion page", actor: .user)) {
            XCTAssertEqual($0 as? TaskRepositoryError, .invalidURL("notion page"))
        }
        XCTAssertThrowsError(try repo.addLink(taskId: "nope", url: "https://example.com", actor: .ai))
    }

    func testRemoveIsLogicalAndUndoable() throws {
        let task = try repo.createTask(NewTask(title: "t"), actor: .user)
        let link = try repo.addLink(taskId: task.id, url: "https://github.com/GpAraki/watashi-no-hikidashi/pull/4", actor: .ai)
        let added = try XCTUnwrap(repo.activity(taskId: task.id).first)

        _ = try repo.undo(activityId: added.id!, actor: .user)
        XCTAssertTrue(try repo.links(taskId: task.id).isEmpty)
        let removed = try XCTUnwrap(repo.activity(taskId: task.id).first)
        XCTAssertEqual(removed.action, .deleteLink)

        _ = try repo.undo(activityId: removed.id!, actor: .user)
        XCTAssertEqual(try repo.links(taskId: task.id).map(\.id), [link.id])

        _ = try repo.removeLink(id: link.id!, actor: .user)
        XCTAssertTrue(try repo.links(taskId: task.id).isEmpty)
        XCTAssertThrowsError(try repo.removeLink(id: 999, actor: .user))
    }

    func testServiceNames() {
        func name(_ s: String) -> String { TaskLink.serviceName(for: URL(string: s)!) }
        XCTAssertEqual(name("https://www.notion.so/x"), "Notion")
        XCTAssertEqual(name("https://acme.notion.site/x"), "Notion")
        XCTAssertEqual(name("https://redesigner.atlassian.net/browse/RFSSN-1"), "Jira")
        XCTAssertEqual(name("https://redesigner.atlassian.net/wiki/spaces/X"), "Confluence")
        XCTAssertEqual(name("https://github.com/a/b"), "GitHub")
        XCTAssertEqual(name("https://www.figma.com/file/x"), "Figma")
        XCTAssertEqual(name("https://docs.google.com/document/d/x"), "Google ドキュメント")
        XCTAssertEqual(name("https://www.example.co.jp/page"), "example.co.jp")
        XCTAssertEqual(name("hikidashi://task/abc"), "引き出し")
    }

    func testURLDetectionInNotes() {
        let notes = "Jira: https://redesigner.atlassian.net/browse/RFSSN-9491\n種別: バグ\n詳細は https://www.notion.so/team/abc と同じく https://redesigner.atlassian.net/browse/RFSSN-9491"
        XCTAssertEqual(URLDetection.urls(in: notes).map(\.absoluteString), [
            "https://redesigner.atlassian.net/browse/RFSSN-9491",
            "https://www.notion.so/team/abc",
        ])
        XCTAssertTrue(URLDetection.urls(in: nil).isEmpty)
        XCTAssertTrue(URLDetection.urls(in: "リンクなし").isEmpty)
    }
}
