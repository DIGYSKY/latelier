// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LAtelier",
    defaultLocalization: "fr",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "LAtelier", targets: ["LAtelier"])
    ],
    targets: [
        // Logique sans interface : commandes, historique, aperçus. Testable seule.
        .target(name: "LAtelierCore"),
        // L'app SwiftUI.
        .executableTarget(
            name: "LAtelier",
            dependencies: ["LAtelierCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "LAtelierCoreTests", dependencies: ["LAtelierCore"]),
    ]
)
