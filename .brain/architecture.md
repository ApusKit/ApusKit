# Architecture

Last reviewed: 2026-08-25
Source of truth: `Package.swift`, `Sources`

The shape of the code **as built** at M0. TRD §3 is the design this implements; where they
differ the code wins, and both get corrected.

## Summary

- A layered SwiftPM package: value types at the bottom, one actor at the top, everything in
  between a protocol seam.
- The only stateful type is `Agent` (an actor). Everything else is a `Sendable` value type or a
  protocol.
- Nothing reaches the network at M0. `ScriptedProvider` satisfies the provider protocol
  deterministically and in memory, which is why the whole suite runs with no keys and no I/O.
- No vendor appears anywhere in the library. Providers arrive through `APIImplementation`, and
  HTTP through `StreamingHTTPTransport`, both injected by the consumer.

## Target graph

```
ApusKitCore ← ApusKitProviders ┐
ApusKitCore ← ApusKitTools     ├→ ApusKitAgent → ApusKit (umbrella, re-export only)
```

The full permitted DAG is PKG-6 in TRD §2. Two edges are hard constraints: no lower target ever
imports `ApusKitAgent`, and `ApusKitAgent` never imports the (future) MCP or Workflows targets.

Each target ships as its own library product, so a consumer may take the provider layer alone and
never touch the loop. `Examples/consumers` is the executable proof, one package per product.

## Data flow (one turn)

1. `Agent.run(_:)` appends to `followUpQueue` and starts the outer loop
   (`Sources/ApusKitAgent/Agent.swift:62`).
2. The inner loop builds an `LLMRequest` and calls `APIImplementation.stream(request:connection:)`,
   which returns an `AsyncThrowingStream` of `StreamEvent`.
3. Events are folded into an `AssistantMessage` as they arrive, and mirrored onto the agent's
   `events` stream as `AgentEvent`s.
4. If the message carries tool calls, they execute **in parallel** in one structured task group,
   each resolved through `ToolRegistry` → `AnyAgentTool`.
5. Results append to history as `ToolResultMessage`s and the loop requests another turn, until a
   turn produces no tool calls.

`Sources/ApusKitAgent/RunLoop.swift` implements this and cites the governing LOOP-n rule inline
at each step — it is the file to read before changing loop behaviour.

## Extension points

Client-conformable (ACC-2), i.e. the public surface consumers build on:
`APIImplementation`, `Tool`, `StreamingHTTPTransport`, and — from M2/M3 — `SessionStore` and
`AgentExtension`.

**Everything else is sealed.** `ToolRegistry`, `ProviderRegistry`, `Agent` and the Core value
types are not conformance targets; sealing preserves the right to add requirements without a
major version.

## Norms

- **Constructor injection everywhere** (DI-1). `Agent.init` takes its provider, connection, model,
  tools and system prompt. There are no singletons and no global mutable state anywhere in the
  package.
- **Nonisolated default isolation in library targets** (CC-1). `MainActor` defaults belong to
  consumers — `Examples/consumers/mainactor-consumer/Package.swift` proves the package works
  under one.
- **Errors are structs wrapping a `@nonexhaustive` `Code` enum** (ERR-2), never bare public enums:
  see `Sources/ApusKitAgent/AgentError.swift` and `Sources/ApusKitCore/StreamError.swift`.
- **Public APIs throw untyped** (ERR-1).
- **Cross-target internals use `package` access** (ACC-1/PKG-8), never `@_spi`. `Agent`'s
  `queuedFollowUpCount` is the live example — it exists so a test can observe queue state without
  widening the public surface.
- **The umbrella holds no logic** (TRD §3.9). `Sources/ApusKit/Exports.swift` is four
  `@_exported public import` lines, the one sanctioned FORB-1 exception.

## Safeguards (merge blockers)

- No locks, semaphores or `DispatchQueue` — actors and `AsyncStream` only (CC-4).
- No `Date()`, wall-clock `Task.sleep`, or `URLSession.shared` inside logic; clock and transport
  are injected (DI-3).
- No force unwrap, `try!`, or IUO in production code (FORB-2) — swift-format enforces it.
- No AppKit/UIKit/ObjC-runtime import anywhere (FORB-3). There is no Linux CI, but nothing may be
  written that would block Linux.
- Nothing from SwiftNIO or the MCP SDK on the public surface — both are fully wrapped (DEP-1).

## Not built yet

Wire-format kernels (SSE, partial-JSON) and the real provider implementations are M1; the JSONL
session tree is M2; the hook bus and AgentExtension are M3; MCP is M4; workflows are M5. TRD §8
maps each to its milestone. Their absence is the plan, not drift.

## Validation

`swift build` (warning-free), `swift test`, `swift test --sanitize=thread`. See `commands.md`.

## Open questions

See `open-questions.md`.
