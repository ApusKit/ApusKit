/// One item in a message context rebuilt by ``Session/buildContext(leaf:)``.
///
/// A `.summary` stands in for the ancestor entries a compaction replaced;
/// everything else that contributes to context is a `.message`.
public enum ContextItem: Sendable, Equatable {
  /// A message carried by a `.message` entry, or retained verbatim by a
  /// compaction's `retainedTail`.
  case message(SessionMessage)

  /// A compaction's summary, substituted for the ancestor entries it
  /// replaced.
  case summary(String)
}

extension Session {
  /// Rebuilds the message context leading to `leaf`, in chronological
  /// (root-to-leaf) order.
  ///
  /// Walks from `leaf` to the root via ``history(from:)``. At the first
  /// compaction entry encountered — the one closest to `leaf` — the walk
  /// stops: that entry's `summary` and `retainedTail` are self-contained
  /// substitutes for the ancestor range it replaced, so nothing further
  /// up the chain is visited (`§3.5`). Entries that are neither
  /// `.message` nor `.compaction` (labels, model/thinking-level changes,
  /// branch summaries, custom payloads) do not contribute to the context.
  ///
  /// - Throws: ``SessionTreeError`` if `leaf`, or an ancestor reached
  ///   while walking to it, is not in the tree.
  /// - Complexity: O(*n*) in the depth of `leaf`.
  public func buildContext(leaf: EntryID) throws -> [ContextItem] {
    let leafToRoot = try history(from: leaf)
    let compactionIndex = leafToRoot.firstIndex { entry in
      if case .compaction = entry.kind { return true }
      return false
    }
    let relevant = compactionIndex.map { leafToRoot[...$0] } ?? leafToRoot[...]

    var items: [ContextItem] = []
    for entry in relevant.reversed() {
      switch entry.kind {
      case .message(let message):
        items.append(.message(message))
      case .compaction(let summary, let retainedTail, _):
        items.append(.summary(summary))
        for message in retainedTail {
          items.append(.message(message))
        }
      case .branchSummary, .custom, .customMessage, .label, .modelChange, .thinkingLevelChange:
        continue
      }
    }
    return items
  }
}
