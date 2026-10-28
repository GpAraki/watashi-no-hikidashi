# 私の引き出し(Hikidashi)

A macOS task manager that lives on your desktop. View tasks in a widget, and let AI manage them via MCP.

Mac のデスクトップウィジェットでタスクを見て、⌃⌥Space ですぐ入れて、進捗をコメントで積み上げ、覚えておくことはメモに残し、Claude や Codex に MCP で整理を任せられる個人用タスク管理アプリです。データは Mac のローカル(SQLite)に置かれ、外部には送信しません。

**ダウンロードと紹介**: https://gparaki.github.io/watashi-no-hikidashi/

このリポジトリは配布用です。アプリ本体(署名・公証済み)は [Releases](https://github.com/GpAraki/watashi-no-hikidashi/releases) から取得できます。ソースコードは公開していません。

## 動作環境

- macOS 14 Sonoma 以降
- Apple Silicon / Intel(Universal)
- Developer ID で署名し、Apple の公証を通しています

## インストール

1. [Releases](https://github.com/GpAraki/watashi-no-hikidashi/releases) から `Hikidashi-<バージョン>.zip` をダウンロードする
2. zip を開き、`Hikidashi.app` を「アプリケーション」フォルダへ移動してから開く(ダウンロードフォルダのまま開くと、macOS が一時的な場所で起動するため AI からつながりません)
3. メニューバーにトレイのアイコンが出たら準備完了
4. デスクトップを右クリック →「ウィジェットを編集」→「私の引き出し」を置く

0.6.0 からは、新しいバージョンが出るとアプリがメニューバーで知らせます。アップデートは `Hikidashi.app` を入れ替えて起動するだけです。データは引き継がれます。入れ替えたあとウィジェットが空のままのときは、次で復帰します。

```bash
pluginkit -a /Applications/Hikidashi.app/Contents/PlugIns/TaskWidget.appex && killall chronod
```

## AI につなぐ

メニューバーの「AI と連携…」(⌘,)を開くと、Claude Code のコマンド、Claude Desktop と Codex の設定をそのままコピーできます。手で設定する場合は次のとおりです。

```bash
# Claude Code(user スコープ)
claude mcp add --scope user hikidashi -- /Applications/Hikidashi.app/Contents/Helpers/TaskMCP
```

```json
{
  "mcpServers": {
    "hikidashi": {
      "command": "/Applications/Hikidashi.app/Contents/Helpers/TaskMCP"
    }
  }
}
```

Claude Desktop は `~/Library/Application Support/Claude/claude_desktop_config.json` に追加して再起動します。

```bash
# Codex(CLI)
codex mcp add hikidashi -- /Applications/Hikidashi.app/Contents/Helpers/TaskMCP
```

```toml
# Codex アプリ・CLI 共通の ~/.codex/config.toml
[mcp_servers.hikidashi]
command = "/Applications/Hikidashi.app/Contents/Helpers/TaskMCP"
```

| ツール | 内容 |
| --- | --- |
| `list_tasks` | 状態・タイプ・期限・優先度・リンク URL で絞り込んで一覧する |
| `create_task` / `update_task` | タスクを追加・変更する |
| `complete_task` / `archive_task` | 完了にする / 論理削除する |
| `add_comment` / `list_comments` | 進捗や判断理由をコメントで残す / 読む |
| `get_journal` | 日ごとのコメントと完了(日報)を返す |
| `add_link` / `remove_link` | Notion や Jira などのリンクを付ける / 外す |
| `list_projects` | プロジェクト一覧 |
| `list_memos` / `create_memo` | メモを一覧する(本文の部分一致・ピン留めで絞り込み) / 追加する |
| `update_memo` / `append_memo` | メモを書き換える・ピン留めを切り替える / 末尾に追記する |
| `archive_memo` | メモを論理削除する |

AI の変更はすべて操作履歴に残り、アプリから取り消せます。

## 主な機能

- **ウィジェット**: small / medium / large。今日の進捗、期限、スプリントを表示し、行の丸で完了チェック
- **入れる**: ⌃⌥Space で浮かぶ入力パネル、一覧の上の入力欄、選んだ文字から右クリック →「引き出しにタスクを追加」
- **音声入力**: 入力パネルとコメント欄のマイクのボタンで、話して入れる。認識は Mac の中だけで行い、音声は外部に送らない
- **タイプ**: 今日 / 期限あり / スプリント / いつか。タイプから期限が決まる
- **日報**: 全タスクのコメントと完了を日付ごとに並べ、Markdown でコピー
- **メモ**: タスクとは別に覚えておくことを残す。1 行目が見出し。ピン留めしたメモはウィジェットに出せる
- **「#調べる」**: メモに URL と「#調べる」を書くと、AI が中身を読んで要点を追記し「#調べ済み」を付ける
- **通知**: 決まった時刻のリマインダーと、AI が更新したときのお知らせ。定時に Claude Code か Codex で自動更新する設定も可能
- **URL スキーム**: `hikidashi://add`(入力パネル)、`hikidashi://tasks`(一覧)、`hikidashi://integration`(AI と連携)、`hikidashi://memos`(メモ)

## 不具合・要望

[Issues](https://github.com/GpAraki/watashi-no-hikidashi/issues) にお寄せください。

## ライセンス

MIT
