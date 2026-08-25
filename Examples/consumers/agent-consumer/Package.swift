// swift-tools-version: 6.2
import PackageDescription

/// Consumer simulation (§7): proves `ApusKitAgent` builds standalone,
/// with no sibling target pulled in transitively as a direct import
/// (DOC-3).
let package = Package(
  name: "agent-consumer",
  platforms: [
    .macOS(.v14)
  ],
  dependencies: [
    .package(path: "../../..")
  ],
  targets: [
    .executableTarget(
      name: "agent-consumer",
      dependencies: [
        .product(name: "ApusKitAgent", package: "ApusKit")
      ]
    )
  ]
)
