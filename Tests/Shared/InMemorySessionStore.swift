public import ApusKitSessions

/// An in-memory ``SessionStore`` fake for tests: holds each session's
/// header and entries in memory instead of on disk (`TEST-2`).
///
/// An actor rather than a lock-protected dictionary, per `CC-4`.
public actor InMemorySessionStore: SessionStore {
  private var sessions: [EntryID: (header: SessionHeader, entries: [SessionEntry])] = [:]

  /// Creates an empty store.
  public init() {}

  /// Records `header`'s session with no entries.
  public func createSession(header: SessionHeader) async throws {
    guard sessions[header.sessionID] == nil else {
      throw SessionStoreError(
        code: .sessionAlreadyExists,
        message: "a session already exists for id \(header.sessionID.hex)"
      )
    }
    sessions[header.sessionID] = (header: header, entries: [])
  }

  /// Appends `entry` to the recorded session for `sessionID`.
  public func appendEntry(_ entry: SessionEntry, toSessionID sessionID: EntryID) async throws {
    guard var session = sessions[sessionID] else {
      throw SessionStoreError(
        code: .sessionNotFound,
        message: "no session exists for id \(sessionID.hex)"
      )
    }
    session.entries.append(entry)
    sessions[sessionID] = session
  }

  /// Returns the recorded header and entries for `sessionID`.
  public func loadSession(sessionID: EntryID) async throws -> SessionFileDecodeResult {
    guard let session = sessions[sessionID] else {
      throw SessionStoreError(
        code: .sessionNotFound,
        message: "no session exists for id \(sessionID.hex)"
      )
    }
    return SessionFileDecodeResult(header: session.header, entries: session.entries, trailing: [])
  }

  /// Lists the recorded session ids, sorted by hex string.
  public func listSessionIDs() async throws -> [EntryID] {
    sessions.keys.sorted { $0.hex < $1.hex }
  }
}
