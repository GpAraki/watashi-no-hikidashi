# watashi-no-hikidashi(私の引き出し)

A macOS task manager that lives on your desktop. View tasks in a widget, and let AI manage them via MCP.

macOS のデスクトップウィジェットでタスクを常時表示し、Claude Desktop や Claude Code から MCP 経由でタスクを読み書きできる個人用タスク管理アプリ。全コンポーネントを Swift で実装し、対象は macOS 14 Sonoma 以降。

**ダウンロード**: [https://gparaki.github.io/watashi-no-hikidashi/](https://gparaki.github.io/watashi-no-hikidashi/)(署名・公証済みの zip。[Releases](https://github.com/GpAraki/watashi-no-hikidashi/releases) からも取得できる)

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

### メイン画面

ツールバーの「+」または ⌘N からタスクを追加できる。タイプが「期限あり」のときは追加時に日時を指定する。検索欄でタイトル・メモを検索できる。追加後は未完了一覧で作成したタスクを選択する。

編集フォームは自動保存。タイトルとメモは入力が 0.6 秒止まったとき、またはタスクを切り替えたときに保存し、選択項目は変更時に保存する。入力中は「保存待ち…」、書き込みに失敗した場合はエラーと再試行ボタンを表示する。

### どのアプリからでも追加(サービス)

テキストを選択して右クリック →「サービス」→「引き出しにタスクを追加」で、選択した内容を今日のタスクにする(1 行目がタイトル、残りがメモ、含まれる URL はリンク)。追加後はポップオーバーが開いてそのタスクが選ばれるので、タイプや期限はそこで変えられる。定義は `project.yml` の `NSServices`、受け口は `TaskApp/ServicesProvider.swift`。メニューに出ないときは一度アプリを起動してから `/System/Library/CoreServices/pbs -update` を実行する。ショートカットはシステム設定 → キーボード → キーボードショートカット → サービスで割り当てられる。

### ウィジェット

small は今日の進捗と次のタスク、medium は今日と近い期限の未完了を合計 3 件まで、large は全セクションの未完了を合計 7 件まで表示する。完了済みは進捗の数字に集約し、収まらないタスクは「ほか n 件を表示」から本体の一覧を開ける。small でも期限ありのタスクには期限を表示する。ウィジェットの編集で「期限あり」「スプリント」「いつかの件数」の表示を切り替えられる。行の丸で完了、タイトルで本体の該当タスクを開く。

### 動作確認のログ

本体・ウィジェット・MCP は `subsystem == "dev.araki.hikidashi"` で os_log に出すので、プロセス間の往復は次で追える。

```bash
/usr/bin/log stream --info --predicate 'subsystem == "dev.araki.hikidashi"' --style compact
```

## MCP サーバーを Claude につなぐ

MCP サーバーはアプリバンドル内の `Contents/Helpers/TaskMCP` にある。ビルドしたアプリを `/Applications` などパスが変わらない場所に置き、その中の実行ファイルを指定する。

```bash
# Claude Code
claude mcp add hikidashi -- /Applications/Hikidashi.app/Contents/Helpers/TaskMCP
```

Claude Desktop は `~/Library/Application Support/Claude/claude_desktop_config.json` に追加する。

```json
{
  "mcpServers": {
    "hikidashi": {
      "command": "/Applications/Hikidashi.app/Contents/Helpers/TaskMCP"
    }
  }
}
```

接続前に共有 DB へ到達できるかは `TaskMCP --check` で確認できる。

| ツール | 内容 |
| --- | --- |
| `list_tasks` | status・プロジェクト・期限・優先度で絞り込んで一覧を返す。`link_url`(完全一致)と `link_contains`(部分一致。Jira の課題キーなど)でリンク URL からも引ける |
| `create_task` | タスクを追加する(`created_by = ai`)。`links` に URL(または `{url, label}`)の配列を渡すと作成と同時にリンクが付く |
| `update_task` | タイトル、メモ、優先度、期限などを変更する。null でクリア |
| `complete_task` | タスクを完了にする |
| `archive_task` | 論理削除する。物理削除は公開しない |
| `add_comment` | タスクにコメントを追加する(author = ai)。進捗や保留の理由などの状況を残す |
| `list_comments` | タスクのコメントを古い順に返す |
| `add_link` | タスクに Notion / Jira / GitHub などの URL を付ける。label 省略時はサービス名 |
| `remove_link` | リンクを外す(論理削除) |
| `list_projects` | プロジェクト一覧を返す |

書き込み系のツールは `activity_log` に `actor = ai` で記録し、書き込み後に Darwin Notification を投げる。

### リンク

タスクには複数の外部リンクを付けられる(`task_link` テーブル)。表示名を省略するとホスト名から Notion / Jira / Confluence / GitHub / Figma などを自動で付ける。一覧ウィンドウの編集フォームにチップと追加欄があり、notes に貼られた URL も点線のチップとして検出して「+」で正式なリンクにできる。ポップオーバーの行とウィジェットの行からも開ける(ウィジェットは本体を経由せずブラウザで開く)。`list_tasks` の結果には `links` が含まれる。追加・削除は `activity_log` に残り、取り消せる。

### Jira と一緒に使う

Claude に Jira や GitHub の MCP も繋いでおくと、課題を進めたついでに引き出しの対応タスクを揃えられる。サーバーの instructions に手順(まず `list_tasks` の `link_url` でその URL を持つタスクを探す → あれば status を揃えて `add_comment` → なければ `links` 付きで `create_task` → 同じ URL のタスクを二重に作らない)を書いてあるので、Claude 側には「引き出しのタスクも更新する」と伝われば動く。プロジェクトの CLAUDE.md や Claude Desktop のプロジェクト指示に次のように書いておくと安定する。

```markdown
- Jira の課題を進めたら、同じ URL をリンクに持つ引き出しのタスク(hikidashi の list_tasks に link_url を渡して探す)を更新し、状況をコメントに書く。
  見つからなければ links にその URL を入れて create_task する。同じ URL のタスクを二重に作らない。
- 課題を Done に遷移させたら、引き出しの対応タスクも complete_task で完了にする。
```

URL の表記が揺れる(クエリ付き、末尾スラッシュなど)ときは `link_contains` に課題キー(`PROJ-123`)や `owner/repo/issues/42` を渡す。部分一致なので `PROJ-1` は `PROJ-12` にも当たる。結果の `links` で同じ課題か確かめる。

### コメント

タスクには人も AI もコメントを付けられる(`comment` テーブル、author = user / ai / widget)。一覧ウィンドウの編集フォームにスレッドと入力欄があり、AI が書いた状況報告をそこで読める。コメントの追加・削除も `activity_log` に残り、「最近の操作」や操作履歴から取り消せる(追加の取り消しは論理削除、削除の取り消しは復元)。

## 名前とアイコン

バンドル名は `Hikidashi.app`(`project.yml` の `PRODUCT_NAME`)、表示名は「私の引き出し」(`CFBundleDisplayName`)。アプリアイコンは `scripts/make-app-icon.swift` で描いて `TaskApp/Assets.xcassets/AppIcon.appiconset` に出力している。色や形を変えるときはスクリプトを直して再実行する。

```bash
swift scripts/make-app-icon.swift TaskApp/Assets.xcassets/AppIcon.appiconset
```

## 配布用ビルド

Developer ID で署名し、Apple の公証を通した zip を配る。Release 構成では `project.yml` で `get-task-allow` の注入を切り、署名にタイムスタンプを付けている(公証の必須条件)。公証の資格情報は `xcrun notarytool store-credentials hikidashi-notary` でキーチェーンに保存しておく。

```bash
xcodegen generate
xcodebuild -project TaskApp.xcodeproj -scheme TaskApp -configuration Release -derivedDataPath build/Release build
APP=build/Release/Build/Products/Release/Hikidashi.app
ditto -c -k --keepParent "$APP" build/dist/Hikidashi-notarize.zip
xcrun notarytool submit build/dist/Hikidashi-notarize.zip --keychain-profile hikidashi-notary --wait
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" build/dist/Hikidashi-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist").zip
```

受け取った側は zip を展開して `Hikidashi.app` を `/Applications` に置き、一度起動する。アプリの置き場所を変えたり別のビルドに入れ替えたりしたあとでウィジェットが空のままになるときは、ウィジェットのデーモンに古い情報が残っている。次で復帰する(ウィジェットはすぐ描き直される)。

```bash
pluginkit -a /Applications/Hikidashi.app/Contents/PlugIns/TaskWidget.appex && killall chronod
```
ウィジェットはデスクトップの右クリック →「ウィジェットを編集」から追加する。MCP の接続先は `/Applications/Hikidashi.app/Contents/Helpers/TaskMCP`。公証が Invalid になったときは `xcrun notarytool log <id> --keychain-profile hikidashi-notary` で理由が読める。

## 紹介サイト(GitHub Pages)

`site/` が [https://gparaki.github.io/watashi-no-hikidashi/](https://gparaki.github.io/watashi-no-hikidashi/) の中身。main の `site/` が変わると `.github/workflows/pages.yml` がデプロイする。新しいバージョンを出すときは、Releases に `Hikidashi-<version>.zip` を載せたあと `site/latest.json` の version / publishedAt / sha256 を更新する(ページのダウンロードボタンはこのファイルを読む)。

## 開発ステップ

- [x] **M1 土台**: TaskCore パッケージとマイグレーション、App Group と署名
- [x] **M2 表示**: 本体からタスクを追加し、ウィジェットに表示する
- [x] **M3 双方向**: ウィジェットからの完了チェックと、Darwin Notification による双方向の反映
- [x] **M4 AI 連動**: TaskMCP を modelcontextprotocol/swift-sdk で実装し、Claude Code からタスクを追加・完了できるようにする
- [x] **M5 UX**: メニューバーのクイック入力、グローバルショートカット、activity_log からの取り消し

## License

MIT
