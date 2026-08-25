/// An error walking or looking up entries in a ``Session``'s tree.
///
/// Per `ERR-2`, this is a struct wrapping a `@nonexhaustive` `Code` enum
/// rather than a public enum of its own.
public struct SessionTreeError: Sendable, Equatable, Error {
  /// The category of failure a `SessionTreeError` represents.
  @nonexhaustive(warn)
  public enum Code: Sendable, Equatable {
    /// No entry exists with the requested id.
    case unknownEntry
  }

  /// The category of this failure.
  public var code: Code

  /// A human-readable description of what went wrong.
  public var message: String

  /// Creates a tree lookup error.
  public init(code: Code, message: String) {
    self.code = code
    self.message = message
  }
}

/// An in-memory session tree: a header plus the entries appended to it,
/// with the parent/child structure a ``SessionEntry``'s `parentID` forms.
///
/// Branching from any entry, or forking an alternative continuation, is
/// just ``append(_:)`` with the branch point's id as the new entry's
/// `parentID` — the tree never rewrites an existing entry (`§3.5`).
public struct Session: Sendable {
  /// This session's header.
  public var header: SessionHeader

  private var entriesByID: [EntryID: SessionEntry] = [:]

  /// Every entry id, in the order it was appended (`API-4`) — the order
  /// ``leaves()`` iterates in.
  private var appendOrder: [EntryID] = []

  private var childIDsByParent: [EntryID: [EntryID]] = [:]

  private var rootIDs: [EntryID] = []

  /// Creates a session tree from a header and, optionally, entries already
  /// known — e.g. entries just decoded from a session file — appended in
  /// `entries`' order.
  public init(header: SessionHeader, entries: [SessionEntry] = []) {
    self.header = header
    for entry in entries {
      append(entry)
    }
  }

  /// Appends `entry` to the tree under its `parentID` (as a root entry if
  /// `parentID` is `nil`).
  ///
  /// This is how branching and forking work: appending with an existing
  /// entry's id as `parentID` branches from that entry, and appending
  /// twice with the same `parentID` forks two alternative continuations
  /// as siblings.
  public mutating func append(_ entry: SessionEntry) {
    entriesByID[entry.id] = entry
    appendOrder.append(entry.id)
    if let parentID = entry.parentID {
      childIDsByParent[parentID, default: []].append(entry.id)
    } else {
      rootIDs.append(entry.id)
    }
  }

  /// Looks up an entry by id.
  public func entry(id: EntryID) -> SessionEntry? {
    entriesByID[id]
  }

  /// The ids of the entries appended directly under `parentID`, in append
  /// order (`API-4`) — or the root entries' ids, in append order, when
  /// `parentID` is `nil`.
  ///
  /// More than one id means a fork: two or more alternative continuations
  /// branching from the same parent.
  public func children(of parentID: EntryID?) -> [EntryID] {
    guard let parentID else { return rootIDs }
    return childIDsByParent[parentID] ?? []
  }

  /// Whether `id` has no children, i.e. is a leaf of the tree.
  public func isLeaf(_ id: EntryID) -> Bool {
    (childIDsByParent[id] ?? []).isEmpty
  }

  /// The ids of every entry with no children, in append order (`API-4`).
  public func leaves() -> [EntryID] {
    appendOrder.filter(isLeaf)
  }

  /// Walks the tree from `leaf` up to the root, following each entry's
  /// `parentID`.
  ///
  /// The result is in leaf-to-root order: `result[0]` is the entry at
  /// `leaf`, and the last element has a `nil` `parentID`.
  ///
  /// - Throws: ``SessionTreeError`` with code `.unknownEntry` if `leaf`,
  ///   or an ancestor reached by following `parentID`, is not in the tree.
  /// - Complexity: O(*n*) in the depth of `leaf`.
  public func history(from leaf: EntryID) throws -> [SessionEntry] {
    var result: [SessionEntry] = []
    var currentID: EntryID? = leaf
    while let id = currentID {
      guard let entry = entriesByID[id] else {
        throw SessionTreeError(
          code: .unknownEntry,
          message: "no entry with id \"\(id.hex)\" in this session"
        )
      }
      result.append(entry)
      currentID = entry.parentID
    }
    return result
  }
}
