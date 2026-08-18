// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Beckit",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Beckit", targets: ["Beckit"]),
        .library(name: "BeckitKit", targets: ["BeckitKit"]),
    ],
    targets: [
        // Pure domain logic: the book model, versioning rules, the working-tree
        // store, word counting, and the legacy importer. No UI, no git, no I/O
        // beyond FileManager — so it is fast to test and impossible to deadlock
        // on the main actor.
        .target(name: "BeckitKit"),

        // Git access. Written against a protocol so the app never touches
        // libgit2 types directly.
        .target(name: "BeckitGit", dependencies: ["BeckitKit"]),

        // Book PDF generation using TextKit + Core Graphics. Replaces the
        // bundled pandoc + TeX Live toolchain outright.
        .target(name: "BeckitPDF", dependencies: ["BeckitKit"]),

        .executableTarget(
            name: "Beckit",
            dependencies: ["BeckitKit", "BeckitGit", "BeckitPDF"],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),

        .testTarget(name: "BeckitKitTests", dependencies: ["BeckitKit"]),
        .testTarget(name: "BeckitGitTests", dependencies: ["BeckitGit", "BeckitKit"]),
        .testTarget(name: "BeckitAppTests", dependencies: ["Beckit"]),
    ]
)
