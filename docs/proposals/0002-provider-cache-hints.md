# 0002 — Provider-neutral cache hints on `LLMRequest`

Status: landed (M1 Real streaming, provider-implementations slice).

## Motivation

`anthropic-messages` supports prompt caching: a request marks specific
content blocks with `cache_control`, and the provider caches everything up
to and including that block for reuse on a later request. For a long-lived
system prompt or a growing conversation history, this is the difference
between re-billing the whole prefix every turn and paying full price once.
`ApusKitCore.Usage` already carries `cacheRead`/`cacheWrite` token counts
(§3.1) and `Usage.cost(at:)` already prices them from `ModelInfo.pricing`
(`PROV-3`) — the accounting side is done. What is missing is a way for a
caller to *say where* the breakpoints go.

`openai-completions` and `openai-responses` have no equivalent knob — the
provider chooses what to cache automatically. So this cannot become a
provider-specific request shape without breaking `PROV-2` (context is
provider-neutral: switching provider mid-session must work with no
provider-specific state living in messages). It has to be one field on the
shared `LLMRequest`, expressed in terms `LLMRequest` already understands
(the position of a message in `messages`), that the Anthropic adapter reads
and renders as `cache_control`, and that both OpenAI adapters simply never
look at.

## Proposed API

```swift
public struct LLMRequest: Sendable, Equatable {
  public var model: String
  public var messages: [LLMRequestMessage]
  public var systemPrompt: String?

  /// Indices into `messages` marking prompt-cache breakpoints (`PROV-2`).
  ///
  /// Each index names a message whose trailing content is a natural
  /// prompt-cache boundary: everything up to and including that message is
  /// intended to be cached together. This is a provider-neutral *hint* —
  /// context itself carries no provider-specific state. The Anthropic
  /// adapter renders each breakpoint as `cache_control` on the
  /// corresponding message's last content block; the OpenAI adapters have
  /// no equivalent wire concept and ignore this field without error.
  public var cacheBreakpoints: Set<Int>

  public init(
    model: String,
    messages: [LLMRequestMessage],
    systemPrompt: String? = nil,
    cacheBreakpoints: Set<Int> = []
  ) {
    self.model = model
    self.messages = messages
    self.systemPrompt = systemPrompt
    self.cacheBreakpoints = cacheBreakpoints
  }
}
```

`anthropic-messages` renders each index in `cacheBreakpoints` as
`cache_control: {"type": "ephemeral"}` on the last content block of the
corresponding rendered request message — matching where Anthropic's own
API expects the marker (the *end* of the region being cached, not its
start). Because `messages` is ordered oldest-first, a breakpoint at index
`i` implicitly covers the system prompt and every message up to and
including `messages[i]`; there is no separate system-prompt case. Both
`openai-completions` and `openai-responses` read every other `LLMRequest`
field and skip `cacheBreakpoints` entirely — no branch, no error, just an
unused property.

`Set<Int>` rather than `[Int]` because breakpoints are a set of positions
with no order or duplicates of their own — `messages`' order is what
matters — and membership testing while rendering a request is the only
operation the adapters perform on it.

## Alternatives considered

- **An opaque `providerOptions: [String: Any]` (or `[String: JSONValue]`)
  bag on `LLMRequest`.** Rejected. It would let *any* provider-specific
  knob leak into the shared request type, which is exactly what `PROV-2`
  exists to prevent — today it would be Anthropic's cache breakpoints,
  tomorrow some other adapter's request-shaping flag, and `LLMRequest`
  stops being something a caller can reason about independent of which
  `APIImplementation` will consume it. `Any` also isn't `Sendable`, and a
  `JSONValue` bag pushes a stringly-typed, unvalidated key namespace onto
  every adapter instead of one typed field every adapter can read (or
  ignore) uniformly.
- **A fixed internal caching policy** (the library decides automatically,
  e.g. always cache the system prompt plus everything but the last
  message). Rejected. Caching is a cost/latency tradeoff the caller must
  control: Anthropic allows at most four breakpoints per request, a cache
  entry has a TTL, and a short or one-shot conversation gains nothing from
  caching while a long-lived agent session gains a lot. A heuristic baked
  into the adapter can't be tuned per use case and would silently spend
  (or silently fail to spend) a caller's cache budget with no way to opt
  out short of a field that does not exist.
- **A two-case enum (`.systemPrompt` / `.message(Int)`) instead of a plain
  `Set<Int>`.** Considered, rejected as unneeded complexity. Because
  `messages` is rendered after `systemPrompt` and a breakpoint always
  covers everything *up to* its position, a breakpoint that should cover
  the system prompt is just the breakpoint at the earliest message index
  a caller cares to mark — a dedicated `.systemPrompt` case would only
  ever mean "cache the system prompt alone, before any message," which no
  known use case calls for and which the Anthropic adapter would still
  have to translate into the same `cache_control` placement. A second enum
  case with no distinct wire behavior is exactly the kind of speculative
  flexibility this API doesn't need.
- **A `cacheBreakpoint: Bool` flag on `LLMRequestMessage` instead of a
  set on `LLMRequest`.** Rejected. `PROV-2`'s framing is deliberately a
  single field on the *request* ("one provider-neutral cache-hint field"),
  not a change to the message wrapper every provider adapter and the
  session layer already depends on; keeping it a request-level set leaves
  `LLMRequestMessage` exactly as it is today and keeps all cache-hint
  bookkeeping in one place instead of scattered across message cases.
