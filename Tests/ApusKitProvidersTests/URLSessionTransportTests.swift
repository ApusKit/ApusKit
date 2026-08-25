// URLSessionTransportTests
//
// Coverage for URLSessionTransport: the request-building and status-mapping
// helpers (package-access per PKG-8), the byte pump, and `stream(_:)` end
// to end against a
// real loopback socket. TEST-2 rules out URLProtocol stubbing, so the only
// honest way to drive `URLSession.bytes(for:)` is to give it a real server
// to talk to.

import ApusKitCore
import ApusKitProviders
import Foundation
import Testing

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

@Suite("URLSessionTransport")
struct URLSessionTransportTests {
  // Force-unwrap justified: "https://example.invalid" is a fixed, valid URL literal.
  // swift-format-ignore: NeverForceUnwrap
  private static let exampleURL = URL(string: "https://example.invalid/v1/stream")!

  @Test("makeURLRequest carries the method, headers, and body")
  func makeURLRequestCarriesFields() {
    let body = Data("payload".utf8)
    let request = HTTPStreamRequest(
      url: Self.exampleURL,
      method: "POST",
      headers: ["Authorization": "Bearer test", "Content-Type": "application/json"],
      body: body
    )

    let urlRequest = URLSessionTransport.makeURLRequest(from: request)

    #expect(urlRequest.url == Self.exampleURL)
    #expect(urlRequest.httpMethod == "POST")
    #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer test")
    #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(urlRequest.httpBody == body)
  }

  @Test("makeURLRequest carries a nil body")
  func makeURLRequestCarriesNilBody() {
    let request = HTTPStreamRequest(url: Self.exampleURL)
    let urlRequest = URLSessionTransport.makeURLRequest(from: request)
    #expect(urlRequest.httpBody == nil)
  }

