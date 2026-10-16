import SwiftUI
import TaskCore

@main
struct TaskAppApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel.load()

    var body: some Scene {
        MenuBarExtra("私の引き出し", systemImage: "tray.full") {
            MenuBarView(model: model)
                .onAppear { appDelegate.model = model }
        }
        .menuBarExtraStyle(.window)
    }

    init() {
        // ポップオーバーが一度も開かれる前に URL が届いても受け取れるよう、起動時に結びつける。
        appDelegate.model = model
    }
}
