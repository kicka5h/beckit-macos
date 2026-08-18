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

        // libgit2, built static and universal by Scripts/build-libgit2.sh and
        // committed so a clone builds without cmake. Bundled rather than shelled
        // out to: /usr/bin/git on a clean Mac is a stub that pops the "install
        // command line developer tools" dialog, which is not something to put in
        // front of someone who just wants to write.
        .binaryTarget(name: "Clibgit2", path: "Vendor/libgit2.xcframework"),

        // Git access. Written against a protocol so the app never touches
        // libgit2 types directly.
        .target(
            name: "BeckitGit",
            dependencies: ["BeckitKit", "Clibgit2"],
            linkerSettings: [
                // The static archive records none of its own dependencies.
                .linkedLibrary("z"),
                .linkedLibrary("iconv"),
                .linkedFramework("Security"),
                .linkedFramework("CoreFoundation"),
            ]
        ),

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
