import AppKit
import SwiftUI
import TaskCore

@main
struct TaskAppApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel.load()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("私の引き出し", systemImage: "tray.full") {
            MenuBarView(model: model)
                .onAppear { appDelegate.model = model }
        }
        .menuBarExtraStyle(.window)
        .onChange(of: model.mainWindowRequest) { _, _ in
            openWindow(id: MainWindowView.windowID)
            NSApp.activate(ignoringOtherApps: true)
        }

        Window("私の引き出し", id: MainWindowView.windowID) {
            MainWindowView(model: model)
        }
        .defaultSize(width: 760, height: 520)
        .windowResizability(.contentMinSize)
        // SwiftUI は届いた URL を Window シーンにも配る。一覧ウィンドウが反応するのは
        // hikidashi://tasks だけにし、hikidashi://task/<id> ではポップオーバーだけを開く。
        .handlesExternalEvents(matching: ["//tasks"])
    }

    init() {
        // ポップオーバーが一度も開かれる前に URL が届いても受け取れるよう、起動時に結びつける。
        appDelegate.model = model
    }
}
