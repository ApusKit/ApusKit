internal import Foundation
public import JSONSchema

/// A provider-neutral definition of a tool the model may call.
///
/// Carries just what an `APIImplementation` needs to describe a tool on
/// the wire (`R4`): a name, a human-readable description, and its
/// arguments schema as a `JSONValue`. This is a sealed value type
/// (`ACC-2`), not a protocol — construct one directly, or derive it from a
/// `Schemable`-conforming type in `ApusKitTools`.
public struct ToolDefinition: Sendable, Equatable {
  /// The tool's name, as the model refers to it in a tool call.
  public var name: String

  /// A human-readable description of what the tool does and when to use it.
  public var description: String

  /// The tool's arguments schema, as JSON Schema.
  public var parameters: JSONValue

  /// Creates a tool definition.
  public init(name: String, description: String, parameters: JSONValue) {
    self.name = name
    self.description = description
    self.parameters = parameters
  }
}

extension JSONValue {
  /// Converts this value to the loosely-typed representation
  /// `JSONSerialization` expects, for adapters that build request bodies
  /// as `[String: Any]`.
  var jsonSerializationValue: Any {
    switch self {
    case .string(let value):
      return value
    case .number(let value):
      return value
    case .integer(let value):
      return value
    case .object(let value):
      return value.mapValues { $0.jsonSerializationValue }
    case .array(let value):
      return value.map { $0.jsonSerializationValue }
    case .boolean(let value):
      return value
    case .null:
      return NSNull()
    }
  }
}
