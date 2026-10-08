# 0004 — Session tree, JSONL codec, compaction, and pluggable store

Status: landed (M2 Sessions).

## Motivation

M2's Sessions deliverable (`F3.1`–`F3.4`, `§3.5`) asks for four things: a
conversation persists as a branching tree rather than a flat transcript,
that tree is wire-compatible with pi's v3 session file format, a
long-running context compacts itself before it overflows a model's
context window, and storage is pluggable behind a protocol with a
file-based implementation shipped built in. Before this slice, no
`ApusKitSessions` target existed at all — a session was whatever an
`Agent` held in memory for the lifetime of one process, with no on-disk
representation, no branch/fork structure, and no way for a consumer to
choose where entries live.

These four gaps are one family, not four independent features, for the
same reason `0003` files typed tools, wire shape, and truncation
together: each piece is only useful in the presence of the others. A
tree with no codec cannot round-trip through a file; a codec with no
tree cannot answer "what is the context at this leaf"; compaction has
nothing to cut without a tree to walk and a wire shape to persist the
cut into; and `SessionStore` is the seam that lets all three be backed
by something other than a hardcoded filesystem path (no consumer
territory is served by a `Session` type nobody can plug their own
storage under). One proposal covers the whole family, plus the
`ApusKitWireFormat` line-splitting kernel (`JSONLCodec`) the file codec
is layered on, since it is new public surface introduced in the same
slice for the same reason.

`ApusKitSessions` depends only on `ApusKitCore` and `ApusKitWireFormat`
(`PKG-6`) — it is not imported by, and does not import, `ApusKitAgent`;
wiring a running `Agent` to a `SessionStore` is out of scope here and
left to M3.

## Proposed API

### `JSONLCodec` (`ApusKitWireFormat`)

```swift
public struct JSONLDecodeResult: Sendable, Equatable {
  public var lines: [String]
  public var trailing: [UInt8]

  public init(lines: [String], trailing: [UInt8])
}

public enum JSONLCodec {
  public static func decode(
    _ bytes: some Sequence<UInt8>
  ) throws(JSONLDecodeError) -> JSONLDecodeResult

  public static func encode(_ lines: some Sequence<String>) -> [UInt8]
}
```

The line-level kernel every session file is layered on (`WIRE-1`,
`ASM-6`): `decode` splits a buffer into complete, `LF`-delimited lines
plus whatever incomplete `trailing` bytes follow the last `LF` — so a
caller reading a file truncated mid-write, or a chunk boundary that
split a line, can decide what to do with the remainder, including
feeding it back in with the next chunk. `encode` is the inverse:
re-encoding every line a `decode` call returned reproduces the original
bytes exactly, up to any undecoded `trailing`. Per `WIRE-1`, `decode`
uses **typed** `throws(JSONLDecodeError)` — the one target in the
package where that is allowed — because a non-UTF-8 line is the only
failure mode and a caller benefits from the narrowed type. This is also
the third of `WIRE-2`'s three parsing kernels (after `SSEParser` and
`PartialJSONAccumulator`, both M1): the nightly Fuzz row now has a
complete subject (`docs/ci-deferrals.md`).

### `EntryID`, `SessionHeader`, `SessionEntry` (`ApusKitSessions`)

```swift
public struct EntryID: Sendable, Hashable, Codable {
  public let hex: String

  public init(hex: String) throws
  public static func random(using generator: inout some RandomNumberGenerator) -> EntryID
}

public struct SessionHeader: Sendable, Codable, Equatable {
  public static let currentVersion = 3

  public var version: Int
  public var sessionID: EntryID

  public init(version: Int, sessionID: EntryID)
}

public enum SessionMessage: Sendable, Codable, Equatable {
  case user(UserMessage)
  case assistant(AssistantMessage)
  case toolResult(ToolResultMessage)
}

public enum SessionEntryKind: Sendable, Codable, Equatable {
  case message(SessionMessage)
  case compaction(summary: String, retainedTail: [SessionMessage], replacedThrough: EntryID)
  case branchSummary(summary: String)
  case custom(kind: String, payloadJSON: String)
  case customMessage(kind: String, payloadJSON: String)
  case label(name: String)
  case modelChange(model: String)
  case thinkingLevelChange(level: String)
}

public struct SessionEntry: Sendable, Codable, Equatable {
  public var id: EntryID
  public var parentID: EntryID?
  public var kind: SessionEntryKind

  public init(id: EntryID, parentID: EntryID?, kind: SessionEntryKind)
}
```

