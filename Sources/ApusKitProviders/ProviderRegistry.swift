/// A runtime catalog of providers and their `APIImplementation`s.
///
/// This is the injection point consumers use to make a provider (built-in
/// or custom) available to the agent loop — the analog of pi's
/// `models.json` / `registerProvider`. `ProviderRegistry` is sealed: it is
/// a value type you populate, not a protocol you conform to.
public struct ProviderRegistry: Sendable {
  private var providers: [String: ModelProvider] = [:]
  private var implementations: [APIImplementationID: any APIImplementation] = [:]

  /// Creates an empty registry.
  public init() {}

  /// Registers (or replaces) a provider catalog entry, keyed by its `id`.
  public mutating func register(_ provider: ModelProvider) {
    providers[provider.id] = provider
  }

  /// Registers (or replaces) an `APIImplementation`, keyed by its `id`.
  public mutating func register(_ impl: any APIImplementation) {
    implementations[impl.id] = impl
  }

  /// Looks up a previously registered provider by its `id`.
  public func provider(id: String) -> ModelProvider? {
    providers[id]
  }

  /// Looks up a previously registered `APIImplementation` by its `id`.
  public func implementation(id: APIImplementationID) -> (any APIImplementation)? {
    implementations[id]
  }
}
