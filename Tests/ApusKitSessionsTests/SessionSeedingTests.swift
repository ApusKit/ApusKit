// SessionSeedingTests
//
// Coverage for `Session.init(header:entries:)` (R9): seeding a session
// tree from entries known up front — e.g. entries just decoded from a
// session file — must build the same tree structure `append(_:)` would,
// one call at a time. Every assertion here fails if the seeding loop in
// `init(header:entries:)` is replaced with a no-op or a partial copy.

import ApusKitCore
import ApusKitSessions
import Testing

private func id(_ hex: String) throws -> EntryID {
  try EntryID(hex: hex)
}

private func messageEntry(_ hex: String, parent: EntryID?, text: String) throws -> SessionEntry {
  SessionEntry(
    id: try id(hex),
    parentID: parent,
    kind: .message(.user(UserMessage(content: [.text(text)])))
  )
}

@Suite("Session entry seeding")
struct SessionSeedingTests {
  private static func header() throws -> SessionHeader {
    SessionHeader(version: SessionHeader.currentVersion, sessionID: try id("00000000"))
  }

  @Test("init(header:entries:) builds tree shape, lookup and append order like repeated append(_:)")
  func seedsTreeShapeLookupAndOrder() throws {
    let root = try messageEntry("00000001", parent: nil, text: "root")
    let mid = try messageEntry("00000002", parent: root.id, text: "mid")
    let forkA = try messageEntry("00000003", parent: mid.id, text: "A")
    let forkB = try messageEntry("00000004", parent: mid.id, text: "B")
    let entries = [root, mid, forkA, forkB]

    let session = Session(header: try Self.header(), entries: entries)

    // Every seeded entry is reachable by id, with the exact payload passed in.
    #expect(session.entry(id: root.id) == root)
    #expect(session.entry(id: mid.id) == mid)
    #expect(session.entry(id: forkA.id) == forkA)
    #expect(session.entry(id: forkB.id) == forkB)

    // Tree shape: root is the sole root entry, mid is its only child, and
    // forkA/forkB are mid's children, in the order they appeared in.
    #expect(session.children(of: nil) == [root.id])
    #expect(session.children(of: root.id) == [mid.id])
    #expect(session.children(of: mid.id) == [forkA.id, forkB.id])

    // Leaf/non-leaf status and append-ordered leaves() follow from the
    // same parent/child wiring.
    #expect(!session.isLeaf(root.id))
    #expect(!session.isLeaf(mid.id))
    #expect(session.isLeaf(forkA.id))
    #expect(session.isLeaf(forkB.id))
    #expect(session.leaves() == [forkA.id, forkB.id])
  }

  @Test("init(header:entries:) seeds a walkable leaf-to-root history")
  func seedsWalkableHistory() throws {
    let root = try messageEntry("00000001", parent: nil, text: "root")
    let mid = try messageEntry("00000002", parent: root.id, text: "mid")
    let leaf = try messageEntry("00000003", parent: mid.id, text: "leaf")
    let entries = [root, mid, leaf]

    let session = Session(header: try Self.header(), entries: entries)

    let path = try session.history(from: leaf.id)
    #expect(path == [leaf, mid, root])
    #expect(path.last?.parentID == nil)
  }
}
