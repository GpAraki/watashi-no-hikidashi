import AppIntents
import TaskCore

/// ウィジェットごとに「今日」以外のどのセクションを出すかを選ぶ。今日は常に出す。
struct TaskWidgetConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "表示するセクション"
    static let description = IntentDescription("今日のタスクは常に表示します。ほかのタイプを出すかを選びます。")

    @Parameter(title: "期限ありを表示", default: true)
    var showDeadline: Bool

    @Parameter(title: "スプリントを表示", default: true)
    var showSprint: Bool

    @Parameter(title: "いつかの件数を表示", default: true)
    var showOpenEnded: Bool
}
