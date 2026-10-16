import SwiftUI
import TaskCore

@main
struct TaskAppApp: App {
    @State private var model = AppModel.load()

    var body: some Scene {
        MenuBarExtra("私の引き出し", systemImage: "tray.full") {
            MenuBarView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
