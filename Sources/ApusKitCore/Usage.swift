/// Token accounting for a single provider turn.
///
/// `ApusKitCore` must not import `ApusKitProviders` (`PKG-6`), so cost is
/// computed here from a caller-supplied `Pricing` value rather than looked
/// up from a provider catalog — see `cost(at:)`.
public struct Usage: Sendable, Codable, Equatable {
  /// Tokens in the request that were not served from cache.
  public var inputTokens: Int

  /// Tokens the model generated.
  public var outputTokens: Int

  /// Cached tokens read from a prompt cache.
  public var cacheReadTokens: Int

  /// Tokens written to a prompt cache for future reuse.
  public var cacheWriteTokens: Int

  /// Creates a token usage record.
  public init(
    inputTokens: Int,
    outputTokens: Int,
    cacheReadTokens: Int = 0,
    cacheWriteTokens: Int = 0
  ) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cacheReadTokens = cacheReadTokens
    self.cacheWriteTokens = cacheWriteTokens
  }

  /// Computes the monetary cost of this usage under the given `pricing`.
  ///
  /// Cost is never hardcoded in `ApusKitCore` (`PROV-3`): it is always
  /// derived from a `Pricing` value supplied by the caller, typically read
  /// from `ApusKitProviders`' `ModelInfo`.
  public func cost(at pricing: Pricing) -> Double {
    let millions = 1_000_000.0
    return Double(inputTokens) / millions * pricing.inputPerMillion
      + Double(outputTokens) / millions * pricing.outputPerMillion
      + Double(cacheReadTokens) / millions * pricing.cacheReadPerMillion
      + Double(cacheWriteTokens) / millions * pricing.cacheWritePerMillion
  }
}

/// Per-token-million pricing for a model, expressed in an unspecified but
/// consistent currency.
///
/// `Pricing` is a pure data type owned by `ApusKitCore` so that `Usage`
/// can expose `cost(at:)` without `ApusKitCore` depending on
/// `ApusKitProviders` (`PKG-6`, `PROV-3`).
public struct Pricing: Sendable, Codable, Equatable {
  /// Cost per million non-cached input tokens.
  public var inputPerMillion: Double

  /// Cost per million output tokens.
  public var outputPerMillion: Double

  /// Cost per million cache-read tokens.
  public var cacheReadPerMillion: Double

  /// Cost per million cache-write tokens.
  public var cacheWritePerMillion: Double

  /// Creates a pricing table.
  public init(
    inputPerMillion: Double,
    outputPerMillion: Double,
    cacheReadPerMillion: Double = 0,
    cacheWritePerMillion: Double = 0
  ) {
    self.inputPerMillion = inputPerMillion
    self.outputPerMillion = outputPerMillion
    self.cacheReadPerMillion = cacheReadPerMillion
    self.cacheWritePerMillion = cacheWritePerMillion
  }
}
