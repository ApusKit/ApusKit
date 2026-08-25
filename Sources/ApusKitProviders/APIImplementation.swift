public import ApusKitCore
public import Foundation

/// The identifier of a wire protocol an `APIImplementation` speaks.
///
/// Modeled as an extensible identifier rather than a closed enum so
/// consumers can register their own `APIImplementation`s under their own
/// identifiers (`PROV-4`) alongside the library's built-in ones.
public struct APIImplementationID: Sendable, Codable, Equatable, Hashable {
  /// The underlying string identifier, e.g. `"anthropic-messages"`.
  public var rawValue: String

  /// Creates an identifier from its raw string form.
  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

extension APIImplementationID {
  /// The Anthropic Messages API wire protocol.
  public static let anthropicMessages = APIImplementationID(rawValue: "anthropic-messages")

  /// The OpenAI Chat Completions API wire protocol.
  public static let openAICompletions = APIImplementationID(rawValue: "openai-completions")

  /// The OpenAI Responses API wire protocol.
  public static let openAIResponses = APIImplementationID(rawValue: "openai-responses")
}

/// One turn of conversation history sent to a provider.
///
/// Wraps `ApusKitCore`'s message types directly so that context stays
/// provider-neutral (`PROV-2`): no provider-specific state is smuggled
/// into the conversation, and switching providers mid-session requires no
/// message conversion.
@nonexhaustive(warn)
public enum LLMRequestMessage: Sendable, Equatable {
  /// A message from the user.
  case user(UserMessage)

  /// A prior message from the model.
  case assistant(AssistantMessage)

  /// The result of a prior tool call.
  case toolResult(ToolResultMessage)
}

/// A request for a single conversational turn from a provider.
public struct LLMRequest: Sendable, Equatable {
  /// The target model identifier, as understood by the provider.
  public var model: String

  /// The conversation so far, oldest first.
  public var messages: [LLMRequestMessage]

  /// An optional system prompt.
  public var systemPrompt: String?

  /// Indices into `messages` marking prompt-cache breakpoints (`PROV-2`).
  ///
  /// Each index names a message whose trailing content is a natural
  /// prompt-cache boundary: everything up to and including that message is
  /// intended to be cached together. This is a provider-neutral *hint* —
  /// context itself carries no provider-specific state. The Anthropic
  /// adapter renders each breakpoint as `cache_control` on the
  /// corresponding message's last content block; the OpenAI adapters have
  /// no equivalent wire concept and ignore this field without error.
  public var cacheBreakpoints: Set<Int>

  /// Tool definitions available to the model for this request (`R4`).
  ///
  /// Provider-neutral: each entry carries a name, a description, and a
  /// JSON-Schema `parameters` value. Defaults to empty so every existing
  /// caller stays source-compatible.
  public var tools: [ToolDefinition]

  /// Creates a request.
  public init(
    model: String,
    messages: [LLMRequestMessage],
    systemPrompt: String? = nil,
    cacheBreakpoints: Set<Int> = [],
    tools: [ToolDefinition] = []
  ) {
    self.model = model
    self.messages = messages
    self.systemPrompt = systemPrompt
    self.cacheBreakpoints = cacheBreakpoints
    self.tools = tools
  }
}

/// Where and how to reach a provider for one request.
///
/// Resolved from a `ModelProvider` (base URL, auth) plus the transport to
/// stream bytes through, and handed to `APIImplementation.stream(request:connection:)`.
public struct ProviderConnection: Sendable {
  /// The provider's base URL.
  public var baseURL: URL

  /// How to authenticate with the provider.
  public var auth: ProviderAuth

  /// The transport used to stream the underlying HTTP bytes.
  public var transport: any StreamingHTTPTransport

  /// Creates a connection.
  public init(baseURL: URL, auth: ProviderAuth, transport: any StreamingHTTPTransport) {
    self.baseURL = baseURL
    self.auth = auth
    self.transport = transport
  }
}

/// Wire adapter: builds provider requests and parses the response stream
/// into unified `StreamEvent`s.
///
/// Conform freely — this is the primary extension point for adding
/// support for a new provider's wire protocol.
public protocol APIImplementation: Sendable {
  /// Which wire protocol this implementation speaks.
  var id: APIImplementationID { get }

  /// Streams a single conversational turn as unified `StreamEvent`s.
  ///
  /// Conforming implementations MUST uphold `PROV-1`: exactly one
  /// `.start` first, exactly one terminal `.done` or `.error` last, and a
  /// `contentIndex` on every `toolCall*` event.
  func stream(request: LLMRequest, connection: ProviderConnection) -> AsyncThrowingStream<
    StreamEvent, any Error
  >
}
