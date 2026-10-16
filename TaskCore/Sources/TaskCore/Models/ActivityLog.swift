import Foundation
import GRDB

/// diff に入る値。JSON にそのまま落とせる最小限の型だけを持つ。
public enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    // MARK: 変換ヘルパ

    static let iso8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    init(_ s: String?) { self = s.map { .string($0) } ?? .null }
    init(_ d: Date?) { self = d.map { .string($0.formatted(Self.iso8601)) } ?? .null }
    init(_ i: Int?) { self = i.map { .int($0) } ?? .null }
    init<R: RawRepresentable>(_ r: R?) where R.RawValue == String { self = r.map { .string($0.rawValue) } ?? .null }
    init<R: RawRepresentable>(_ r: R?) where R.RawValue == Int { self = r.map { .int($0.rawValue) } ?? .null }

    // MARK: 読み出しヘルパ(取り消しで diff を書き戻すときに使う)

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v) where v.rounded() == v: return Int(v)
        default: return nil
        }
    }

    /// ISO 8601 文字列を Date に戻す。null は nil、解釈できない文字列はエラー。
    public func dateValue() throws -> Date? {
        switch self {
        case .null: return nil
        case .string(let v):
            if let d = try? Date(v, strategy: Self.iso8601) { return d }
            if let d = try? Date(v, strategy: Date.ISO8601FormatStyle()) { return d }
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not a date: \(v)"))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not a date"))
        }
    }
}

/// 1 フィールド分の変更前後。
public struct FieldChange: Codable, Hashable, Sendable {
    public var from: JSONValue
    public var to: JSONValue

    public init(from: JSONValue, to: JSONValue) {
        self.from = from
        self.to = to
    }
}

/// カラム名(snake_case)をキーにした変更差分。
public typealias TaskDiff = [String: FieldChange]

/// タスクに対する操作履歴。AI による変更の確認と取り消しに使う。
public struct ActivityLog: Codable, Identifiable, Hashable, Sendable {
    public var id: Int64?
    public var taskId: String
    public var actor: ChangeActor
    public var action: ActivityAction
    /// `TaskDiff` を JSON 化した文字列。
    public var diff: String?
    public var createdAt: Date

    public init(id: Int64? = nil, taskId: String, actor: ChangeActor, action: ActivityAction, diff: TaskDiff?, createdAt: Date) {
        self.id = id
        self.taskId = taskId
        self.actor = actor
        self.action = action
        self.diff = diff.flatMap(Self.encode)
        self.createdAt = createdAt
    }

    public func decodedDiff() -> TaskDiff? {
        guard let diff, let data = diff.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TaskDiff.self, from: data)
    }

    static func encode(_ diff: TaskDiff) -> String? {
        guard !diff.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(diff)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

extension ActivityLog: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "activity_log"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public enum Columns {
        public static let id = Column("id")
        public static let taskId = Column("task_id")
        public static let actor = Column("actor")
        public static let action = Column("action")
        public static let createdAt = Column("created_at")
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
