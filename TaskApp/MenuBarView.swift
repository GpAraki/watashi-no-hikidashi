import SwiftUI
import TaskCore

struct MenuBarView: View {
    @Bindable var model: AppModel
    @State private var draft = ""

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
                    .onSubmit {
                        let title = draft.trimmingCharacters(in: .whitespaces)
                        guard !title.isEmpty else { return }
                        model.add(title: title)
                        draft = ""
                    }

                if model.tasks.isEmpty {
                    Text("未完了のタスクはありません")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.tasks) { task in
                                TaskRow(task: task) { model.toggle(task) }
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }

                if let error = model.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Divider()
            HStack {
                Text(model.databasePath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("終了") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 320)
    }
}

private struct TaskRow: View {
    let task: TaskItem
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
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
        .padding(.vertical, 2)
    }
}
