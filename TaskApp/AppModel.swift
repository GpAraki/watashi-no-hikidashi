import AppKit
import Foundation
import KeyboardShortcuts
import Observation
import OSLog
import ServiceManagement
import TaskCore
import WidgetKit

extension KeyboardShortcuts.Name {
    /// どこからでもポップオーバーを開いてクイック入力にフォーカスする。既定は ⌃⌥Space。
    static let quickInput = Self("quickInput", default: .init(.space, modifiers: [.control, .option]))
}

/// 本体アプリの状態。DB の読み書きと、プロセス間通知の受信を担う。
@MainActor
@Observable
final class AppModel {
    enum State {
        case ready(TaskRepository)
        case failed(String)
    }

    let state: State
    private(set) var tasks: [TaskItem] = []
    /// 完了済み(アーカイブされていないもの)。完了が新しい順、最大 `doneLimit` 件。
    private(set) var doneTasks: [TaskItem] = []
    /// 直近の操作履歴。AI やウィジェットが何をしたかの確認と取り消しに使う。
    private(set) var recentActivity: [ActivityEntry] = []
    private(set) var lastError: String?
    /// グローバルショートカットから開いたとき、クイック入力にフォーカスを移す合図。
    var quickInputFocusRequest = 0
    /// メインウィンドウを開く合図。`TaskAppApp` が監視して `openWindow` を呼ぶ。
    private(set) var mainWindowRequest = 0
    /// メインウィンドウで選択されているタスク。
    var mainWindowSelection: String?
    /// ログイン時起動(SMAppService)の現在の状態。
    private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled
    /// スプリントの区切り方(DB の setting から読む)。
    private(set) var sprintSchedule = SprintSchedule.default()
    /// タスク id ごとのコメント件数(削除済みを除く)。
    private(set) var commentCounts: [String: Int] = [:]
    /// タスク id ごとのリンク(削除済みを除く)。
    private(set) var linksByTask: [String: [TaskLink]] = [:]
    private static let doneLimit = 20
    private static let activityLimit = 15
    /// ディープリンクで開かれたタスク。一覧でハイライトする。
    private(set) var selectedTaskId: String?
    /// 選択されたタスクが一覧(未完了)に無いとき、代わりに見せる 1 件。
    private(set) var selectedTaskOutsideList: TaskItem?
    /// メニューバーのポップオーバーが表示中か。`MenuBarView` の onAppear / onDisappear で更新する。
    private(set) var isPopoverVisible = false
    private var observation: ChangeObservation?
    private let logger = Logger(subsystem: "dev.araki.hikidashi", category: "app")

    static func load() -> AppModel {
        do {
            let url = try AppGroup.databaseURL()
            let database = try AppDatabase.open(at: url)
            let repository = TaskRepository(database: database, notifier: ChangeNotifier())
            return AppModel(state: .ready(repository))
        } catch {
            return AppModel(state: .failed(error.localizedDescription))
        }
    }