`EntryID` wraps pi v3's 8-hex entry/session identifier (`§3.5`) as a
validated, `Codable` value type rather than a bare `String`, so an
identifier that didn't come from `decode` or `random(using:)` cannot
exist. `SessionMessage` mirrors `ApusKitProviders`' `LLMRequestMessage`
union but is defined independently: `ApusKitSessions` cannot import
`ApusKitProviders` (`PKG-6`), so reusing that type is not an option.
`SessionEntryKind` covers the eight entry types pi's v3 format defines,
named per `API-2` and corresponding one-to-one with `§3.5`'s
`message, compaction, branch_summary, custom, custom_message, label,
model_change, thinking_level_change`. `SessionEntry` is the flat,
append-only unit both the tree (below) and `SessionStore` operate on:
its `parentID` is the only place tree structure is recorded — nothing
about position in a file or a store implies structure.

### `SessionFileCodec` (`ApusKitSessions`)

```swift
public struct SessionFileDecodeResult: Sendable, Equatable {
  public var header: SessionHeader
  public var entries: [SessionEntry]
  public var trailing: [UInt8]

  public init(header: SessionHeader, entries: [SessionEntry], trailing: [UInt8])
}

public enum SessionFileCodec {
  public static func encode(
    header: SessionHeader,
    entries: some Sequence<SessionEntry>
  ) throws -> [UInt8]

  public static func decode(_ bytes: some Sequence<UInt8>) throws -> SessionFileDecodeResult
}
```

The session-file shape on top of `JSONLCodec`'s line kernel: the first
line is a JSON-encoded `SessionHeader`, every line after it a
JSON-encoded `SessionEntry`. Per `WIRE-1`/`ASM-6`, line splitting and
reassembly stay in `ApusKitWireFormat`; `SessionFileCodec` only knows
that a session file's first line is a header and the rest are entries,
and reuses `JSONLDecodeResult.trailing` verbatim as
`SessionFileDecodeResult.trailing` so a caller streaming a growing file
gets the same incomplete-last-line handling `JSONLCodec` already
provides.

### `Session` and `ContextItem` (`ApusKitSessions`)

```swift
public struct Session: Sendable {
  public var header: SessionHeader

  public init(header: SessionHeader, entries: [SessionEntry] = [])

  public mutating func append(_ entry: SessionEntry)
  public func entry(id: EntryID) -> SessionEntry?
  public func children(of parentID: EntryID?) -> [EntryID]
  public func isLeaf(_ id: EntryID) -> Bool
  public func leaves() -> [EntryID]
  public func history(from leaf: EntryID) throws -> [SessionEntry]
}

public enum ContextItem: Sendable, Equatable {
  case message(SessionMessage)
  case summary(String)
}

extension Session {
  public func buildContext(leaf: EntryID) throws -> [ContextItem]
}
```

`Session` is the in-memory tree: a header plus the entries appended to
it, with parent/child structure derived entirely from each entry's
`parentID`. Branching from any point and forking an alternative
continuation are both just `append(_:)` — appending with an existing
entry's id as `parentID` branches from it, and appending twice with the
same `parentID` forks two siblings (`F3.1`); the tree never rewrites an
existing entry. `leaves()` and `children(of:)` return ids in append
order (`API-4`) rather than a dictionary's nondeterministic order, the
same determinism posture `0003` establishes for `LLMRequest.tools`.
`buildContext(leaf:)` walks `history(from:)` leaf-to-root and stops at
the first compaction entry it meets, substituting that entry's
`summary` and `retainedTail` for everything the compaction replaced
(`§3.5`) — entries that are neither `.message` nor `.compaction`
(labels, model/thinking-level changes, branch summaries, custom
payloads) don't contribute to context and are skipped.

