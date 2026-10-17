import Foundation

/// 固定長スプリントの区切り方。`anchor`(あるスプリントの開始日 0 時)から `lengthDays` ごとに区切る。
///
/// 既定は水曜開始・7 日(水曜〜火曜)。設定は `setting` テーブルに JSON で保存し、3 プロセスで共有する。
public struct SprintSchedule: Codable, Equatable, Sendable {
    /// あるスプリントの開始日(その日の 0 時)。ここから前後に `lengthDays` ごとに区切る。
    public var anchor: Date
    /// スプリントの日数。7 なら毎週、14 なら隔週。
    public var lengthDays: Int

    public init(anchor: Date, lengthDays: Int = 7) {
        self.anchor = anchor
        self.lengthDays = max(1, lengthDays)
    }

    /// 曜日と長さから作る。`reference` 以前で最も近いその曜日を anchor にする。
    /// - Parameter startWeekday: `Calendar` の weekday(1 = 日 … 4 = 水 … 7 = 土)。
    public init(startWeekday: Int, lengthDays: Int = 7, reference: Date = Date(), calendar: Calendar = .current) {
        var day = calendar.startOfDay(for: reference)
        while calendar.component(.weekday, from: day) != startWeekday {
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        self.init(anchor: day, lengthDays: lengthDays)
    }

    /// 水曜開始・7 日。
    public static func `default`(calendar: Calendar = .current) -> SprintSchedule {
        SprintSchedule(startWeekday: 4, lengthDays: 7, reference: Date(timeIntervalSince1970: 1_767_225_600), calendar: calendar)
    }

    /// anchor の曜日(1 = 日 … 7 = 土)。
    public func startWeekday(calendar: Calendar = .current) -> Int {
        calendar.component(.weekday, from: anchor)
    }

    /// `date` を含むスプリントの期間。`end` は次のスプリントの開始(含まない)。
    public func interval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let day = calendar.startOfDay(for: date)
        let anchorDay = calendar.startOfDay(for: anchor)
        let days = calendar.dateComponents([.day], from: anchorDay, to: day).day ?? 0
        let index = Int((Double(days) / Double(lengthDays)).rounded(.down))
        let start = calendar.date(byAdding: .day, value: index * lengthDays, to: anchorDay)!
        let end = calendar.date(byAdding: .day, value: lengthDays, to: start)!
        return DateInterval(start: start, end: end)
    }

    /// `date` を含むスプリントの最終日の終わり(23:59:59)。スプリントタスクの `due_at` に使う。
    public func dueDate(forSprintContaining date: Date, calendar: Calendar = .current) -> Date {
        interval(containing: date, calendar: calendar).end.addingTimeInterval(-1)
    }

    /// 次のスプリントの最終日の終わり。
    public func dueDate(forSprintAfter date: Date, calendar: Calendar = .current) -> Date {
        let current = interval(containing: date, calendar: calendar)
        return interval(containing: current.end, calendar: calendar).end.addingTimeInterval(-1)
    }
}

extension Calendar {
    /// `date` の日の終わり(23:59:59)。当日タスクの `due_at` に使う。
    public func endOfDay(for date: Date) -> Date {
        let start = startOfDay(for: date)
        return self.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
    }
}
