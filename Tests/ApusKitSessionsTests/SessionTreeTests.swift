// SessionTreeTests
//
// Coverage for `Session`'s tree structure (R4): appending under any
// parent, branching from any entry, forking alternative continuations as
// siblings, and walking history leaf-to-root via `history(from:)`.

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

@Suite("Session tree")
struct SessionTreeTests {
  private static func header() throws -> SessionHeader {
    SessionHeader(version: SessionHeader.currentVersion, sessionID: try id("00000000"))
  }

  @Test("an entry appended with a nil parentID becomes a root, reachable via children(of: nil)")
  func appendingRootEntry() throws {
    var session = Session(header: try Self.header())
    let root = try messageEntry("00000001", parent: nil, text: "root")
    session.append(root)

    #expect(session.children(of: nil) == [root.id])
    #expect(session.entry(id: root.id) == root)
  }

  @Test("appending under an existing entry's id branches from it")
  func appendingUnderExistingEntryBranches() throws {
    var session = Session(header: try Self.header())
    let root = try messageEntry("00000001", parent: nil, text: "root")
    let child = try messageEntry("00000002", parent: root.id, text: "branch")
    session.append(root)
    session.append(child)

    #expect(session.children(of: root.id) == [child.id])
    #expect(session.isLeaf(child.id))
    #expect(!session.isLeaf(root.id))
  }

  @Test("appending two entries under the same parent forks alternative continuations")
  func appendingTwoUnderSameParentForks() throws {
    var session = Session(header: try Self.header())
    let root = try messageEntry("00000001", parent: nil, text: "root")
    let forkA = try messageEntry("00000002", parent: root.id, text: "continuation A")
    let forkB = try messageEntry("00000003", parent: root.id, text: "continuation B")
    session.append(root)
    session.append(forkA)
    session.append(forkB)

    #expect(session.children(of: root.id) == [forkA.id, forkB.id])
    #expect(session.isLeaf(forkA.id))
    #expect(session.isLeaf(forkB.id))
  }

  @Test("leaves() returns every childless entry, in append order")
  func leavesReturnsChildlessEntriesInAppendOrder() throws {
    var session = Session(header: try Self.header())
    let root = try messageEntry("00000001", parent: nil, text: "root")
    let mid = try messageEntry("00000002", parent: root.id, text: "mid")
    let forkA = try messageEntry("00000003", parent: mid.id, text: "A")
    let forkB = try messageEntry("00000004", parent: root.id, text: "B")
    session.append(root)
    session.append(mid)
    session.append(forkA)
    session.append(forkB)

    #expect(session.leaves() == [forkA.id, forkB.id])
  }

  @Test("history(from:) walks leaf-to-root, ending at the entry with a nil parentID")
  func historyWalksLeafToRoot() throws {
    var session = Session(header: try Self.header())
    let root = try messageEntry("00000001", parent: nil, text: "root")
    let mid = try messageEntry("00000002", parent: root.id, text: "mid")
    let leaf = try messageEntry("00000003", parent: mid.id, text: "leaf")
    session.append(root)
    session.append(mid)
    session.append(leaf)

    let path = try session.history(from: leaf.id)
    #expect(path == [leaf, mid, root])
    #expect(path.last?.parentID == nil)
  }

  @Test("history(from:) walks only the branch a leaf sits on, not sibling forks")
  func historyIgnoresOtherForks() throws {
    var session = Session(header: try Self.header())
    let root = try messageEntry("00000001", parent: nil, text: "root")
    let forkA = try messageEntry("00000002", parent: root.id, text: "A")
    let forkB = try messageEntry("00000003", parent: root.id, text: "B")
    session.append(root)
    session.append(forkA)
    session.append(forkB)

    let path = try session.history(from: forkA.id)
    #expect(path == [forkA, root])
  }

  @Test("history(from:) throws unknownEntry for an id not in the tree")
  func historyThrowsForUnknownID() throws {
    let session = Session(header: try Self.header())
    let missing = try id("deadbeef")

    #expect(throws: SessionTreeError.self) {
      try session.history(from: missing)
    }
    do {
      _ = try session.history(from: missing)
      Issue.record("expected history(from:) to throw")
    } catch let error as SessionTreeError {
      #expect(error.code == .unknownEntry)
    } catch {
      Issue.record("expected a SessionTreeError, got \(error)")
    }
  }

  @Test("history(from:) throws unknownEntry when a dangling parentID is reached")
  func historyThrowsForDanglingParent() throws {
    var session = Session(header: try Self.header())
    let dangling = try id("deadbeef")
    let leaf = try messageEntry("00000001", parent: dangling, text: "leaf")
    session.append(leaf)

    do {
      _ = try session.history(from: leaf.id)
      Issue.record("expected history(from:) to throw")
    } catch let error as SessionTreeError {
      #expect(error.code == .unknownEntry)
    } catch {
      Issue.record("expected a SessionTreeError, got \(error)")
    }
  }
}
