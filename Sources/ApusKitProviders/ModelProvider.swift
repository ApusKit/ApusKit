public import ApusKitCore
public import Foundation

/// How to authenticate with a provider.
public enum ProviderAuth: Sendable, Equatable {
  /// An API key sent in a provider-specific header.
  case apiKey(String)

  /// A bearer token sent as `Authorization: Bearer <token>`.
  case bearer(String)

  /// Arbitrary headers to attach to every request.
  case headers([String: String])

  /// No authentication.
  case none
}

/// A model available from a provider, including its pricing.
public struct ModelInfo: Sendable, Equatable {
  /// The model identifier, as understood by the provider.
  public var id: String

  /// The model's context window, in tokens.
  public var contextWindow: Int

  /// Pricing used to compute `Usage.cost(at:)` for this model (`PROV-3`).
  public var pricing: Pricing

  /// Creates a model info entry.
  public init(id: String, contextWindow: Int, pricing: Pricing) {
    self.id = id
    self.contextWindow = contextWindow
    self.pricing = pricing
  }
}

/// A catalog entry describing where and how to reach a provider's models.
///
/// Anyone can construct and inject a `ModelProvider` — the library never
/// hardcodes a vendor.
public struct ModelProvider: Sendable {
  /// The provider identifier, e.g. `"anthropic"`, `"openai"`, `"my-proxy"`.
  public var id: String

  /// The provider's base URL.
  public var baseURL: URL

  /// Which wire protocol the provider speaks.
  public var api: APIImplementationID

  /// How to authenticate with the provider.
  public var auth: ProviderAuth

  /// The models this provider offers.
  public var models: [ModelInfo]

  /// Creates a provider catalog entry.
  public init(
    id: String,
    baseURL: URL,
    api: APIImplementationID,
    auth: ProviderAuth,
    models: [ModelInfo]
  ) {
    self.id = id
    self.baseURL = baseURL
    self.api = api
    self.auth = auth
    self.models = models
  }
}
