import AppKit
import OSLog
import TaskCore

/// `hikidashi://` の URL を受け取って AppModel に渡す。
///
/// `MenuBarExtra` の中身は閉じている間は生成されないので、SwiftUI の `onOpenURL` では
/// URL を取りこぼす。AppKit のデリゲートで受けて、モデル側で選択とポップオーバー表示を行う。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel? {
        didSet { servicesProvider.model = model }
    }
    private let logger = Logger(subsystem: "dev.araki.hikidashi", category: "deeplink")
    private let servicesProvider = ServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 「サービス」メニューからの呼び出しを受ける。
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()
    }

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
