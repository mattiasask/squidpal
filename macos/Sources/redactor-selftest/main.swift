import Foundation
import RedactorCore
import RedactorFixtures

// Runs the same cases as the XCTest suite. Works with only the Command Line
// Tools installed (no Xcode / XCTest needed):  swift run redactor-selftest
var passed = 0, failed = 0
func report(_ name: String, _ problem: String?) {
    if let problem {
        failed += 1
        print("FAIL  \(name): \(problem)")
    } else {
        passed += 1
        print("ok    \(name)")
    }
}
for c in Fixtures.redactionCases { report(c.name, c.check()) }
for c in Fixtures.boolCases { report(c.name, c.check()) }
print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
