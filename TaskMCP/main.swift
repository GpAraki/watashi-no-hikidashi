import Foundation
import MCP
import TaskCore

// 「私の引き出し」の MCP サーバー。stdio で動き、アプリバンドルの Contents/Helpers に同梱される。
// stdout は JSON-RPC 専用なので、診断出力はすべて stderr に出す。

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func openRepository() throws -> TaskRepository {
    let url = try AppGroup.databaseURL()
    return TaskRepository(database: try AppDatabase.open(at: url), notifier: ChangeNotifier())
}

let arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first {
case "--check":
    // 接続設定のデバッグ用: 共有 DB に到達できるかだけを確認する。
    do {
        let repository = try openRepository()
        let tasks = try repository.tasks(matching: .open)
        print("db: \(try AppGroup.databaseURL().path)")
        print("\(tasks.count) open task(s)")
        for task in tasks {
            print("- [\(task.status.rawValue)] \(task.title) (\(task.createdBy.rawValue))")
        }
    } catch {
        log("error: \(error.localizedDescription)")
        exit(1)
    }

case "--help", "-h":
    print("usage: TaskMCP [--check]\n  (引数なし) stdio で MCP サーバーとして動く\n  --check    共有 DB への到達を確認して終了する")

default:
    do {
        let tools = TaskTools(repository: try openRepository())
        let server = Server(
            name: "hikidashi-tasks",
            version: "0.1.0",
            title: "私の引き出し",
            instructions: TaskTools.serverInstructions,
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: tools.tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            await tools.call(params)
        }
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    } catch {
        log("TaskMCP failed: \(error.localizedDescription)")
        exit(1)
    }
}
