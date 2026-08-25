// swift-tools-version: 6.2
import PackageDescription

/// Consumer simulation (§7): proves `ApusKitTools` builds standalone,
/// with no sibling target pulled in transitively as a direct import
/// (DOC-3).
let package = Package(
  name: "tools-consumer",
  platforms: [
    .macOS(.v14)
  ],
  dependencies: [
    .package(path: "../../..")
  ],
  targets: [
    .executableTarget(
      name: "tools-consumer",
      dependencies: [
        .product(name: "ApusKitTools", package: "ApusKit")
      ]
    )
  ]
)
