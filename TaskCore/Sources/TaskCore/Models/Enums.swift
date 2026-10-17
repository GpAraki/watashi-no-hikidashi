import Foundation
import GRDB

public enum TaskStatus: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case todo
    case doing
    case done
}

/// タスクの「いつまでにやるか」の約束の強さ。期限の扱いと表示の区切りを決める。
public enum TaskType: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    /// いつかやる。期限なし。
    case openEnded = "open_ended"
    /// 日付までに終える。`due_at` 必須。
    case deadline
    /// 今のスプリント内に終える。`due_at` はスプリント終了時刻。
    case sprint
    /// 今日中に終える。`due_at` はその日の終わり。
    case today

    /// 期限を持つタイプか。
    public var requiresDueDate: Bool { self != .openEnded }

    /// 画面に出す名前。
    public var displayName: String {
        switch self {
        case .openEnded: "いつか"
        case .deadline: "期限あり"
        case .sprint: "スプリント"
        case .today: "今日"
        }
    }

    /// 一覧で並べる順。
    public var sortRank: Int {
        switch self {
        case .today: 0
        case .deadline: 1
        case .sprint: 2
        case .openEnded: 3
        }
    }
}

/// 1 が最低、3 が最高。NULL は未設定。
public enum TaskPriority: Int, Codable, Sendable, CaseIterable, Comparable, DatabaseValueConvertible {
    case low = 1
    case medium = 2
    case high = 3

    public static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// `task.created_by` に入る値。
public enum TaskCreator: String, Codable, Sendable, DatabaseValueConvertible {
    case user
    case ai
}

/// `activity_log.actor` に入る値。誰がその操作をしたか。
public enum ChangeActor: String, Codable, Sendable, DatabaseValueConvertible {
    case user
    case ai
    case widget

    /// 作成者としての扱い。ウィジェット操作は人間の操作なので user。
    public var creator: TaskCreator {
        self == .ai ? .ai : .user
    }
}

public enum ActivityAction: String, Codable, Sendable, DatabaseValueConvertible {
    case create
    case update
    case complete
    case reopen
    case archive
    case restore
    /// コメントの追加。diff は comment_id と comment(本文)。
    case comment
    /// コメントの論理削除。
    case deleteComment = "delete_comment"
    /// リンクの追加。diff は link_id と url。
    case link
    /// リンクの論理削除。
    case deleteLink = "delete_link"
}
