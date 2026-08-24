/// A publicly re-exported dependency: `Data` for image payloads.
public import Foundation

/// A single unit of message content.
///
/// Assistant messages are built up from a sequence of content blocks as a
/// provider streams a response; user messages and tool results carry
/// content blocks too.
public enum ContentBlock: Sendable, Codable, Equatable {
  /// Plain text content.
  case text(String)

  /// An inline image, carried as raw bytes plus its MIME type.
  ///
  /// There is deliberately no URL case: providers that accept image URLs
  /// are expected to fetch and inline the bytes before constructing this
  /// block, keeping `ApusKitCore` free of networking (`CORE-1`).
  case image(data: Data, mimeType: String)

  /// A model's visible reasoning/thinking text.
  case thinking(String)

  /// A request from the model to invoke a tool.
  ///
  /// `argumentsJSON` carries the call arguments as a JSON string rather
  /// than a decoded value, so `ApusKitCore` stays dependency-free.
  case toolCall(id: String, name: String, argumentsJSON: String)
}
