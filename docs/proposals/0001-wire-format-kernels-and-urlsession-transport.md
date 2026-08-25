# 0001 — Wire-format kernels and the default URLSession transport

Status: landed (M1 Real streaming, wire-format slice).

## Motivation

M1 needs a home for the two incremental parsers every streaming provider
implementation will depend on: an SSE parser (event boundaries can split
anywhere across HTTP chunk boundaries) and a partial-JSON accumulator
(tool-call `arguments` arrive as streamed fragments that must be decodable
at any prefix). Per `PKG-6` these are new public API families, living in a
new target, `ApusKitWireFormat`, between `ApusKitCore` and
`ApusKitProviders` in the dependency DAG — hence `DOC-4`.

M1 also needs a zero-dependency default for the `StreamingHTTPTransport`
seam declared in `ApusKitProviders`, so a consumer can stream a live
request without opting into the `NIO` trait.

## Proposed API

`ApusKitWireFormat`:

```swift
public struct SSEEvent: Sendable, Equatable {
  public var event: String?
  public var data: String
  public var id: String?
}

public struct SSEParseError: Sendable, Equatable, Error {
  @nonexhaustive(warn)
  public enum Code: Sendable, Equatable { case invalidUTF8 }
  public var code: Code
  public var message: String
}

public struct SSEParser: Sendable {
  public init()
  public mutating func feed(_ bytes: some Sequence<UInt8>) throws(SSEParseError) -> [SSEEvent]
}

public struct PartialJSONAccumulator: Sendable {
  public init()
  public mutating func append(_ fragment: String)
  public func snapshot() -> String
}
```

`ApusKitProviders`:

```swift
public struct URLSessionTransport: StreamingHTTPTransport {
  public init(session: URLSession)
  public func stream(_ request: HTTPStreamRequest) -> AsyncThrowingStream<HTTPStreamChunk, any Error>
}
```

`SSEParser.feed(_:)` is the only public API in the package that uses typed
`throws`, per `WIRE-1`. `URLSessionTransport.init` takes its `URLSession`
by injection with no default, per `DI-3`.

## Alternatives considered

- **A `JSONValue` enum on `PartialJSONAccumulator.snapshot()`.** Rejected.
  A parsed-value type belongs to `swift-json-schema`'s `JSONValue`, which
  is unreachable from `ApusKitWireFormat` under `PKG-6` (this target
  imports only `ApusKitCore`). Introducing a second, competing public JSON
  value type — one ApusKit invents and one `swift-json-schema` already
  ships — would fork the surface a consumer decodes against for no
  benefit: the accumulator's whole job is to hand back *text* that is safe
  to decode, not to pre-empt what the caller decodes it into. Returning
  `String` keeps decoding entirely the caller's job, as `ApusKitTools`
  already does via `Schemable & Decodable`.
- **Trial-and-error repair via `JSONSerialization`, retrying with bytes
  trimmed off the end until parsing succeeds.** Rejected for the shipped
  implementation. It is simple to write, but re-running a full JSON parse
  once per trimmed byte is exactly what `WIRE-2`'s allocation-conscious
  requirement warns against for a nightly fuzz target, and it gives no
  structural signal for *why* a suffix was dropped (a dangling key vs. a
  dangling comma vs. a truncated number all just "fail to parse"). The
  shipped accumulator instead tokenizes once and walks the JSON grammar's
  state machine directly, so only the true last token is ever inspected
  for repair.
- **A single parser type per kernel that both frames and decodes.**
  Rejected for the SSE side too: `SSEParser` frames events (splits on the
  blank-line boundary, unfolds multi-line `data:`) but leaves each
  `data:` payload as a `String` for the caller to interpret — an
  `anthropic-messages` vs. `openai-completions` implementation each read
  that payload differently, and neither belongs in the shared kernel.
