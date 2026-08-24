// TestSupport
//
// Shared test fakes and script-building helpers used by the per-target
// Swift Testing suites, especially the ApusKitAgentTests M0 gate suite.
// Per TEST-2, these are protocol-seam fakes — never URLProtocol stubbing.

public import ApusKitCore
public import ApusKitProviders
public import ApusKitTools
public import JSONSchemaBuilder

/// A tool that records every call it receives and returns a fixed result.
///
/// An actor so recorded calls can be inspected safely after the agent
/// loop has run it, without locks (`CC-4`).
public actor RecordingTool: Tool {
  /// The arguments `RecordingTool` decodes its calls into.
  @Schemable
  public struct Arguments: Decodable, Sendable, Equatable {
    /// An arbitrary payload the test script supplies.
    public var value: String

    /// Creates arguments.
    public init(value: String) {
      self.value = value
    }
  }

  /// This tool's name, as referenced by scripted `toolCall` events.
  public nonisolated let name: String

  /// This tool's description.
  public nonisolated let description: String

  private let result: ToolResult

  /// Every call this tool has received, in order.
  public private(set) var recordedCalls: [Arguments] = []

  /// Creates a recording tool.
  ///
  /// - Parameters:
  ///   - name: The name scripted `toolCall` events should reference.
  ///   - description: A description for the tool.
  ///   - result: The fixed result returned from every call.
  public init(
    name: String = "recording_tool",
    description: String = "Records its calls.",
    result: ToolResult = ToolResult(content: [.text("ok")])
  ) {
    self.name = name
    self.description = description
    self.result = result
  }

  /// Records `arguments` and returns the fixed result.
  public func execute(
    toolCallID: String,
    arguments: Arguments,
    signal: ToolCancellationSignal,
    onUpdate: @Sendable (ToolUpdate) -> Void
  ) async throws -> ToolResult {
    recordedCalls.append(arguments)
    return result
  }
}

/// The error `ThrowingTool` always throws.
public struct ThrowingToolError: Error, Sendable, Equatable {
  /// Creates the error.
  public init() {}
}

/// A tool that always throws, to exercise `TOOL-2`/`LOOP-3` error
/// conversion end to end through the real agent loop.
public struct ThrowingTool: Tool {
  /// The arguments `ThrowingTool` decodes its calls into.
  @Schemable
  public struct Arguments: Decodable, Sendable {
    /// An arbitrary payload the test script supplies.
    public var value: String

    /// Creates arguments.
    public init(value: String) {
      self.value = value
    }
  }

  /// This tool's name, as referenced by scripted `toolCall` events.
  public let name: String

  /// This tool's description.
  public let description: String

  /// Creates a throwing tool.
  public init(name: String = "throwing_tool", description: String = "Always throws.") {
    self.name = name
    self.description = description
  }

  /// Always throws `ThrowingToolError`.
  public func execute(
    toolCallID: String,
    arguments: Arguments,
    signal: ToolCancellationSignal,
    onUpdate: @Sendable (ToolUpdate) -> Void
  ) async throws -> ToolResult {
    throw ThrowingToolError()
  }
}

/// Builds `StreamEvent` sequences for `ScriptedProvider`, covering the
/// turn shapes the ApusKitAgentTests gate suite needs.
public enum ScriptedTurn {
  /// A turn where the model produces final text and stops normally.
  public static func text(
    _ text: String,
    usage: Usage = Usage(inputTokens: 1, outputTokens: 1)
  ) -> [StreamEvent] {
    [
      .start,
      .textDelta(contentIndex: 0, text: text),
      .done(usage: usage, stopReason: .endTurn),
    ]
  }

  /// A turn where the model requests a single tool call and stops for
  /// tool use.
  public static func toolCall(
    id: String,
    name: String,
    argumentsJSON: String,
    usage: Usage = Usage(inputTokens: 1, outputTokens: 1)
  ) -> [StreamEvent] {
    [
      .start,
      .toolCallStart(contentIndex: 0, id: id, name: name),
      .toolCallDelta(contentIndex: 0, argumentsJSONDelta: argumentsJSON),
      .toolCallEnd(contentIndex: 0),
      .done(usage: usage, stopReason: .toolUse),
    ]
  }

