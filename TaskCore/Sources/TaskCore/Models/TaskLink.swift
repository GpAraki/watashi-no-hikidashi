import Foundation
import GRDB

/// タスクに紐づく外部リンク(Notion、Jira、GitHub など)。1 タスクに複数持てる。削除は論理削除。
public struct TaskLink: Codable, Identifiable, Hashable, Sendable {
    public var id: Int64?
    public var taskId: String
    public var url: URL
    /// 表示名。nil なら `displayLabel` がホスト名から決める。
    public var label: String?
    public var createdBy: ChangeActor
    public var createdAt: Date
    public var deletedAt: Date?

    public init(id: Int64? = nil, taskId: String, url: URL, label: String? = nil, createdBy: ChangeActor, createdAt: Date, deletedAt: Date? = nil) {
        self.id = id
        self.taskId = taskId
        self.url = url
        self.label = label
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.deletedAt = deletedAt
    }

    public var isDeleted: Bool { deletedAt != nil }

    /// 画面に出す名前。明示のラベルがなければサービス名、それも分からなければホスト名。
    public var displayLabel: String {
        if let label, !label.isEmpty { return label }
        return Self.serviceName(for: url)
    }

    /// URL のホストからサービス名を推定する。
    public static func serviceName(for url: URL) -> String {
        let host = (url.host() ?? "").lowercased()
        let path = url.path().lowercased()
        let table: [(String, String)] = [
            ("notion.so", "Notion"), ("notion.site", "Notion"),
            ("github.com", "GitHub"), ("gitlab.com", "GitLab"),
            ("figma.com", "Figma"), ("slack.com", "Slack"),
            ("docs.google.com", "Google ドキュメント"), ("drive.google.com", "Google Drive"),
            ("sheets.google.com", "Google スプレッドシート"), ("calendar.google.com", "Google カレンダー"),
            ("miro.com", "Miro"), ("linear.app", "Linear"), ("trello.com", "Trello"),
            ("zoom.us", "Zoom"), ("youtube.com", "YouTube"), ("x.com", "X"),
        ]
        if host.hasSuffix("atlassian.net") {
            return path.hasPrefix("/wiki") ? "Confluence" : "Jira"
        }
        for (suffix, name) in table where host == suffix || host.hasSuffix("." + suffix) {
            return name
        }
        if url.scheme == "hikidashi" { return "引き出し" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : (host.isEmpty ? url.absoluteString : host)
    }
}

extension TaskLink: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "task_link"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public enum Columns {
        public static let id = Column("id")
        public static let taskId = Column("task_id")
        public static let url = Column("url")
        public static let createdAt = Column("created_at")
        public static let deletedAt = Column("deleted_at")
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// 文章中の URL を拾う。notes に貼られたリンクをチップとして出すために使う。
public enum URLDetection {
    public static func urls(in text: String?) -> [URL] {
        guard let text, !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        return detector.matches(in: text, options: [], range: range).compactMap { match in
            guard let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            return seen.insert(url.absoluteString).inserted ? url : nil
        }
    }
}
