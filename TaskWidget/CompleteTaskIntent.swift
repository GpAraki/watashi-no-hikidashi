import AppIntents
import OSLog
import TaskCore
import WidgetKit

/// ウィジェットの行のチェックボックスから呼ばれる。完了/再開を DB に書き、`actor = widget` でログを残す。
///
/// `Toggle(isOn:intent:)` は `isOn` の新しい値を `markDone` に入れて実行する。
/// 書き込みに成功すると `TaskRepository` が Darwin Notification を投げるので本体が更新され、
/// 本体もウィジェットも読み直す。ウィジェット自身の表示は本体の通知を待たず即時に更新する。
struct CompleteTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "タスクを完了にする"
    static let description = IntentDescription("ウィジェットからタスクを完了または未完了に切り替えます。")
    static let isDiscoverable = false

    @Parameter(title: "タスク ID")
    var taskId: String

    @Parameter(title: "完了にする")
    var markDone: Bool

    init() {}

    init(taskId: String, markDone: Bool) {
        self.taskId = taskId
        self.markDone = markDone
    }

    func perform() async throws -> some IntentResult {
        let logger = Logger(subsystem: "dev.araki.hikidashi", category: "widget")
        logger.info("intent: \(self.markDone ? "complete" : "reopen", privacy: .public) \(self.taskId, privacy: .public)")
        do {
            let repository = try WidgetDatabase.repository.get()
            if markDone {
                try repository.completeTask(id: taskId, actor: .widget)
            } else {
                try repository.reopenTask(id: taskId, actor: .widget)
            }
        } catch {
            logger.error("intent failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