### `Compaction` (`ApusKitSessions`)

```swift
public typealias CompactionSummarizer =
  @Sendable ([SessionMessage]) async throws -> CompactionSummary

public struct CompactionSummary: Sendable, Equatable {
  public var text: String
  public var tokenCount: Int

  public init(text: String, tokenCount: Int)
}

public enum Compaction {
  public static let defaultReserve = 16_384
  public static let defaultRetainedTokens = 20_000
  public static let defaultMaxAttempts = 3

  public static func shouldCompact(
    contextTokens: Int, contextWindow: Int, reserve: Int = defaultReserve
  ) -> Bool

  public struct CutPoint: Sendable, Equatable {
    public var index: Int
    public var retainedTokens: Int
    public init(index: Int, retainedTokens: Int)
  }

  public static func cutPoint(
    tokenCounts: [Int], retainedTokens: Int = defaultRetainedTokens
  ) -> CutPoint

  @concurrent
  public static func compact(
    messages: [SessionMessage],
    tokenCounts: [Int],
    replacedThrough: EntryID,
    retainedTokens: Int = defaultRetainedTokens,
    summaryTokenBudget: Int,
    maxAttempts: Int = defaultMaxAttempts,
    summarize: CompactionSummarizer
  ) async throws -> SessionEntryKind
}
```

Ported from pi's iterative summarization, with `16 384` and `20 000`
normative rather than tuning knobs (`§3.5`). `shouldCompact` answers the
trigger question (`contextTokens > contextWindow - reserve`); `cutPoint`
walks `tokenCounts` from the end backward to find the boundary that
keeps roughly `retainedTokens` of the most recent tokens intact, without
ever emptying the tail on a single oversized recent message. `compact`
then moves that boundary earlier if it would strand a tool result whose
originating `ContentBlock.toolCall` is about to be summarized away, so
`retainedTail` is always self-contained — a shape providers reject
otherwise — and invokes the injected `summarize` closure, re-invoking it
up to `maxAttempts` times if a returned summary still overflows
`summaryTokenBudget`. `CompactionSummarizer` takes a plain `@Sendable`
closure rather than a provider connection: `ApusKitSessions` cannot
import `ApusKitProviders` (`PKG-6`), and a closure is also not one of
`ACC-2`'s closed conformable protocols, so there is nothing to add to
that set for this.

#### Amendment (2026-10-08): the token-counter seam

```swift
public typealias CompactionTokenCounter =
  @Sendable (SessionMessage) async throws -> Int

extension Compaction {
  @concurrent
  public static func compact(
    messages: [SessionMessage],
    replacedThrough: EntryID,
    retainedTokens: Int = defaultRetainedTokens,
    summaryTokenBudget: Int,
    maxAttempts: Int = defaultMaxAttempts,
    countTokens: CompactionTokenCounter,
    summarize: CompactionSummarizer
  ) async throws -> SessionEntryKind

  @concurrent
  public static func compactIfNeeded(
    messages: [SessionMessage],
    contextWindow: Int,
    replacedThrough: EntryID,
    reserve: Int = defaultReserve,
    retainedTokens: Int = defaultRetainedTokens,
    summaryTokenBudget: Int,
    maxAttempts: Int = defaultMaxAttempts,
    countTokens: CompactionTokenCounter,
    summarize: CompactionSummarizer
  ) async throws -> SessionEntryKind?
}
```

`§3.5` (amended 2026-10-01) puts the *whole* compaction policy in
`ApusKitSessions` behind two injected seams, a summarizer and a token
counter, so `ApusKitAgent` wires them up and never re-implements the
policy. The `tokenCounts:` entry points above left counting to every
caller. `CompactionTokenCounter` is the second seam: a `@Sendable`
closure, like `CompactionSummarizer`, so `ACC-2`'s closed conformable set
is unchanged, and `async throws` so a provider's count-tokens endpoint
can stand behind it. `compactIfNeeded` counts each message once, checks
the sum against `shouldCompact`, and on a trigger compacts with the same
counts, returning `nil` without calling `summarize` otherwise.
`compact(…countTokens:…)` is the unconditional form for a forced
compaction. Both are additive: the array-based functions stay as the pure
kernel the new entry points delegate to. This partly supersedes the
"store token counts … instead of the caller passing `tokenCounts`"
alternative below. Counting stays outside the target as before, but the
caller now injects a counter instead of computing the counts itself.

