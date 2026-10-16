import Foundation

/// プロセス間の変更通知。Darwin Notification で「変わった」ことだけを伝える。
///
/// Darwin Notification はペイロードを運べないので、受信側は必ず DB を読み直す。
/// 通知はメインスレッドのランループで配送されるため、受信側プロセスは
/// ランループを回している必要がある(GUI アプリとウィジェットは問題ない)。
public final class ChangeNotifier: Sendable {
    /// 3 ターゲットで共有する通知名。
    public static let defaultName = "dev.araki.hikidashi.tasks.changed"

    public let name: String

    public init(name: String = ChangeNotifier.defaultName) {
        self.name = name
    }

    /// 変更があったことを全プロセスに知らせる。
    public func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    /// 通知を購読する。返り値を保持している間だけ有効。
    ///
    /// - Parameters:
    ///   - debounce: AI が短時間に複数件書き込む場合に備え、最後の通知から
    ///     この時間だけ待ってから 1 回にまとめて呼ぶ。
    ///   - queue: handler を呼ぶキュー。
    public func observe(
        debounce: TimeInterval = 0.3,
        on queue: DispatchQueue = .main,
        handler: @escaping @Sendable () -> Void
    ) -> ChangeObservation {
        let observation = ChangeObservation(name: name, debounce: debounce, queue: queue, handler: handler)
        observation.start()
        return observation
    }
}

/// 購読のハンドル。`cancel()` するか解放すると購読が止まる。
public final class ChangeObservation: @unchecked Sendable {
    private let name: String
    private let debounce: TimeInterval
    private let queue: DispatchQueue
    private let handler: @Sendable () -> Void

    private let lock = NSLock()
    private var pending: DispatchWorkItem?
    private var active = false

    fileprivate init(name: String, debounce: TimeInterval, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        self.name = name
        self.debounce = debounce
        self.queue = queue
        self.handler = handler
    }

    deinit {
        cancel()
    }

    fileprivate func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !active else { return }
        active = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<ChangeObservation>.fromOpaque(observer).takeUnretainedValue().schedule()
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        active = false
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString),
            nil
        )
        pending?.cancel()
        pending = nil
    }

    private func schedule() {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        pending?.cancel()
        let handler = handler
        let item = DispatchWorkItem { handler() }
        pending = item
        if debounce <= 0 {
            queue.async(execute: item)
        } else {
            queue.asyncAfter(deadline: .now() + debounce, execute: item)
        }
    }
}
