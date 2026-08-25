internal import ApusKitCore
public import Foundation

/// Built-in provider catalog: documented static factory functions that
/// build an ordinary, public `ModelProvider` for a well-known vendor.
///
/// None of these factories is invoked anywhere inside the library, and
/// calling one registers nothing by itself — a consumer must explicitly
/// hand the result to a `ProviderRegistry`. That keeps the library's
/// promise of never hardcoding a vendor (TRD §0) intact: the catalog is
/// opt-in sugar over the injectable `ModelProvider` type, not a
/// compiled-in registration. Every field on the returned `ModelProvider`
/// and its `ModelInfo` entries is a public `var`, so a consumer can
/// override the base URL, swap the auth, or replace the model list
/// wholesale before registering it.
///
/// Pricing and context-window figures are illustrative of each vendor's
/// published rates at the time this catalog was authored and may drift —
/// override `models` on the returned value to keep them current.
extension ModelProvider {
  /// Anthropic's Messages API.
  public static func anthropic(apiKey: String) -> ModelProvider {
    ModelProvider(
      id: "anthropic",
      baseURL: catalogURL("https://api.anthropic.com/v1"),
      api: .anthropicMessages,
      auth: .apiKey(apiKey),
      models: [
        ModelInfo(
          id: "claude-opus-4-1-20250805",
          contextWindow: 200_000,
          pricing: Pricing(
            inputPerMillion: 15, outputPerMillion: 75,
            cacheReadPerMillion: 1.5, cacheWritePerMillion: 18.75)
        ),
        ModelInfo(
          id: "claude-sonnet-4-5-20250929",
          contextWindow: 200_000,
          pricing: Pricing(
            inputPerMillion: 3, outputPerMillion: 15,
            cacheReadPerMillion: 0.3, cacheWritePerMillion: 3.75)
        ),
        ModelInfo(
          id: "claude-haiku-4-5-20251001",
          contextWindow: 200_000,
          pricing: Pricing(
            inputPerMillion: 1, outputPerMillion: 5,
            cacheReadPerMillion: 0.1, cacheWritePerMillion: 1.25)
        ),
      ]
    )
  }

  /// OpenAI's Responses API.
  public static func openAI(apiKey: String) -> ModelProvider {
    ModelProvider(
      id: "openai",
      baseURL: catalogURL("https://api.openai.com/v1"),
      api: .openAIResponses,
      auth: .bearer(apiKey),
      models: [
        ModelInfo(
          id: "gpt-5",
          contextWindow: 400_000,
          pricing: Pricing(inputPerMillion: 1.25, outputPerMillion: 10, cacheReadPerMillion: 0.125)
        ),
        ModelInfo(
          id: "gpt-5-mini",
          contextWindow: 400_000,
          pricing: Pricing(inputPerMillion: 0.25, outputPerMillion: 2, cacheReadPerMillion: 0.025)
        ),
      ]
    )
  }

  /// Google's OpenAI-compatible Gemini endpoint.
  ///
  /// Google speaks no wire protocol of its own in this catalog — it is
  /// reached through the same `openai-completions` `APIImplementation`
  /// used for `openRouter`, `groq`, and `ollama`, at Google's
  /// OpenAI-compatibility base URL.
  public static func google(apiKey: String) -> ModelProvider {
    ModelProvider(
      id: "google",
      baseURL: catalogURL("https://generativelanguage.googleapis.com/v1beta/openai"),
      api: .openAICompletions,
      auth: .bearer(apiKey),
      models: [
        ModelInfo(
          id: "gemini-2.5-pro",
          contextWindow: 1_048_576,
          pricing: Pricing(inputPerMillion: 1.25, outputPerMillion: 10)
        ),
        ModelInfo(
          id: "gemini-2.5-flash",
          contextWindow: 1_048_576,
          pricing: Pricing(inputPerMillion: 0.3, outputPerMillion: 2.5)
        ),
      ]
    )
  }

  /// OpenRouter's OpenAI-compatible model marketplace.
  public static func openRouter(apiKey: String) -> ModelProvider {
    ModelProvider(
      id: "openrouter",
      baseURL: catalogURL("https://openrouter.ai/api/v1"),
      api: .openAICompletions,
      auth: .bearer(apiKey),
      models: [
        ModelInfo(
          id: "anthropic/claude-sonnet-4.5",
          contextWindow: 200_000,
          pricing: Pricing(inputPerMillion: 3, outputPerMillion: 15)
        ),
        ModelInfo(
          id: "openai/gpt-5",
          contextWindow: 400_000,
          pricing: Pricing(inputPerMillion: 1.25, outputPerMillion: 10)
        ),
      ]
    )
  }

  /// Groq's OpenAI-compatible low-latency inference endpoint.
  public static func groq(apiKey: String) -> ModelProvider {
    ModelProvider(
      id: "groq",
      baseURL: catalogURL("https://api.groq.com/openai/v1"),
      api: .openAICompletions,
      auth: .bearer(apiKey),
      models: [
        ModelInfo(
          id: "llama-3.3-70b-versatile",
          contextWindow: 128_000,
          pricing: Pricing(inputPerMillion: 0.59, outputPerMillion: 0.79)
        )
      ]
    )
  }

  /// Ollama's default local base URL.
  public static let defaultOllamaBaseURL: URL = catalogURL("http://localhost:11434/v1")

  /// A local (or otherwise self-hosted) Ollama server exposing its
  /// OpenAI-compatible endpoint.
  ///
  /// `baseURL` defaults to Ollama's default local port but accepts any
  /// OpenAI-compatible base URL, per TRD §3.3's "Ollama/local (any
  /// OpenAI-compatible baseURL)". Local models carry no published
  /// per-token price, so `models` defaults to empty — pass the models you
  /// have pulled, with `Pricing` zeroed or set to your own accounting.
  public static func ollama(
    baseURL: URL = ModelProvider.defaultOllamaBaseURL,
    models: [ModelInfo] = []
  ) -> ModelProvider {
    ModelProvider(
      id: "ollama",
      baseURL: baseURL,
      api: .openAICompletions,
      auth: .none,
      models: models
    )
  }

  /// Builds a `URL` from a fixed, known-valid literal without a force
  /// unwrap (`FORB-2`). Falls back to a file URL only if `string` were
  /// ever malformed — none of this catalog's literals are.
  private static func catalogURL(_ string: String) -> URL {
    URL(string: string) ?? URL(fileURLWithPath: string)
  }
}
