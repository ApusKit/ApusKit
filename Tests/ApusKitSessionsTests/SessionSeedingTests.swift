// SessionSeedingTests
//
// Coverage for `Session.init(header:entries:)` (R9): seeding a session
// tree from entries known up front — e.g. entries just decoded from a
// session file — must build the same tree structure `append(_:)` would,
// one call at a time. Every assertion here fails if the seeding loop in
// `init(header:entries:)` is replaced with a no-op or a partial copy.
//
// R9's second half — every public async witness in `JSONLFileSessionStore`
// repeating the isolation annotation of the `SessionStore` requirement it
// satisfies (`CC-2`) — is pinned at the bottom of this file.

import ApusKitCore
import ApusKitSessions
import Foundation
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

// MARK: - Witness isolation annotations

/// One `async` function declaration found in a source file, with the
/// attribute written immediately above it, if any.
private struct AsyncDeclaration: Equatable {
  /// The declaration's base name, e.g. `"loadSession"`.
  var name: String

  /// The attribute on the line above the declaration — `"@concurrent"`,
  /// `"nonisolated(nonsending)"` — or `nil` if there is none.
  var isolation: String?
}

/// Scans a file in `Sources/ApusKitSessions/` for `async` declarations
/// and the isolation attribute each one carries.
///
/// `CC-2` is a source-level contract: with
/// `NonisolatedNonsendingByDefault` off, dropping `@concurrent` from a
/// witness changes no runtime behaviour that a test could observe, so the
/// annotation is checked where it lives — in the text of the declaration.
private func asyncDeclarations(inSessionsFileNamed fileName: String) throws -> [AsyncDeclaration] {
  let url =
    URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // Tests/ApusKitSessionsTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // repository root
    .appendingPathComponent("Sources", isDirectory: true)
    .appendingPathComponent("ApusKitSessions", isDirectory: true)
    .appendingPathComponent(fileName)
  let lines = try String(contentsOf: url, encoding: .utf8).split(
    separator: "\n",
    omittingEmptySubsequences: false
  )

  return lines.enumerated().compactMap { index, line -> AsyncDeclaration? in
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("func ") || trimmed.hasPrefix("public func ") else { return nil }
    guard trimmed.contains(" async "), let parenthesis = trimmed.firstIndex(of: "(") else {
      return nil
    }
    guard let funcKeyword = trimmed.range(of: "func ") else { return nil }
    let name = String(trimmed[funcKeyword.upperBound..<parenthesis])

    // Walk back over the doc comment to the attribute, if one is written.
    var above = index - 1
    while above >= 0 {
      let candidate = lines[above].trimmingCharacters(in: .whitespaces)
      if candidate.isEmpty || candidate.hasPrefix("//") {
        above -= 1
        continue
      }
      return AsyncDeclaration(
        name: name,
        isolation: candidate.hasPrefix("@") || candidate.hasPrefix("nonisolated")
          ? candidate : nil
      )
    }
    return AsyncDeclaration(name: name, isolation: nil)
  }
}

@Suite("JSONLFileSessionStore witness isolation")
struct JSONLFileSessionStoreIsolationTests {
  @Test("every async witness repeats its SessionStore requirement's isolation annotation")
  func witnessesRepeatRequirementIsolation() throws {
    let requirements = try asyncDeclarations(inSessionsFileNamed: "SessionStore.swift")
    let witnesses = try asyncDeclarations(inSessionsFileNamed: "JSONLFileSessionStore.swift")

    // Guard the scanner itself: an expression that matched nothing would
    // otherwise make this test vacuously green.
    #expect(
      requirements.map(\.name).sorted() == [
        "appendEntry", "createSession", "listSessionIDs", "loadSession",
      ]
    )
    #expect(witnesses.map(\.name).sorted() == requirements.map(\.name).sorted())

    for requirement in requirements {
      #expect(
        requirement.isolation != nil,
        "SessionStore.\(requirement.name) must state its isolation explicitly (CC-2)"
      )
      let witness = witnesses.first { $0.name == requirement.name }
      #expect(
        witness?.isolation == requirement.isolation,
        """
        JSONLFileSessionStore.\(requirement.name) is annotated \
        \(witness?.isolation ?? "nothing") but witnesses a SessionStore requirement annotated \
        \(requirement.isolation ?? "nothing") (CC-2)
        """
      )
    }
  }
}
