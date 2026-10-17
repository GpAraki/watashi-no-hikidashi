import Foundation
import MCP
import TaskCore

/// MCP ツールの定義と実行。すべて `TaskRepository` 経由で DB を触る(actor = ai)。
struct TaskTools: Sendable {
    let repository: TaskRepository

    static let serverInstructions = """
        個人用タスク管理アプリ「私の引き出し」のタスクを読み書きします。
        - status は todo / doing / done。
        - type はタスクの約束の強さ: today(今日中。期限は自動でその日の終わり)、sprint(今のスプリント内。期限は自動でスプリント終了)、
          deadline(日付まで。due_at 必須)、open_ended(いつか。期限なし)。
          type を省略すると due_at があれば deadline、なければ open_ended になる。「今日やる」なら today、「今週中」なら sprint を選ぶ。
        - priority は 1(低)〜3(高)の整数。
        - 日時は ISO 8601(例: 2026-10-18T15:00:00+09:00)。日付だけ(2026-10-18)を渡すとその日の 0 時として扱います。
        - 削除は archive_task による論理削除のみです。
        - AI が行った変更はすべて履歴に残り、ユーザーが取り消せます。
        """

    // MARK: - ツール定義

    private static let statusSchema: Value = .object([
        "type": "string",
        "enum": .array(TaskStatus.allCases.map { .string($0.rawValue) }),
    ])
    private static let typeSchema: Value = .object([
        "type": "string",
        "enum": .array(TaskType.allCases.map { .string($0.rawValue) }),
        "description": "today = 今日中, sprint = 今のスプリント内, deadline = 日付まで(due_at 必須), open_ended = いつか",
    ])
    private static let prioritySchema: Value = .object([
        "type": "integer", "minimum": 1, "maximum": 3,
        "description": "1 = 低, 2 = 中, 3 = 高",
    ])
    private static let dateSchema: Value = .object([
        "type": "string",
        "description": "ISO 8601 の日時、または YYYY-MM-DD",
    ])
    private static let idSchema: Value = .object(["type": "string", "description": "タスクの id(UUID)"])

