import OSLog
import SwiftUI
import TaskCore

/// メインウィンドウ。タスク一覧と編集、activity_log の閲覧と取り消し、ログイン時起動の設定。
struct MainWindowView: View {
    static let windowID = "main"

    @Bindable var model: AppModel
    @State private var viewMode: ViewMode = .list
    /// 操作履歴は既定で隠し、ツールバーのボタンで出す。選択は記憶する。
    @AppStorage("mainWindow.showActivity") private var showActivity = false
    @State private var scope: Scope = .open
    @State private var aiOnly = false
    @State private var tasks: [TaskItem] = []
    @State private var activity: [ActivityEntry] = []

    enum ViewMode: String, CaseIterable, Identifiable {
        case list, calendar
        var id: String { rawValue }
    }

    enum Scope: String, CaseIterable, Identifiable {
        case open, done, archived, all
        var id: String { rawValue }
        var label: String {
            switch self {
            case .open: "未完了"
            case .done: "完了済み"
            case .archived: "アーカイブ"
            case .all: "すべて"
            }
        }
        func includes(_ task: TaskItem) -> Bool {
            switch self {
            case .open: !task.isArchived && !task.isDone
            case .done: !task.isArchived && task.isDone
            case .archived: task.isArchived
            case .all: true
            }
        }
    }

