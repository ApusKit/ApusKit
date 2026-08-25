/// The first line of a session file: format version and session identity.
///
/// A session file is a header line followed by ``SessionEntry`` lines
/// (`R2`); the header identifies which session the entries below belong
/// to and which wire format version they were written in.
public struct SessionHeader: Sendable, Codable, Equatable {
  /// The pi v3 session-file format version (`§3.5`, "pi v3
  /// wire-compatible").
  public static let currentVersion = 3

  /// The session-file format version this header and the entries that
  /// follow it conform to.
  public var version: Int

  /// This session's id.
  public var sessionID: EntryID

  /// Creates a session header.
  public init(version: Int, sessionID: EntryID) {
    self.version = version
    self.sessionID = sessionID
  }

  private enum CodingKeys: String, CodingKey {
    case version
    case sessionID = "sessionId"
  }
}
