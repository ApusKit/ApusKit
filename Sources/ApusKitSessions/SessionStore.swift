/// An error a ``SessionStore`` throws when it cannot satisfy a request.
///
/// Per `ERR-2`, this is a struct wrapping a `@nonexhaustive` `Code` enum
/// rather than a public enum of its own.
public struct SessionStoreError: Sendable, Equatable, Error {
  /// The category of failure a ``SessionStoreError`` represents.
  @nonexhaustive(warn)
  public enum Code: Sendable, Equatable {
    /// No session with the requested id exists in this store.
    case sessionNotFound

    /// A session with the given id already exists in this store.
    case sessionAlreadyExists
  }

  /// The category of this failure.
  public var code: Code

  /// A human-readable description of what went wrong.
  public var message: String

  /// Creates a session store error.
  public init(code: Code, message: String) {
    self.code = code
    self.message = message
  }
}

/// Pluggable storage for a session's header and entries (`§3.5`, `F3.4`).
///
/// `SessionStore` knows nothing about tree structure or context rebuild —
/// it only persists and retrieves the flat, append-ordered entries a
/// session holds; branching, forking, and leaf-to-root rebuild are built
/// on top of what it returns, keyed by each entry's `parentID`. Conform
/// freely: this is one of `ACC-2`'s client-conformable protocols, so a
/// consumer can back a session in a database, cloud storage, or anything
/// else instead of the filesystem.
public protocol SessionStore: Sendable {
  /// Creates a new, empty session identified by `header.sessionID`.
  ///
  /// - Throws: ``SessionStoreError`` with code `.sessionAlreadyExists` if
  ///   a session with that id already exists in this store.
  @concurrent
  func createSession(header: SessionHeader) async throws

  /// Appends `entry` to the session identified by `sessionID`.
  ///
  /// Entries are appended in call order, independent of `entry.parentID`
  /// — the tree structure branching relies on lives in each entry's
  /// `parentID`, not in append position (`§3.5`).
  ///
  /// - Throws: ``SessionStoreError`` with code `.sessionNotFound` if no
  ///   session with `sessionID` exists in this store.
  @concurrent
  func appendEntry(_ entry: SessionEntry, toSessionID sessionID: EntryID) async throws

  /// Loads a session's header and every entry appended to it, in append
  /// order.
  ///
  /// - Throws: ``SessionStoreError`` with code `.sessionNotFound` if no
  ///   session with `sessionID` exists in this store.
  @concurrent
  func loadSession(sessionID: EntryID) async throws -> SessionFileDecodeResult

  /// Lists the ids of every session this store holds, in a deterministic
  /// order (`API-4`): ascending by `EntryID.hex`.
  @concurrent
  func listSessionIDs() async throws -> [EntryID]
}
