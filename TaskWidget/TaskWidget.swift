import OSLog
import SwiftUI
import TaskCore
import WidgetKit

struct TaskEntry: TimelineEntry {
    let date: Date
    let scope: TaskScope
    let tasks: [TaskItem]
    let error: String?
}

/// ウィジェットプロセスから共有 DB を開く。拡張は短命なので失敗も含めて 1 度だけ評価する。
enum WidgetDatabase {
    static let repository: Result<TaskRepository, Error> = {
        do {
            let db = try AppDatabase.open(at: AppGroup.databaseURL())
            // notifier を渡すことで、ウィジェットからの書き込みが本体に Darwin Notification で伝わる。
            return .success(TaskRepository(database: db, notifier: ChangeNotifier()))
        } catch {
            return .failure(error)
        }
    }()
}

struct TaskTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TaskEntry {
        TaskEntry(date: .now, scope: .today, tasks: Self.sample, error: nil)
    }

    func snapshot(for configuration: TaskWidgetConfiguration, in context: Context) async -> TaskEntry {
        if context.isPreview { return placeholder(in: context) }
        return load(configuration, in: context)
    }

    func timeline(for configuration: TaskWidgetConfiguration, in context: Context) async -> Timeline<TaskEntry> {
        let entry = load(configuration, in: context)
        Logger(subsystem: "dev.araki.hikidashi", category: "widget")
            .info("timeline reloaded: scope=\(configuration.scope.rawValue, privacy: .public) tasks=\(entry.tasks.count) error=\(entry.error ?? "-", privacy: .public)")
        // 本体からの即時更新に加えて、保険として定期的に読み直す。
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: entry.date)!
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func load(_ configuration: TaskWidgetConfiguration, in context: Context) -> TaskEntry {
        let limit = context.family == .systemLarge ? 10 : 5
        switch WidgetDatabase.repository {
        case .failure(let error):
            return TaskEntry(date: .now, scope: configuration.scope, tasks: [], error: error.localizedDescription)
        case .success(let repo):
            do {
                let tasks = try repo.tasks(matching: configuration.scope.filter(now: .now, limit: limit))
                return TaskEntry(date: .now, scope: configuration.scope, tasks: tasks, error: nil)
            } catch {
                return TaskEntry(date: .now, scope: configuration.scope, tasks: [], error: error.localizedDescription)
            }
        }
    }

    static let sample: [TaskItem] = {
        let now = Date()
        return ["設計ドキュメントを読む", "App Group を通す", "ウィジェットを表示する"].enumerated().map { i, title in
            TaskItem(title: title, sortOrder: i, createdBy: .user, createdAt: now, updatedAt: now)
        }
    }()
}

struct TaskWidgetView: View {
    let entry: TaskEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("\(entry.tasks.count)").font(.caption).foregroundStyle(.secondary)
            }
            if let error = entry.error {
                Text(error).font(.caption2).foregroundStyle(.red)
            } else if entry.tasks.isEmpty {
                Text("タスクはありません").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(entry.tasks) { task in
                    TaskWidgetRow(task: task)
                }
            }
            Spacer(minLength: 0)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var title: String {
        switch entry.scope {
        case .today: "今日"
        case .all: "未完了"
        case .highPriority: "優先度高"
        }
    }
}

/// 1 行。チェックボックスは `CompleteTaskIntent` を実行し、タイトルは本体のディープリンクを開く。
struct TaskWidgetRow: View {
    let task: TaskItem

    var body: some View {
        HStack(spacing: 6) {
            Toggle(isOn: task.isDone, intent: CompleteTaskIntent(taskId: task.id, markDone: !task.isDone)) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.callout)
                    .foregroundStyle(task.isDone ? Color.accentColor : Color.secondary)
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .invalidatableContent()

            Link(destination: DeepLink.taskURL(id: task.id)) {
                HStack(spacing: 0) {
                    Text(task.title)
                        .lineLimit(1)
                        .strikethrough(task.isDone)
                        .foregroundStyle(task.isDone ? .secondary : .primary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
        }
        .font(.callout)
    }
}

struct TaskWidget: Widget {
    let kind = "TaskWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: TaskWidgetConfiguration.self, provider: TaskTimelineProvider()) { entry in
            TaskWidgetView(entry: entry)
        }
        .configurationDisplayName("私の引き出し")
        .description("デスクトップにタスクを表示します。")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
