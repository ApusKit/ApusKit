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

          var buffer: [UInt8] = []
          buffer.reserveCapacity(Self.chunkFlushThreshold)
          for try await byte in byteStream {
            buffer.append(byte)
            if buffer.count >= Self.chunkFlushThreshold {
              continuation.yield(HTTPStreamChunk(data: Data(buffer)))
              buffer.removeAll(keepingCapacity: true)
            }
          }
          if !buffer.isEmpty {
            continuation.yield(HTTPStreamChunk(data: Data(buffer)))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// Bytes are flushed as a chunk once this many have arrived, so the
  /// stream never buffers the whole response body before yielding.
  private static let chunkFlushThreshold = 4096

  /// Builds the `URLRequest` for `request`. Package-access so tests can
  /// exercise request-building with no network (`ASM-3`).
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
  /// `nil` for a successful response. Package-access so tests can
  /// exercise status mapping with no network (`ASM-3`).
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
