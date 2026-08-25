// swift-tools-version: 6.2
import PackageDescription

/// Consumer simulation (§7): the MainActor-default variant simulating an
/// app consumer (DOC-3) — the `ApusKit` umbrella built under
/// `-default-isolation MainActor` plus `NonisolatedNonsendingByDefault`,
/// rather than this package's own strict-concurrency settings.
let package = Package(
  name: "mainactor-consumer",
  platforms: [
    .macOS(.v14)
  ],
  dependencies: [
    .package(name: "ApusKit", path: "../../..")
  ],
  targets: [
    .executableTarget(
      name: "mainactor-consumer",
      dependencies: [
        .product(name: "ApusKit", package: "ApusKit")
      ],
      swiftSettings: [
        .defaultIsolation(MainActor.self),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
      ]
    )
  ]
)
