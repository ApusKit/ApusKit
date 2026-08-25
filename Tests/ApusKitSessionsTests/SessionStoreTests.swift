// SessionStoreTests
//
// R7: `SessionStore` is client-conformable, `JSONLFileSessionStore` is the
// built-in conformance, and `InMemorySessionStore` is the TestSupport
// fake. Both are driven through the same contract here — create a
// session, load it back, append entries in append order, list ids
// deterministically, and surface `.sessionAlreadyExists` /
// `.sessionNotFound` the same way regardless of backing.

import ApusKitCore
import ApusKitSessions
import Foundation
import TestSupport
import Testing

/// A deterministic `RandomNumberGenerator` so session/entry ids do not
/// depend on the system's entropy source.
private struct SeededGenerator: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }
}

/// Runs the shared `SessionStore` contract against `store`, so both
/// `JSONLFileSessionStore` and `InMemorySessionStore` are pinned to the
/// same behaviour.
private func assertStoreContract(
  _ store: some SessionStore,
  sourceLocation: SourceLocation = #_sourceLocation
) async throws {
  var generator = SeededGenerator(state: 1)
  let sessionID = EntryID.random(using: &generator)
  let header = SessionHeader(version: SessionHeader.currentVersion, sessionID: sessionID)

  try await store.createSession(header: header)

  let emptyLoad = try await store.loadSession(sessionID: sessionID)
  #expect(emptyLoad.header == header, sourceLocation: sourceLocation)
  #expect(emptyLoad.entries.isEmpty, sourceLocation: sourceLocation)

  let firstEntryID = EntryID.random(using: &generator)
  let firstEntry = SessionEntry(
    id: firstEntryID,
    parentID: nil,
    kind: .message(.user(UserMessage(content: [.text("hello")])))
  )
  let secondEntry = SessionEntry(
    id: EntryID.random(using: &generator),
    parentID: firstEntryID,
    kind: .label(name: "checkpoint")
  )
  try await store.appendEntry(firstEntry, toSessionID: sessionID)
  try await store.appendEntry(secondEntry, toSessionID: sessionID)

  let loaded = try await store.loadSession(sessionID: sessionID)
  #expect(loaded.header == header, sourceLocation: sourceLocation)
  #expect(loaded.entries == [firstEntry, secondEntry], sourceLocation: sourceLocation)

  let ids = try await store.listSessionIDs()
  #expect(ids == [sessionID], sourceLocation: sourceLocation)

  do {
    try await store.createSession(header: header)
    Issue.record(
      "expected createSession to throw for an already-existing session",
      sourceLocation: sourceLocation
    )
  } catch let error as SessionStoreError {
    #expect(error.code == .sessionAlreadyExists, sourceLocation: sourceLocation)
  } catch {
    Issue.record("expected a SessionStoreError, got \(error)", sourceLocation: sourceLocation)
  }

  let unknownID = EntryID.random(using: &generator)
  do {
    _ = try await store.loadSession(sessionID: unknownID)
    Issue.record(
      "expected loadSession to throw for an unknown session",
      sourceLocation: sourceLocation
    )
  } catch let error as SessionStoreError {
    #expect(error.code == .sessionNotFound, sourceLocation: sourceLocation)
  } catch {
    Issue.record("expected a SessionStoreError, got \(error)", sourceLocation: sourceLocation)
  }

  do {
    try await store.appendEntry(firstEntry, toSessionID: unknownID)
    Issue.record(
      "expected appendEntry to throw for an unknown session",
      sourceLocation: sourceLocation
    )
  } catch let error as SessionStoreError {
    #expect(error.code == .sessionNotFound, sourceLocation: sourceLocation)
  } catch {
    Issue.record("expected a SessionStoreError, got \(error)", sourceLocation: sourceLocation)
  }
}

@Suite("SessionStore implementations")
struct SessionStoreTests {
  /// Creates a `JSONLFileSessionStore` rooted at a fresh temp directory,
  /// removed after the test regardless of outcome.
  private func withFileStore(
    _ body: (JSONLFileSessionStore) async throws -> Void
  ) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ApusKitSessionsTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(JSONLFileSessionStore(directoryURL: directory))
  }

  @Test("JSONLFileSessionStore satisfies the SessionStore contract")
  func jsonlFileSessionStoreSatisfiesContract() async throws {
    try await withFileStore { store in
      try await assertStoreContract(store)
    }
  }

  @Test("InMemorySessionStore satisfies the SessionStore contract")
  func inMemorySessionStoreSatisfiesContract() async throws {
    try await assertStoreContract(InMemorySessionStore())
  }

  @Test("listSessionIDs returns ids in ascending hex order regardless of creation order")
  func listSessionIDsIsSortedByHex() async throws {
    try await withFileStore { store in
      let idB = try EntryID(hex: "bbbbbbbb")
      let idA = try EntryID(hex: "aaaaaaaa")
      try await store.createSession(
        header: SessionHeader(version: SessionHeader.currentVersion, sessionID: idB)
      )
      try await store.createSession(
        header: SessionHeader(version: SessionHeader.currentVersion, sessionID: idA)
      )

      let ids = try await store.listSessionIDs()
      #expect(ids == [idA, idB])
    }
  }
}
