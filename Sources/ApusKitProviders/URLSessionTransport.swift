package import ApusKitCore
public import Foundation

/// The default `StreamingHTTPTransport` conformance: zero extra
/// dependencies, backed by `URLSession.bytes(for:)`.
///
/// Per `DI-3`, the `URLSession` is always supplied by the caller — there
/// is no default parameter and this type never reaches the process-wide
/// shared session.
public struct URLSessionTransport: StreamingHTTPTransport {
  private let session: URLSession

  /// Creates a transport that issues requests through `session`.
  public init(session: URLSession) {
    self.session = session
  }

  /// Performs `request` and streams the response body as it arrives.
  ///
  /// A non-2xx response finishes the stream with a `StreamError` of code
  /// `.provider` before any chunk is yielded.
  public func stream(_ request: HTTPStreamRequest) -> AsyncThrowingStream<
    HTTPStreamChunk, any Error
  > {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let urlRequest = Self.makeURLRequest(from: request)
          let (byteStream, response) = try await session.bytes(for: urlRequest)
          if let error = Self.mapNon2xxResponse(response) {
            continuation.finish(throwing: error)
            return
          }
          try await Self.forwardBytes(byteStream, to: continuation)
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Yields every byte of `bytes` onward as soon as it arrives, never
  /// holding one back behind a size threshold.
  ///
  /// Withholding bytes until a buffer filled would stall a slow, small
  /// response — an SSE body that dribbles in arrives at the consumer only
  /// when the connection closes — so a chunk is emitted per byte read.
  /// `Data` stores a payload this small inline, so no heap allocation is
  /// incurred per chunk. Package-access (`PKG-8`) so tests can drive it
  /// from a hand-fed byte sequence with no network (`TEST-2`).
  package static func forwardBytes<Bytes: AsyncSequence>(
    _ bytes: Bytes,
    to continuation: AsyncThrowingStream<HTTPStreamChunk, any Error>.Continuation
  ) async throws where Bytes.Element == UInt8 {
    for try await byte in bytes {
      continuation.yield(HTTPStreamChunk(data: Data([byte])))
    }
  }

  /// Builds the `URLRequest` for `request`. Package-access (`PKG-8`) so
  /// tests can exercise request-building with no network (`TEST-2`).
  package static func makeURLRequest(from request: HTTPStreamRequest) -> URLRequest {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method
    for (field, value) in request.headers {
      urlRequest.setValue(value, forHTTPHeaderField: field)
    }
    urlRequest.httpBody = request.body
    return urlRequest
  }

  /// Maps a non-2xx (or non-HTTP) response to a `StreamError`, or returns
  /// `nil` for a successful response. Package-access (`PKG-8`) so tests
  /// can exercise status mapping with no network (`TEST-2`).
  package static func mapNon2xxResponse(_ response: URLResponse) -> StreamError? {
    guard let httpResponse = response as? HTTPURLResponse else {
      return StreamError(code: .provider, message: "response was not an HTTP response")
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      return StreamError(
        code: .provider,
        message: "provider returned HTTP status \(httpResponse.statusCode)"
      )
    }
    return nil
  }
}
