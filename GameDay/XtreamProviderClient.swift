import Foundation

actor XtreamProviderClient {
    private let credentials: ProviderCredentials
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(credentials: ProviderCredentials) {
        self.credentials = credentials
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpAdditionalHeaders = [
            "Accept": "application/json",
            "User-Agent": "GameDay/0.1 (iPhone; Xtream Client)"
        ]
        self.session = URLSession(configuration: configuration)
    }

    func validateAccount() async throws {
        let envelope: AccountEnvelope = try await request(credentials.apiURL())
        guard envelope.userInfo.auth.boolValue,
              envelope.userInfo.status?.lowercased() != "disabled",
              envelope.userInfo.status?.lowercased() != "expired" else {
            throw ProviderError.invalidCredentials
        }
    }

    func fetchCategories() async throws -> [LiveCategory] {
        try await request(credentials.apiURL(action: "get_live_categories"))
    }

    func fetchLiveChannels() async throws -> [LiveChannel] {
        try await request(credentials.apiURL(action: "get_live_streams"))
    }

    private func request<T: Decodable>(_ url: URL) async throws -> T {
        var mostRecentError: Error = ProviderError.invalidResponse

        for attempt in 1...2 {
            do {
                return try await performRequest(url)
            } catch {
                mostRecentError = error
                guard attempt < 2, shouldRetry(error) else { throw error }
                try await Task.sleep(for: .seconds(1))
            }
        }

        throw mostRecentError
    }

    private func performRequest<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard (200...299).contains(response.statusCode) else { throw ProviderError.serverStatus(response.statusCode) }
        do { return try decoder.decode(T.self, from: data) }
        catch { throw ProviderError.invalidResponse }
    }

    private func shouldRetry(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [.networkConnectionLost, .timedOut, .cannotConnectToHost, .dnsLookupFailed].contains(urlError.code)
        }
        if case ProviderError.serverStatus(let status) = error {
            return status == 429 || (500...599).contains(status)
        }
        return false
    }
}
