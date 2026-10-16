import XCTest
@testable import TaskCore

final class DeepLinkTests: XCTestCase {
    func testTaskRoundTrip() throws {
        let id = "D4CCB6B9-ADB2-48A2-998D-0E5CFDBBF761"
        let url = DeepLink.taskURL(id: id)
        XCTAssertEqual(url.absoluteString, "hikidashi://task/\(id)")
        XCTAssertEqual(DeepLink(url: url), .task(id: id))
    }

    func testRejectsOtherForms() throws {
        XCTAssertNil(DeepLink(url: URL(string: "https://task/abc")!))
        XCTAssertNil(DeepLink(url: URL(string: "hikidashi://project/abc")!))
        XCTAssertNil(DeepLink(url: URL(string: "hikidashi://task")!))
        XCTAssertNil(DeepLink(url: URL(string: "hikidashi://task/")!))
        XCTAssertNil(DeepLink(url: URL(string: "hikidashi://task/a/b")!))
    }
}
