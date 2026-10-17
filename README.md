# watashi-no-hikidashi(私の引き出し)

A macOS task manager that lives on your desktop. View tasks in a widget, and let AI manage them via MCP.

macOS のデスクトップウィジェットでタスクを常時表示し、Claude Desktop や Claude Code から MCP 経由でタスクを読み書きできる個人用タスク管理アプリ。全コンポーネントを Swift で実装し、対象は macOS 14 Sonoma 以降。

## 構成

本体・ウィジェット・MCP サーバーの 3 プロセスが、共有パッケージ TaskCore を通じて同じ SQLite(App Group の共有コンテナ内)を読み書きする。

```
.
├── project.yml          # XcodeGen 定義(TaskApp.xcodeproj はここから生成する)
├── TaskCore/            # Swift Package(共有)
│   └── Sources/TaskCore/
│       ├── AppGroup.swift         # App Group 識別子と DB パス
│       ├── Models/                # TaskItem, Project, ActivityLog, 各種 enum
│       ├── Database/              # GRDB、マイグレーション、TaskRepository
│       └── ChangeNotifier/        # Darwin Notification の送受信
├── TaskApp/             # 本体: メニューバー常駐(MenuBarExtra)
├── TaskWidget/          # Widget Extension(Contents/PlugIns)
└── TaskMCP/             # MCP サーバー(Contents/Helpers、stdio)
```

## 開発

必要なもの: Xcode 26 以降、[XcodeGen](https://github.com/yonaskolb/XcodeGen)(`brew install xcodegen`)。

```bash
# Xcode プロジェクトを生成する(project.yml を変えたら再実行)
xcodegen generate

# TaskCore のテスト
cd TaskCore && swift test

# アプリのビルド
xcodebuild -project TaskApp.xcodeproj -scheme TaskApp -configuration Debug build
```

生成された `TaskApp.xcodeproj` は git 管理外。Xcode で開くときも先に `xcodegen generate` を実行する。

### 署名と App Group

- 署名は `project.yml` の `DEVELOPMENT_TEAM` / `CODE_SIGN_IDENTITY` で決まる。現在は Developer ID Application 証明書による手動署名。
- App Group は Team ID 接頭辞形式(`<TeamID>.dev.araki.hikidashi`)。この形式はプロビジョニングプロファイルを要求せず、同じ Team で署名した 3 プロセスがダイアログなしで共有コンテナにアクセスできる。
- 識別子を変えるときは `project.yml` の entitlements と `TaskCore/Sources/TaskCore/AppGroup.swift` の両方を揃える。
- DB ファイル: `~/Library/Group Containers/<TeamID>.dev.araki.hikidashi/tasks.sqlite`(WAL モード)。

### タスクのタイプ

タスクは「いつまでにやるか」の約束の強さでタイプを持つ。期限はタイプから自動で決まり、タイプ省略時は期限の有無から推定する。

| タイプ | 意味 | 期限 | ウィジェット |
| --- | --- | --- | --- |
| `today` 今日 | 今日中に終える | その日の 23:59:59 | 最上段。進捗バー付き。日付をまたいだ未完了は「期限切れ」で残る |
| `deadline` 期限あり | 日付までに終える | 必須 | 期限順。「今日」「あと n 日」「期限切れ」のバッジ |
| `sprint` スプリント | 今のスプリント内に終える | スプリント最終日の 23:59:59 | 期間・残り日数・進捗付きのセクション |
| `open_ended` いつか | いつかやる | なし | 件数だけ |

スプリントは固定長で、既定は水曜開始の 7 日(水〜火)。一覧ウィンドウのツールバーで開始曜日と長さを変えられ、設定は `setting` テーブルで 3 プロセスが共有する。

### ウィジェット

small は今日の進捗、medium は今日と近い期限、large は全セクション。ウィジェットの編集で「期限あり」「スプリント」「いつかの件数」の表示を切り替えられる。行の丸で完了、タイトルで本体の該当タスクを開く。

### 動作確認のログ

本体・ウィジェット・MCP は `subsystem == "dev.araki.hikidashi"` で os_log に出すので、プロセス間の往復は次で追える。

```bash
/usr/bin/log stream --info --predicate 'subsystem == "dev.araki.hikidashi"' --style compact
```

## MCP サーバーを Claude につなぐ

MCP サーバーはアプリバンドル内の `Contents/Helpers/TaskMCP` にある。ビルドしたアプリを `/Applications` などパスが変わらない場所に置き、その中の実行ファイルを指定する。

```bash
# Claude Code
claude mcp add hikidashi -- /Applications/TaskApp.app/Contents/Helpers/TaskMCP
```

Claude Desktop は `~/Library/Application Support/Claude/claude_desktop_config.json` に追加する。

```json
{
  "mcpServers": {
    "hikidashi": {
      "command": "/Applications/TaskApp.app/Contents/Helpers/TaskMCP"
    }
  }
}
```

接続前に共有 DB へ到達できるかは `TaskMCP --check` で確認できる。

| ツール | 内容 |
| --- | --- |
| `list_tasks` | status・プロジェクト・期限・優先度で絞り込んで一覧を返す |
| `create_task` | タスクを追加する(`created_by = ai`) |
| `update_task` | タイトル、メモ、優先度、期限などを変更する。null でクリア |
| `complete_task` | タスクを完了にする |
| `archive_task` | 論理削除する。物理削除は公開しない |
| `list_projects` | プロジェクト一覧を返す |

書き込み系のツールは `activity_log` に `actor = ai` で記録し、書き込み後に Darwin Notification を投げる。

## 開発ステップ

- [x] **M1 土台**: TaskCore パッケージとマイグレーション、App Group と署名
- [x] **M2 表示**: 本体からタスクを追加し、ウィジェットに表示する
- [x] **M3 双方向**: ウィジェットからの完了チェックと、Darwin Notification による双方向の反映
- [x] **M4 AI 連動**: TaskMCP を modelcontextprotocol/swift-sdk で実装し、Claude Code からタスクを追加・完了できるようにする
- [x] **M5 UX**: メニューバーのクイック入力、グローバルショートカット、activity_log からの取り消し

## License

MIT