    let tools: [Tool] = [
        Tool(
            name: "list_tasks",
            description: "タスクを一覧する。既定では論理削除されていないものをすべて返す。status・type・プロジェクト・期限・優先度で絞り込める。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "status": .object([
                        "description": "絞り込む status。複数可。",
                        "type": "array",
                        "items": statusSchema,
                    ]),
                    "type": .object([
                        "description": "絞り込む type。複数可。",
                        "type": "array",
                        "items": typeSchema,
                    ]),
                    "project_id": .object(["type": "string"]),
                    "due_before": dateSchema,
                    "due_after": dateSchema,
                    "min_priority": prioritySchema,
                    "include_archived": .object(["type": "boolean", "description": "論理削除済みも含める"]),
                    "limit": .object(["type": "integer", "minimum": 1]),
                ]),
            ]),
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
        Tool(
            name: "create_task",
            description: "タスクを追加する(created_by = ai)。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "title": .object(["type": "string"]),
                    "notes": .object(["type": "string"]),
                    "project_id": .object(["type": "string", "description": "list_projects で得た id"]),
                    "status": statusSchema,
                    "type": typeSchema,
                    "priority": prioritySchema,
                    "due_at": dateSchema,
                ]),
                "required": .array(["title"]),
            ])
        ),
        Tool(
            name: "update_task",
            description: "タスクのタイトル、メモ、プロジェクト、type、優先度、期限、status、並び順を変更する。渡したフィールドだけが変わる。notes / project_id / priority / due_at に null を渡すとクリアされる(due_at を null にすると open_ended になる)。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "id": idSchema,
                    "title": .object(["type": "string"]),
                    "notes": .object(["type": .array(["string", "null"])]),
                    "project_id": .object(["type": .array(["string", "null"])]),
                    "status": statusSchema,
                    "type": .object([
                        "type": "string",
                        "enum": .array(TaskType.allCases.map { .string($0.rawValue) }),
                        "description": "タイプを変える。due_at を同時に渡さなければ期限はタイプの既定値に置き直される",
                    ]),
                    "priority": .object([
                        "type": .array(["integer", "null"]), "minimum": 1, "maximum": 3,
                        "description": "1 = 低, 2 = 中, 3 = 高。null でクリア",
                    ]),
                    "due_at": .object([
                        "type": .array(["string", "null"]),
                        "description": "ISO 8601 の日時、または YYYY-MM-DD。null でクリア",
                    ]),
                    "sort_order": .object(["type": "integer"]),
                ]),
                "required": .array(["id"]),
            ])
        ),
        Tool(
            name: "complete_task",
            description: "タスクを完了(done)にする。",
            inputSchema: .object([
                "type": "object",
                "properties": .object(["id": idSchema]),
                "required": .array(["id"]),
            ]),
            annotations: Tool.Annotations(idempotentHint: true)
        ),
        Tool(
            name: "archive_task",
            description: "タスクを論理削除する。一覧から消えるが履歴は残り、ユーザーが復元できる。物理削除はできない。",
            inputSchema: .object([
                "type": "object",
                "properties": .object(["id": idSchema]),
                "required": .array(["id"]),
            ]),
            annotations: Tool.Annotations(destructiveHint: true, idempotentHint: true)
        ),
        Tool(
            name: "list_projects",
            description: "プロジェクトの一覧を返す。",
            inputSchema: .object(["type": "object", "properties": .object([:])]),
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
    ]

    // MARK: - 実行

    func call(_ params: CallTool.Parameters) async -> CallTool.Result {
        let args = params.arguments ?? [:]
        do {
            switch params.name {
            case "list_tasks":
                let filter = TaskFilter(
                    statuses: try args.statuses("status"),
                    types: try args.types("type"),
                    projectId: try args.string("project_id"),
                    dueBefore: try args.date("due_before"),
                    dueAfter: try args.date("due_after"),
                    minimumPriority: try args.priority("min_priority"),
                    includeArchived: try args.bool("include_archived") ?? false,
                    limit: try args.int("limit")
                )
                return try result(try repository.tasks(matching: filter))

            case "create_task":
                let new = NewTask(
                    title: try args.required("title", args.string),
                    notes: try args.string("notes"),
                    projectId: try args.string("project_id"),
                    status: try args.status("status") ?? .todo,
                    type: try args.type("type"),
                    priority: try args.priority("priority"),
                    dueAt: try args.date("due_at")
                )
                return try result(try repository.createTask(new, actor: .ai))

            case "update_task":
                let id = try args.required("id", args.string)
                let changes = TaskChanges(
                    title: try args.nonNullPatch("title", args.string),
                    notes: try args.patch("notes", args.string),
                    projectId: try args.patch("project_id", args.string),
                    status: try args.nonNullPatch("status", args.status),
                    type: try args.nonNullPatch("type", args.type),
                    priority: try args.patch("priority", args.priority),
                    dueAt: try args.patch("due_at", args.date),
                    sortOrder: try args.nonNullPatch("sort_order", args.int)
                )
                return try result(try repository.updateTask(id: id, changes: changes, actor: .ai))

            case "complete_task":
                let id = try args.required("id", args.string)
                return try result(try repository.completeTask(id: id, actor: .ai))

            case "archive_task":
                let id = try args.required("id", args.string)
                return try result(try repository.archiveTask(id: id, actor: .ai))

            case "list_projects":
                return try result(try repository.projects())

            default:
                return failure("unknown tool: \(params.name)")
            }
        } catch {
            return failure(error.localizedDescription)
        }
    }

    // MARK: - 出力

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return e
    }()

    private func result<T: Encodable>(_ value: T) throws -> CallTool.Result {
        let data = try Self.encoder.encode(value)
        let text = String(decoding: data, as: UTF8.self)
        let structured = try JSONDecoder().decode(Value.self, from: data)
        // structuredContent は仕様上オブジェクトなので、配列は包む。
        let wrapped: Value = structured.arrayValue != nil ? .object(["items": structured]) : structured
        return CallTool.Result(content: [.text(text)], structuredContent: Optional(wrapped), isError: false)
    }

    private func failure(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(message)], isError: true)
    }
}

// MARK: - 引数の取り出し

struct ToolArgumentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension [String: Value] {
    func required<T>(_ key: String, _ read: (String) throws -> T?) throws -> T {
        guard let value = try read(key) else {
            throw ToolArgumentError(message: "'\(key)' は必須です")
        }
        return value
    }

