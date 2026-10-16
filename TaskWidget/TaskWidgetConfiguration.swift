import AppIntents
import TaskCore

/// ウィジェットごとに「何を表示するか」を選ぶ設定。
struct TaskWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "表示するタスク"
    static let description = IntentDescription("ウィジェットに表示するタスクの範囲を選びます。")

    @Parameter(title: "範囲", default: .today)
    var scope: TaskScope
}

enum TaskScope: String, AppEnum {
    case today
    case all
    case highPriority

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "範囲")
    static let caseDisplayRepresentations: [TaskScope: DisplayRepresentation] = [
        .today: "今日のタスク",
        .all: "すべての未完了",
        .highPriority: "優先度が高いもの",
    ]

    func filter(now: Date, limit: Int) -> TaskFilter {
        var f: TaskFilter
        switch self {
        case .today: f = .today(now: now)
        case .all: f = .open
        case .highPriority:
            f = .open
            f.minimumPriority = .high
        }
        f.limit = limit
        return f
    }
}
