import Foundation

actor SportsScheduleClient {
    private struct League: Sendable {
        let name: String
        let sport: Sport
        let path: String
        let groups: String?
        let historyDays: Int

        init(name: String, sport: Sport, path: String, groups: String? = nil, historyDays: Int = 1) {
            self.name = name
            self.sport = sport
            self.path = path
            self.groups = groups
            self.historyDays = historyDays
        }
    }

    private static let leagues = [
        League(name: "NFL", sport: .nfl, path: "football/nfl", historyDays: 7),
        League(name: "College Football", sport: .ncaaf, path: "football/college-football", groups: "80", historyDays: 7),
        League(name: "Formula 1", sport: .racing, path: "racing/f1"),
        League(name: "NASCAR Cup", sport: .racing, path: "racing/nascar-premier"),
        League(name: "IndyCar", sport: .racing, path: "racing/irl"),
        League(name: "NHL", sport: .nhl, path: "hockey/nhl"),
        League(name: "Premier League", sport: .soccer, path: "soccer/eng.1"),
        League(name: "La Liga", sport: .soccer, path: "soccer/esp.1"),
        League(name: "MLS", sport: .soccer, path: "soccer/usa.1"),
        League(name: "Champions League", sport: .soccer, path: "soccer/uefa.champions"),
        League(name: "NBA", sport: .nba, path: "basketball/nba"),
        League(name: "MLB", sport: .mlb, path: "baseball/mlb")
    ]

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = ["Accept": "application/json", "User-Agent": "GameDay/0.1 (iPhone)"]
        session = URLSession(configuration: configuration)
    }

    func fetchEvents() async -> [SportsEvent] {
        await withTaskGroup(of: [SportsEvent].self) { group in
            for league in Self.leagues {
                group.addTask { [session] in
                    (try? await Self.fetch(league: league, session: session)) ?? []
                }
            }
            var result: [SportsEvent] = []
            for await events in group { result.append(contentsOf: events) }
            return result.sorted { $0.start < $1.start }
        }
    }

    /// A small current-day refresh used while the game browser is visible so
    /// live/final transitions do not wait for the full schedule refresh.
    func fetchCurrentEvents() async -> [SportsEvent] {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        let today = formatter.string(from: Date())

        return await withTaskGroup(of: [SportsEvent].self) { group in
            for league in Self.leagues {
                group.addTask { [session] in
                    (try? await Self.fetchDay(today, league: league, session: session)) ?? []
                }
            }
            var unique: [String: SportsEvent] = [:]
            for await events in group {
                for event in events { unique[event.id] = event }
            }
            return unique.values.sorted { $0.start < $1.start }
        }
    }

    private static func fetch(league: League, session: URLSession) async throws -> [SportsEvent] {
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd"
        let now = Date()
        let dates = (-league.historyDays...7).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: now).map(formatter.string(from:))
        }

        // Keep each league's date requests sequential. Launching every league and
        // every day simultaneously caused the schedule service to throttle the app,
        // which made a valid response look like an empty schedule.
        var unique: [String: SportsEvent] = [:]
        for date in dates {
            let events = (try? await fetchDay(date, league: league, session: session)) ?? []
            for event in events { unique[event.id] = event }
        }
        return unique.values.sorted { $0.start < $1.start }
    }

    private static func fetchDay(_ date: String, league: League, session: URLSession) async throws -> [SportsEvent] {
        var components = URLComponents(string: "https://site.api.espn.com/apis/site/v2/sports/\(league.path)/scoreboard")!
        components.queryItems = [
            URLQueryItem(name: "dates", value: date),
            URLQueryItem(name: "limit", value: "1000")
        ]
        if let groups = league.groups { components.queryItems?.append(URLQueryItem(name: "groups", value: groups)) }

        let (data, response) = try await session.data(from: components.url!)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode), data.count <= 16 * 1024 * 1024 else { return [] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = root["events"] as? [[String: Any]] else { return [] }
        return rows.flatMap { parse(raw: $0, league: league) }
    }

    private static func parse(raw: [String: Any], league: League) -> [SportsEvent] {
        let rawID = String(describing: raw["id"] ?? UUID().uuidString)
        let rawTitle = raw["name"] as? String ?? "Unnamed event"
        let competitions = (raw["competitions"] as? [[String: Any]]) ?? [[:]]
        let selected = league.sport == .racing ? competitions : Array(competitions.prefix(1))

        return selected.compactMap { competition in
            let competitionID = String(describing: competition["id"] ?? rawID)
            let dateValue = (competition["date"] as? String) ?? (raw["date"] as? String) ?? ""
            guard let start = parseDate(dateValue) else { return nil }

            let statusRoot = (competition["status"] as? [String: Any]) ?? (raw["status"] as? [String: Any]) ?? [:]
            let statusType = statusRoot["type"] as? [String: Any] ?? [:]
            let state = statusType["state"] as? String ?? "pre"
            let status = (statusType["shortDetail"] as? String) ?? (statusType["description"] as? String) ?? "Scheduled"
            let competitors = competition["competitors"] as? [[String: Any]] ?? []
            let teams = league.sport == .racing ? [] : competitors.compactMap { item -> SportsTeam? in
                guard let team = item["team"] as? [String: Any] else { return nil }
                return SportsTeam(
                    name: team["displayName"] as? String ?? "",
                    shortName: team["shortDisplayName"] as? String ?? "",
                    abbreviation: team["abbreviation"] as? String ?? ""
                )
            }

            var title = rawTitle
            if let firstTeam = teams.first?.shortName, !firstTeam.isEmpty {
                let duplicatedPrefix = "\(firstTeam) \(firstTeam)"
                if title.localizedCaseInsensitiveCompare(duplicatedPrefix) == .orderedSame {
                    title = firstTeam
                } else if title.lowercased().hasPrefix(duplicatedPrefix.lowercased() + " ") {
                    title.removeFirst(firstTeam.count + 1)
                }
            }
            if league.sport == .racing, let type = competition["type"] as? [String: Any] {
                let sessionName = (type["text"] as? String) ?? (type["abbreviation"] as? String) ?? ""
                if !sessionName.isEmpty { title += " · \(sessionName)" }
            }

            let broadcasts = (competition["broadcasts"] as? [[String: Any]] ?? []).flatMap { $0["names"] as? [String] ?? [] }
            let score = scoreText(competitors: competitors, state: state)
            return SportsEvent(
                id: "espn:\(league.path):\(rawID):\(competitionID)",
                title: title,
                sport: league.sport,
                league: league.name,
                start: start,
                status: status,
                state: state,
                teams: teams,
                broadcasts: Array(Set(broadcasts)).sorted(),
                score: score
            )
        }
    }

    private static func scoreText(competitors: [[String: Any]], state: String) -> String? {
        guard state == "in" || state == "post" else { return nil }
        let rows = competitors.compactMap { item -> String? in
            guard let team = item["team"] as? [String: Any] else { return nil }
            let name = (team["abbreviation"] as? String) ?? (team["shortDisplayName"] as? String) ?? "?"
            let rawScore = item["score"]
            let score: String
            if let value = rawScore as? String { score = value }
            else if let value = rawScore as? NSNumber { score = value.stringValue }
            else if let value = rawScore as? [String: Any] { score = String(describing: value["displayValue"] ?? value["value"] ?? "") }
            else { return nil }
            return "\(name) \(score)"
        }
        guard rows.count == 2 else { return nil }
        return rows.joined(separator: " — ")
    }

    static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) {
            return date
        }

        // ESPN commonly returns minute-precision timestamps such as
        // "2026-09-20T17:00Z", which ISO8601DateFormatter rejects on iOS.
        let minutePrecision = DateFormatter()
        minutePrecision.locale = Locale(identifier: "en_US_POSIX")
        minutePrecision.calendar = Calendar(identifier: .gregorian)
        minutePrecision.timeZone = TimeZone(secondsFromGMT: 0)
        minutePrecision.dateFormat = "yyyy-MM-dd'T'HH:mmXXXXX"
        return minutePrecision.date(from: value)
    }
}