    var body: some View {
        HSplitView {
            Group {
                switch viewMode {
                case .list: taskList
                case .calendar: CalendarPane(model: model, tasks: tasks.filter { !$0.isArchived })
                }
            }
            .frame(minWidth: viewMode == .calendar ? 340 : 260, idealWidth: viewMode == .calendar ? 380 : 320)
            VStack(spacing: 0) {
                if let task = selectedTask {
                    TaskEditor(task: task, model: model)
                        .padding()
                } else {
                    Text("タスクを選ぶと編集できます")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 160, maxHeight: showActivity ? nil : .infinity)
                }
                if showActivity {
                    Divider()
                    activityList
                }
            }
            .frame(minWidth: 360)
        }
        .frame(minWidth: 700, minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Picker("表示", selection: $viewMode) {
                    Label("一覧", systemImage: "list.bullet").tag(ViewMode.list)
                    Label("カレンダー", systemImage: "calendar").tag(ViewMode.calendar)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("一覧とカレンダーを切り替える")
            }
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: $showActivity) {
                    Label("操作履歴", systemImage: "clock.arrow.circlepath")
                }
                .toggleStyle(.button)
                .help(showActivity ? "操作履歴を隠す" : "操作履歴を表示する(AI やウィジェットの操作と取り消し)")
                .keyboardShortcut("h", modifiers: [.command, .shift])
            }
            ToolbarItem(placement: .automatic) {
                SprintSettingsMenu(model: model)
            }
            ToolbarItem(placement: .automatic) {
                Toggle("ログイン時に起動", isOn: Binding(
                    get: { model.launchesAtLogin },
                    set: { model.setLaunchesAtLogin($0) }
                ))
                .toggleStyle(.checkbox)
            }
        }
        .onAppear {
            Logger(subsystem: "dev.araki.hikidashi", category: "app").info("main window appeared")
            refresh()
        }
        .onChange(of: model.tasks) { _, _ in refresh() }
        .onChange(of: model.doneTasks) { _, _ in refresh() }
        .onChange(of: model.recentActivity) { _, _ in refresh() }
        .onChange(of: model.mainWindowSelection) { _, id in
            // ディープリンクなどで選択されたタスクが今の絞り込みに無ければ「すべて」に切り替える。
            guard let id, let task = tasks.first(where: { $0.id == id }), !scope.includes(task) else { return }
            scope = .all
        }
    }

    private var selectedTask: TaskItem? {
        guard let id = model.mainWindowSelection else { return nil }
        return tasks.first { $0.id == id }
    }

    private var visibleTasks: [TaskItem] {
        tasks.filter(scope.includes).sorted { a, b in
            if a.type.sortRank != b.type.sortRank { return a.type.sortRank < b.type.sortRank }
            return (a.dueAt ?? .distantFuture, a.sortOrder) < (b.dueAt ?? .distantFuture, b.sortOrder)
        }
    }

    private var taskList: some View {
        VStack(spacing: 0) {
            Picker("", selection: $scope) {
                ForEach(Scope.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            List(selection: $model.mainWindowSelection) {
                ForEach(visibleTasks) { task in
                    HStack(spacing: 8) {
                        Button {
                            model.toggle(task)
                        } label: {
                            Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(task.isDone || task.isArchived ? Color.secondary : task.type.color)
                        }
                        .buttonStyle(.plain)
                        .disabled(task.isArchived)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(task.title)
                                    .strikethrough(task.isDone)
                                    .foregroundStyle(task.isArchived ? .tertiary : (task.isDone ? .secondary : .primary))
                                DueBadge(task: task)
                            }
                            HStack(spacing: 6) {
                                Label(task.type.displayName, systemImage: task.type.systemImage).foregroundStyle(task.type.color)
                                if let p = task.priority { Text(priorityLabel(p)) }
                                if let due = task.dueAt, task.type != .today { Text(due, style: .date) }
                                if task.createdBy == .ai {
                                    Text("AI").padding(.horizontal, 4).background(.quaternary, in: Capsule())
                                }
                                if task.isArchived { Text("アーカイブ済み") }
                                if let n = model.commentCounts[task.id], n > 0 {
                                    Label("\(n)", systemImage: "bubble.left").labelStyle(.titleAndIcon)
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .tag(task.id)
                }
            }
            .overlay {
                if visibleTasks.isEmpty {
                    Text("タスクはありません").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var activityList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("操作履歴").font(.headline)
                Spacer()
                Toggle("AI の操作だけ", isOn: $aiOnly).toggleStyle(.checkbox).font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            List(activity.filter { !aiOnly || $0.entry.actor == .ai }) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(actorLabel(item.entry.actor))
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .background(actorColor(item.entry.actor).opacity(0.2), in: Capsule())
                        .frame(width: 72, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(actionLabel(item.entry.action)): \(item.taskTitle)").lineLimit(1)
                        Text(diffSummary(item.entry))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Text(item.entry.createdAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if item.entry.diff != nil {
                        Button("元に戻す") { model.undo(item) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { model.mainWindowSelection = item.entry.taskId }
            }
        }
    }

    private func refresh() {
        tasks = model.allTasks()
        activity = model.fullActivity()
    }

    private func priorityLabel(_ p: TaskPriority) -> String {
        switch p {
        case .low: "優先度 低"
        case .medium: "優先度 中"
        case .high: "優先度 高"
        }
    }

    private func actorLabel(_ a: ChangeActor) -> String { a.displayName }

    private func actorColor(_ a: ChangeActor) -> Color { a.color }

    private func actionLabel(_ a: ActivityAction) -> String { a.displayName }

    /// diff を「title: 初稿 → 改稿」のような 1 行にまとめる。
    private func diffSummary(_ entry: ActivityLog) -> String {
        guard let diff = entry.decodedDiff() else { return "" }
        return diff.keys.sorted().map { key in
            "\(key): \(render(diff[key]!.from)) → \(render(diff[key]!.to))"
        }.joined(separator: "、")
    }

    private func render(_ v: JSONValue) -> String {
        switch v {
        case .null: "なし"
        case .string(let s): s
        case .int(let i): String(i)
        case .double(let d): String(d)
        case .bool(let b): b ? "true" : "false"
        }
    }
}

/// 選択中タスクの編集フォーム。フィールドごとに確定時に保存する。
private struct TaskEditor: View {
    let task: TaskItem
    @Bindable var model: AppModel

    @State private var title = ""
    @State private var notes = ""
    @State private var priority: TaskPriority?
    @State private var hasDue = false
    @State private var due = Date()
    @State private var status: TaskStatus = .todo
    @State private var type: TaskType = .openEnded

    var body: some View {
        Form {
            TextField("タイトル", text: $title)
                .onSubmit { save(TaskChanges(title: .set(title))) }
            TaskTypePicker(type: $type, label: "タイプ")
                .onChange(of: type) { old, new in
                    guard old != new, new != task.type else { return }
                    // タイプだけ変えると期限はタイプの既定値になる(当日 → 今日の終わり、スプリント → スプリント終了)。
                    // 有期限は期限が必要なので、今の期限か今日の 18 時を一緒に渡す。
                    if new == .deadline {
                        save(TaskChanges(type: .set(.deadline), dueAt: .set(task.dueAt ?? defaultDue)))
                    } else {
                        save(TaskChanges(type: .set(new)))
                    }
                }
            TextField("メモ", text: $notes, axis: .vertical)
                .lineLimit(2...6)
                .onSubmit { save(TaskChanges(notes: .set(notes.isEmpty ? nil : notes))) }
            Picker("状態", selection: $status) {
                Text("未着手").tag(TaskStatus.todo)
                Text("進行中").tag(TaskStatus.doing)
                Text("完了").tag(TaskStatus.done)
            }
            .onChange(of: status) { old, new in
                guard old != new, new != task.status else { return }
                save(TaskChanges(status: .set(new)))
            }
            Picker("優先度", selection: $priority) {
                Text("なし").tag(TaskPriority?.none)
                Text("低").tag(TaskPriority?.some(.low))
                Text("中").tag(TaskPriority?.some(.medium))
                Text("高").tag(TaskPriority?.some(.high))
            }
            .onChange(of: priority) { old, new in
                guard old != new, new != task.priority else { return }
                save(TaskChanges(priority: .set(new)))
            }
            if task.type != .openEnded {
                DatePicker("期限", selection: $due, displayedComponents: [.date, .hourAndMinute])
                    .onChange(of: due) { old, new in
                        guard old != new, new != task.dueAt else { return }
                        save(TaskChanges(dueAt: .set(new)))
                    }
                if task.type == .sprint {
                    HStack {
                        Spacer()
                        Button("次のスプリントへ") {
                            save(TaskChanges(dueAt: .set(model.sprintSchedule.dueDate(forSprintAfter: task.dueAt ?? .now))))
                        }
                        .controlSize(.small)
                    }
                }
            }
            HStack {
                if task.isArchived {
                    Button("復元") { model.restore(task) }
                } else {
                    Button("アーカイブ") { model.archive(task) }
                }
                Spacer()
                Button("メモを保存") { save(TaskChanges(notes: .set(notes.isEmpty ? nil : notes))) }
                    .disabled(notes == (task.notes ?? ""))
            }
            .padding(.top, 4)

            Section("コメント") {
                CommentsSection(task: task, model: model)
            }
        }
        .formStyle(.grouped)
        .onAppear { load() }
        .onChange(of: task) { _, _ in load() }
    }

    private var defaultDue: Date {
        Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: .now) ?? .now
    }

    private func load() {
        title = task.title
        notes = task.notes ?? ""
        priority = task.priority
        hasDue = task.dueAt != nil
        due = task.dueAt ?? defaultDue
        status = task.status
        type = task.type
    }

    private func save(_ changes: TaskChanges) {
        model.update(task, changes: changes)
    }
}

/// スプリントの区切り方(開始曜日と日数)を変えるメニュー。
private struct SprintSettingsMenu: View {
    @Bindable var model: AppModel

    private let weekdays: [(Int, String)] = [(1, "日"), (2, "月"), (3, "火"), (4, "水"), (5, "木"), (6, "金"), (7, "土")]

    var body: some View {
        Menu {
            Picker("開始曜日", selection: Binding(
                get: { model.sprintSchedule.startWeekday() },
                set: { model.setSprintSchedule(SprintSchedule(startWeekday: $0, lengthDays: model.sprintSchedule.lengthDays)) }
            )) {
                ForEach(weekdays, id: \.0) { day in
                    Text("\(day.1)曜日").tag(day.0)
                }
            }
            Picker("長さ", selection: Binding(
                get: { model.sprintSchedule.lengthDays },
                set: { model.setSprintSchedule(SprintSchedule(startWeekday: model.sprintSchedule.startWeekday(), lengthDays: $0)) }
            )) {
                Text("1 週間").tag(7)
                Text("2 週間").tag(14)
                Text("3 週間").tag(21)
                Text("4 週間").tag(28)
            }
            Divider()
            Text(currentSprint)
        } label: {
            Label("スプリント", systemImage: "flag.checkered")
        }
        .help("スプリントの区切り方。今のスプリント: \(currentSprint)")
    }

    private var currentSprint: String {
        let interval = model.sprintSchedule.interval(containing: .now)
        let f = Date.FormatStyle().month(.defaultDigits).day().weekday(.abbreviated)
        return "今のスプリント: \(interval.start.formatted(f)) 〜 \(interval.end.addingTimeInterval(-1).formatted(f))"
    }
}

/// タスクのコメントのスレッド。人も AI も書き、どちらのコメントも削除(論理削除、取り消し可)できる。
private struct CommentsSection: View {
    let task: TaskItem
    @Bindable var model: AppModel
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var comments: [Comment] { model.comments(for: task.id) }

    var body: some View {
        if comments.isEmpty {
            Text("まだコメントはありません").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(comments) { comment in
            HStack(alignment: .top, spacing: 8) {
                Text(comment.author.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(comment.author.color.opacity(0.2), in: Capsule())
                    .frame(width: 72, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(comment.body).textSelection(.enabled)
                    Text(comment.createdAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    model.deleteComment(comment)
                } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("コメントを削除(操作履歴から元に戻せます)")
            }
            .padding(.vertical, 2)
        }
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            TextField("状況をコメント… (⌘↩ で送信)", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($focused)
                .onSubmit(submit)
            Button("送信", action: submit)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func submit() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        model.addComment(to: task.id, body: body)
        draft = ""
        focused = true
    }
}
