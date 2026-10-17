import AppKit
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

extension ChangeActor {
    var displayName: String {
        switch self {
        case .user: "あなた"
        case .ai: "AI"
        case .widget: "ウィジェット"
        }
    }

    var color: Color {
        switch self {
        case .user: .gray
        case .ai: .purple
        case .widget: .blue
        }
    }
}

extension ActivityAction {
    var displayName: String {
        switch self {
        case .create: "追加"
        case .update: "変更"
        case .complete: "完了"
        case .reopen: "再開"
        case .archive: "アーカイブ"
        case .restore: "復元"
        case .comment: "コメント"
        case .deleteComment: "コメント削除"
        case .link: "リンク追加"
        case .deleteLink: "リンク削除"
        }
    }
}

/// リンクの見た目。サービス名をラベルにし、クリックで既定のブラウザで開く。
struct LinkChip: View {
    let url: URL
    var label: String? = nil
    /// notes から検出しただけで未登録のリンクは点線で区別する。
    var detected = false
    var onRemove: (() -> Void)? = nil
    var onRegister: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label(label ?? TaskLink.serviceName(for: url), systemImage: linkSymbol(for: url))
                    .font(.caption)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(url.absoluteString)
            if let onRegister {
                Button(action: onRegister) { Image(systemName: "plus.circle") }
                    .buttonStyle(.plain).font(.caption)
                    .help("リンクとして登録する")
            }
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain).font(.caption)
                    .help("リンクを外す(操作履歴から元に戻せます)")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(detected ? 0.06 : 0.12), in: Capsule())
        .overlay(
            Capsule().strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: detected ? 1 : 0, dash: detected ? [3, 2] : []))
        )
        .foregroundStyle(Color.accentColor)
    }
}

func linkSymbol(for url: URL) -> String {
    switch TaskLink.serviceName(for: url) {
    case "Notion": "doc.text"
    case "Jira", "Linear", "Trello": "ticket"
    case "Confluence", "Google ドキュメント": "doc.richtext"
    case "GitHub", "GitLab": "chevron.left.forwardslash.chevron.right"
    case "Figma": "paintbrush"
    case "Slack": "bubble.left.and.bubble.right"
    case "Google Drive", "Google スプレッドシート": "tablecells"
    case "Zoom", "Google カレンダー": "calendar"
    case "引き出し": "tray"
    default: "link"
    }
}

/// 行に置く小さなリンクボタン。1 つならそのまま開き、複数ならメニュー。
struct LinksButton: View {
    let links: [TaskLink]
    let detected: [URL]

    private var all: [(URL, String)] {
        links.map { ($0.url, $0.displayLabel) } + detected
            .filter { d in !links.contains { $0.url == d } }
            .map { ($0, TaskLink.serviceName(for: $0)) }
    }

    var body: some View {
        if all.count == 1, let only = all.first {
            Button { NSWorkspace.shared.open(only.0) } label: {
                Image(systemName: linkSymbol(for: only.0)).font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("\(only.1) を開く")
        } else if all.count > 1 {
            Menu {
                ForEach(Array(all.enumerated()), id: \.offset) { _, item in
                    Button(item.1) { NSWorkspace.shared.open(item.0) }
                }
            } label: {
                Label("\(all.count)", systemImage: "link").font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("リンクを開く")
        }
    }
}
