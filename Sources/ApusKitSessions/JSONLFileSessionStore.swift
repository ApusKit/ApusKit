internal import ApusKitWireFormat
public import Foundation

/// The built-in ``SessionStore``: persists each session as its own JSONL
/// file, named `<sessionID>.hex.jsonl`, inside a directory the caller
/// supplies.
///
/// File paths always come in as parameters — nothing is hardcoded (`DI-1`).
/// Every witness repeats ``SessionStore``'s `@concurrent` annotation
/// explicitly (`CC-2`), so this store's synchronous `FileManager`/`Data`
/// calls run off whatever actor called them rather than blocking one
/// (`CC-4`).
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
  @concurrent
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
  ///
  /// If the existing file does not already end on a line terminator, one
  /// is written before the entry, so appending to a file another writer
  /// left unterminated still yields a readable session.
  @concurrent
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
    var appendedBytes = Data(JSONLCodec.encode([line]))
    // Opened for update, not writing, so the final byte can be read back
    // below.
    let handle = try FileHandle(forUpdating: url)
    defer { try? handle.close() }
    let end = try handle.seekToEnd()
    // A file written by someone else — a real pi v3 session, or a write
    // cut short — may not end on `LF`. Appending straight onto it would
    // concatenate two JSON objects onto one line and permanently break
    // `loadSession`, so terminate that line first.
    if end > 0 {
      try handle.seek(toOffset: end - 1)
      let lastByte = try handle.read(upToCount: 1)
      if lastByte != Data([0x0A]) {
        appendedBytes.insert(0x0A, at: appendedBytes.startIndex)
      }
      try handle.seekToEnd()
    }
    try handle.write(contentsOf: appendedBytes)
  }

  /// Reads and decodes the session file for `sessionID`.
  @concurrent
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
  @concurrent
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
