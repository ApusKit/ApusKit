public import Foundation

/// A single streaming HTTP request.
public struct HTTPStreamRequest: Sendable, Equatable {
  /// The request URL.
  public var url: URL

  /// The HTTP method, e.g. `"POST"`.
  public var method: String

  /// Request headers.
  public var headers: [String: String]

  /// The request body, if any.
  public var body: Data?

  /// Creates a streaming HTTP request.
  public init(url: URL, method: String = "POST", headers: [String: String] = [:], body: Data? = nil)
  {
    self.url = url
    self.method = method
    self.headers = headers
    self.body = body
  }
}

/// A chunk of bytes received from a streaming HTTP response.
public struct HTTPStreamChunk: Sendable, Equatable {
  /// The raw bytes of this chunk.
  public var data: Data

  /// Creates a chunk.
  public init(data: Data) {
    self.data = data
  }
}

/// Transport seam: performs a streaming HTTP request and yields the
/// response body as it arrives.
///
/// Conform freely — this is the extension point for plugging in a
/// different HTTP stack (e.g. the `NIO`-trait `AsyncHTTPClientTransport`)
/// in place of the default `URLSessionTransport`.
public protocol StreamingHTTPTransport: Sendable {
  /// Performs `request` and streams the response body as it arrives.
  func stream(_ request: HTTPStreamRequest) -> AsyncThrowingStream<HTTPStreamChunk, any Error>
}
