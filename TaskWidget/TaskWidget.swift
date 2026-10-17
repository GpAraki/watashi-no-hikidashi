import OSLog
import SwiftUI
import TaskCore
import WidgetKit

/// ウィジェット 1 回分の表示内容。タイプごとに区切って持つ。
struct TaskEntry: TimelineEntry {
    let date: Date
    let configuration: TaskWidgetConfiguration
    /// 当日タスク。期限切れ → 未完了 → 今日完了したもの、の順。
    let today: [TaskItem]
    /// 有期限の未完了。期限が近い順。
    let deadlines: [TaskItem]
    /// 今のスプリントの未完了。
    let sprint: [TaskItem]
    let sprintInterval: DateInterval
    let sprintDoneCount: Int
    let openEndedCount: Int
    let error: String?

    var todayDoneCount: Int { today.filter(\.isDone).count }
    var sprintTotalCount: Int { sprint.count + sprintDoneCount }

    static func empty(_ configuration: TaskWidgetConfiguration, error: String? = nil) -> TaskEntry {
        TaskEntry(date: .now, configuration: configuration, today: [], deadlines: [], sprint: [],
                  sprintInterval: SprintSchedule.default().interval(containing: .now), sprintDoneCount: 0, openEndedCount: 0, error: error)
    }
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
        Self.sample(TaskWidgetConfiguration())
    }

    func snapshot(for configuration: TaskWidgetConfiguration, in context: Context) async -> TaskEntry {
        if context.isPreview { return Self.sample(configuration) }
        return load(configuration)
    }

    func timeline(for configuration: TaskWidgetConfiguration, in context: Context) async -> Timeline<TaskEntry> {
        let entry = load(configuration)
        Logger(subsystem: "dev.araki.hikidashi", category: "widget")
            .info("timeline reloaded: today=\(entry.today.count) deadlines=\(entry.deadlines.count) sprint=\(entry.sprint.count) error=\(entry.error ?? "-", privacy: .public)")
        // 本体からの即時更新に加えて、日付またぎと保険の定期更新。
        let calendar = Calendar.current
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: entry.date))!
        let next = min(midnight, calendar.date(byAdding: .minute, value: 15, to: entry.date)!)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func load(_ configuration: TaskWidgetConfiguration) -> TaskEntry {
        switch WidgetDatabase.repository {
        case .failure(let error):
            return .empty(configuration, error: error.localizedDescription)
        case .success(let repo):
            do {
                return try Self.build(configuration, repository: repo, now: .now)
            } catch {
                return .empty(configuration, error: error.localizedDescription)
            }
        }
    }

    /// DB の内容をセクションに振り分ける。
    static func build(_ configuration: TaskWidgetConfiguration, repository: TaskRepository, now: Date) throws -> TaskEntry {
        let calendar = Calendar.current
        let all = try repository.tasks(matching: TaskFilter(statuses: nil))
        let schedule = try repository.sprintSchedule()
        let sprintInterval = schedule.interval(containing: now, calendar: calendar)

        let today = all.filter { task in
            guard task.type == .today else { return false }
            if task.isDone { return task.completedAt.map { calendar.isDate($0, inSameDayAs: now) } ?? false }
            return true
        }.sorted { a, b in
            // 期限切れ → 未完了 → 完了
            func rank(_ t: TaskItem) -> Int { t.isDone ? 2 : (t.isOverdue(now: now) ? 0 : 1) }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return (a.dueAt ?? .distantFuture, a.sortOrder) < (b.dueAt ?? .distantFuture, b.sortOrder)
        }

        let deadlines = all.filter { $0.type == .deadline && !$0.isDone }
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }

        let sprintTasks = all.filter { task in
            guard task.type == .sprint else { return false }
            if task.isDone { return task.completedAt.map(sprintInterval.contains) ?? false }
            return true
        }
        let sprint = sprintTasks.filter { !$0.isDone }
            .sorted { a, b in
                if a.isOverdue(now: now) != b.isOverdue(now: now) { return a.isOverdue(now: now) }
                return a.sortOrder < b.sortOrder
            }

        return TaskEntry(
            date: now,
            configuration: configuration,
            today: today,
            deadlines: deadlines,
            sprint: sprint,
            sprintInterval: sprintInterval,
            sprintDoneCount: sprintTasks.count - sprint.count,
            openEndedCount: all.filter { $0.type == .openEnded && !$0.isDone }.count,
            error: nil
        )
    }

    static func sample(_ configuration: TaskWidgetConfiguration) -> TaskEntry {
        let now = Date()
        let cal = Calendar.current
        func task(_ title: String, _ type: TaskType, due: Date?, done: Bool = false, order: Int) -> TaskItem {
            TaskItem(title: title, status: done ? .done : .todo, type: type, dueAt: due, sortOrder: order, createdBy: .user,
                     createdAt: now, updatedAt: now, completedAt: done ? now : nil)
        }
        let schedule = SprintSchedule.default()
        return TaskEntry(
            date: now, configuration: configuration,
            today: [
                task("レビュー依頼を返す", .today, due: cal.endOfDay(for: now), order: 1),
                task("経費精算を出す", .today, due: cal.endOfDay(for: now), order: 2),
                task("朝会の議題を書く", .today, due: cal.endOfDay(for: now), done: true, order: 3),
            ],
            deadlines: [
                task("提案書ドラフト", .deadline, due: cal.date(byAdding: .day, value: 2, to: now), order: 1),
                task("四半期レポート", .deadline, due: cal.date(byAdding: .day, value: 12, to: now), order: 2),
            ],
            sprint: [
                task("ウィジェットのタイプ別表示", .sprint, due: schedule.dueDate(forSprintContaining: now), order: 1),
                task("MCP に type を追加", .sprint, due: schedule.dueDate(forSprintContaining: now), order: 2),
            ],
            sprintInterval: schedule.interval(containing: now), sprintDoneCount: 3, openEndedCount: 5, error: nil
        )
    }
}

