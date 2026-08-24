public import ApusKitCore
public import ApusKitProviders
public import ApusKitTools

/// Owns one conversation's message state and drives it through the
/// pi-ported agent run loop against an injected provider and tool set.
///
/// Constructor-injected (`DI-1`): the provider, transport, and tools all
/// arrive through `init(apiImplementation:connection:model:pricing:tools:systemPrompt:)`
/// — `Agent` holds no singletons and no global mutable state. Cancel an
/// in-flight run with `abort()`; interruption is structured-concurrency
/// cancellation (`LOOP-6`), never a detached task.
public actor Agent {
  let apiImplementation: any APIImplementation
  let connection: ProviderConnection
  let model: String
  let systemPrompt: String?
  let pricing: Pricing
  let tools: ToolRegistry

  var history: [LLMRequestMessage] = []
  var followUpQueue: [UserMessage] = []
  var runningTask: Task<AssistantMessage, Never>?

  let eventContinuation: AsyncStream<AgentEvent>.Continuation

  /// A stream of every event this agent's run loop produces.
  ///
  /// `AgentEvent`'s cases mirror TRD §3.6: `agentStart/End`, `turnStart/End`,
  /// `messageStart/Update/End`, `toolExecutionStart/Update/End`.
  public let events: AsyncStream<AgentEvent>

  /// Creates an agent.
  ///
  /// - Parameters:
  ///   - apiImplementation: The provider wire adapter to stream turns through.
  ///   - connection: Where and how to reach the provider.
  ///   - model: The model identifier to request.
  ///   - pricing: Used to compute `Usage.cost(at:)` for reporting (`PROV-3`);
  ///     never hardcoded by `Agent` itself.
  ///   - tools: The tools available to the model during this conversation.
  ///   - systemPrompt: An optional system prompt sent with every request.
  public init(
    apiImplementation: any APIImplementation,
    connection: ProviderConnection,
    model: String,
    pricing: Pricing,
    tools: ToolRegistry,
    systemPrompt: String? = nil
  ) {
    self.apiImplementation = apiImplementation
    self.connection = connection
    self.model = model
    self.pricing = pricing
    self.tools = tools
    self.systemPrompt = systemPrompt
    (self.events, self.eventContinuation) = AsyncStream.makeStream()
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

    let task = Task { await self.drainFollowUpQueue() }
    runningTask = task
    let result = await task.value
    runningTask = nil
    return result
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
