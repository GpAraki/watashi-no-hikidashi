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
        - タスクには外部リンク(Notion / Jira / GitHub などの URL)を複数付けられます。参照先があるタスクは notes に URL を書くのではなく、
          create_task の links か add_link を使ってください。list_tasks の結果には links が含まれます。
        - add_comment でタスクに状況や判断理由を書き残せます。進捗を伝えたいとき、保留にした理由、次にやることなどはコメントに書いてください(タイトルやメモの上書きではなく)。
        - AI が行った変更はすべて履歴に残り、ユーザーが取り消せます。

        Jira / GitHub などの課題(issue、チケット、PR)を扱ったときの手順:
        1. まず list_tasks を link_url にその課題の URL を渡して呼び、同じ URL をリンクに持つタスクを探す。
           URL の表記が揺れそうなら(クエリ付き、末尾スラッシュなど)、link_contains に課題キー(例: PROJ-123)や
           `owner/repo/issues/42` を渡して部分一致で探し、結果の links を見て同じ課題か確かめる。
        2. 見つかったら、そのタスクの status を課題の状態に揃え(着手したら doing、終わったら complete_task)、
           何をしたか・何が残っているかを add_comment で書く。
        3. 見つからなければ、create_task を links にその課題の URL を入れて呼ぶ(add_link を別に呼ぶ必要はない)。
        4. 同じ URL のタスクを二重に作らない。作る前に必ず 1 を行う。
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
            description: "タスクを一覧する。既定では論理削除されていないものをすべて返す。status・type・プロジェクト・期限・優先度・リンク URL で絞り込める。Jira / GitHub の課題に対応するタスクを探すときは、link_url(完全一致)か link_contains(部分一致。課題キーなど)を使う。各タスクの links に付いている URL が入る。",
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
                    "link_url": .object([
                        "type": "string",
                        "description": "この URL と完全一致するリンクを持つタスクに絞る(例: https://example.atlassian.net/browse/PROJ-123)。課題を扱うときは最初にこれで探す",
                    ]),
                    "link_contains": .object([
                        "type": "string",
                        "description": "この文字列をリンク URL に含むタスクに絞る(大文字小文字は区別しない)。Jira の課題キー(PROJ-123)や GitHub の owner/repo/issues/42 など。PROJ-1 は PROJ-12 にも一致するので、結果の links で確かめる",
                    ]),
                    "include_archived": .object(["type": "boolean", "description": "論理削除済みも含める"]),
                    "limit": .object(["type": "integer", "minimum": 1]),
                ]),
            ]),
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
        Tool(
            name: "create_task",
            description: "タスクを追加する(created_by = ai)。Jira / GitHub の課題から起こすときは links にその URL を入れ、先に list_tasks の link_url で同じ URL のタスクがないことを確かめる。結果には付けた links が含まれる。",
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
                    "links": .object([
                        "type": "array",
                        "description": "作成と同時に付ける外部リンク。URL の文字列、または {url, label} のオブジェクト。1 つでも不正な URL があればタスクは作られない",
                        "items": .object([
                            "anyOf": .array([
                                .object(["type": "string", "description": "https:// から始まる URL"]),
                                .object([
                                    "type": "object",
                                    "properties": .object([
                                        "url": .object(["type": "string", "description": "https:// から始まる URL"]),
                                        "label": .object(["type": "string", "description": "表示名(省略可。省略するとサービス名)"]),
                                    ]),
                                    "required": .array(["url"]),
                                ]),
                            ]),
                        ]),
                    ]),
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
            description: "タスクを完了(done)にする。対応する Jira / GitHub の課題を閉じたときも、list_tasks の link_url で見つけたタスクをこれで完了にする。",
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
            name: "add_comment",
            description: "タスクにコメントを追加する(author = ai)。進捗、保留の理由、次の一手などの状況を書く。Jira / GitHub の課題を進めたら、対応するタスク(list_tasks の link_url で探す)に何をしたかをここに書く。ユーザーはアプリで読んで返信・取り消しができる。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "id": idSchema,
                    "body": .object(["type": "string", "description": "コメント本文"]),
                ]),
                "required": .array(["id", "body"]),
            ])
        ),
        Tool(
            name: "list_comments",
            description: "タスクのコメントを古い順に返す。人(user)・AI(ai)・ウィジェット(widget)のどれが書いたかが author に入る。",
            inputSchema: .object([
                "type": "object",
                "properties": .object(["id": idSchema]),
                "required": .array(["id"]),
            ]),
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
        Tool(
            name: "add_link",
            description: "既存のタスクに外部リンク(Notion、Jira、GitHub、Figma など)を付ける。label を省略するとサービス名が表示名になる。同じ URL は二重に登録されない。新しく作るタスクには create_task の links を使う。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "id": idSchema,
                    "url": .object(["type": "string", "description": "https:// から始まる URL"]),
                    "label": .object(["type": "string", "description": "表示名(省略可)"]),
                ]),
                "required": .array(["id", "url"]),
            ])
        ),
        Tool(
            name: "remove_link",
            description: "タスクからリンクを外す(論理削除。ユーザーが操作履歴から戻せる)。link_id は list_tasks の links[].id。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "link_id": .object(["type": "integer"]),
                ]),
                "required": .array(["link_id"]),
            ])
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
                    linkURL: try args.string("link_url"),
                    linkContains: try args.string("link_contains"),
                    includeArchived: try args.bool("include_archived") ?? false,
                    limit: try args.int("limit")
                )
                let tasks = try repository.tasks(matching: filter)
                let links = try repository.linksByTask()
                return try result(tasks.map { TaskWithLinks(task: $0, links: links[$0.id] ?? []) })

            case "create_task":
                let new = NewTask(
                    title: try args.required("title", args.string),
                    notes: try args.string("notes"),
                    projectId: try args.string("project_id"),
                    status: try args.status("status") ?? .todo,
                    type: try args.type("type"),
                    priority: try args.priority("priority"),
                    dueAt: try args.date("due_at"),
                    links: try args.links("links")
                )
                let task = try repository.createTask(new, actor: .ai)
                return try result(TaskWithLinks(task: task, links: try repository.links(taskId: task.id)))

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

            case "add_link":
                let id = try args.required("id", args.string)
                let url = try args.required("url", args.string)
                return try result(try repository.addLink(taskId: id, url: url, label: try args.string("label"), actor: .ai))

            case "remove_link":
                let linkId = try args.required("link_id", args.int)
                return try result(try repository.removeLink(id: Int64(linkId), actor: .ai))

            case "add_comment":
                let id = try args.required("id", args.string)
                let body = try args.required("body", args.string)
                return try result(try repository.addComment(taskId: id, body: body, actor: .ai))

            case "list_comments":
                let id = try args.required("id", args.string)
                return try result(try repository.comments(taskId: id))

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

    /// `links` の要素は URL の文字列か `{url, label}` のオブジェクト。
    func links(_ key: String) throws -> [NewLink] {
        guard let raw = self[key], !raw.isNull else { return [] }
        let items: [Value] = raw.arrayValue ?? [raw]
        return try items.map { item in
            if let url = item.stringValue { return NewLink(url: url) }
            guard let object = item.objectValue else {
                throw ToolArgumentError(message: "'\(key)' の要素は URL の文字列か {url, label} のオブジェクトです")
            }
            let url = try object.required("url", object.string)
            return NewLink(url: url, label: try object.string("label"))
        }
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

/// list_tasks の 1 件。TaskItem のフィールドに links を足して出す。
struct TaskWithLinks: Encodable {
    let task: TaskItem
    let links: [TaskLink]

    enum ExtraKeys: String, CodingKey { case links }

    func encode(to encoder: Encoder) throws {
        try task.encode(to: encoder)
        var extra = encoder.container(keyedBy: ExtraKeys.self)
        try extra.encode(links, forKey: .links)
    }
}
