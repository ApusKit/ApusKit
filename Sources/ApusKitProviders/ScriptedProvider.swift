public import ApusKitCore

extension APIImplementationID {
  /// The wire protocol identifier `ScriptedProvider` reports by default.
  public static let scripted = APIImplementationID(rawValue: "scripted")
}

/// A deterministic `APIImplementation` that replays caller-supplied
/// `StreamEvent` sequences instead of talking to a real provider.
///
/// Each call to `stream(request:connection:)` replays the next sequence
/// in order, so a multi-turn conversation can be scripted by handing
/// `ScriptedProvider` one event sequence per expected turn. Testing is
/// first-class in ApusKit: `ScriptedProvider` is public and documented so
/// consumers can drive the real agent loop with no network and no API
/// keys.
///
/// Per `CC-4`, the per-call script cursor is not protected by a lock —
/// it lives in an internal actor consulted from inside the stream body.
public struct ScriptedProvider: APIImplementation {
  /// The wire protocol identifier this instance reports.
  public let id: APIImplementationID

  private let scriptQueue: ScriptQueue

  /// Creates a scripted provider.
  ///
  /// - Parameters:
  ///   - id: The identifier this provider reports. Defaults to `.scripted`.
  ///   - scripts: One `StreamEvent` sequence per expected `stream(request:connection:)`
  ///     call, in call order.
  public init(id: APIImplementationID = .scripted, scripts: [[StreamEvent]]) {
    self.id = id
    self.scriptQueue = ScriptQueue(scripts: scripts)
  }

  /// Replays the next scripted event sequence.
  ///
  /// `request` and `connection` are ignored: `ScriptedProvider` is
  /// deterministic and does not inspect what it is asked to stream.
  public func stream(request: LLMRequest, connection: ProviderConnection) -> AsyncThrowingStream<
    StreamEvent, any Error
  > {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let events = try await scriptQueue.nextScript()
          for event in events {
            continuation.yield(event)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

/// Holds `ScriptedProvider`'s ordered scripts and the cursor into them.
///
/// An actor rather than a lock-protected variable, per `CC-4`.
private actor ScriptQueue {
  private var scripts: [[StreamEvent]]
  private var nextIndex = 0

  init(scripts: [[StreamEvent]]) {
    self.scripts = scripts
  }

  func nextScript() throws -> [StreamEvent] {
    guard nextIndex < scripts.count else {
      throw StreamError(
        code: .provider,
        message: "ScriptedProvider has no more scripted turns to replay."
      )
    }
    let script = scripts[nextIndex]
    nextIndex += 1
    return script
  }
}
