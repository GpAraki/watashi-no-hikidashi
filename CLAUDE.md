# CLAUDE.md

macOS 向け個人用タスク管理アプリ。デスクトップウィジェットで表示し、MCP 経由で AI が読み書きする。設計の全体像は README を参照。

## 構成と役割

- `TaskCore/` — 共有 Swift Package。モデル、GRDB による DB アクセス、マイグレーション、`TaskRepository`、`ChangeNotifier`。本体・ウィジェット・MCP の 3 ターゲットはすべてここ経由で DB を触る。DB コードをターゲット側に書かない。
- `TaskApp/` — メニューバー常駐の本体(SwiftUI `MenuBarExtra`)。他プロセスからの変更通知を受けて `WidgetCenter.reloadAllTimelines()` を呼ぶ役割も持つ。
- `TaskWidget/` — WidgetKit 拡張(`AppIntentConfiguration`)。
- `TaskMCP/` — stdio で動く MCP サーバー(modelcontextprotocol/swift-sdk)。アプリバンドルの `Contents/Helpers/` に同梱。ツール定義と引数の解釈は `TaskMCP/TaskTools.swift`。stdout は JSON-RPC 専用なので診断出力は stderr に出す。`TaskMCP --check` で共有 DB への到達だけ確認できる。
- `project.yml` — XcodeGen 定義。`TaskApp.xcodeproj` は生成物で git 管理外。

## コマンド

```bash
xcodegen generate                       # project.yml を変えたら必ず実行
cd TaskCore && swift test               # TaskCore の単体テスト(XCTest)
xcodebuild -project TaskApp.xcodeproj -scheme TaskMCP -configuration Debug build   # MCP サーバーだけ
xcodebuild -project TaskApp.xcodeproj -scheme TaskApp -configuration Debug build
```

## 守ること

- **タスクの型名は `TaskItem`**。Swift Concurrency の `Task` と衝突するため。テーブル名は `task` のまま。
- **書き込みは必ず `TaskRepository` 経由**。`activity_log` への記録(actor = user / ai / widget)と、書き込み後の Darwin Notification 送信をまとめて行っている。
- **削除は論理削除**(`deleted_at`)。物理削除 API は作らない。AI には `archive_task` だけを公開する。
- **更新の「変更しない」と「nil にする」は `Patch<T>`** で区別する(`.unchanged` / `.set(nil)`)。
- **タスクのタイプ(`TaskType`)が期限を決める**。当日は今日の終わり、スプリントは `SprintSchedule`(`setting` テーブル、既定は水曜開始 7 日)の終わり、有期限は `due_at` 必須、無期限は常に nil。この解決は `TaskRepository.resolveDueDate` に集約し、UI 側で期限を計算しない。タイプ省略時は期限の有無から推定する。
- **プロセス間通知はペイロードを持たない**。受信側は必ず DB を読み直す。受信側で数百 ms のデバウンスを入れる(`ChangeNotifier.observe(debounce:)`)。
- **App Group 識別子は Team ID 接頭辞形式**。変更時は `project.yml` と `TaskCore/Sources/TaskCore/AppGroup.swift` を同時に直す。
- Swift 6 言語モード、strict concurrency = complete。`Sendable` でない Foundation のフォーマッタを static に置かない(`Date.ISO8601FormatStyle` などを使う)。
- 新しいマイグレーションは `AppDatabase.migrator` に追記する。登録済みのマイグレーションは書き換えない。
- MCP ツールのエラーは例外を投げずに `isError: true` の結果で返す(モデルが読んで直せるように)。

## 署名まわりの注意

- 現在は Developer ID Application 証明書で手動署名。CLI ビルド時、初回は codesign がキーチェーンの許可ダイアログで止まることがある(「常に許可」で解消)。
- Xcode の自動署名に戻すには Apple Developer で最新の利用規約に同意が必要。
