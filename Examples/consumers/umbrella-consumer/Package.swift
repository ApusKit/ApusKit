// swift-tools-version: 6.2
import PackageDescription

/// Consumer simulation (§7): proves the `ApusKit` umbrella builds
/// standalone and re-exports every underlying target (DOC-3).
let package = Package(
  name: "umbrella-consumer",
  platforms: [
    .macOS(.v14)
  ],
  dependencies: [
    .package(path: "../../..")
  ],
  targets: [
    .executableTarget(
      name: "umbrella-consumer",
      dependencies: [
        .product(name: "ApusKit", package: "ApusKit")
      ]
    )
  ]
)
