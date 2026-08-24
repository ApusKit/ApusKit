/// An error `Agent` failed to keep internal to its run loop.
///
/// Per `LOOP-3`, the run loop itself never lets an error escape — failures
/// become a final `AssistantMessage` with `stopReason == .error`. This
/// type exists per `ERR-2` (a struct wrapping a `@nonexhaustive` `Code`
/// enum) as the error the loop wraps failures in on its way to that final
/// message, and as the public error type for any other `ApusKitAgent` API
/// that does throw.
public struct AgentError: Sendable, Equatable, Error {
  /// The category of failure an `AgentError` represents.
  @nonexhaustive(warn)
  public enum Code: Sendable, Equatable {
    /// The provider's stream ended in an error.
    case providerStream

    /// The run was cancelled (see `Agent.abort()`).
    case cancelled
  }

  /// The category of this failure.
  public var code: Code

  /// A human-readable description of what went wrong.
  public var message: String

  /// Creates an agent error.
  public init(code: Code, message: String) {
    self.code = code
    self.message = message
  }
}
