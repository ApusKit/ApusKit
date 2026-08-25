// FixtureTransport
//
// Offline replay seam for the wire-compat conformance suite (TEST-3).
// A recorded provider transcript in `Tests/Fixtures/` is replayed through
// the `StreamingHTTPTransport` protocol seam, never URLProtocol (TEST-2),
// so an `APIImplementation` can be proven byte-for-byte with no network
// access and no API keys.

public import ApusKitProviders
public import Foundation

/// Locates the recorded provider transcripts in `Tests/Fixtures/`.
///
/// Resolves the directory from this file's own source location rather
/// than a resource bundle, so the fixtures stay plain files a maintainer
/// can diff, and no target needs a resource declaration.
public enum Fixtures {
  /// The absolute URL of the repository's `Tests/Fixtures/` directory.
  public static var directory: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // Tests/Shared
      .deletingLastPathComponent()  // Tests
      .appendingPathComponent("Fixtures", isDirectory: true)
  }

  /// Reads a recorded transcript.
  ///
  /// - Parameters:
  ///   - name: The transcript's file name, e.g. `"text-and-tool-call.sse"`.
  ///   - implementation: The subdirectory naming the API implementation,
  ///     e.g. `"anthropic-messages"`.
  /// - Returns: The transcript's raw bytes, exactly as recorded.
  /// - Throws: If the transcript is missing or unreadable.
  public static func transcript(
    _ name: String,
    for implementation: String
  ) throws -> Data {
    let url =
      directory
      .appendingPathComponent(implementation, isDirectory: true)
      .appendingPathComponent(name)
    return try Data(contentsOf: url)
  }
}

/// A `StreamingHTTPTransport` that records the request it is given and
/// replays fixed response bytes, optionally split into chunks.
///
/// Splitting is the point: `PROV-1` requires an implementation to survive
/// a chunk boundary falling anywhere, so a suite replays the same
/// transcript at every byte offset through this fake.
public struct FixtureTransport: StreamingHTTPTransport {
  private let chunks: [Data]
  private let log: RequestSpyLog
  private let failure: (any Error)?

  /// Creates a transport that yields `body` as a single chunk.
  ///
  /// - Parameters:
  ///   - body: The response bytes to replay.
  ///   - log: Records the request this transport is asked to perform.
  public init(body: Data, log: RequestSpyLog = RequestSpyLog()) {
    self.init(chunks: [body], log: log)
  }

  /// Creates a transport that yields `chunks` in order.
  ///
  /// - Parameters:
  ///   - chunks: The response bytes, already split at the boundaries
  ///     under test.
  ///   - log: Records the request this transport is asked to perform.
  public init(chunks: [Data], log: RequestSpyLog = RequestSpyLog()) {
    self.chunks = chunks
    self.log = log
    self.failure = nil
  }

  /// Creates a transport that records the request and then fails.
  ///
  /// - Parameters:
  ///   - failure: The error to terminate the stream with.
  ///   - log: Records the request this transport is asked to perform.
  public init(failing failure: any Error, log: RequestSpyLog = RequestSpyLog()) {
    self.chunks = []
    self.log = log
    self.failure = failure
  }

  /// Records `request`, then replays the fixture bytes.
  public func stream(_ request: HTTPStreamRequest) -> AsyncThrowingStream<
    HTTPStreamChunk, any Error
  > {
    let chunks = chunks
    let log = log
    let failure = failure

    return AsyncThrowingStream { continuation in
      let task = Task {
        await log.record(request)
        for chunk in chunks {
          continuation.yield(HTTPStreamChunk(data: chunk))
        }
        if let failure {
          continuation.finish(throwing: failure)
        } else {
          continuation.finish()
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

/// Records every `HTTPStreamRequest` a `FixtureTransport` is asked to perform.
///
/// An actor rather than a lock-protected array, per `CC-4`.
public actor RequestSpyLog {
  /// Every request recorded, in send order.
  public private(set) var requests: [HTTPStreamRequest] = []

  /// Creates an empty log.
  public init() {}

  func record(_ request: HTTPStreamRequest) {
    requests.append(request)
  }
}

extension Data {
  /// Splits these bytes into two chunks at `offset`.
  ///
  /// Used to replay one transcript at every byte boundary, proving an
  /// implementation never depends on where a chunk happens to end.
  ///
  /// - Parameter offset: The byte index to split at. An offset at or
  ///   beyond `count` yields the whole payload as one chunk.
  /// - Returns: One or two chunks whose concatenation equals `self`.
  public func splitOnce(at offset: Int) -> [Data] {
    guard offset > 0, offset < count else { return [self] }
    let index = self.index(startIndex, offsetBy: offset)
    return [self[startIndex..<index], self[index..<endIndex]]
  }
}
