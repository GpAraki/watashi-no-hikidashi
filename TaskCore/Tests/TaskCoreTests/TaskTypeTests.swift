import GRDB
import XCTest
@testable import TaskCore

final class TaskTypeTests: XCTestCase {
    private var repo: TaskRepository!
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    private var tokyo: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }

    override func setUpWithError() throws {
        let now = fixedNow
        repo = TaskRepository(database: try AppDatabase.inMemory(), now: { now })
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        tokyo.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi, second: s))!
    }

    // MARK: SprintSchedule

    func testDefaultScheduleIsWednesdayToTuesday() {
        let schedule = SprintSchedule.default(calendar: tokyo)
        XCTAssertEqual(schedule.startWeekday(calendar: tokyo), 4)
        XCTAssertEqual(schedule.lengthDays, 7)

        // 2026-10-17 は土曜。含むスプリントは 10/14(水)〜10/20(火)。
        let saturday = date(2026, 10, 17, 12)
        let interval = schedule.interval(containing: saturday, calendar: tokyo)
        XCTAssertEqual(interval.start, date(2026, 10, 14))
        XCTAssertEqual(interval.end, date(2026, 10, 21))
        XCTAssertEqual(schedule.dueDate(forSprintContaining: saturday, calendar: tokyo), date(2026, 10, 20, 23, 59, 59))
        XCTAssertEqual(schedule.dueDate(forSprintAfter: saturday, calendar: tokyo), date(2026, 10, 27, 23, 59, 59))

        // 水曜 0 時はその週のスプリントの初日、火曜 23:59 は前のスプリントの最終日。
        XCTAssertEqual(schedule.interval(containing: date(2026, 10, 21), calendar: tokyo).start, date(2026, 10, 21))
        XCTAssertEqual(schedule.interval(containing: date(2026, 10, 20, 23, 59), calendar: tokyo).start, date(2026, 10, 14))
    }

    func testTwoWeekScheduleUsesAnchor() {
        let schedule = SprintSchedule(anchor: date(2026, 10, 7), lengthDays: 14)
        XCTAssertEqual(schedule.interval(containing: date(2026, 10, 17), calendar: tokyo), DateInterval(start: date(2026, 10, 7), end: date(2026, 10, 21)))
        XCTAssertEqual(schedule.interval(containing: date(2026, 10, 21), calendar: tokyo).start, date(2026, 10, 21))
        // anchor より前の日付も正しく区切れる
        XCTAssertEqual(schedule.interval(containing: date(2026, 9, 30), calendar: tokyo).start, date(2026, 9, 23))
    }

    func testScheduleFromWeekday() {
        let schedule = SprintSchedule(startWeekday: 2, lengthDays: 7, reference: date(2026, 10, 17), calendar: tokyo)
        XCTAssertEqual(schedule.anchor, date(2026, 10, 12)) // 直近の月曜
    }

    // MARK: 期限の自動決定

    func testTodayTaskGetsEndOfDay() throws {
        let task = try repo.createTask(NewTask(title: "t", type: .today), actor: .user)
        XCTAssertEqual(task.type, .today)
        XCTAssertEqual(task.dueAt, Calendar.current.endOfDay(for: fixedNow))
        let diff = try XCTUnwrap(repo.activity(taskId: task.id).first?.decodedDiff())
        XCTAssertEqual(diff["type"]?.to, .string("today"))
        XCTAssertNotNil(diff["due_at"])
    }

    func testSprintTaskGetsSprintEnd() throws {
        let task = try repo.createTask(NewTask(title: "t", type: .sprint), actor: .ai)
        XCTAssertEqual(task.dueAt, try repo.sprintSchedule().dueDate(forSprintContaining: fixedNow))
    }

    func testDeadlineRequiresDueDate() {
        XCTAssertThrowsError(try repo.createTask(NewTask(title: "t", type: .deadline), actor: .user)) { error in
            XCTAssertEqual(error as? TaskRepositoryError, .dueDateRequired)
        }
    }

    func testOpenEndedIgnoresDueDate() throws {
        let task = try repo.createTask(NewTask(title: "t", type: .openEnded, dueAt: fixedNow), actor: .user)
        XCTAssertNil(task.dueAt)
    }

    func testTypeIsInferredFromDueDateWhenOmitted() throws {
        XCTAssertEqual(try repo.createTask(NewTask(title: "a", dueAt: fixedNow), actor: .ai).type, .deadline)
        XCTAssertEqual(try repo.createTask(NewTask(title: "b"), actor: .ai).type, .openEnded)
    }

    func testChangingTypeResetsDueDateUnlessGiven() throws {
        let task = try repo.createTask(NewTask(title: "t", type: .today), actor: .user)

        let opened = try repo.updateTask(id: task.id, changes: TaskChanges(type: .set(.openEnded)), actor: .user)
        XCTAssertEqual(opened.type, .openEnded)
        XCTAssertNil(opened.dueAt)

        let due = fixedNow.addingTimeInterval(86400 * 3)
        let deadline = try repo.updateTask(id: task.id, changes: TaskChanges(type: .set(.deadline), dueAt: .set(due)), actor: .user)
        XCTAssertEqual(deadline.type, .deadline)
        XCTAssertEqual(deadline.dueAt, due)

        // 有期限の期限だけ変える: タイプはそのまま
        let moved = try repo.updateTask(id: task.id, changes: TaskChanges(dueAt: .set(due.addingTimeInterval(3600))), actor: .ai)
        XCTAssertEqual(moved.type, .deadline)

        // タイプを指定せず期限だけ消すと無期限になる
        let cleared = try repo.updateTask(id: task.id, changes: TaskChanges(dueAt: .set(nil)), actor: .ai)
        XCTAssertEqual(cleared.type, .openEnded)
        XCTAssertNil(cleared.dueAt)
        // 無期限に期限だけ付けると有期限になる
        let redated = try repo.updateTask(id: task.id, changes: TaskChanges(dueAt: .set(due)), actor: .ai)
        XCTAssertEqual(redated.type, .deadline)
        // 戻しておく(下の undo の対象をタイプ変更にするため)
        _ = try repo.updateTask(id: task.id, changes: TaskChanges(type: .set(.deadline), dueAt: .set(due)), actor: .user)

        // タイプ変更は取り消せる(期限も戻る): 「当日 → 無期限」の変更を取り消す
        let entry = try XCTUnwrap(repo.activity(taskId: task.id).last { $0.decodedDiff()?["type"]?.to == .string("open_ended") })
        let undone = try repo.undo(activityId: entry.id!, actor: .user)
        XCTAssertEqual(undone.type, .today)
        XCTAssertEqual(undone.dueAt, Calendar.current.endOfDay(for: fixedNow))
    }

    func testFilterByType() throws {
        _ = try repo.createTask(NewTask(title: "a", type: .today), actor: .user)
        _ = try repo.createTask(NewTask(title: "b", type: .sprint), actor: .user)
        _ = try repo.createTask(NewTask(title: "c"), actor: .user)
        XCTAssertEqual(try repo.tasks(matching: TaskFilter(types: [.today])).map(\.title), ["a"])
        XCTAssertEqual(try repo.tasks(matching: TaskFilter(types: [.sprint, .openEnded])).map(\.title), ["b", "c"])
    }

    func testOverdueAndDueToday() throws {
        let yesterday = TaskItem(title: "y", type: .today, dueAt: fixedNow.addingTimeInterval(-3600), sortOrder: 1, createdBy: .user, createdAt: fixedNow, updatedAt: fixedNow)
        XCTAssertTrue(yesterday.isOverdue(now: fixedNow))
        let later = TaskItem(title: "l", type: .deadline, dueAt: fixedNow.addingTimeInterval(3600), sortOrder: 1, createdBy: .user, createdAt: fixedNow, updatedAt: fixedNow)
        XCTAssertFalse(later.isOverdue(now: fixedNow))
        XCTAssertTrue(later.isDueToday(now: fixedNow))
    }

    // MARK: 設定

    func testSprintScheduleIsPersisted() throws {
        XCTAssertEqual(try repo.sprintSchedule(), .default())
        let custom = SprintSchedule(anchor: date(2026, 10, 7), lengthDays: 14)
        try repo.setSprintSchedule(custom)
        XCTAssertEqual(try repo.sprintSchedule(), custom)
        let task = try repo.createTask(NewTask(title: "t", type: .sprint), actor: .user)
        XCTAssertEqual(task.dueAt, custom.dueDate(forSprintContaining: fixedNow))
    }

    // MARK: マイグレーション

    func testV2BackfillsTypeFromDueDate() throws {
        let writer = try AppDatabase.inMemory(migratingUpTo: "v1_initial")
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO task (id, title, status, due_at, sort_order, created_by, created_at, updated_at)
                VALUES ('with-due', 'a', 'todo', ?, 1, 'user', ?, ?), ('no-due', 'b', 'todo', NULL, 2, 'ai', ?, ?)
                """, arguments: [fixedNow, fixedNow, fixedNow, fixedNow, fixedNow])
        }
        let db = try AppDatabase(writer: writer)
        let migrated = TaskRepository(database: db)
        XCTAssertEqual(try migrated.task(id: "with-due")?.type, .deadline)
        XCTAssertEqual(try migrated.task(id: "no-due")?.type, .openEnded)
    }
}
