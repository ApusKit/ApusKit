import ApusKitCore
import ApusKitSessions
import Foundation

// Proves `ApusKitSessions` is usable with no other ApusKit target
// imported as a package product dependency (Package.swift declares
// exactly one) and with no agent loop anywhere: builds a small session
// tree by hand, rebuilds context at its leaf, then round-trips both
// entries through `JSONLFileSessionStore`. `public import ApusKitCore`
// inside `ApusKitSessions` propagates API-surface diagnostics but not
// transitive bare-name visibility, so spelling `UserMessage`/
// `AssistantMessage` here still needs `import ApusKitCore` directly (see
// agent-consumer).
var rng = SystemRandomNumberGenerator()
let sessionID = EntryID.random(using: &rng)
let rootID = EntryID.random(using: &rng)
let leafID = EntryID.random(using: &rng)

let header = SessionHeader(version: SessionHeader.currentVersion, sessionID: sessionID)

let rootEntry = SessionEntry(
  id: rootID,
  parentID: nil,
  kind: .message(.user(UserMessage(content: [.text("What's the weather?")])))
)
let leafEntry = SessionEntry(
  id: leafID,
  parentID: rootID,
  kind: .message(
    .assistant(
      AssistantMessage(
        content: [.text("It's sunny.")],
        stopReason: .endTurn,
        usage: Usage(inputTokens: 5, outputTokens: 4)
      )
    )
  )
)

// Branching from any entry is just appending under its id as `parentID` —
// no rewriting of existing lines.
var session = Session(header: header, entries: [rootEntry])
session.append(leafEntry)

let directoryURL = FileManager.default.temporaryDirectory
  .appendingPathComponent("sessions-consumer-\(sessionID.hex)", isDirectory: true)

do {
  let context = try session.buildContext(leaf: leafID)
  print("Rebuilt context has \(context.count) item(s)")

  let store = JSONLFileSessionStore(directoryURL: directoryURL)
  try await store.createSession(header: header)
  try await store.appendEntry(rootEntry, toSessionID: sessionID)
  try await store.appendEntry(leafEntry, toSessionID: sessionID)

  let loaded = try await store.loadSession(sessionID: sessionID)
  let sessionHex = loaded.header.sessionID.hex
  print("Round-tripped \(loaded.entries.count) entr(y/ies) for session \(sessionHex)")
} catch {
  print("Sessions example error: \(error)")
}

try? FileManager.default.removeItem(at: directoryURL)