    private init(state: State) {
        self.state = state
        guard case .ready = state else { return }
        reload()
        // 他プロセス(ウィジェット・MCP)からの変更を受けて一覧とウィジェットを更新する。
        observation = ChangeNotifier().observe { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.logger.info("change notification received; reloading list and widget timelines")
                self.reload()
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
        KeyboardShortcuts.onKeyUp(for: .quickInput) { [weak self] in
            Task { @MainActor in self?.requestQuickInput() }
        }
    }

    var repository: TaskRepository? {
        if case .ready(let repo) = state { return repo }
        return nil
    }

    var databasePath: String {
        (try? AppGroup.databaseURL().path) ?? "-"
    }

    func reload() {
        guard let repository else { return }
        do {
            tasks = try repository.tasks(matching: .open)
            doneTasks = try repository.tasks(matching: TaskFilter(statuses: [.done]))
                .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
                .prefix(Self.doneLimit)
                .map { $0 }
            recentActivity = try repository.recentActivity(limit: Self.activityLimit)
            sprintSchedule = try repository.sprintSchedule()
            commentCounts = try repository.commentCounts()
            linksByTask = try repository.linksByTask()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refreshSelection()
    }

    /// 操作履歴の 1 件を取り消す(ユーザー操作として記録される)。
    func undo(_ activity: ActivityEntry) {
        perform { try $0.undo(activityId: activity.id, actor: .user) }
    }

    /// グローバルショートカット。ポップオーバーを開いてクイック入力にフォーカスする。
    func requestQuickInput() {
        logger.info("quick input shortcut")
        showPopover()
        quickInputFocusRequest += 1
    }

    // MARK: ディープリンク

    /// `hikidashi://task/<id>` を受けたとき。該当タスクを選択してポップオーバーを開く。
    func open(_ link: DeepLink) {
        switch link {
        case .task(let id):
            selectedTaskId = id
            reload()
            showPopover()
        case .list:
            showMainWindow()
        }
    }

    // MARK: メインウィンドウ

    func showMainWindow(selecting taskId: String? = nil) {
        logger.info("show main window")
        if let taskId { mainWindowSelection = taskId }
        reload()
        mainWindowRequest += 1
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 一覧ウィンドウ用。アーカイブ済みも含めて全部返す(表示側で絞る)。
    func allTasks() -> [TaskItem] {
        guard let repository else { return [] }
        do {
            return try repository.tasks(matching: TaskFilter(includeArchived: true))
        } catch {
            lastError = error.localizedDescription
            return []
        }
    }

    /// 履歴ウィンドウ用。直近 200 件。
    func fullActivity() -> [ActivityEntry] {
        guard let repository else { return [] }
        return (try? repository.recentActivity(limit: 200)) ?? []
    }

    func update(_ task: TaskItem, changes: TaskChanges) {
        perform { try $0.updateTask(id: task.id, changes: changes, actor: .user) }
    }

    func archive(_ task: TaskItem) {
        perform { try $0.archiveTask(id: task.id, actor: .user) }
    }

    func restore(_ task: TaskItem) {
        perform { try $0.restoreTask(id: task.id, actor: .user) }
    }

    // MARK: ログイン時起動

    func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
        logger.info("launch at login: \(self.launchesAtLogin)")
    }

    func clearSelection() {
        selectedTaskId = nil
        selectedTaskOutsideList = nil
    }

    func popoverDidAppear() {
        isPopoverVisible = true
        logger.info("popover appeared")
    }

    func popoverDidDisappear() {
        isPopoverVisible = false
        logger.info("popover disappeared")
        // ハイライトは一度見せたら消す。
        clearSelection()
    }

    private func refreshSelection() {
        guard let id = selectedTaskId else {
            selectedTaskOutsideList = nil
            return
        }
        if tasks.contains(where: { $0.id == id }) {
            selectedTaskOutsideList = nil
        } else {
            selectedTaskOutsideList = (try? repository?.task(id: id)) ?? nil
        }
    }

    /// `MenuBarExtra(.window)` にはプログラムから開く公開 API が無いので、
    /// ステータスバーのボタンをクリックしたことにする。すでに開いていれば何もしない。
    private func showPopover() {
        guard !isPopoverVisible else {
            logger.info("popover already visible; only highlighting")
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where String(describing: type(of: window)).contains("NSStatusBarWindow") {
            if let button = Self.statusBarButton(in: window.contentView) {
                logger.info("opening popover via status bar button")
                button.performClick(nil)
                return
            }
        }
        logger.error("status bar button not found; cannot open popover")
    }

    private static func statusBarButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for sub in view.subviews {
            if let found = statusBarButton(in: sub) { return found }
        }
        return nil
    }

    func add(title: String, type: TaskType = .today) {
        perform { try $0.createTask(NewTask(title: title, type: type), actor: .user) }
    }

    // MARK: リンク

    func links(for taskId: String) -> [TaskLink] { linksByTask[taskId] ?? [] }

    /// notes に書かれていて、まだリンクとして登録されていない URL。
    func detectedURLs(for task: TaskItem) -> [URL] {
        let registered = Set(links(for: task.id).map(\.url))
        return URLDetection.urls(in: task.notes).filter { !registered.contains($0) }
    }

    func addLink(to taskId: String, url: String, label: String? = nil) {
        perform { try $0.addLink(taskId: taskId, url: url, label: label, actor: .user) }
    }

    func removeLink(_ link: TaskLink) {
        guard let id = link.id else { return }
        perform { try $0.removeLink(id: id, actor: .user) }
    }

    // MARK: コメント

    func comments(for taskId: String) -> [Comment] {
        guard let repository else { return [] }
        return (try? repository.comments(taskId: taskId)) ?? []
    }

    func addComment(to taskId: String, body: String) {
        perform { try $0.addComment(taskId: taskId, body: body, actor: .user) }
    }

    func deleteComment(_ comment: Comment) {
        guard let id = comment.id else { return }
        perform { try $0.deleteComment(id: id, actor: .user) }
    }

    /// カレンダーから。指定した日時を期限にした有期限タスク。
    func addDeadline(title: String, dueAt: Date) {
        perform { try $0.createTask(NewTask(title: title, type: .deadline, dueAt: dueAt), actor: .user) }
    }

    /// 未完了タスクをタイプ別に、表示順(今日 → 期限あり → スプリント → いつか)で返す。
    var tasksByType: [(type: TaskType, tasks: [TaskItem])] {
        TaskType.displayOrder.compactMap { type in
            let items = tasks.filter { $0.type == type }
                .sorted { ($0.dueAt ?? .distantFuture, $0.sortOrder) < ($1.dueAt ?? .distantFuture, $1.sortOrder) }
            return items.isEmpty ? nil : (type, items)
        }
    }

    func setSprintSchedule(_ schedule: SprintSchedule) {
        guard let repository else { return }
        do {
            try repository.setSprintSchedule(schedule)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        reload()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func toggle(_ task: TaskItem) {
        perform { repo in
            if task.isDone {
                try repo.reopenTask(id: task.id, actor: .user)
            } else {
                try repo.completeTask(id: task.id, actor: .user)
            }
        }
    }

    private func perform(_ work: (TaskRepository) throws -> Void) {
        guard let repository else { return }
        do {
            try work(repository)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        reload()
        // 自分で書いたときは通知を待たずに即時更新する。
        WidgetCenter.shared.reloadAllTimelines()
    }
}
