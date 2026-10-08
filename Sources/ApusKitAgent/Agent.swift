public import ApusKitCore
public import ApusKitProviders
public import ApusKitTools
internal import Foundation

/// Owns one conversation's message state and drives it through the
/// pi-ported agent run loop against an injected provider and tool set.
///
/// Constructor-injected (`DI-1`): the provider, transport, and tools all
/// arrive through `init(apiImplementation:connection:model:tools:systemPrompt:)`
/// — `Agent` holds no singletons and no global mutable state. Cancel an
/// in-flight run with `abort()`; interruption is structured-concurrency
/// cancellation (`LOOP-6`), never a detached task.
public actor Agent {
  let apiImplementation: any APIImplementation
  let connection: ProviderConnection
  let model: String
  let systemPrompt: String?
  let tools: ToolRegistry

  var history: [LLMRequestMessage] = []
  var followUpQueue: [UserMessage] = []
  var runningTask: Task<AssistantMessage, Never>?

  var eventSubscribers: [UUID: AsyncStream<AgentEvent>.Continuation] = [:]

  /// Creates an agent.
  ///
  /// - Parameters:
  ///   - apiImplementation: The provider wire adapter to stream turns through.
  ///   - connection: Where and how to reach the provider.
  ///   - model: The model identifier to request.
  ///   - tools: The tools available to the model during this conversation.
  ///   - systemPrompt: An optional system prompt sent with every request.
  public init(
    apiImplementation: any APIImplementation,
    connection: ProviderConnection,
    model: String,
    tools: ToolRegistry,
    systemPrompt: String? = nil
  ) {
    self.apiImplementation = apiImplementation
    self.connection = connection
    self.model = model
    self.tools = tools
    self.systemPrompt = systemPrompt
  }

  deinit {
    // Without this, a consumer's `for await` over an event stream would
    // never return once the agent it observes has gone away.
    for continuation in eventSubscribers.values {
      continuation.finish()
    }
  }

  /// Returns a new stream of every event this agent's run loop produces.
  ///
  /// Each call returns an **independent** stream, so a UI, a logger and a
  /// session journal can observe the same agent without competing for
  /// events. `AgentEvent`'s cases mirror TRD §3.6: `agentStart/End`,
  /// `turnStart/End`, `messageStart/Update/End`, `toolExecutionStart/Update/End`.
  ///
  /// A stream spans the **agent's** lifetime, not one run: `run(_:)` may be
  /// called repeatedly, and each run is delimited by `.agentStart` and
  /// `.agentEnd`. To observe a single run, stop iterating at `.agentEnd`.
  /// The stream finishes when the agent is deinitialized.
  ///
  /// Events produced before this call are not replayed — create the stream
  /// before calling `run(_:)` to observe a run from its first event.
  ///
  /// - Parameter bufferingPolicy: How many undelivered events this stream
  ///   retains. The default bounds memory for a slow or absent consumer;
  ///   pass `.unbounded` only when losing an event is unacceptable and the
  ///   consumer is guaranteed to drain.
  public func makeEventStream(
    bufferingPolicy: AsyncStream<AgentEvent>.Continuation.BufferingPolicy = .bufferingNewest(256)
  ) -> AsyncStream<AgentEvent> {
    let (stream, continuation) = AsyncStream<AgentEvent>.makeStream(
      bufferingPolicy: bufferingPolicy)
    eventSubscribers[UUID()] = continuation
    return stream
  }

  /// Delivers `event` to every live subscriber, dropping any whose stream
  /// has ended.
  ///
  /// Pruning on yield is what keeps `eventSubscribers` from growing without
  /// bound as consumers come and go: a terminated continuation reports
  /// `.terminated` rather than needing an `onTermination` callback that
  /// would have to hop back onto this actor to clean up after itself.
  func emit(_ event: AgentEvent) {
    for (id, continuation) in eventSubscribers {
      if case .terminated = continuation.yield(event) {
        eventSubscribers.removeValue(forKey: id)
      }
    }
  }

  /// Queues `message` and drives the run loop (`LOOP-1`) until every
  /// queued message has produced a final assistant message.
  ///
  /// Returns the last final `AssistantMessage` produced. Per `LOOP-3`,
  /// this never throws: any failure is reported as a final message with
  /// `stopReason == .error` (or `.aborted`), both on the return value and
  /// on `events`.
  public func run(_ message: UserMessage) async -> AssistantMessage {
    followUpQueue.append(message)

    if let runningTask {
      return await runningTask.value
    }

    // The drain clears `runningTask` itself, in the same synchronous
    // stretch as its final empty-queue check, so no `run(_:)` can observe a
    // finished-but-non-nil task. Clearing it here, after this caller
    // resumes, left a window in which a racing call returned the previous
    // run's result and stranded its message (`LOOP-1`) — and, once a new
    // run had started in that window, would have cleared *its* task.
    let task = Task { await self.drainFollowUpQueue() }
    runningTask = task
    return await task.value
  }

  /// How many follow-up messages are queued but not yet drained.
  ///
  /// `package`-visible per `PKG-8` (never `@_spi`, never `public`): the
  /// `LOOP-1` outer-loop test has to wait until a concurrently queued
  /// message has actually landed in the queue before it releases the
  /// in-flight turn. Without an observable condition that test would have
  /// to guess with a yield count, and a guess that lands wrong makes the
  /// test pass for the wrong reason instead of failing.
  package var queuedFollowUpCount: Int {
    followUpQueue.count
  }

  /// Runs synchronously on the actor in a run's final stretch, just
  /// before `.agentEnd` is emitted.
  ///
  /// A test seam, `package`-visible per `PKG-8` (never `@_spi`, never
  /// `public`). The `run(_:)` race regression test (`TEST-7`) has to call
  /// `run(_:)` after a drain has decided to stop but before its first
  /// caller resumes. An event-stream observer cannot hit that window
  /// deterministically: `AsyncStream` wakes it on the generic executor, and
  /// its hop back to the actor races the first caller's resumption. A `Task`
  /// created here with the agent's isolation is enqueued on the actor
  /// directly, ahead of that resumption.
  package var runEndingProbe: (@Sendable (isolated Agent) -> Void)?

  /// Installs `probe` as `runEndingProbe`.
  package func setRunEndingProbe(_ probe: (@Sendable (isolated Agent) -> Void)?) {
    runEndingProbe = probe
  }

  /// Cancels any in-flight run.
  ///
  /// Per `LOOP-6`, `Agent` spawns no detached tasks: the task driving
  /// `run(_:)` and the structured task group driving parallel tool
  /// execution (`LOOP-7`) both unwind cooperatively once cancelled,
  /// producing a clean final message with `stopReason == .aborted`.
  public func abort() {
    runningTask?.cancel()
  }
}
