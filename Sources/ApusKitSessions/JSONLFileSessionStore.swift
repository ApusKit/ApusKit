internal import ApusKitWireFormat
public import Foundation

/// The built-in ``SessionStore``: persists each session as its own JSONL
/// file, named `<sessionID>.hex.jsonl`, inside a directory the caller
/// supplies.
///
/// File paths always come in as parameters — nothing is hardcoded (`DI-1`).
/// Every requirement is `@concurrent` (inherited from ``SessionStore``),
/// so this store's synchronous `FileManager`/`Data` calls run off whatever
/// actor called them rather than blocking one (`CC-4`).
public struct JSONLFileSessionStore: SessionStore {
  /// The directory this store reads and writes session files in.
  public let directoryURL: URL

  /// Creates a store rooted at `directoryURL`.
  ///
  /// The directory is created on first use by `createSession(header:)` if
  /// it does not already exist.
  public init(directoryURL: URL) {
    self.directoryURL = directoryURL
  }

  private func fileURL(for sessionID: EntryID) -> URL {
    directoryURL.appendingPathComponent("\(sessionID.hex).jsonl")
  }

  /// Writes `header`'s session file with no entries.
  public func createSession(header: SessionHeader) async throws {
    let url = fileURL(for: header.sessionID)
    guard !FileManager.default.fileExists(atPath: url.path) else {
      throw SessionStoreError(
        code: .sessionAlreadyExists,
        message: "a session already exists for id \(header.sessionID.hex)"
      )
    }
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let bytes = try SessionFileCodec.encode(header: header, entries: [])
    try Data(bytes).write(to: url, options: .atomic)
  }

  /// Appends `entry`'s encoded line to the session file for `sessionID`.
  public func appendEntry(_ entry: SessionEntry, toSessionID sessionID: EntryID) async throws {
    let url = fileURL(for: sessionID)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw SessionStoreError(
        code: .sessionNotFound,
        message: "no session exists for id \(sessionID.hex)"
      )
    }
    let data = try JSONEncoder().encode(entry)
    // JSONEncoder always emits UTF-8 text, so this never actually loses bytes.
    let line = String(decoding: data, as: UTF8.self)
    let appendedBytes = Data(JSONLCodec.encode([line]))
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: appendedBytes)
  }

  /// Reads and decodes the session file for `sessionID`.
  public func loadSession(sessionID: EntryID) async throws -> SessionFileDecodeResult {
    let url = fileURL(for: sessionID)
    guard let data = FileManager.default.contents(atPath: url.path) else {
      throw SessionStoreError(
        code: .sessionNotFound,
        message: "no session exists for id \(sessionID.hex)"
      )
    }
    return try SessionFileCodec.decode(data)
  }

  /// Lists the session ids present in `directoryURL`, sorted by hex string.
  public func listSessionIDs() async throws -> [EntryID] {
    guard FileManager.default.fileExists(atPath: directoryURL.path) else {
      return []
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
    let ids = names.compactMap { name -> EntryID? in
      guard name.hasSuffix(".jsonl") else { return nil }
      return try? EntryID(hex: String(name.dropLast(".jsonl".count)))
    }
    return ids.sorted { $0.hex < $1.hex }
  }
}
