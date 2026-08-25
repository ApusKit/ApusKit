/// An error validating an ``EntryID``.
///
/// Per `ERR-2`, this is a struct wrapping a `@nonexhaustive` `Code` enum
/// rather than a public enum of its own.
public struct EntryIDError: Sendable, Equatable, Error {
  /// The category of failure an ``EntryIDError`` represents.
  @nonexhaustive(warn)
  public enum Code: Sendable, Equatable {
    /// The string was not exactly 8 hexadecimal digits.
    case invalidFormat
  }

  /// The category of this failure.
  public var code: Code

  /// A human-readable description of what went wrong.
  public var message: String

  /// Creates an id validation error.
  public init(code: Code, message: String) {
    self.code = code
    self.message = message
  }
}

/// An 8-hex-character identifier for a ``SessionEntry`` and its
/// `parentID`.
///
/// Pi's v3 session format identifies entries with short hex ids rather
/// than UUIDs, so entries stay compact and session files stay
/// human-diffable. Entries sharing a `parentID` are siblings — the branch
/// point that makes in-place branching and forking possible (`§3.5`).
public struct EntryID: Sendable, Hashable, Codable {
  /// The 8-character lowercase hex string this id wraps.
  public let hex: String

  /// Creates an id from an already-formed string.
  ///
  /// - Throws: ``EntryIDError`` if `hex` is not exactly 8 hexadecimal
  ///   digits.
  public init(hex: String) throws {
    guard Self.isValidHex(hex) else {
      throw EntryIDError(
        code: .invalidFormat,
        message: "EntryID must be 8 hex characters, got \"\(hex)\""
      )
    }
    self.hex = hex.lowercased()
  }

  private init(validated hex: String) {
    self.hex = hex
  }

  /// Mints a new random id.
  ///
  /// `generator` is injected (`DI-1`) rather than drawn from a global
  /// source, so id minting stays deterministic under test.
  public static func random(using generator: inout some RandomNumberGenerator) -> EntryID {
    let digits = Array("0123456789abcdef")
    var hex = ""
    hex.reserveCapacity(8)
    for _ in 0..<8 {
      hex.append(digits[Int.random(in: 0..<digits.count, using: &generator)])
    }
    return EntryID(validated: hex)
  }

  private static func isValidHex(_ string: String) -> Bool {
    string.count == 8 && string.allSatisfy(\.isHexDigit)
  }

  /// Decodes an id from a single JSON string value.
  ///
  /// - Throws: `DecodingError` if the string is not exactly 8 hexadecimal
  ///   digits.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    guard Self.isValidHex(raw) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "EntryID must be 8 hex characters, got \"\(raw)\""
      )
    }
    self.hex = raw.lowercased()
  }

  /// Encodes this id as a single JSON string value.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(hex)
  }
}
