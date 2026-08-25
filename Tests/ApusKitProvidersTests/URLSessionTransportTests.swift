// URLSessionTransportTests
//
// Coverage for URLSessionTransport's request-building and status-mapping
// helpers (ASM-3): no network is exercised, per TEST-2.

import ApusKitCore
import ApusKitProviders
import Foundation
import Testing

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

  @Test("init takes the URLSession by injection")
  func initTakesSessionByInjection() {
    // Proves there is no default parameter reaching `URLSession.shared`:
    // an explicit session must be supplied to construct a transport.
    _ = URLSessionTransport(session: URLSession(configuration: .ephemeral))
  }
}
