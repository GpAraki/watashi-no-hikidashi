import AppKit
import OSLog
import TaskCore

/// macOS の「サービス」の受け口。どのアプリでも選択テキストを右クリック →「引き出しにタスクを追加」で呼ばれる。
/// 定義は project.yml(Info.plist の NSServices)。`NSApp.servicesProvider` に登録して使う。
@MainActor
final class ServicesProvider: NSObject {
    weak var model: AppModel?
    private let logger = Logger(subsystem: "dev.araki.hikidashi", category: "services")

    /// NSServices の NSMessage と同名。選択テキストまたは URL を受け取り、今日のタスクとして追加する。
    @objc func addTaskFromSelection(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let text = pboard.string(forType: .string)
            ?? pboard.string(forType: NSPasteboard.PasteboardType("public.utf8-plain-text"))
            ?? pboard.string(forType: .URL)
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error.pointee = "選択されたテキストがありません"
            logger.warning("service called without text")
            return
        }
        logger.info("service: add task from selection (\(text.count) chars)")
        guard let model else {
            error.pointee = "アプリの準備ができていません"
            return
        }
        if model.addFromSelection(text) == nil {
            error.pointee = (model.lastError ?? "タスクを追加できませんでした") as NSString
        }
    }
}
