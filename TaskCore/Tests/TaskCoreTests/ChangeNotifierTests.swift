import XCTest
@testable import TaskCore

final class ChangeNotifierTests: XCTestCase {
    func testPostIsDeliveredAndDebounced() {
        let notifier = ChangeNotifier(name: "dev.araki.hikidashi.test.\(UUID().uuidString)")
        let fired = expectation(description: "handler called once")
        fired.assertForOverFulfill = true

        let observation = notifier.observe(debounce: 0.1) { fired.fulfill() }
        defer { observation.cancel() }

        notifier.post()
        notifier.post()
        notifier.post()

        wait(for: [fired], timeout: 2)
    }

    func testRepositoryPostsAfterWrite() throws {
        let notifier = ChangeNotifier(name: "dev.araki.hikidashi.test.\(UUID().uuidString)")
        let fired = expectation(description: "notified")
        let observation = notifier.observe(debounce: 0) { fired.fulfill() }
        defer { observation.cancel() }

        let repo = TaskRepository(database: try AppDatabase.inMemory(), notifier: notifier)
        try repo.createTask(NewTask(title: "t"), actor: .ai)

        wait(for: [fired], timeout: 2)
    }

    func testCancelledObservationDoesNotFire() {
        let notifier = ChangeNotifier(name: "dev.araki.hikidashi.test.\(UUID().uuidString)")
        let notFired = expectation(description: "not called")
        notFired.isInverted = true

        let observation = notifier.observe(debounce: 0) { notFired.fulfill() }
        observation.cancel()
        notifier.post()

        wait(for: [notFired], timeout: 0.3)
    }
}
