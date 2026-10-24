// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DayLog",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DayLog", targets: ["DayLog"]),
        .executable(name: "redactor-selftest", targets: ["redactor-selftest"]),
    ],
    targets: [
        .target(name: "RedactorCore"),
        .target(name: "RedactorFixtures", dependencies: ["RedactorCore"]),
        .executableTarget(name: "DayLog", dependencies: ["RedactorCore"]),
        .executableTarget(name: "redactor-selftest", dependencies: ["RedactorCore", "RedactorFixtures"]),
        .testTarget(name: "RedactorTests", dependencies: ["RedactorCore", "RedactorFixtures"]),
    ]
)
