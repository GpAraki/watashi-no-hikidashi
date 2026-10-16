import Foundation
import GRDB

public struct Project: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var sortOrder: Int

    public init(id: String = UUID().uuidString, name: String, sortOrder: Int) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
    }
}

extension Project: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "project"
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase

    public enum Columns {
        public static let id = Column("id")
        public static let name = Column("name")
        public static let sortOrder = Column("sort_order")
    }
}