// MARK: - 見た目

/// タイプごとの色。本体側の TaskTypeStyle と揃える。
extension TaskType {
    var color: Color {
        switch self {
        case .today: .blue
        case .deadline: .orange
        case .sprint: .purple
        case .openEnded: .gray
        }
    }
}

struct TaskWidgetView: View {
    let entry: TaskEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if let error = entry.error {
                VStack(alignment: .leading, spacing: 6) {
                    Text("今日").font(.headline)
                    Text(error).font(.caption2).foregroundStyle(.red)
                    Spacer(minLength: 0)
                }
            } else {
                switch family {
                case .systemSmall: small
                case .systemMedium: medium
                default: large
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // MARK: small: 今日の進捗だけ

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日").font(.headline)
                Spacer()
                Text("\(entry.todayDoneCount)/\(entry.today.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ProgressBar(value: progress(done: entry.todayDoneCount, total: entry.today.count), color: TaskType.today.color)
            if let first = entry.today.first(where: { !$0.isDone }) {
                TaskWidgetRow(task: first, now: entry.date, compact: true)
            } else if entry.today.isEmpty {
                Text("当日タスクなし").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("今日は全部終わりました").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if entry.configuration.showDeadline, let urgent = entry.deadlines.first {
                Divider()
                TaskWidgetRow(task: urgent, now: entry.date, compact: true)
            }
        }
    }

    // MARK: medium: 今日 + 近い期限

    private var medium: some View {
        VStack(alignment: .leading, spacing: 6) {
            todaySection(limit: 3)
            if entry.configuration.showDeadline, !entry.deadlines.isEmpty {
                Divider()
                ForEach(entry.deadlines.prefix(2)) { task in
                    TaskWidgetRow(task: task, now: entry.date)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: large: 全セクション

    private var large: some View {
        VStack(alignment: .leading, spacing: 6) {
            todaySection(limit: 4)
            if entry.configuration.showDeadline {
                sectionHeader("期限あり", trailing: entry.deadlines.isEmpty ? "なし" : nil)
                ForEach(entry.deadlines.prefix(3)) { task in
                    TaskWidgetRow(task: task, now: entry.date)
                }
                overflow(entry.deadlines.count - 3)
            }
            if entry.configuration.showSprint {
                sectionHeader("スプリント", trailing: sprintSummary)
                ProgressBar(value: progress(done: entry.sprintDoneCount, total: entry.sprintTotalCount), color: TaskType.sprint.color)
                ForEach(entry.sprint.prefix(3)) { task in
                    TaskWidgetRow(task: task, now: entry.date)
                }
                overflow(entry.sprint.count - 3)
            }
            Spacer(minLength: 0)
            if entry.configuration.showOpenEnded {
                HStack {
                    Text("いつか").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(entry.openEndedCount) 件").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: 部品

    private func todaySection(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日").font(.headline)
                Spacer()
                Text("\(entry.todayDoneCount) / \(entry.today.count)").font(.caption).foregroundStyle(.secondary)
            }
            ProgressBar(value: progress(done: entry.todayDoneCount, total: entry.today.count), color: TaskType.today.color)
            if entry.today.isEmpty {
                Text("当日タスクはありません").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(entry.today.prefix(limit)) { task in
                TaskWidgetRow(task: task, now: entry.date)
            }
            overflow(entry.today.count - limit)
        }
    }

    private func sectionHeader(_ title: String, trailing: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            if let trailing {
                Text(trailing).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.top, 4)
    }

    private var sprintSummary: String {
        let f = Date.FormatStyle().month(.defaultDigits).day()
        let end = entry.sprintInterval.end.addingTimeInterval(-1)
        let daysLeft = max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: entry.date), to: entry.sprintInterval.end).day ?? 0)
        return "\(entry.sprintInterval.start.formatted(f))〜\(end.formatted(f)) ・ 残り \(daysLeft) 日 ・ \(entry.sprintDoneCount) / \(entry.sprintTotalCount)"
    }

    @ViewBuilder
    private func overflow(_ count: Int) -> some View {
        if count > 0 {
            Text("ほか \(count) 件").font(.caption2).foregroundStyle(.tertiary).padding(.leading, 24)
        }
    }

    private func progress(done: Int, total: Int) -> Double {
        total == 0 ? 0 : Double(done) / Double(total)
    }
}

struct ProgressBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: 4)
    }
}

/// 1 行。チェックボックスは `CompleteTaskIntent` を実行し、タイトルは本体のディープリンクを開く。
struct TaskWidgetRow: View {
    let task: TaskItem
    let now: Date
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            Toggle(isOn: task.isDone, intent: CompleteTaskIntent(taskId: task.id, markDone: !task.isDone)) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.callout)
                    .foregroundStyle(task.isDone ? Color.secondary : task.type.color)
            }
            .toggleStyle(.button)
            .buttonStyle(.plain)
            .invalidatableContent()

            Link(destination: DeepLink.taskURL(id: task.id)) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .lineLimit(1)
                        .strikethrough(task.isDone)
                        .foregroundStyle(task.isDone ? .secondary : .primary)
                    Spacer(minLength: 0)
                    if !compact || task.isOverdue(now: now) {
                        badge
                    }
                }
                .contentShape(Rectangle())
            }
        }
        .font(compact ? .caption : .callout)
    }

    /// 期限の状態。当日タイプは期限切れのときだけ出す。
    @ViewBuilder
    private var badge: some View {
        if let dueAt = task.dueAt, !task.isDone {
            let calendar = Calendar.current
            if task.isOverdue(now: now) {
                Pill(text: "期限切れ", color: .red)
            } else if task.type == .deadline {
                if task.isDueToday(now: now) {
                    Pill(text: "今日", color: .orange)
                } else {
                    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: dueAt)).day ?? 0
                    if days <= 7 {
                        Pill(text: "あと \(days) 日", color: .orange)
                    } else {
                        Text(dueAt, format: Date.FormatStyle().month(.defaultDigits).day())
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

struct TaskWidget: Widget {
    let kind = "TaskWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: TaskWidgetConfiguration.self, provider: TaskTimelineProvider()) { entry in
            TaskWidgetView(entry: entry)
        }
        .configurationDisplayName("私の引き出し")
        .description("今日・期限あり・スプリントのタスクをデスクトップに表示します。")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
