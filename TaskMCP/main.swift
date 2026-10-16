import Foundation
import TaskCore

// M1 時点のスタブ。共有コンテナの DB に Helper プロセスから到達できることを確認する。
// M4 で modelcontextprotocol/swift-sdk による stdio MCP サーバーに置き換える。

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

do {
    let url = try AppGroup.databaseURL()
    let repository = TaskRepository(database: try AppDatabase.open(at: url), notifier: ChangeNotifier())
    let args = Array(CommandLine.arguments.dropFirst())

    switch args.first {
    case "add":
        let title = args.dropFirst().joined(separator: " ")
        let task = try repository.createTask(NewTask(title: title), actor: .ai)
        print("created \(task.id): \(task.title)")
    case "list", nil:
        let tasks = try repository.tasks(matching: .open)
        print("db: \(url.path)")
        print("\(tasks.count) open task(s)")
        for task in tasks {
            print("- [\(task.status.rawValue)] \(task.title) (\(task.createdBy.rawValue))")
        }
    default:
        fail("usage: TaskMCP [list | add <title>]")
    }
} catch {
    fail("error: \(error.localizedDescription)")
}
