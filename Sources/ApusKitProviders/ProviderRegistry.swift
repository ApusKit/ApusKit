public import ApusKitCore

/// An error resolving a model, provider, or `APIImplementation` from a
/// `ProviderRegistry`.
///
/// Per `ERR-2`, this is a struct wrapping a `@nonexhaustive` `Code` enum
/// rather than a public enum, so new failure kinds can be added without a
/// source break.
public struct ProviderRegistryError: Sendable, Equatable, Error {
  /// The category of failure a `ProviderRegistryError` represents.
  @nonexhaustive(warn)
  public enum Code: Sendable, Equatable {
    /// No registered provider lists a model with the requested id.
    case unknownModel

    /// A provider was found, but no `APIImplementation` is registered
    /// under its `APIImplementationID`.
    case unregisteredImplementation
  }

  /// The category of this failure.
  public var code: Code

  /// A human-readable description of what went wrong.
  public var message: String

  /// Creates a registry resolution error.
  public init(code: Code, message: String) {
    self.code = code
    self.message = message
  }
}

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

  /// Resolves `model` to its registered provider, matching
  /// `APIImplementation`, and a `ProviderConnection` built from that
  /// provider's `baseURL`/`auth` plus the injected `transport`.
  ///
  /// `transport` is always supplied by the caller (`DI-3`): a registry
  /// never constructs or defaults to a live transport itself.
  ///
  /// - Throws: `ProviderRegistryError` with code `.unknownModel` if no
  ///   registered provider lists `model`, or `.unregisteredImplementation`
  ///   if the matching provider's `APIImplementationID` has no registered
  ///   `APIImplementation`.
  public func resolve(
    model: String,
    transport: any StreamingHTTPTransport
  ) throws -> (
    provider: ModelProvider, implementation: any APIImplementation, connection: ProviderConnection
  ) {
    let (provider, _) = try lookup(model: model)
    guard let implementation = implementations[provider.api] else {
      throw ProviderRegistryError(
        code: .unregisteredImplementation,
        message:
          "No APIImplementation is registered for \"\(provider.api.rawValue)\", required by provider \"\(provider.id)\"."
      )
    }
    let connection = ProviderConnection(
      baseURL: provider.baseURL, auth: provider.auth, transport: transport)
    return (provider, implementation, connection)
  }

  /// Computes the monetary cost of `usage` for `model`, derived from the
  /// resolved provider's `ModelInfo.pricing` via `Usage.cost(at:)`
  /// (`PROV-3`) — never a rate hardcoded in this target.
  ///
  /// - Throws: `ProviderRegistryError` with code `.unknownModel` if no
  ///   registered provider lists `model`.
  public func cost(of usage: Usage, model: String) throws -> Double {
    let (_, info) = try lookup(model: model)
    return usage.cost(at: info.pricing)
  }

  /// Finds the registered provider that lists `model`, and that model's
  /// catalog entry.
  private func lookup(model: String) throws -> (provider: ModelProvider, info: ModelInfo) {
    for provider in providers.values {
      if let info = provider.models.first(where: { $0.id == model }) {
        return (provider, info)
      }
    }
    throw ProviderRegistryError(
      code: .unknownModel,
      message: "No registered provider offers model \"\(model)\"."
    )
  }
}
