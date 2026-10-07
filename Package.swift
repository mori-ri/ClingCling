// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClingCling",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClingCling", targets: ["ClingCling"]),
        .library(name: "ClingClingCore", targets: ["ClingClingCore"]),
    ],
    targets: [
        // UI に依存しない判定ロジック（Privacy Gate / 分類 / Action 順位 / 保存）
        .target(
            name: "ClingClingCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // メニューバー常駐アプリ本体（AppKit + SwiftUI）
        .executableTarget(
            name: "ClingCling",
            dependencies: ["ClingClingCore"]
        ),
        .testTarget(
            name: "ClingClingCoreTests",
            dependencies: ["ClingClingCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
