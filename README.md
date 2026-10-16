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
└── TaskMCP/             # MCP サーバー(Contents/Helpers)。現在はスタブ
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

### ウィジェットの表示範囲

ウィジェットの既定の範囲「今日」は期限が今日までの未完了タスクだけを出す。期限なしのタスク(AI が期限を付けずに作ったものなど)も見たいときは、ウィジェットの編集で範囲を「すべての未完了」にする。行の丸で完了、タイトルで本体の該当タスクを開く。

### 動作確認のログ

本体・ウィジェット・MCP は `subsystem == "dev.araki.hikidashi"` で os_log に出すので、プロセス間の往復は次で追える。

```bash
/usr/bin/log stream --info --predicate 'subsystem == "dev.araki.hikidashi"' --style compact
```

## 開発ステップ

- [x] **M1 土台**: TaskCore パッケージとマイグレーション、App Group と署名
- [x] **M2 表示**: 本体からタスクを追加し、ウィジェットに表示する
- [x] **M3 双方向**: ウィジェットからの完了チェックと、Darwin Notification による双方向の反映
- [ ] **M4 AI 連動**: TaskMCP を modelcontextprotocol/swift-sdk で実装し、Claude Code からタスクを追加・完了できるようにする
- [x] **M5 UX**: メニューバーのクイック入力、グローバルショートカット、activity_log からの取り消し

## License

MIT
