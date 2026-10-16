# Macタスク管理アプリ 設計ドキュメント

Oct 14, 2026 · @荒木

## 概要

macOSのデスクトップウィジェットでタスクを常時表示し、Claude DesktopやClaude CodeからMCP経由でタスクを読み書きできる個人用タスク管理アプリを作る。全コンポーネントをSwiftで実装し、対象はmacOS 14 Sonoma以降とする。

- **AIの位置づけ**: アプリ内にLLM呼び出しは持たず、MCPサーバーとしてタスク操作を外部のAIに公開する。自前のAI機能は後から追加する
- **データ**: ローカルのSQLiteを唯一の正とし、クラウド同期はスコープ外
- **言語統一の理由**: データ層を1つのSwift Packageにまとめ、本体・ウィジェット・MCPサーバーの3つで同じモデルとDBコードを共有するため

## 全体構成

本体・ウィジェット・MCPサーバーの3プロセスが、共有パッケージTaskCoreを通じて同じSQLiteを読み書きする。MCPサーバーとウィジェット拡張は本体のアプリバンドルに同梱する。

&#91;embedded content: 全体構成 · 4ターゲットと共有DB\]

```
TaskApp/
├── TaskCore/            # Swift Package（共有）
│   ├── Models           # Task, Project
│   ├── Database         # GRDB、マイグレーション、Repository
│   └── ChangeNotifier   # Darwin Notificationの送受信
├── TaskApp/             # 本体：メニューバー常駐 + 一覧ウィンドウ
├── TaskWidget/          # Widget Extension（Contents/PlugIns）
└── TaskMCP/             # MCPサーバー（Contents/Helpers）
```

## データ層

GRDB.swift + SQLiteを採用し、DBファイルはApp Groupの共有コンテナ（`~/Library/Group Containers/<group-id>/tasks.sqlite`）に置く。3プロセスから同時に読み書きするため、WALモードを有効にする。

SwiftDataを選ばない理由は3つある。外部プロセスからの書き込みの扱い、マイグレーションの見通し、SQLを直接書ける点で、GRDBのほうがこの構成に向いている。

```sql
CREATE TABLE project (
  id TEXT PRIMARY KEY,           -- UUID
  name TEXT NOT NULL,
  sort_order INTEGER NOT NULL
);

CREATE TABLE task (
  id TEXT PRIMARY KEY,
  project_id TEXT REFERENCES project(id),
  title TEXT NOT NULL,
  notes TEXT,
  status TEXT NOT NULL,          -- todo / doing / done
  priority INTEGER,
  due_at DATETIME,
  sort_order INTEGER NOT NULL,
  created_by TEXT NOT NULL,      -- user / ai
  created_at DATETIME NOT NULL,
  updated_at DATETIME NOT NULL,
  completed_at DATETIME,
  deleted_at DATETIME            -- 論理削除
);

CREATE TABLE activity_log (
  id INTEGER PRIMARY KEY,
  task_id TEXT NOT NULL,
  actor TEXT NOT NULL,           -- user / ai / widget
  action TEXT NOT NULL,          -- create / update / complete / archive
  diff TEXT,                     -- JSON
  created_at DATETIME NOT NULL
);
```

`created_by` と `activity_log` は、AIによる変更をUIで見分け、取り消せるようにするために持つ。削除も同じ理由で論理削除にする。

## プロセス間の変更通知

GRDBの変更監視は同一プロセス内しか拾えないため、プロセス間はDarwin Notification（`CFNotificationCenterGetDarwinNotifyCenter`）で「変わった」ことだけを伝える。通知はペイロードを持てないので、受信側は必ずDBを読み直す。

&#91;embedded content: 変更通知の流れ · 書き込みからウィジェット再描画まで\]

- 本体自身が書き込んだときは、通知を待たずに直接 `reloadAllTimelines()` を呼ぶ
- AIが短時間に複数件を書き込む場合に備え、受信側で数百ミリ秒のデバウンスを入れる
- 通知名はTaskCoreの定数として3ターゲットで共有する

