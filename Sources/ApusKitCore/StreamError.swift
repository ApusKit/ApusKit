/// An error surfaced by a provider's event stream.
///
/// Per `ERR-2`, public error types are structs wrapping a `@nonexhaustive`
/// `Code` enum rather than a monolithic public enum, so new failure kinds
/// can be added without a source break.
public struct StreamError: Sendable, Codable, Equatable, Error {
  /// The category of failure a `StreamError` represents.
  @nonexhaustive(warn)
  public enum Code: Sendable, Codable, Equatable {
    /// The underlying transport failed (connection drop, timeout, ...).
    case transport

    /// The provider rejected the request (auth, invalid payload, ...).
    case provider

    /// The provider's response could not be parsed into stream events.
    case decoding

    /// The stream was cancelled before it completed.
    case cancelled
  }

  /// The category of this failure.
  public var code: Code

  /// A human-readable description of what went wrong.
  public var message: String

  /// Creates a stream error.
  public init(code: Code, message: String) {
    self.code = code
    self.message = message
  }
}