  @Test("a 2xx response maps to no error", arguments: [200, 201, 204, 299])
  func successStatusMapsToNoError(statusCode: Int) throws {
    // Force-unwrap justified: fixed status code and header fields always
    // produce a valid `HTTPURLResponse`.
    // swift-format-ignore: NeverForceUnwrap
    let response = HTTPURLResponse(
      url: Self.exampleURL, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    #expect(URLSessionTransport.mapNon2xxResponse(response) == nil)
  }

  @Test("a non-2xx response maps to a provider StreamError", arguments: [400, 401, 404, 500, 503])
  func failureStatusMapsToProviderError(statusCode: Int) throws {
    // swift-format-ignore: NeverForceUnwrap
    let response = HTTPURLResponse(
      url: Self.exampleURL, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    let error = URLSessionTransport.mapNon2xxResponse(response)
    #expect(error?.code == .provider)
  }

  @Test("a non-HTTP response maps to a provider StreamError")
  func nonHTTPResponseMapsToProviderError() {
    let response = URLResponse(
      url: Self.exampleURL, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
    let error = URLSessionTransport.mapNon2xxResponse(response)
    #expect(error?.code == .provider)
  }

  @Test(
    "stream issues its request through the injected session (DI-3)",
    .timeLimit(.minutes(1))
  )
  func streamUsesTheInjectedSession() async throws {
    // `session` is private, so DI-3 has no surface to read directly. The
    // injected session is instead given a configuration nothing else would
    // have — a 50 ms request timeout — against a server that accepts the
    // connection and never answers. A transport honouring the injection
    // fails almost immediately; one that quietly substituted
    // `URLSession.shared` would sit on that session's 60 s default.
    // Constructing the type and discarding it, as this test used to, asserted
    // nothing: `init(session: URLSession = .shared)` left the suite green.
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 0.05
    let port = try #require(LoopbackHTTPServer.start(response: "", ending: .hold))
    let url = try #require(URL(string: "http://127.0.0.1:\(port)/v1/stream"))
    let transport = URLSessionTransport(session: URLSession(configuration: configuration))

    let clock = ContinuousClock()
    let started = clock.now
    await #expect(throws: (any Error).self) {
      for try await _ in transport.stream(HTTPStreamRequest(url: url)) {}
    }
    #expect(clock.now - started < .seconds(5))
  }

  @Test(
    "forwardBytes yields each byte before the source finishes",
    .timeLimit(.minutes(1))
  )
  func forwardBytesYieldsIncrementally() async throws {
    // Drives the byte pump from a hand-fed source that stays open, so a
    // chunk can only be observed if it was yielded as the byte arrived.
    // Buffering the body until the source ends would wait forever on the
    // first `next()`; the time limit turns that regression into a failure
    // rather than a hung suite.
    let (source, sourceInput) = AsyncStream<UInt8>.makeStream()
    let (chunks, chunkInput) = AsyncThrowingStream<HTTPStreamChunk, any Error>.makeStream()

    let pump = Task {
      try await URLSessionTransport.forwardBytes(source, to: chunkInput)
      chunkInput.finish()
    }

    var received = chunks.makeAsyncIterator()
    for byte in Array("hi!".utf8) {
      sourceInput.yield(byte)
      let chunk = try await received.next()
      #expect(chunk?.data == Data([byte]))
    }

    sourceInput.finish()
    try await pump.value
    let terminator = try await received.next()
    #expect(terminator == nil)
  }

  @Test("forwardBytes propagates a source failure")
  func forwardBytesPropagatesFailure() async throws {
    let (source, sourceInput) = AsyncThrowingStream<UInt8, any Error>.makeStream()
    let (chunks, chunkInput) = AsyncThrowingStream<HTTPStreamChunk, any Error>.makeStream()
    sourceInput.finish(throwing: StreamError(code: .provider, message: "boom"))

    await #expect(throws: StreamError.self) {
      try await URLSessionTransport.forwardBytes(source, to: chunkInput)
    }
    chunkInput.finish()
    var received = chunks.makeAsyncIterator()
    #expect(try await received.next() == nil)
  }

  // MARK: - stream(_:) end to end

  @Test(
    "stream yields body bytes while the response is still open",
    .timeLimit(.minutes(1))
  )
  func streamYieldsBytesBeforeTheResponseEnds() async throws {
    // The server writes an event and then holds the connection open
    // forever. An implementation that buffered the whole body would never
    // yield a chunk, so the time limit — not a sleep — is what turns a
    // buffering regression into a failure.
    let body = "data: hello\n\n"
    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n" + body
    let port = try #require(LoopbackHTTPServer.start(response: response, ending: .hold))
    let url = try #require(URL(string: "http://127.0.0.1:\(port)/v1/stream"))
    let transport = URLSessionTransport(session: URLSession(configuration: .ephemeral))

    var received = Data()
    let request = HTTPStreamRequest(url: url, method: "POST", body: Data("{}".utf8))
    for try await chunk in transport.stream(request) {
      received.append(chunk.data)
      if received.count >= body.utf8.count { break }
    }

    #expect(String(decoding: received, as: UTF8.self) == body)
  }

  @Test(
    "stream delivers the whole body and then finishes",
    .timeLimit(.minutes(1))
  )
  func streamDeliversTheWholeBodyAndFinishes() async throws {
    let body = "one\ntwo\nthree\n"
    let response =
      "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
    let port = try #require(LoopbackHTTPServer.start(response: response, ending: .close))
    let url = try #require(URL(string: "http://127.0.0.1:\(port)/v1/stream"))
    let transport = URLSessionTransport(session: URLSession(configuration: .ephemeral))

    var chunkCount = 0
    var received = Data()
    for try await chunk in transport.stream(HTTPStreamRequest(url: url)) {
      chunkCount += 1
      received.append(chunk.data)
    }

    #expect(String(decoding: received, as: UTF8.self) == body)
    #expect(chunkCount == body.utf8.count)
  }

  @Test(
    "stream finishes with a provider StreamError on a non-2xx response",
    .timeLimit(.minutes(1))
  )
  func streamMapsNon2xxToProviderStreamError() async throws {
    let payload = "upstream is down"
    let response =
      "HTTP/1.1 503 Service Unavailable\r\nContent-Length: \(payload.utf8.count)\r\n\r\n" + payload
    let port = try #require(LoopbackHTTPServer.start(response: response, ending: .close))
    let url = try #require(URL(string: "http://127.0.0.1:\(port)/v1/stream"))
    let transport = URLSessionTransport(session: URLSession(configuration: .ephemeral))

    var yieldedChunks = 0
    var caught: StreamError?
    do {
      for try await _ in transport.stream(HTTPStreamRequest(url: url)) {
        yieldedChunks += 1
      }
    } catch let error as StreamError {
      caught = error
    }

    #expect(yieldedChunks == 0)
    #expect(caught?.code == .provider)
  }
}

/// A one-connection HTTP server on the loopback interface.
///
/// TEST-2 forbids URLProtocol stubbing, so `stream(_:)` can only be driven
/// end to end by handing `URLSession` a real socket. The server is
/// deliberately dumb: it accepts one connection, discards the request,
/// writes a scripted response, and then either closes or holds the
/// connection open so a buffering regression shows up as a stalled stream.
/// It is a test fixture — the blocking socket I/O runs on its own detached
/// thread, never on an actor (CC-4).
private enum LoopbackHTTPServer {
  /// What the server does once it has written its scripted response.
  enum Ending {
    /// Close the connection, ending the body.
    case close
    /// Keep the connection open until the client hangs up.
    case hold
  }

