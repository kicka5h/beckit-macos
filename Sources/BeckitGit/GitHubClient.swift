import Foundation

/// GitHub OAuth device flow and the handful of REST calls Beckit makes.
///
/// Device flow needs no client secret, which is why it suits a distributed
/// desktop app: there is nothing in the binary worth extracting.
public struct GitHubClient: Sendable {
    private let session: URLSession
    private let clientID: String

    /// The OAuth app's client ID. Not a secret — device flow does not use a
    /// client secret. Injected at build time so forks can point at their own
    /// OAuth app without patching source.
    public static var defaultClientID: String {
        Bundle.main.object(forInfoDictionaryKey: "BeckitOAuthClientID") as? String
            ?? ProcessInfo.processInfo.environment["BECKIT_OAUTH_CLIENT_ID"]
            ?? ""
    }

    public init(clientID: String = GitHubClient.defaultClientID, session: URLSession = .shared) {
        self.clientID = clientID
        self.session = session
    }

    // MARK: - Device flow

    public struct DeviceCode: Sendable, Decodable {
        public let deviceCode: String
        public let userCode: String
        public let verificationURI: URL
        public let expiresIn: Int
        public let interval: Int

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case userCode = "user_code"
            case verificationURI = "verification_uri"
            case expiresIn = "expires_in"
            case interval
        }
    }

    /// Step one: ask GitHub for a code to show the writer.
    public func requestDeviceCode(scope: String = "repo") async throws -> DeviceCode {
        try requireClientID()
        return try await post(
            to: "https://github.com/login/device/code",
            body: ["client_id": clientID, "scope": scope],
            as: DeviceCode.self)
    }

    /// Step two: poll until the writer authorises the app in their browser.
    ///
    /// Honours GitHub's `interval` and backs off further when told to
    /// `slow_down`; polling faster than instructed gets the request rejected.
    public func pollForToken(_ device: DeviceCode) async throws -> String {
        let deadline = ContinuousClock.now.advanced(by: .seconds(device.expiresIn))
        var interval = Duration.seconds(device.interval)

        while ContinuousClock.now < deadline {
            try await Task.sleep(for: interval)
            try Task.checkCancellation()

            let response = try await post(
                to: "https://github.com/login/oauth/access_token",
                body: [
                    "client_id": clientID,
                    "device_code": device.deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ],
                as: TokenResponse.self)

            if let token = response.accessToken { return token }

            switch response.error {
            case "authorization_pending": continue
            case "slow_down": interval += .seconds(5)
            case "access_denied": throw GitHubError.authorizationDenied
            case "expired_token": throw GitHubError.deviceCodeExpired
            case let other?: throw GitHubError.api(response.errorDescription ?? other)
            case nil: throw GitHubError.api("Unexpected response from GitHub.")
            }
        }
        throw GitHubError.deviceCodeExpired
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case error
            case errorDescription = "error_description"
        }
    }

    // MARK: - REST

    public struct Account: Sendable, Decodable {
        public let login: String
        public let avatarURL: URL?

        enum CodingKeys: String, CodingKey {
            case login
            case avatarURL = "avatar_url"
        }
    }

    public struct Repository: Sendable, Decodable, Identifiable, Hashable {
        public let id: Int
        public let name: String
        public let fullName: String
        public let cloneURL: URL
        public let isPrivate: Bool
        public let updatedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id, name
            case fullName = "full_name"
            case cloneURL = "clone_url"
            case isPrivate = "private"
            case updatedAt = "updated_at"
        }
    }

    /// Confirms a stored token still works and returns who it belongs to.
    public func account(token: String) async throws -> Account {
        try await get("https://api.github.com/user", token: token, as: Account.self)
    }

    /// Every repository the token can push to, newest activity first.
    public func repositories(token: String) async throws -> [Repository] {
        var all: [Repository] = []
        var page = 1
        // GitHub caps a page at 100; stop early rather than walking a huge
        // account forever.
        while page <= 10 {
            let url = "https://api.github.com/user/repos"
                + "?per_page=100&page=\(page)&sort=updated&affiliation=owner,collaborator"
            let batch = try await get(url, token: token, as: [Repository].self)
            all.append(contentsOf: batch)
            if batch.count < 100 { break }
            page += 1
        }
        return all
    }

    public func createRepository(
        named name: String,
        isPrivate: Bool,
        description: String,
        token: String
    ) async throws -> Repository {
        try await post(
            to: "https://api.github.com/user/repos",
            body: ["name": name, "private": isPrivate, "description": description,
                   "auto_init": true],
            token: token,
            as: Repository.self)
    }

    // MARK: - Transport

    private func requireClientID() throws {
        guard !clientID.isEmpty else { throw GitHubError.missingClientID }
    }

    private func post<T: Decodable>(
        to urlString: String,
        body: [String: any Sendable],
        token: String? = nil,
        as type: T.Type
    ) async throws -> T {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request, token: token, as: type)
    }

    private func get<T: Decodable>(
        _ urlString: String, token: String, as type: T.Type
    ) async throws -> T {
        try await send(URLRequest(url: URL(string: urlString)!), token: token, as: type)
    }

    private func send<T: Decodable>(
        _ request: URLRequest, token: String?, as type: T.Type
    ) async throws -> T {
        var request = request
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Beckit", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 20

        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            throw GitHubError.invalidToken
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // The token endpoint reports its errors in a 200 body, so anything
            // that lands here is a genuine HTTP failure worth surfacing.
            let message = (try? JSONDecoder().decode(APIError.self, from: data))?.message
            throw GitHubError.api(message ?? "GitHub returned \(http.statusCode).")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    private struct APIError: Decodable { let message: String }
}

public enum GitHubError: Error, LocalizedError {
    case missingClientID
    case authorizationDenied
    case deviceCodeExpired
    case invalidToken
    case api(String)

    public var errorDescription: String? {
        switch self {
        case .missingClientID:
            """
            No GitHub OAuth client ID is configured in this build. \
            Set BeckitOAuthClientID in Info.plist.
            """
        case .authorizationDenied:
            "You declined the authorization request on GitHub."
        case .deviceCodeExpired:
            "The sign-in code expired. Start again to get a new one."
        case .invalidToken:
            "Your GitHub sign-in is no longer valid. Sign in again."
        case .api(let message):
            message
        }
    }
}
