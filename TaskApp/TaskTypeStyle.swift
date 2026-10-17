import SwiftUI
import TaskCore

/// タイプごとの色とアイコン。ウィジェット側の `TaskType.color` と揃える。
extension TaskType {
    var color: Color {
        switch self {
        case .today: .blue
        case .deadline: .orange
        case .sprint: .purple
        case .openEnded: .gray
        }
    }

    var systemImage: String {
        switch self {
        case .today: "sun.max"
        case .deadline: "calendar"
        case .sprint: "flag.checkered"
        case .openEnded: "tray"
        }
    }

    /// 一覧の区切りに使う順(今日 → 期限あり → スプリント → いつか)。
    static let displayOrder: [TaskType] = TaskType.allCases.sorted { $0.sortRank < $1.sortRank }
}

/// 期限の状態を短く示すバッジ。
struct DueBadge: View {
    let task: TaskItem
    var now = Date()

    var body: some View {
        if let dueAt = task.dueAt, !task.isDone {
            let calendar = Calendar.current
            if task.isOverdue(now: now) {
                pill("期限切れ", .red)
            } else if task.type == .deadline || task.type == .sprint {
                if task.isDueToday(now: now) {
                    pill("今日", .orange)
                } else {
                    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: dueAt)).day ?? 0
                    if days <= 7 {
                        pill("あと \(days) 日", task.type.color)
                    } else {
                        Text(dueAt, format: Date.FormatStyle().month(.defaultDigits).day())
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

/// タイプを選ぶコンパクトなピッカー。
struct TaskTypePicker: View {
    @Binding var type: TaskType
    var label = ""

    var body: some View {
        Picker(label, selection: $type) {
            ForEach(TaskType.displayOrder, id: \.self) { t in
                Label(t.displayName, systemImage: t.systemImage).tag(t)
            }
        }
    }
}