  /// A turn that requests a tool call but reports a non-`.toolUse` stop
  /// reason, as some providers do — used to exercise `LOOP-1`, which keys
  /// the inner loop on tool calls remaining rather than on the stop reason.
  public static func toolCallStopping(
    id: String,
    name: String,
    argumentsJSON: String,
    stopReason: StopReason,
    usage: Usage = Usage(inputTokens: 1, outputTokens: 1)
  ) -> [StreamEvent] {
    [
      .start,
      .toolCallStart(contentIndex: 0, id: id, name: name),
      .toolCallDelta(contentIndex: 0, argumentsJSONDelta: argumentsJSON),
      .toolCallEnd(contentIndex: 0),
      .done(usage: usage, stopReason: stopReason),
    ]
  }

  /// A turn that requests a tool call but is cut off by the model's
  /// length limit before finishing — used to exercise `LOOP-4`.
  public static func toolCallTruncatedByLength(
    id: String,
    name: String,
    argumentsJSON: String,
    usage: Usage = Usage(inputTokens: 1, outputTokens: 1)
  ) -> [StreamEvent] {
    [
      .start,
      .toolCallStart(contentIndex: 0, id: id, name: name),
      .toolCallDelta(contentIndex: 0, argumentsJSONDelta: argumentsJSON),
      .done(usage: usage, stopReason: .length),
    ]
  }

  /// A turn where the model requests several tool calls at once and stops
  /// for tool use — used to exercise `LOOP-7`.
  ///
  /// - Parameters:
  ///   - calls: The requested calls, one content block each, in order.
  ///   - usage: The usage reported on the terminal `done` event.
  public static func toolCalls(
    _ calls: [(id: String, name: String, argumentsJSON: String)],
    usage: Usage = Usage(inputTokens: 1, outputTokens: 1)
  ) -> [StreamEvent] {
    var events: [StreamEvent] = [.start]
    for (index, call) in calls.enumerated() {
      events.append(.toolCallStart(contentIndex: index, id: call.id, name: call.name))
      events.append(.toolCallDelta(contentIndex: index, argumentsJSONDelta: call.argumentsJSON))
      events.append(.toolCallEnd(contentIndex: index))
    }
    events.append(.done(usage: usage, stopReason: .toolUse))
    return events
  }
}

/// Records how many tool executions overlapped, and which ones ran to
/// completion, so `LOOP-7` can be asserted without timing heuristics.
///
/// An actor rather than a lock-protected counter, per `CC-4`.
public actor ConcurrencyProbe {
  /// The highest number of `ConcurrencyProbeTool` executions that were
  /// in flight at the same time.
  public private(set) var maxConcurrent = 0

  /// The names of the tools that ran to completion, in completion order.
  /// A tool cancelled mid-execution never appears here.
  public private(set) var completedNames: [String] = []

  private var active = 0

  /// Creates a probe.
  public init() {}

  func begin() {
    active += 1
    maxConcurrent = max(maxConcurrent, active)
  }

  func end(name: String) {
    active -= 1
    completedNames.append(name)
  }
}

/// A tool that reports its overlap with other tools to a shared
/// `ConcurrencyProbe`, sleeps, and then finishes — used to exercise
/// `LOOP-7`'s parallel execution and `terminate: true` batch ending.
public struct ConcurrencyProbeTool: Tool {
  /// The arguments `ConcurrencyProbeTool` decodes its calls into.
  @Schemable
  public struct Arguments: Decodable, Sendable {
    /// An arbitrary payload the test script supplies.
    public var value: String

    /// Creates arguments.
    public init(value: String) {
      self.value = value
    }
  }

  /// This tool's name, as referenced by scripted `toolCall` events.
  public let name: String

  /// This tool's description.
  public let description: String

