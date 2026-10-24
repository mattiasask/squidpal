import XCTest
import RedactorCore
import RedactorFixtures

final class RedactorTests: XCTestCase {
    func testRedactionCases() {
        for c in Fixtures.redactionCases {
            XCTAssertNil(c.check(), c.name)
        }
    }

    func testBooleanCases() {
        for c in Fixtures.boolCases {
            XCTAssertNil(c.check(), c.name)
        }
    }

    func testOutputNeverContainsValuesInKinds() {
        let r = Redactor.redact("password: hunter2")
        XCTAssertEqual(r.kinds, ["secret"])
        XCTAssertFalse(r.kinds.joined().contains("hunter2"))
    }
}
