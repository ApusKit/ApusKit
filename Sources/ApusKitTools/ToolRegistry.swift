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

  /// Every registered tool, ordered by `name`.
  ///
  /// The order is part of the contract. The backing store is a dictionary,
  /// so an unsorted enumeration would vary run to run — and this collection
  /// feeds the tool list sent to the provider, where a flapping order
  /// churns the prompt prefix and defeats prompt caching. Sorting belongs
  /// here, once, rather than in each caller.
  ///
  /// - Complexity: O(*n* log *n*) in the number of registered tools.
  public var allTools: [AnyAgentTool] {
    tools.values.sorted { $0.name < $1.name }
  }
}
