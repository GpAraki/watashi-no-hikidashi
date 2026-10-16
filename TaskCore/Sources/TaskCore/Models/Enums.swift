import Foundation
import GRDB

public enum TaskStatus: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case todo
    case doing
    case done
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
}
