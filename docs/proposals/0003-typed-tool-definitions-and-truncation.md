# 0003 — Typed tool definitions, schema validation, and output truncation

Status: landed (M1 Real streaming, typed-tools slice).

## Motivation

M1's tools deliverable (`F2.1`–`F2.4`) asks for four things: a tool's
arguments are typed Swift, its JSON Schema is derived automatically, a
call is validated against that schema before the tool ever runs, and
oversized output is truncated predictably with a way to fetch the rest.
Before this slice, `AnyAgentTool` decoded a tool call's arguments straight
through `JSONDecoder` with no schema check (`TOOL-1` unmet), tool output
was never capped (`TRUNC-1` unmet), and `LLMRequest` had no `tools`
field at all — so no built-in `APIImplementation` could ever tell a model
a tool existed, no matter how a consumer wired up their `ToolRegistry`.

These three gaps are one family, not three independent features: a
provider-neutral wire shape for a tool (`ToolDefinition`), a place to
carry a request's tools through `LLMRequest` to an adapter, and a
head-truncation primitive for the results tools produce. All three are
new public API surface introduced together, so one proposal covers them,
the way `0002` covers `LLMRequest.cacheBreakpoints` as one family rather
than filing separately for the field and for the Anthropic adapter's
`cache_control` rendering.

## Proposed API

### `ToolDefinition` (`ApusKitProviders`)

```swift
public struct ToolDefinition: Sendable, Equatable {
  public var name: String
  public var description: String
  public var parameters: JSONValue

  public init(name: String, description: String, parameters: JSONValue)
}
```

A provider-neutral description of a tool the model may call: a name, a
human-readable description, and its arguments schema as a `JSONValue`.
It is a sealed value type (`ACC-2`), not a protocol — construct one
directly, or derive one from a `Tool`'s `Schemable`-conforming
`Arguments` type, as `Agent`'s run loop does for every registered tool
each turn (`R6`):

```swift
let toolDefinitions = tools.allTools
  .sorted { $0.name < $1.name }
  .map { tool in
    ToolDefinition(name: tool.name, description: tool.description, parameters: tool.schema)
  }
```

Sorted by name before mapping: `ToolRegistry.allTools`' order is
dictionary-backed and nondeterministic, and an unsorted mapping would
make the tool list sent on the wire flap from turn to turn for no reason
a caller could see.

### `LLMRequest.tools` (`ApusKitProviders`)

```swift
public struct LLMRequest: Sendable, Equatable {
  // ...existing fields (see 0002)...

  /// Tool definitions available to the model for this request (`R4`).
  public var tools: [ToolDefinition]

  public init(
    model: String,
    messages: [LLMRequestMessage],
    systemPrompt: String? = nil,
    cacheBreakpoints: Set<Int> = [],
    tools: [ToolDefinition] = []
  )
}
```

Defaults to `[]` so every existing caller and every existing
`APIImplementation` conformance stays source-compatible. `anthropic-messages`
renders a non-empty `tools` as Anthropic's `name`/`description`/
`input_schema` tool objects (`R5`), and omits the `tools` key entirely
when the list is empty rather than sending `"tools": []` — the same
"ignore what a caller didn't ask for" posture `0002` establishes for
`cacheBreakpoints` on the OpenAI adapters. `openai-completions` and
`openai-responses` do not yet render `tools` on the wire; carrying tool
definitions into every adapter's request body is the field's purpose,
but only the Anthropic adapter's rendering landed in this slice; the two
OpenAI-shaped adapters currently read every other `LLMRequest` field and
silently ignore `tools`, the same way every adapter already ignores a
field it has no wire concept for. Adding their rendering is follow-up
work, not a change to this API — `LLMRequest.tools` is deliberately
adapter-agnostic so an adapter's rendering can land independently of the
field's shape.

### Schema validation before execution (`ApusKitTools`)

`AnyAgentTool.execute` validates `argumentsJSON` against the wrapped
tool's `Schemable`-derived schema before `JSONDecoder` or the tool's own
`execute` ever runs (`TOOL-1`):

