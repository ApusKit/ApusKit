/// A name-keyed store of type-erased tools, backed by `AnyAgentTool`.
///
/// Sealed — populate a `ToolRegistry` value rather than conforming to it.
public struct ToolRegistry: Sendable {
  private var tools: [String: AnyAgentTool] = [:]

  /// Creates an empty registry.
  public init() {}

  /// Type-erases and registers `tool`, keyed by its `name`.
  public mutating func register(_ tool: some Tool) {
    tools[tool.name] = AnyAgentTool(tool)
  }

  /// Registers an already type-erased tool, keyed by its `name`.
  public mutating func register(_ tool: AnyAgentTool) {
    tools[tool.name] = tool
  }

  /// Looks up a previously registered tool by `name`.
  public func tool(named name: String) -> AnyAgentTool? {
    tools[name]
  }

  /// Every registered tool, in no particular order.
  public var allTools: [AnyAgentTool] {
    Array(tools.values)
  }
}
