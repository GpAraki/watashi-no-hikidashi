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
    /// タスク id → 最初のリンク。行のアイコンからブラウザで開く。
    let firstLinks: [String: URL]
    let error: String?

    var todayDoneCount: Int { today.filter(\.isDone).count }
    var sprintTotalCount: Int { sprint.count + sprintDoneCount }

    static func empty(_ configuration: TaskWidgetConfiguration, error: String? = nil) -> TaskEntry {
        TaskEntry(date: .now, configuration: configuration, today: [], deadlines: [], sprint: [],
                  sprintInterval: SprintSchedule.default().interval(containing: .now), sprintDoneCount: 0, openEndedCount: 0, firstLinks: [:], error: error)
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
        let links = try repository.linksByTask()
        var firstLinks: [String: URL] = [:]
        for task in all {
            if let link = links[task.id]?.first { firstLinks[task.id] = link.url }
            else if let detected = URLDetection.urls(in: task.notes).first { firstLinks[task.id] = detected }
        }
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
            firstLinks: firstLinks,
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
            sprintInterval: schedule.interval(containing: now), sprintDoneCount: 3, openEndedCount: 5, firstLinks: [:], error: nil
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
        .widgetURL(DeepLink.list.url)
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
                TaskWidgetRow(task: first, now: entry.date, link: entry.firstLinks[first.id], compact: true)
            } else if entry.today.isEmpty {
                Text("当日タスクなし").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("今日は全部終わりました").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if entry.configuration.showDeadline, let urgent = entry.deadlines.first {
                Divider()
                TaskWidgetRow(task: urgent, now: entry.date, link: entry.firstLinks[urgent.id], compact: true)
            }
        }
    }

    // MARK: medium: 未完了を合計 3 行まで

    private var openToday: [TaskItem] { entry.today.filter { !$0.isDone } }
    private var visibleDeadlines: [TaskItem] { entry.configuration.showDeadline ? entry.deadlines : [] }
    private var visibleSprint: [TaskItem] { entry.configuration.showSprint ? entry.sprint : [] }

    private var medium: some View {
        let todayLimit = min(openToday.count, visibleDeadlines.isEmpty ? 3 : 2)
        let deadlineLimit = min(visibleDeadlines.count, 3 - todayLimit)
        return VStack(alignment: .leading, spacing: 6) {
            todaySection(limit: todayLimit)
            if deadlineLimit > 0 {
                sectionHeader("期限あり", trailing: "\(visibleDeadlines.count) 件")
                ForEach(visibleDeadlines.prefix(deadlineLimit)) { task in
                    TaskWidgetRow(task: task, now: entry.date, link: entry.firstLinks[task.id])
                }
            }
            Spacer(minLength: 0)
            remainingLink(openToday.count + visibleDeadlines.count - todayLimit - deadlineLimit)
        }
    }

    // MARK: large: セクション間で空き枠を融通し、未完了を合計 7 行まで

    private var large: some View {
        let limits = largeLimits
        return VStack(alignment: .leading, spacing: 6) {
            todaySection(limit: limits.today)
            if entry.configuration.showDeadline {
                sectionHeader("期限あり", trailing: visibleDeadlines.isEmpty ? "なし" : "\(visibleDeadlines.count) 件")
                ForEach(visibleDeadlines.prefix(limits.deadline)) { task in
                    TaskWidgetRow(task: task, now: entry.date, link: entry.firstLinks[task.id])
                }
            }
            if entry.configuration.showSprint {
                sectionHeader("スプリント", trailing: "残り \(sprintDaysLeft) 日")
                HStack {
                    Text(sprintPeriod)
                    Spacer()
                    Text("\(entry.sprintDoneCount) / \(entry.sprintTotalCount) 完了")
                }
                .font(.caption2).foregroundStyle(.secondary)
                ProgressBar(value: progress(done: entry.sprintDoneCount, total: entry.sprintTotalCount), color: TaskType.sprint.color)
                ForEach(visibleSprint.prefix(limits.sprint)) { task in
                    TaskWidgetRow(task: task, now: entry.date, link: entry.firstLinks[task.id])
                }
            }
            Spacer(minLength: 0)
            HStack {
                remainingLink(openToday.count + visibleDeadlines.count + visibleSprint.count - limits.today - limits.deadline - limits.sprint)
                Spacer(minLength: 0)
                if entry.configuration.showOpenEnded {
                    Link("いつか \(entry.openEndedCount) 件", destination: DeepLink.list.url)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var largeLimits: (today: Int, deadline: Int, sprint: Int) {
        var today = min(openToday.count, 3)
        var deadline = min(visibleDeadlines.count, 2)
        var sprint = min(visibleSprint.count, 2)
        var spare = 7 - today - deadline - sprint
        let moreToday = min(spare, openToday.count - today)
        today += moreToday
        spare -= moreToday
        let moreDeadline = min(spare, visibleDeadlines.count - deadline)
        deadline += moreDeadline
        spare -= moreDeadline
        sprint += min(spare, visibleSprint.count - sprint)
        return (today, deadline, sprint)
    }

    // MARK: 部品

    private func todaySection(limit: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日").font(.headline)
                Spacer()
                Text("\(entry.todayDoneCount) / \(entry.today.count) 完了").font(.caption).foregroundStyle(.secondary)
            }
            ProgressBar(value: progress(done: entry.todayDoneCount, total: entry.today.count), color: TaskType.today.color)
            if openToday.isEmpty {
                Text(entry.today.isEmpty ? "今日のタスクはありません" : "今日は全部終わりました")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(openToday.prefix(limit)) { task in
                TaskWidgetRow(task: task, now: entry.date, link: entry.firstLinks[task.id])
            }
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

    private var sprintPeriod: String {
        let f = Date.FormatStyle().month(.defaultDigits).day()
        let end = entry.sprintInterval.end.addingTimeInterval(-1)
        return "\(entry.sprintInterval.start.formatted(f))〜\(end.formatted(f))"
    }

    private var sprintDaysLeft: Int {
        max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: entry.date), to: entry.sprintInterval.end).day ?? 0)
    }

    private func remainingLink(_ count: Int) -> some View {
        Link(destination: DeepLink.list.url) {
            Text(count > 0 ? "ほか \(count) 件を表示 ›" : "すべて表示 ›")
                .font(.caption2).foregroundStyle(.secondary)
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
    var link: URL? = nil
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
                        .lineLimit(compact ? 2 : 1)
                        .strikethrough(task.isDone)
                        .foregroundStyle(task.isDone ? .secondary : .primary)
                    Spacer(minLength: 0)
                    badge.fixedSize(horizontal: true, vertical: false)
                }
                .contentShape(Rectangle())
            }

            if let link, !compact {
                // 外部リンクはブラウザで直接開く(本体を経由しない)。
                Link(destination: link) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                        if compact {
                            Text(dueAt, format: Date.FormatStyle().month(.defaultDigits).day())
                                .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            Pill(text: days == 1 ? "明日" : "あと \(days) 日", color: .orange)
                        }
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
