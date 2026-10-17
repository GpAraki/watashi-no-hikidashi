import SwiftUI
import TaskCore

/// 月カレンダー。期限のあるタスクを日付に置き、日を選ぶとその日のタスクを下に出す。
/// 今のスプリントの期間は薄い紫で塗る。
struct CalendarPane: View {
    @Bindable var model: AppModel
    /// 表示対象(アーカイブ済みは渡さない)。
    let tasks: [TaskItem]

    @State private var month: Date = Calendar.current.startOfMonth(for: .now)
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: .now)
    @State private var draft = ""

    private let calendar = Calendar.current
    private let weekdaySymbols = ["日", "月", "火", "水", "木", "金", "土"]

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 12).padding(.vertical, 8)
            weekdayRow.padding(.horizontal, 8)
            grid.padding(.horizontal, 8).padding(.bottom, 8)
            Divider()
            dayList
        }
        .onChange(of: model.mainWindowSelection) { _, id in
            // 右の履歴などから選ばれたタスクの日へ移動する。
            guard let id, let task = tasks.first(where: { $0.id == id }), let due = task.dueAt else { return }
            selectedDay = calendar.startOfDay(for: due)
            month = calendar.startOfMonth(for: due)
        }
    }

    // MARK: ヘッダー

    private var header: some View {
        HStack {
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
            Text(month, format: .dateTime.year().month(.wide))
                .font(.headline)
                .frame(minWidth: 120)
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
            Spacer()
            Button("今日") {
                month = calendar.startOfMonth(for: .now)
                selectedDay = calendar.startOfDay(for: .now)
            }
            .controlSize(.small)
        }
        .buttonStyle(.borderless)
    }

    private var weekdayRow: some View {
        HStack(spacing: 2) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { i, s in
                Text(s)
                    .font(.caption2)
                    .foregroundStyle(i == 0 ? .red : (i == 6 ? .blue : .secondary))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: グリッド

    private var grid: some View {
        let days = monthDays()
        let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        return LazyVGrid(columns: columns, spacing: 2) {
            ForEach(days, id: \.self) { day in
                DayCell(
                    day: day,
                    inMonth: calendar.isDate(day, equalTo: month, toGranularity: .month),
                    isToday: calendar.isDateInToday(day),
                    isSelected: calendar.isDate(day, inSameDayAs: selectedDay),
                    inCurrentSprint: model.sprintSchedule.interval(containing: .now).contains(day),
                    isSprintStart: calendar.isDate(model.sprintSchedule.interval(containing: day).start, inSameDayAs: day),
                    tasks: tasks(on: day)
                )
                .onTapGesture { selectedDay = day }
            }
        }
    }

    /// 月の 1 日を含む週の日曜から 6 週分(42 日)。
    private func monthDays() -> [Date] {
        let first = calendar.startOfMonth(for: month)
        let leading = calendar.component(.weekday, from: first) - 1
        let start = calendar.date(byAdding: .day, value: -leading, to: first)!
        return (0..<42).map { calendar.date(byAdding: .day, value: $0, to: start)! }
    }

    private func tasks(on day: Date) -> [TaskItem] {
        tasks.filter { task in
            guard let due = task.dueAt else { return false }
            return calendar.isDate(due, inSameDayAs: day)
        }
        .sorted { a, b in
            if a.isDone != b.isDone { return !a.isDone }
            if a.type.sortRank != b.type.sortRank { return a.type.sortRank < b.type.sortRank }
            return (a.dueAt ?? .distantFuture) < (b.dueAt ?? .distantFuture)
        }
    }

    private func shiftMonth(_ delta: Int) {
        month = calendar.date(byAdding: .month, value: delta, to: month)!
    }

    // MARK: 選んだ日のタスク

    private var dayList: some View {
        let items = tasks(on: selectedDay)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selectedDay, format: .dateTime.month().day().weekday(.abbreviated))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(items.filter { !$0.isDone }.count) 件")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            List(selection: $model.mainWindowSelection) {
                ForEach(items) { task in
                    HStack(spacing: 8) {
                        Button { model.toggle(task) } label: {
                            Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(task.isDone ? Color.secondary : task.type.color)
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(task.title)
                                .strikethrough(task.isDone)
                                .foregroundStyle(task.isDone ? .secondary : .primary)
                            HStack(spacing: 6) {
                                Label(task.type.displayName, systemImage: task.type.systemImage)
                                    .foregroundStyle(task.type.color)
                                if let due = task.dueAt, task.type == .deadline {
                                    Text(due, format: .dateTime.hour().minute())
                                }
                            }
                            .font(.caption2)
                        }
                        Spacer()
                        DueBadge(task: task)
                    }
                    .tag(task.id)
                }
            }
            .overlay {
                if items.isEmpty {
                    Text("この日のタスクはありません").foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                TextField("この日に期限ありタスクを追加…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let title = draft.trimmingCharacters(in: .whitespaces)
                        guard !title.isEmpty else { return }
                        model.addDeadline(title: title, dueAt: calendar.date(bySettingHour: 18, minute: 0, second: 0, of: selectedDay) ?? selectedDay)
                        draft = ""
                    }
            }
            .padding(8)
        }
    }
}

/// カレンダーの 1 マス。日付と、その日が期限のタスクをタイプ色の点で示す。
private struct DayCell: View {
    let day: Date
    let inMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let inCurrentSprint: Bool
    let isSprintStart: Bool
    let tasks: [TaskItem]

    private var openTasks: [TaskItem] { tasks.filter { !$0.isDone } }
    private var overdue: Bool { openTasks.contains { $0.isOverdue() } }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 2) {
                if isSprintStart {
                    Image(systemName: "flag.fill").font(.system(size: 7)).foregroundStyle(TaskType.sprint.color)
                }
                Spacer(minLength: 0)
                Text(day, format: .dateTime.day())
                    .font(.caption.weight(isToday ? .bold : .regular))
                    .foregroundStyle(inMonth ? (isToday ? TaskType.today.color : Color.primary) : Color.secondary.opacity(0.5))
            }
            HStack(spacing: 2) {
                ForEach(dots.prefix(4), id: \.self) { color in
                    Circle().fill(color).frame(width: 5, height: 5)
                }
                if openTasks.count > 4 {
                    Text("+\(openTasks.count - 4)").font(.system(size: 8)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 6)
        }
        .padding(4)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : (inCurrentSprint ? TaskType.sprint.color.opacity(0.08) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isToday ? TaskType.today.color : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .help(helpText)
    }

    /// 未完了はタイプ色、期限切れは赤、完了はグレー。
    private var dots: [Color] {
        let open = openTasks.map { $0.isOverdue() ? Color.red : $0.type.color }
        let done = tasks.filter(\.isDone).map { _ in Color.gray.opacity(0.5) }
        return open + done
    }

    private var helpText: String {
        guard !tasks.isEmpty else { return "" }
        return tasks.map { ($0.isDone ? "✓ " : "") + $0.title }.joined(separator: "\n")
    }
}

extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date))!
    }
}
