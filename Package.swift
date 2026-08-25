// swift-tools-version: 6.2
import PackageDescription

/// Swift settings applied uniformly to every target (PKG-1, PKG-3).
let commonSwiftSettings: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("InternalImportsByDefault"),
  .enableExperimentalFeature("StrictConcurrency"),
  .treatAllWarnings(as: .error),
]

let package = Package(
  name: "ApusKit",
  platforms: [
    .macOS(.v14),
    .iOS(.v17),
    .macCatalyst(.v17),
    .tvOS(.v17),
    .visionOS(.v1),
  ],
  products: [
    .library(name: "ApusKitCore", targets: ["ApusKitCore"]),
    .library(name: "ApusKitWireFormat", targets: ["ApusKitWireFormat"]),
    .library(name: "ApusKitProviders", targets: ["ApusKitProviders"]),
    .library(name: "ApusKitTools", targets: ["ApusKitTools"]),
    .library(name: "ApusKitSessions", targets: ["ApusKitSessions"]),
    .library(name: "ApusKitAgent", targets: ["ApusKitAgent"]),
    .library(name: "ApusKit", targets: ["ApusKit"]),
  ],
  traits: [
    .trait(name: "NIO"),
    .trait(name: "MCP"),
  ],
  dependencies: [
    .package(url: "https://github.com/ajevans99/swift-json-schema", exact: "0.9.1"),
    .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0"),
  ],
  targets: [
    .target(
      name: "ApusKitCore",
      swiftSettings: commonSwiftSettings
    ),
    .target(
      name: "ApusKitWireFormat",
      dependencies: [
        "ApusKitCore"
      ],
      swiftSettings: commonSwiftSettings
    ),
    .target(
      name: "ApusKitProviders",
      dependencies: [
        "ApusKitCore",
        "ApusKitWireFormat",
        .product(name: "JSONSchema", package: "swift-json-schema"),
      ],
      swiftSettings: commonSwiftSettings
    ),
    .target(
      name: "ApusKitTools",
      dependencies: [
        "ApusKitCore",
        .product(name: "JSONSchemaBuilder", package: "swift-json-schema"),
        .product(name: "JSONSchema", package: "swift-json-schema"),
      ],
      swiftSettings: commonSwiftSettings
    ),
    .target(
      // PKG-6: imports only ApusKitCore and ApusKitWireFormat.
      name: "ApusKitSessions",
      dependencies: [
        "ApusKitCore",
        "ApusKitWireFormat",
      ],
      swiftSettings: commonSwiftSettings
    ),
    .target(
      name: "ApusKitAgent",
      dependencies: [
        "ApusKitCore",
        "ApusKitProviders",
        "ApusKitTools",
      ],
      swiftSettings: commonSwiftSettings
    ),
    .target(
      name: "ApusKit",
      dependencies: [
        "ApusKitCore",
        "ApusKitWireFormat",
        "ApusKitProviders",
        "ApusKitTools",
        "ApusKitSessions",
        "ApusKitAgent",
      ],
      swiftSettings: commonSwiftSettings
    ),
    .target(
      name: "TestSupport",
      dependencies: [
        "ApusKitCore",
        "ApusKitProviders",
        "ApusKitTools",
        "ApusKitSessions",
        "ApusKitAgent",
      ],
      path: "Tests/Shared",
      swiftSettings: commonSwiftSettings
    ),
    .testTarget(
      name: "ApusKitCoreTests",
      dependencies: [
        "ApusKitCore",
        "TestSupport",
      ],
      swiftSettings: commonSwiftSettings
    ),
    .testTarget(
      name: "ApusKitWireFormatTests",
      dependencies: [
        "ApusKitWireFormat"
      ],
      swiftSettings: commonSwiftSettings
    ),
    .testTarget(
      name: "ApusKitProvidersTests",
      dependencies: [
        "ApusKitProviders",
        "TestSupport",
      ],
      swiftSettings: commonSwiftSettings
    ),
    .testTarget(
      name: "ApusKitToolsTests",
      dependencies: [
        "ApusKitTools",
        "TestSupport",
      ],
      swiftSettings: commonSwiftSettings
    ),
    .testTarget(
      name: "ApusKitAgentTests",
      dependencies: [
        "ApusKitAgent",
        "TestSupport",
      ],
      swiftSettings: commonSwiftSettings
    ),
    .testTarget(
      name: "ApusKitSessionsTests",
      dependencies: [
        "ApusKitSessions",
        "TestSupport",
      ],
      swiftSettings: commonSwiftSettings
    ),
  ]
)
