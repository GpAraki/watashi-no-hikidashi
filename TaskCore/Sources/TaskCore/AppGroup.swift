import Foundation

/// App Group の共有コンテナまわりの定数。
///
/// 識別子は macOS の慣例どおり Team ID を接頭辞にする。この形式は
/// プロビジョニングプロファイルに依存せず、同じ Team で署名された
/// プロセス(本体・ウィジェット・MCP サーバー)がダイアログなしで
/// 共有コンテナを読み書きできる。値を変えるときは project.yml の
/// entitlements も揃えること。
public enum AppGroup {
    public static let teamID = "D5F23S696X"
    public static let identifier = "\(teamID).dev.araki.hikidashi"
    public static let databaseFileName = "tasks.sqlite"

    public enum Error: Swift.Error, LocalizedError {
        case containerUnavailable(String)

        public var errorDescription: String? {
            switch self {
            case .containerUnavailable(let id):
                return "App Group '\(id)' のコンテナにアクセスできません。entitlements と署名を確認してください。"
            }
        }
    }

    /// `~/Library/Group Containers/<identifier>/`
    public static func containerURL() throws -> URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            throw Error.containerUnavailable(identifier)
        }
        return url
    }

    /// 3 プロセスが共有する SQLite ファイルの場所。
    public static func databaseURL() throws -> URL {
        try containerURL().appendingPathComponent(databaseFileName)
    }
}