```swift
let validation = try T.Arguments.schema.definition().validate(instance: argumentsJSON)
guard validation.isValid else {
  // → error ToolResult naming the schema violation, never a throw (TOOL-2)
}
```

A violation short-circuits into an error `ToolResult` carrying the
validation failure reasons, joined, in its `content` and `details`
(`TOOL-2`: invalid input becomes a result the model can react to, never
a crash or a thrown error). `AnyAgentTool` also now exposes that same
schema publicly:

```swift
public let schema: JSONValue
```

so a caller building a `ToolDefinition` (or inspecting a registered
tool's contract directly) reads the identical schema `execute` validates
against — one derivation, two uses.

### `headTruncate` and `TruncatedText` (`ApusKitTools`)

```swift
public struct TruncatedText: Sendable, Equatable {
  public var text: String
  public var isTruncated: Bool
  public var originalLineCount: Int
  public var originalByteCount: Int
}

public func headTruncate(
  _ text: String,
  offset: Int = 0,
  limit: Int = 2000,
  maxBytes: Int = 50_000
) -> TruncatedText
```

Head-truncates `text` at `limit` lines or `maxBytes` UTF-8 bytes,
whichever comes first (`TRUNC-1`), and reports whether the source held
more than the returned window did. `offset` lets a caller fetch the
remainder of a previously-truncated text: call again with `offset` set
to the `limit` used the first time to continue right after it (`R8`) —
an offset/limit pair rather than an opaque cursor, because both bounds
are already meaningful units (a line count and a byte count) a caller
already has in hand from the first call's `TruncatedText`, with no
cursor-encoding scheme to invent or version.

`AnyAgentTool.execute` applies `headTruncate` to every text content
block of a tool's result before returning it, recording `truncated`,
`originalLineCount`, and `originalByteCount` in `ToolResult.details`
only when truncation actually occurred — so an unaffected result carries
no extra bookkeeping, and a truncated one carries exactly what a caller
needs to decide whether and how to ask for the rest.

## Alternatives considered

- **Validate arguments inside each `Tool.execute` implementation
  instead of centrally in `AnyAgentTool`.** Rejected. `TOOL-1` says
  arguments are validated *before the tool runs*, and every tool's
  `Arguments` already derives a schema via `Schemable` — duplicating a
  validation call into every conforming type would be the same check
  written once per tool instead of once per call site, with no
  behavioral difference and a real chance some future tool forgets it.
  `AnyAgentTool` is already the one place every tool call passes through
  on the way from a raw `argumentsJSON` string to a typed `Arguments`
  value; that is where a schema check belongs.
- **An opaque cursor/continuation token for `headTruncate` instead of
  `offset`/`limit`.** Rejected, for the same reason `0002` rejects an
  opaque `providerOptions` bag: it would hide two numbers a caller
  already has (the `limit` it passed, and the line count it wants next)
  behind a token that has to be threaded through and stays meaningless
  outside this one function, instead of just taking the numbers
  directly.
- **Throwing on a schema violation instead of returning an error
  `ToolResult`.** Rejected. `TOOL-2` already commits `AnyAgentTool` to
  never letting a wrapped tool's failure escape as a thrown error — a
  malformed call from the model is exactly the kind of failure a model
  can react to and retry, not a programming error the caller needs to
  catch. Treating "arguments didn't match the schema" as a different
  failure channel from "the tool itself failed" would give
  `AnyAgentTool.execute` two exit shapes for what is, from the caller's
  side, the same kind of event: a tool call that didn't succeed.
- **Truncating by character count instead of lines-then-bytes.**
  Rejected. Tool output is overwhelmingly line-oriented (file contents,
  command output, logs), so a line-count `limit` gives a caller a
  predictable, human-meaningful window to page through with `offset`;
  `maxBytes` exists only as a hard ceiling under that window, so a
  single pathological line (e.g. a minified blob) can't blow past a
  reasonable response size even when it fits under `limit` lines.
