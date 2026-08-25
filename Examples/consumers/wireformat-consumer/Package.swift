// swift-tools-version: 6.2
import PackageDescription

/// Consumer simulation (§7): proves `ApusKitWireFormat` builds standalone,
/// with no sibling target pulled in transitively as a direct import (DOC-3).
let package = Package(
  name: "wireformat-consumer",
  platforms: [
    .macOS(.v14)
  ],
  dependencies: [
    .package(name: "ApusKit", path: "../../..")
  ],
  targets: [
    .executableTarget(
      name: "wireformat-consumer",
      dependencies: [
        .product(name: "ApusKitWireFormat", package: "ApusKit")
      ]
    )
  ]
)
