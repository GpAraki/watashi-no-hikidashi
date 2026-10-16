import AppKit
import OSLog
import TaskCore

/// `hikidashi://` の URL を受け取って AppModel に渡す。
///
/// `MenuBarExtra` の中身は閉じている間は生成されないので、SwiftUI の `onOpenURL` では
/// URL を取りこぼす。AppKit のデリゲートで受けて、モデル側で選択とポップオーバー表示を行う。
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private let logger = Logger(subsystem: "dev.araki.hikidashi", category: "deeplink")

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let link = DeepLink(url: url) else {
                logger.warning("unknown url: \(url.absoluteString, privacy: .public)")
                continue
            }
            logger.info("open url: \(url.absoluteString, privacy: .public)")
            model?.open(link)
        }
    }
}