  #if canImport(Darwin)
    private static let streamSocketType = SOCK_STREAM
  #else
    private static let streamSocketType = Int32(SOCK_STREAM.rawValue)
  #endif

  /// Starts the server and returns the loopback port it listens on, or
  /// `nil` if the socket could not be bound.
  static func start(response: String, ending: Ending) -> UInt16? {
    let bytes = Array(response.utf8)
    let listener = socket(AF_INET, streamSocketType, 0)
    guard listener >= 0 else { return nil }

    var reuse: Int32 = 1
    _ = withUnsafePointer(to: &reuse) { pointer in
      setsockopt(
        listener, SOL_SOCKET, SO_REUSEADDR, pointer, socklen_t(MemoryLayout<Int32>.size))
    }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let addressSize = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, addressSize)
      }
    }
    guard bindResult == 0, listen(listener, 1) == 0 else {
      close(listener)
      return nil
    }

    var bound = sockaddr_in()
    var boundSize = addressSize
    let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(listener, $0, &boundSize)
      }
    }
    guard nameResult == 0 else {
      close(listener)
      return nil
    }

    Thread.detachNewThread { serve(listener: listener, response: bytes, ending: ending) }
    return UInt16(bigEndian: bound.sin_port)
  }

  private static func serve(listener: Int32, response: [UInt8], ending: Ending) {
    let connection = accept(listener, nil, nil)
    close(listener)
    guard connection >= 0 else { return }
    defer { close(connection) }

    #if canImport(Darwin)
      // Without this a write to a client that already hung up raises
      // SIGPIPE, which would take the whole test process down.
      var noSignal: Int32 = 1
      _ = withUnsafePointer(to: &noSignal) { pointer in
        setsockopt(
          connection, SOL_SOCKET, SO_NOSIGPIPE, pointer, socklen_t(MemoryLayout<Int32>.size))
      }
    #endif

    var scratch = [UInt8](repeating: 0, count: 4096)
    // The request head is read only so the client is not blocked writing it;
    // nothing about it is parsed.
    _ = scratch.withUnsafeMutableBytes { recv(connection, $0.baseAddress, $0.count, 0) }
    _ = response.withUnsafeBytes { send(connection, $0.baseAddress, $0.count, 0) }

    guard case .hold = ending else { return }
    while true {
      let read = scratch.withUnsafeMutableBytes { recv(connection, $0.baseAddress, $0.count, 0) }
      if read <= 0 { return }
    }
  }
}