    /// キーがあれば `.set(値)`(null なら `.set(nil)`)、なければ `.unchanged`。
    func patch<T: Sendable>(_ key: String, _ read: (String) throws -> T?) throws -> Patch<T?> {
        guard let raw = self[key] else { return .unchanged }
        if raw.isNull { return .set(nil) }
        return .set(try read(key))
    }

    /// null を許さないフィールド用。キーがなければ `.unchanged`。
    func nonNullPatch<T: Sendable>(_ key: String, _ read: (String) throws -> T?) throws -> Patch<T> {
        guard let raw = self[key] else { return .unchanged }
        guard !raw.isNull, let value = try read(key) else {
            throw ToolArgumentError(message: "'\(key)' に null は指定できません")
        }
        return .set(value)
    }

    func string(_ key: String) throws -> String? {
        guard let raw = self[key], !raw.isNull else { return nil }
        guard let s = raw.stringValue else { throw ToolArgumentError(message: "'\(key)' は文字列で指定してください") }
        return s
    }

    func int(_ key: String) throws -> Int? {
        guard let raw = self[key], !raw.isNull else { return nil }
        if let i = raw.intValue { return i }
        if let d = raw.doubleValue, d.rounded() == d { return Int(d) }
        throw ToolArgumentError(message: "'\(key)' は整数で指定してください")
    }

    func bool(_ key: String) throws -> Bool? {
        guard let raw = self[key], !raw.isNull else { return nil }
        guard let b = raw.boolValue else { throw ToolArgumentError(message: "'\(key)' は true/false で指定してください") }
        return b
    }

    func status(_ key: String) throws -> TaskStatus? {
        guard let s = try string(key) else { return nil }
        guard let status = TaskStatus(rawValue: s) else {
            throw ToolArgumentError(message: "'\(key)' は todo / doing / done のいずれかです")
        }
        return status
    }

    func statuses(_ key: String) throws -> Set<TaskStatus>? {
        guard let raw = self[key], !raw.isNull else { return nil }
        let items: [Value] = raw.arrayValue ?? [raw]
        var set = Set<TaskStatus>()
        for item in items {
            guard let s = item.stringValue, let status = TaskStatus(rawValue: s) else {
                throw ToolArgumentError(message: "'\(key)' は todo / doing / done の配列です")
            }
            set.insert(status)
        }
        return set
    }

    func type(_ key: String) throws -> TaskType? {
        guard let raw = self[key], !raw.isNull else { return nil }
        guard let s = raw.stringValue, let t = TaskType(rawValue: s) else {
            throw ToolArgumentError(message: "'\(key)' は \(TaskType.allCases.map(\.rawValue).joined(separator: " / ")) のいずれかです")
        }
        return t
    }

    func types(_ key: String) throws -> Set<TaskType>? {
        guard let raw = self[key], !raw.isNull else { return nil }
        let items: [Value] = raw.arrayValue ?? [raw]
        var set = Set<TaskType>()
        for item in items {
            guard let s = item.stringValue, let t = TaskType(rawValue: s) else {
                throw ToolArgumentError(message: "'\(key)' は \(TaskType.allCases.map(\.rawValue).joined(separator: " / ")) の配列です")
            }
            set.insert(t)
        }
        return set
    }

    func priority(_ key: String) throws -> TaskPriority? {
        guard let i = try int(key) else { return nil }
        guard let p = TaskPriority(rawValue: i) else {
            throw ToolArgumentError(message: "'\(key)' は 1〜3 の整数です")
        }
        return p
    }

    func date(_ key: String) throws -> Date? {
        guard let s = try string(key) else { return nil }
        if let d = DateParsing.parse(s) { return d }
        throw ToolArgumentError(message: "'\(key)' は ISO 8601 の日時か YYYY-MM-DD で指定してください: \(s)")
    }
}

enum DateParsing {
    static func parse(_ s: String) -> Date? {
        let text = s.trimmingCharacters(in: .whitespaces)
        if let d = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .colon)) { return d }
        if let d = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: false).timeZone(separator: .colon)) { return d }
        if let d = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: false).timeZone(separator: .omitted)) { return d }
        if let d = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: false)) { return d }
        if let d = try? Date(text, strategy: .iso8601.year().month().day()) {
            // 日付だけならローカルタイムのその日の 0 時として扱う。
            let utc = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: d)
            var local = Calendar.current
            local.timeZone = .current
            return local.date(from: DateComponents(year: utc.year, month: utc.month, day: utc.day))
        }
        return nil
    }
}
