import Foundation
import os

/// A web service of a test's own, behind a `URLSession` it hands out.
///
/// The cloud engines and the model downloader take their session as a
/// parameter, so a test can answer every request they make — a 401, a 429
/// with `Retry-After`, a body that isn't JSON — without a key or a network.
/// Each stub is found by a header its session adds to every request, which
/// is what lets stubs in tests running side by side answer only their own.
final class StubHTTP: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]

        var path: String { url.path }
        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    enum Reply: Sendable {
        case status(Int, body: Data = Data(), headers: [String: String] = [:])
        case json(Int, String, headers: [String: String] = [:])
        case failure(URLError.Code)
        /// Never answers, for a test about cancelling a request in flight.
        case hang
    }

    typealias Handler = @Sendable (Request, Int) -> Reply

    private let id = UUID().uuidString
    private let handler: Handler
    private let log = OSAllocatedUnfairLock(initialState: [Request]())

    init(_ handler: @escaping Handler) {
        self.handler = handler
        StubProtocol.register(self, id: id)
    }

    deinit { StubProtocol.unregister(id: id) }

    /// A session whose every request reaches this stub.
    lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        configuration.httpAdditionalHeaders = [StubProtocol.header: id]
        return URLSession(configuration: configuration)
    }()

    var configuration: URLSessionConfiguration { session.configuration }

    var requests: [Request] { log.withLock { $0 } }

    func requests(to path: String) -> [Request] { requests.filter { $0.path == path } }

    fileprivate func answer(_ request: URLRequest) -> Reply {
        let recorded = Request(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:])
        let count = log.withLock { log -> Int in
            log.append(recorded)
            return log.filter { $0.path == recorded.path }.count
        }
        return handler(recorded, count)
    }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let header = "X-Amanu-Stub"
    private static let stubs = OSAllocatedUnfairLock(initialState: [String: Weak]())

    struct Weak { weak var stub: StubHTTP? }

    static func register(_ stub: StubHTTP, id: String) {
        stubs.withLock { $0[id] = Weak(stub: stub) }
    }

    static func unregister(id: String) {
        _ = stubs.withLock { $0.removeValue(forKey: id) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: header) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: Self.header),
              let stub = Self.stubs.withLock({ $0[id]?.stub })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let reply = stub.answer(request)
        let status: Int, body: Data, headers: [String: String]
        switch reply {
        case .hang:
            return
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        case .status(let code, let data, let extra):
            (status, body, headers) = (code, data, extra)
        case .json(let code, let text, let extra):
            (status, body, headers) = (
                code, Data(text.utf8), extra.merging(["Content-Type": "application/json"]) { a, _ in a })
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: headers.merging(["Content-Length": "\(body.count)"]) { a, _ in a })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
