import Foundation

struct ProviderCredentials: Codable, Equatable {
    let host: URL
    let username: String
    let password: String

    init(host: String, username: String, password: String) throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty, !password.isEmpty else { throw ProviderError.missingCredentials }
        guard var components = URLComponents(string: trimmedHost),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else { throw ProviderError.invalidHost }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = basePath.isEmpty ? "" : "/\(basePath)"
        guard let url = components.url else { throw ProviderError.invalidHost }
        self.host = url
        self.username = trimmedUsername
        self.password = password
    }

    func apiURL(action: String? = nil) throws -> URL {
        var components = URLComponents(url: host.appendingPathComponent("player_api.php"), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "username", value: username), URLQueryItem(name: "password", value: password)]
        if let action { items.append(URLQueryItem(name: "action", value: action)) }
        components?.queryItems = items
        guard let url = components?.url else { throw ProviderError.invalidHost }
        return url
    }

    func liveStreamURL(streamID: Int, extension fileExtension: String?) -> URL? {
        let ext = (fileExtension?.isEmpty == false ? fileExtension! : "ts")
        return host
            .appendingPathComponent("live")
            .appendingPathComponent(username)
            .appendingPathComponent(password)
            .appendingPathComponent("\(streamID).\(ext)")
    }
}

enum ProviderError: LocalizedError {
    case missingCredentials
    case invalidHost
    case invalidCredentials
    case invalidResponse
    case serverStatus(Int)

    var errorDescription: String? {
        switch self {
        case .missingCredentials: "Enter your host, username, and password."
        case .invalidHost: "Enter a valid HTTP or HTTPS provider address."
        case .invalidCredentials: "The provider rejected those credentials. Check the details and try again."
        case .invalidResponse: "The provider returned data GameDay could not read."
        case .serverStatus(let status): "The provider returned an error (\(status)). Try again shortly."
        }
    }

    static func userMessage(for error: Error) -> String {
        if let providerError = error as? ProviderError { return providerError.localizedDescription }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "The provider is not responding. Try cellular data or another Wi-Fi network; this network may block the provider."
            case .notConnectedToInternet: return "Connect to the internet and try again."
            case .cannotFindHost, .cannotConnectToHost: return "GameDay could not reach the provider. Try cellular data or another Wi-Fi network."
            case .networkConnectionLost: return "The provider interrupted the channel download. Try again on a stable connection."
            case .appTransportSecurityRequiresSecureConnection: return "iOS blocked this HTTP provider. This build may be outdated or incorrectly signed; reinstall the latest GameDay build."
            default: return "The connection failed. Check the provider address and try again."
            }
        }
        return "The import failed. Your entered values are still here so you can retry."
    }
}

struct LiveCategory: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String

    enum CodingKeys: String, CodingKey { case id = "category_id"; case name = "category_name" }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeStringOrNumber(forKey: .id)
        name = (try? container.decodeStringOrNumber(forKey: .name)) ?? "Untitled category"
    }
}

struct LiveChannel: Identifiable, Codable, Hashable, Sendable {
    let streamID: Int
    let name: String
    let categoryID: String?
    let streamType: String?
    let containerExtension: String?

    var id: Int { streamID }

    enum CodingKeys: String, CodingKey {
        case streamID = "stream_id"
        case name
        case categoryID = "category_id"
        case streamType = "stream_type"
        case containerExtension = "container_extension"
    }

    init(streamID: Int, name: String, categoryID: String?, streamType: String? = "live", containerExtension: String? = "m3u8") {
        self.streamID = streamID
        self.name = name
        self.categoryID = categoryID
        self.streamType = streamType
        self.containerExtension = containerExtension
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        streamID = try container.decodeIntOrString(forKey: .streamID)
        name = (try? container.decodeStringOrNumber(forKey: .name)) ?? "Channel \(streamID)"
        categoryID = try? container.decodeStringOrNumber(forKey: .categoryID)
        streamType = try? container.decodeStringOrNumber(forKey: .streamType)
        containerExtension = try? container.decodeStringOrNumber(forKey: .containerExtension)
    }
}

struct AccountEnvelope: Decodable {
    let userInfo: UserInfo
    enum CodingKeys: String, CodingKey { case userInfo = "user_info" }
}

struct UserInfo: Decodable {
    let auth: FlexibleBool
    let status: String?

    enum CodingKeys: String, CodingKey { case auth, status }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        auth = try container.decode(FlexibleBool.self, forKey: .auth)
        status = try? container.decodeStringOrNumber(forKey: .status)
    }
}

enum FlexibleBool: Decodable {
    case value(Bool)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) { self = .value(bool); return }
        if let int = try? container.decode(Int.self) { self = .value(int != 0); return }
        if let string = try? container.decode(String.self) { self = .value(["1", "true", "active"].contains(string.lowercased())); return }
        self = .value(false)
    }

    var boolValue: Bool { if case .value(let value) = self { value } else { false } }
}

private extension KeyedDecodingContainer {
    func decodeStringOrNumber(forKey key: Key) throws -> String {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        throw DecodingError.typeMismatch(
            String.self,
            DecodingError.Context(codingPath: codingPath + [key], debugDescription: "Expected a string or number.")
        )
    }

    func decodeIntOrString(forKey key: Key) throws -> Int {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key), let integer = Int(value) { return integer }
        throw DecodingError.typeMismatch(
            Int.self,
            DecodingError.Context(codingPath: codingPath + [key], debugDescription: "Expected an integer or numeric string.")
        )
    }
}
