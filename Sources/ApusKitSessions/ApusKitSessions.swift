// ApusKitSessions
//
// The pi-v3-wire-compatible session layer: a JSONL session tree with
// in-place branching, leaf-to-root context rebuild, and compaction behind
// an injected `@Sendable` summarizer closure, plus a pluggable store.
//
// PKG-6: this module imports only ApusKitCore and ApusKitWireFormat. It
// does not import ApusKitProviders — compaction takes a closure, not a
// provider connection — and it is not yet wired into ApusKitAgent (M3's
// F4.x work).
