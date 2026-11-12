// swift-tools-version: 6.0
// Логика без UI (разбор Textile, лента, модели, API-хелперы, уведомления) — отдельным модулем для
// `swift test` на Маке без симулятора. Само приложение собирается из project.yml (XcodeGen).
import PackageDescription

let package = Package(
    name: "RedTaskCore",
    platforms: [.macOS(.v15), .iOS(.v18)],
    targets: [
        .target(
            name: "RedTaskCore",
            path: "RedTask",
            sources: [
                "Data/Models.swift", "Data/Textile.swift", "Data/Activity.swift", "Data/RedmineAPI.swift",
                "Data/Storage.swift", "Data/Thumbnails.swift", "Data/FormFields.swift", "Data/Queries.swift", "Notify/NotifModel.swift",
            ]
        ),
        .testTarget(name: "RedTaskTests", dependencies: ["RedTaskCore"], path: "RedTaskTests", resources: [.copy("vectors.json"), .copy("wiki-table.txt")]),
    ]
)
