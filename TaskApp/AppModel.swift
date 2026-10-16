import Foundation
import Observation
import TaskCore
import WidgetKit

/// 本体アプリの状態。DB の読み書きと、プロセス間通知の受信を担う。
@MainActor
@Observable
final class AppModel {
    enum State {
        case ready(TaskRepository)
        case failed(String)
    }

    let state: State
    private(set) var tasks: [TaskItem] = []
    private(set) var lastError: String?
    private var observation: ChangeObservation?

    static func load() -> AppModel {
        do {
            let url = try AppGroup.databaseURL()
            let database = try AppDatabase.open(at: url)
            let repository = TaskRepository(database: database, notifier: ChangeNotifier())
            return AppModel(state: .ready(repository))
        } catch {
            return AppModel(state: .failed(error.localizedDescription))
        }
    }

    private init(state: State) {
        self.state = state
        guard case .ready = state else { return }
        reload()
        // 他プロセス(ウィジェット・MCP)からの変更を受けて一覧とウィジェットを更新する。
        observation = ChangeNotifier().observe { [weak self] in
            Task { @MainActor in
                self?.reload()
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    var repository: TaskRepository? {
        if case .ready(let repo) = state { return repo }
        return nil
    }

    var databasePath: String {
        (try? AppGroup.databaseURL().path) ?? "-"
    }

    func reload() {
        guard let repository else { return }
        do {
            tasks = try repository.tasks(matching: .open)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func add(title: String) {
        perform { try $0.createTask(NewTask(title: title), actor: .user) }
    }

    func toggle(_ task: TaskItem) {
        perform { repo in
            if task.isDone {
                try repo.reopenTask(id: task.id, actor: .user)
            } else {
                try repo.completeTask(id: task.id, actor: .user)
            }
        }
    }

    private func perform(_ work: (TaskRepository) throws -> Void) {
        guard let repository else { return }
        do {
            try work(repository)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        reload()
        // 自分で書いたときは通知を待たずに即時更新する。
        WidgetCenter.shared.reloadAllTimelines()
    }
}