  private let probe: ConcurrencyProbe
  private let duration: Duration
  private let terminate: Bool

  /// Creates a probe tool.
  ///
  /// - Parameters:
  ///   - name: The name scripted `toolCall` events should reference.
  ///   - probe: The shared probe this tool reports to.
  ///   - duration: How long to sleep before finishing. A long sleep makes
  ///     a cancelled execution observable: it never reaches `probe`'s
  ///     completion list.
  ///   - terminate: The `terminate` flag of the returned `ToolResult`.
  public init(
    name: String,
    probe: ConcurrencyProbe,
    duration: Duration = .milliseconds(200),
    terminate: Bool = false
  ) {
    self.name = name
    self.description = "Reports tool-execution overlap to a shared probe."
    self.probe = probe
    self.duration = duration
    self.terminate = terminate
  }

  /// Sleeps for this tool's duration, reporting its overlap to the probe.
  public func execute(
    toolCallID: String,
    arguments: Arguments,
    signal: ToolCancellationSignal,
    onUpdate: @Sendable (ToolUpdate) -> Void
  ) async throws -> ToolResult {
    await probe.begin()
    try await Task.sleep(for: duration)
    await probe.end(name: name)
    return ToolResult(content: [.text("\(name) finished")], terminate: terminate)
  }
}

/// An `APIImplementation` that opens a stream and then never finishes it,
/// so a run can be aborted mid-stream deterministically (`LOOP-6`).
///
/// It yields `.start` — which reaches the caller as
/// `AgentEvent.messageUpdate(.start)` — and then sleeps until the
/// consuming task is cancelled.
public struct HangingProvider: APIImplementation {
  /// The wire protocol identifier this instance reports.
  public let id: APIImplementationID

  /// Creates a hanging provider.
  ///
  /// - Parameter id: The identifier this provider reports. Defaults to `.scripted`.
  public init(id: APIImplementationID = .scripted) {
    self.id = id
  }

  /// Yields `.start` and then hangs until cancelled.
  public func stream(request: LLMRequest, connection: ProviderConnection) -> AsyncThrowingStream<
    StreamEvent, any Error
  > {
    AsyncThrowingStream { continuation in
      let task = Task {
        continuation.yield(.start)
        do {
          try await Task.sleep(for: .seconds(30))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

/// Records the `LLMRequest`s an agent sends, so tests can assert on what
/// the conversation actually looked like on the wire.
///
/// An actor rather than a lock-protected array, per `CC-4`.
public actor RequestLog {
  /// Every request recorded, in send order.
  public private(set) var requests: [LLMRequest] = []

  /// Creates an empty log.
  public init() {}

  func record(_ request: LLMRequest) {
    requests.append(request)
  }
}

/// A `ScriptedProvider` that records each request into a `RequestLog`
/// before replaying that turn's scripted events.
public struct RequestRecordingProvider: APIImplementation {
  /// The wire protocol identifier this instance reports.
  public let id: APIImplementationID

  private let scripted: ScriptedProvider
  private let log: RequestLog

  /// Creates a recording provider.
  ///
  /// - Parameters:
  ///   - id: The identifier this provider reports. Defaults to `.scripted`.
  ///   - scripts: One `StreamEvent` sequence per expected turn, in call order.
  ///   - log: The log every request is recorded into.
  public init(
    id: APIImplementationID = .scripted,
    scripts: [[StreamEvent]],
    log: RequestLog
  ) {
    self.id = id
    self.scripted = ScriptedProvider(id: id, scripts: scripts)
    self.log = log
  }

  /// Records `request`, then replays the next scripted event sequence.
  public func stream(request: LLMRequest, connection: ProviderConnection) -> AsyncThrowingStream<
    StreamEvent, any Error
  > {
    let scripted = scripted
    let log = log

    return AsyncThrowingStream { continuation in
      let task = Task {
        await log.record(request)
        do {
          for try await event in scripted.stream(request: request, connection: connection) {
            continuation.yield(event)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
