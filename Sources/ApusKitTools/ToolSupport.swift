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
