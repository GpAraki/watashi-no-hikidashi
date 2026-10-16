import Foundation

/// 本体アプリを開くための URL。ウィジェットの行から `hikidashi://task/<id>` で本体の該当タスクを開く。
///
/// スキームは `project.yml` の `CFBundleURLSchemes` と揃える。
public enum DeepLink: Equatable, Sendable {
    public static let scheme = "hikidashi"

    /// 該当タスクを本体で選択状態にする。
    case task(id: String)

    public var url: URL {
        switch self {
        case .task(let id):
            var components = URLComponents()
            components.scheme = Self.scheme
            components.host = "task"
            components.path = "/" + id
            return components.url!
        }
    }

    /// `hikidashi://task/<id>` の形の URL を解釈する。別スキームや未知の形は nil。
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        let host = url.host()?.lowercased()
        let segments = url.pathComponents.filter { $0 != "/" }
        switch (host, segments.count) {
        case ("task", 1) where !segments[0].isEmpty:
            self = .task(id: segments[0])
        default:
            return nil
        }
    }

    /// ウィジェットなどで使う便宜メソッド。
    public static func taskURL(id: String) -> URL {
        DeepLink.task(id: id).url
    }
}
