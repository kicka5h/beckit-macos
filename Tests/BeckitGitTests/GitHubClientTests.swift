import Foundation
import Testing
@testable import BeckitGit

/// Covers the device-flow request's response handling.
///
/// Worth testing offline because GitHub reports several failures from this
/// endpoint as a **200** carrying an error body rather than an HTTP error. An
/// implementation that decodes straight into the success type turns "device
/// flow is switched off" — the single most likely first-run failure — into an
/// opaque decoding error, which is exactly what happened here before.
/// Serialised because the stub protocol holds one canned response for the whole
/// process — URLProtocol is registered per session configuration, not per
/// request, so parallel tests would read each other's response.
@Suite("GitHub device flow", .serialized)
struct GitHubClientTests {

    private func client(returning body: String, status: Int = 200) -> GitHubClient {
        StubProtocol.respond(status: status, body: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return GitHubClient(
            clientID: "Ov23liTEST", session: URLSession(configuration: configuration))
    }

    @Test("A successful response becomes a device code")
    func success() async throws {
        let client = client(returning: """
            {"device_code":"abc123","user_code":"526B-80DC",
             "verification_uri":"https://github.com/login/device",
             "expires_in":899,"interval":5}
            """)

        let device = try await client.requestDeviceCode()
        #expect(device.deviceCode == "abc123")
        #expect(device.userCode == "526B-80DC")
        #expect(device.expiresIn == 899)
        #expect(device.interval == 5)
    }

    /// GitHub has omitted `interval` in the past. Five seconds is its documented
    /// default, and polling faster than the interval earns a `slow_down`.
    @Test("A missing interval falls back to GitHub's documented default")
    func missingInterval() async throws {
        let client = client(returning: """
            {"device_code":"abc123","user_code":"526B-80DC",
             "verification_uri":"https://github.com/login/device","expires_in":899}
            """)

        #expect(try await client.requestDeviceCode().interval == 5)
    }

    @Test("Device flow being switched off is reported as such, not as a decode failure")
    func deviceFlowDisabled() async {
        let client = client(returning: """
            {"error":"device_flow_disabled",
             "error_description":"Device Flow has not been enabled for this app."}
            """)

        await #expect(throws: GitHubError.self) {
            _ = try await client.requestDeviceCode()
        }

        // The message has to name the fix: the setting is on a different screen
        // from the one where the app is registered, and it is off by default.
        do {
            _ = try await client.requestDeviceCode()
        } catch let error as GitHubError {
            #expect(error.errorDescription?.contains("Enable Device Flow") == true)
        } catch {
            Issue.record("expected a GitHubError, got \(error)")
        }
    }

    @Test("An unrecognised client ID says so")
    func unknownClientID() async {
        let client = client(returning: #"{"error":"unauthorized_client"}"#)

        do {
            _ = try await client.requestDeviceCode()
            Issue.record("expected a failure")
        } catch let error as GitHubError {
            #expect(error.errorDescription?.contains("does not recognise") == true)
        } catch {
            Issue.record("expected a GitHubError, got \(error)")
        }
    }

    @Test("A build with no client ID fails before touching the network")
    func missingClientID() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let client = GitHubClient(
            clientID: "", session: URLSession(configuration: configuration))

        await #expect(throws: GitHubError.self) {
            _ = try await client.requestDeviceCode()
        }
    }
}

/// Serves a canned response to any request, so the client's parsing can be
/// tested without the network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    private struct Response: Sendable {
        var status: Int
        var body: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var canned = Response(status: 200, body: "{}")

    static func respond(status: Int, body: String) {
        lock.withLock { canned = Response(status: status, body: body) }
    }

    private static var current: Response {
        lock.withLock { canned }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = Self.current
        let http = HTTPURLResponse(
            url: request.url!, statusCode: response.status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
