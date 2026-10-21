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

    func testFilterByLinkURLAndContains() throws {
        let jira = try repo.createTask(NewTask(title: "Jira の課題"), actor: .user)
        let github = try repo.createTask(NewTask(title: "GitHub の issue"), actor: .user)
        let plain = try repo.createTask(NewTask(title: "リンクなし"), actor: .user)
        try repo.addLink(taskId: jira.id, url: "https://example.atlassian.net/browse/PROJ-123", actor: .ai)
        try repo.addLink(taskId: github.id, url: "https://github.com/GpAraki/watashi-no-hikidashi/issues/42", actor: .ai)
        _ = plain

        // 完全一致。前後の空白は無視する。
        XCTAssertEqual(try repo.tasks(matching: TaskFilter(linkURL: " https://example.atlassian.net/browse/PROJ-123 ")).map(\.id), [jira.id])
        XCTAssertTrue(try repo.tasks(matching: TaskFilter(linkURL: "https://example.atlassian.net/browse/PROJ-12")).isEmpty, "完全一致は前方一致にならない")

        // 部分一致。大文字小文字は区別せず、LIKE のメタ文字はそのまま文字として扱う。
        XCTAssertEqual(try repo.tasks(matching: TaskFilter(linkContains: "proj-123")).map(\.id), [jira.id])
        XCTAssertEqual(try repo.tasks(matching: TaskFilter(linkContains: "watashi-no-hikidashi/issues/42")).map(\.id), [github.id])
        XCTAssertEqual(try repo.tasks(matching: TaskFilter(linkContains: "atlassian.net/browse/")).map(\.id), [jira.id])
        XCTAssertTrue(try repo.tasks(matching: TaskFilter(linkContains: "PROJ_123")).isEmpty, "_ はワイルドカードにならない")
        XCTAssertTrue(try repo.tasks(matching: TaskFilter(linkContains: "%")).isEmpty, "% はワイルドカードにならない")

        // 他の絞り込みと組み合わせられる。
        try repo.completeTask(id: jira.id, actor: .user)
        XCTAssertTrue(try repo.tasks(matching: TaskFilter(statuses: [.todo, .doing], linkContains: "PROJ-123")).isEmpty)
        XCTAssertEqual(try repo.tasks(matching: TaskFilter(linkContains: "PROJ-123")).map(\.id), [jira.id])

        // 外したリンクでは引けない。アーカイブ済みのタスクは既定で除外される。
        let link = try XCTUnwrap(repo.links(taskId: github.id).first)
        try repo.removeLink(id: link.id!, actor: .user)
        XCTAssertTrue(try repo.tasks(matching: TaskFilter(linkContains: "issues/42")).isEmpty)
        try repo.archiveTask(id: jira.id, actor: .user)
        XCTAssertTrue(try repo.tasks(matching: TaskFilter(linkContains: "PROJ-123")).isEmpty)
        XCTAssertEqual(try repo.tasks(matching: TaskFilter(linkContains: "PROJ-123", includeArchived: true)).map(\.id), [jira.id])
    }

    func testCreateTaskWithLinks() throws {
        let task = try repo.createTask(NewTask(title: "課題から起こす", links: [
            NewLink(url: "https://example.atlassian.net/browse/PROJ-7", label: "チケット"),
            NewLink(url: " https://github.com/GpAraki/watashi-no-hikidashi/pull/9 "),
            NewLink(url: "https://example.atlassian.net/browse/PROJ-7"),
        ]), actor: .ai)

        let links = try repo.links(taskId: task.id)
        XCTAssertEqual(links.map(\.url.absoluteString), [
            "https://example.atlassian.net/browse/PROJ-7",
            "https://github.com/GpAraki/watashi-no-hikidashi/pull/9",
        ], "同じ URL は 1 回だけ登録される")
        XCTAssertEqual(links.map(\.displayLabel), ["チケット", "GitHub"])
        XCTAssertEqual(links.map(\.createdBy), [.ai, .ai])
        XCTAssertEqual(try repo.tasks(matching: TaskFilter(linkURL: "https://example.atlassian.net/browse/PROJ-7")).map(\.id), [task.id])

        let actions = try repo.activity(taskId: task.id).map(\.action)
        XCTAssertEqual(actions, [.link, .link, .create], "作成 1 件とリンク 2 件がログに残る")

        // 不正な URL が混じっていればタスクごと作られない。
        XCTAssertThrowsError(try repo.createTask(NewTask(title: "失敗する", links: [NewLink(url: "not a url")]), actor: .ai)) {
            XCTAssertEqual($0 as? TaskRepositoryError, .invalidURL("not a url"))
        }
        XCTAssertTrue(try repo.tasks().filter { $0.title == "失敗する" }.isEmpty)
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
