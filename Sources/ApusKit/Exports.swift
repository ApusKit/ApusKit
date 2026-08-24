// ApusKit
//
// The umbrella module: re-exports every ApusKit target so a consumer can
// `import ApusKit` once instead of importing each target individually.
// This module contains no logic of its own (TRD §3.9) — its
// `@_exported public import` statements are the single sanctioned
// exception to FORB-1.

@_exported public import ApusKitAgent
@_exported public import ApusKitCore
@_exported public import ApusKitProviders
@_exported public import ApusKitTools
