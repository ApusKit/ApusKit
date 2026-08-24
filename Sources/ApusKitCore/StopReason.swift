/// Why a provider stream stopped producing an assistant turn.
///
/// This enum is wire-facing: providers report a stop reason and it is
/// persisted with the message. `@nonexhaustive(warn)` (`ENUM-1`) lets
/// `ApusKit` add new reasons without a source break; consumers should
/// switch over this type with `@unknown default`.
@nonexhaustive(warn)
public enum StopReason: Sendable, Codable, Equatable {
  /// The model finished its turn normally.
  case endTurn

  /// The model stopped in order to invoke one or more tools.
  case toolUse

  /// The model hit its output token/length limit mid-generation.
  case length

  /// The turn was cancelled by the caller (see `Agent.abort()`).
  case aborted

  /// The turn ended because of a provider or transport error.
  case error
}