## ウィジェット

WidgetKitの `AppIntentConfiguration` で作り、デスクトップ上でタスクの確認と完了チェックができるようにする。テキスト入力はWidgetKitの制約でできないため、タスクの追加は本体側で受ける。

- **表示対象の設定**: ウィジェットごとに「今日のタスク」「特定プロジェクト」「優先度が高いもの」から選べるようにする
- **完了チェック**: 各行に `Toggle(isOn:intent:)` を置き、`CompleteTaskIntent` がTaskCore経由でDBを更新する（`actor = widget` でログを残す）
- **タップ時の動作**: `widgetURL` のディープリンクで、本体の該当タスクを開く
- **サイズ**: medium（5件程度）とlarge（10件程度）から始める
- **更新ポリシー**: 本体からの即時更新に加え、タイムラインに15〜30分間隔の定期更新を入れて保険にする

## 本体アプリ

`MenuBarExtra` でメニューバーに常駐させ、タスクの追加と編集、プロセス間通知の受信を担う。常駐させることで、MCP経由の変更を受けてウィジェットを即時更新する役割も果たす。

- **メニューバー**: ポップオーバーにクイック入力欄と今日のタスク一覧を置く
- **グローバルショートカット**: sindresorhus/KeyboardShortcuts で、どこからでもクイック入力を呼び出せるようにする
- **メインウィンドウ**: タスク一覧、編集、activity\_logの閲覧（AIが行った変更の確認と取り消し）
- **ログイン時起動**: `SMAppService.mainApp` で登録する

## MCPサーバー

公式のmodelcontextprotocol/swift-sdkを使い、stdioで動く実行ファイルとしてアプリバンドル内（`Contents/Helpers/TaskMCP`）に同梱する。Claude DesktopやClaude Codeの設定ではこのパスを指定する。

| ツール | 内容 |
| --- | --- |
| `list_tasks` | status・プロジェクト・期限などで絞り込んで一覧を返す |
| `create_task` | タスクを追加する（`created_by = ai`） |
| `update_task` | タイトル、メモ、優先度、期限などを変更する |
| `complete_task` | タスクを完了にする |
| `archive_task` | 論理削除する。物理削除はAIに公開しない |
| `list_projects` | プロジェクト一覧を返す |

書き込み系のツールは、必ず `activity_log` に `actor = ai` で記録し、書き込み後にDarwin Notificationを投げる。

## 署名・配布とリスク

App Groupとウィジェットの署名が最大の難所なので、開発の最初に通す。配布まで考えるとApple Developer Programへの加入は実質必須となる。

| リスク | 対策 |
| --- | --- |
| ウィジェット拡張はサンドボックス必須で、App Groupの設定を誤るとDBが見えない | 最初のマイルストーンでApp Groupと署名を通す |
| macOS 15以降、他アプリのGroup Containerへのアクセスで確認ダイアログが出る場合がある | TaskMCPも同じTeamで署名し、同じApp Groupのentitlementを付ける |
| 本体が起動していないとウィジェットが即時更新されない | ログイン時起動と、タイムラインの定期更新で補う |
| 3プロセスの同時書き込み | WALモードとbusy timeoutを設定し、書き込みは短いトランザクションに限る |
| 配布時にGatekeeperで止められる | Developer IDで署名し、ノータライズする |

## 開発ステップ

ネイティブ側の難所（署名、ウィジェット、プロセス間通知）をM1〜M3で片付け、M4からAI連動を試す。

- [x] **M1 土台**: TaskCoreパッケージとマイグレーションを作り、App Groupと署名を通す
- [x] **M2 表示**: 本体からタスクを追加し、ウィジェットに表示されるところまで作る
- [x] **M3 双方向**: ウィジェットからの完了チェックと、Darwin Notificationによる双方向の反映を作る
- [x] **M4 AI連動**: TaskMCPを追加し、Claude Codeからタスクを追加・完了できるようにする
- [x] **M5 UX**: メニューバーのクイック入力、グローバルショートカット、activity\_logからの取り消しを詰める

期限は未定。
