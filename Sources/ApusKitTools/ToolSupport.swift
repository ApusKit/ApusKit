/// Lets a running tool observe whether the agent loop has cancelled its
/// enclosing tool call.
///
/// Cancellation is structured-concurrency cancellation (`LOOP-6`): a tool
/// author checks `isCancelled` cooperatively during long-running work
/// rather than being torn down unexpectedly.
public struct ToolCancellationSignal: Sendable {
  /// Creates a cancellation signal.
  public init() {}

  /// Whether the task executing the tool has been cancelled.
  public var isCancelled: Bool {
    Task.isCancelled
  }
}

/// A progress update a tool reports while it is still running.
///
/// Delivered through `Tool.execute`'s `onUpdate` callback so a host can
/// show partial progress before the final `ToolResult` is available.
public struct ToolUpdate: Sendable, Equatable {
  /// A human-readable progress message.
  public var message: String

  /// Creates a progress update.
  public init(message: String) {
    self.message = message
  }
}
