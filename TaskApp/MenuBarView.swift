import KeyboardShortcuts
import SwiftUI
import TaskCore

struct MenuBarView: View {
    @Bindable var model: AppModel
    @State private var draft = ""
    @State private var showDone = false
    @State private var showActivity = false
    @FocusState private var quickInputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.state {
            case .failed(let message):
                Label("データベースを開けません", systemImage: "exclamationmark.triangle")
                    .font(.headline)
                Text(message).font(.caption).foregroundStyle(.secondary)
            case .ready:
                TextField("タスクを追加…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($quickInputFocused)
                    .onSubmit {
                        let title = draft.trimmingCharacters(in: .whitespaces)
                        guard !title.isEmpty else { return }
                        model.add(title: title)
                        draft = ""
                    }

                // ディープリンクで開かれたタスクが未完了一覧に無いとき(完了済みなど)は、その 1 件を上に出す。
                if let selected = model.selectedTaskOutsideList {
                    TaskRow(task: selected, isSelected: true) { model.toggle(selected) }
                }

                if model.tasks.isEmpty {
                    Text("未完了のタスクはありません")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(model.tasks) { task in
                                    TaskRow(task: task, isSelected: task.id == model.selectedTaskId) { model.toggle(task) }
                                        .id(task.id)
                                }
                            }
                        }
                        .frame(maxHeight: 260)
                        .onChange(of: model.selectedTaskId, initial: true) { _, id in
                            guard let id else { return }
                            withAnimation { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }

                if !model.doneTasks.isEmpty {
                    DisclosureGroup(isExpanded: $showDone) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(model.doneTasks) { task in
                                    TaskRow(task: task) { model.toggle(task) }
                                }
                            }
                        }
                        .frame(maxHeight: 140)
                    } label: {
                        Text("完了済み (\(model.doneTasks.count))").font(.caption).foregroundStyle(.secondary)
                    }
                }

                if !model.recentActivity.isEmpty {
                    DisclosureGroup(isExpanded: $showActivity) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(model.recentActivity) { activity in
                                    ActivityRow(activity: activity) { model.undo(activity) }
                                }
                            }
                        }
                        .frame(maxHeight: 160)
                    } label: {
                        Text("最近の操作").font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let error = model.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Divider()
            HStack(spacing: 6) {
                Button("すべて表示…") { model.showMainWindow() }
                    .keyboardShortcut("l")
                Spacer()
                Text("ショートカット").font(.caption2).foregroundStyle(.secondary)
                KeyboardShortcuts.Recorder(for: .quickInput)
                    .controlSize(.small)
                Button("終了") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            Text(model.databasePath)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(12)
        .frame(width: 320)
        .onAppear {
            model.popoverDidAppear()
            quickInputFocused = true
        }
        .onDisappear { model.popoverDidDisappear() }
        .onChange(of: model.quickInputFocusRequest) { _, _ in
            quickInputFocused = true
        }
    }
}

private struct TaskRow: View {
    let task: TaskItem
    var isSelected = false
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? .secondary : .primary)
                HStack(spacing: 6) {
                    if let due = task.dueAt {
                        Text(due, style: .date)
                    }
                    if task.createdBy == .ai {
                        Text("AI").padding(.horizontal, 4).background(.quaternary, in: Capsule())
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
    }
}

/// 操作履歴 1 行。「誰が・何を・どのタスクに」と、取り消しボタン。
private struct ActivityRow: View {
    let activity: ActivityEntry
    let onUndo: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(actorLabel)
                .font(.caption2)
                .padding(.horizontal, 4)
                .background(actorColor.opacity(0.2), in: Capsule())
            VStack(alignment: .leading, spacing: 1) {
                Text("\(actionLabel): \(activity.taskTitle)")
                    .font(.caption)
                    .lineLimit(1)
                Text(activity.entry.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if activity.entry.diff != nil {
                Button("元に戻す", action: onUndo)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
    }

    private var actorLabel: String {
        switch activity.entry.actor {
        case .user: "あなた"
        case .ai: "AI"
        case .widget: "ウィジェット"
        }
    }

    private var actorColor: Color {
        switch activity.entry.actor {
        case .user: .gray
        case .ai: .purple
        case .widget: .blue
        }
    }

    private var actionLabel: String {
        switch activity.entry.action {
        case .create: "追加"
        case .update: "変更"
        case .complete: "完了"
        case .reopen: "再開"
        case .archive: "アーカイブ"
        case .restore: "復元"
        }
    }
}