### `SessionStore` and `JSONLFileSessionStore` (`ApusKitSessions`)

```swift
public protocol SessionStore: Sendable {
  @concurrent
  func createSession(header: SessionHeader) async throws

  @concurrent
  func appendEntry(_ entry: SessionEntry, toSessionID sessionID: EntryID) async throws

  @concurrent
  func loadSession(sessionID: EntryID) async throws -> SessionFileDecodeResult

  @concurrent
  func listSessionIDs() async throws -> [EntryID]
}

public struct JSONLFileSessionStore: SessionStore {
  public let directoryURL: URL

  public init(directoryURL: URL)
}
```

`SessionStore` knows nothing about tree structure — it only persists
and retrieves the flat, append-ordered entries a session holds (`F3.4`);
branching, forking, and leaf-to-root rebuild are built on top of what it
returns, via `Session` and `buildContext(leaf:)` above. It joins
`APIImplementation`, `Tool`, `StreamingHTTPTransport`, `AgentExtension`,
and the hook handlers in `ACC-2`'s closed conformable set — a consumer
backs a session in a database, cloud storage, or anywhere else instead
of the filesystem by conforming directly, with zero library changes.
`JSONLFileSessionStore` is the one implementation the library ships:
each session is its own `<sessionID>.hex.jsonl` file inside a
caller-supplied directory (`DI-1` — no hardcoded path), read and written
through `SessionFileCodec` and `Foundation`'s synchronous `FileManager`
and `Data` APIs. Every witness repeats `SessionStore`'s `@concurrent`
annotation explicitly (`CC-2`), so those synchronous calls run off
whatever actor called them rather than blocking one (`CC-4`).
`listSessionIDs()` returns ids sorted ascending by `EntryID.hex`
(`API-4`) rather than `FileManager`'s directory enumeration order, which
is filesystem-dependent and not something a caller should have to rely
on.

## Alternatives considered

- **Reuse `ApusKitProviders.LLMRequestMessage` for `SessionMessage`
  instead of defining a separate union.** Rejected. `PKG-6` forbids
  `ApusKitSessions` from importing `ApusKitProviders` — the dependency
  would run the wrong direction relative to the DAG in `AGENTS.md`
  (`ApusKitCore ← ApusKitProviders`, with `ApusKitSessions` also
  depending only on `ApusKitCore`), and would make the session file
  format's stability hostage to changes in a provider-facing wire type
  that has nothing to do with what a session file persists.
- **A single flat `[SessionEntry]` array with no `Session` tree type,
  leaving branch/leaf/history queries to each caller.** Rejected.
  `F3.1` asks for branching and forking as first-class operations, and
  every one of them — "what are this entry's children", "which entries
  have no children", "walk from this leaf to the root" — is a query
  every caller needs, not something to reimplement per call site the
  way `0003` rejects reimplementing schema validation per tool.
- **Store token counts or context-window state inside `Session` so
  `Compaction` could read them directly, instead of the caller passing
  `tokenCounts` explicitly.** Rejected. Counting tokens needs a model's
  tokenizer, which is provider territory (`PKG-6` again) — `Session` and
  `Compaction` stay provider-agnostic by taking token counts as data the
  caller already computed, the same posture `0002` takes toward
  `LLMRequest.cacheBreakpoints` (indices the caller supplies, not
  something the library derives on its own).
- **An opaque cursor for `SessionFileDecodeResult.trailing` instead of
  raw `[UInt8]`.** Rejected, for the reason `0003` rejects an opaque
  cursor for `headTruncate`: the caller already has the bytes in hand
  from its own read, and `trailing` is exactly what `JSONLCodec.decode`
  already reports for the identical reason — there is nothing to encode
  that isn't already a plain byte buffer.
