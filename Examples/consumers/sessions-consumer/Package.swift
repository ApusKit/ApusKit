// swift-tools-version: 6.2
import PackageDescription

/// Consumer simulation (§7): proves `ApusKitSessions` builds standalone,
/// with no sibling target pulled in transitively as a direct import
/// (DOC-3).
let package = Package(
  name: "sessions-consumer",
  platforms: [
    .macOS(.v14)
  ],
  dependencies: [
    .package(name: "ApusKit", path: "../../..")
  ],
  targets: [
    .executableTarget(
      name: "sessions-consumer",
      dependencies: [
        .product(name: "ApusKitSessions", package: "ApusKit")
      ]
    )
  ]
)
