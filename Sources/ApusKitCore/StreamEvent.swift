/// A single event in a provider's unified streaming response.
///
/// `APIImplementation`s in `ApusKitProviders` translate a vendor's wire
/// format into a sequence of `StreamEvent`s. Per `PROV-1`, a well-formed
/// stream for one request contains exactly one `start` first, exactly one
/// terminal `done` or `error` last, and every `toolCall*` event carries a
/// `contentIndex` identifying which content block it belongs to.
///
/// This enum is wire-facing and `@nonexhaustive(warn)` (`ENUM-1`);
/// consumers should switch over it with `@unknown default`.
@nonexhaustive(warn)
public enum StreamEvent: Sendable, Codable, Equatable {
  /// The stream has begun producing a new assistant turn.
  case start

  /// An incremental chunk of visible text for the content block at
  /// `contentIndex`.
  case textDelta(contentIndex: Int, text: String)

  /// An incremental chunk of thinking text for the content block at
  /// `contentIndex`.
  case thinkingDelta(contentIndex: Int, text: String)

  /// A new tool-call content block has started at `contentIndex`.
  case toolCallStart(contentIndex: Int, id: String, name: String)

  /// An incremental chunk of a tool call's arguments JSON, for the content
  /// block at `contentIndex`.
  case toolCallDelta(contentIndex: Int, argumentsJSONDelta: String)

  /// The tool-call content block at `contentIndex` is complete.
  case toolCallEnd(contentIndex: Int)

  /// The stream finished normally with the given usage and stop reason.
  case done(usage: Usage, stopReason: StopReason)

  /// The stream finished because of an error.
  case error(StreamError)
}
