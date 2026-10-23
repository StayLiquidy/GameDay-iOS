import Foundation

enum Sport: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case all = "All"
    case nfl = "NFL"
    case ncaaf = "NCAAF"
    case racing = "Racing"
    case nhl = "NHL"
    case soccer = "Soccer"
    case nba = "NBA"
    case mlb = "MLB"
    case other = "Other"

    var id: String { rawValue }
}

struct SportsTeam: Codable, Hashable, Sendable {
    let name: String
    let shortName: String
    let abbreviation: String
}

struct SportsEvent: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let sport: Sport
    let league: String
    let start: Date
    let status: String
    let state: String
    let teams: [SportsTeam]
    let broadcasts: [String]
    let score: String?

    var isLive: Bool { state == "in" }

    var timeLabel: String {
        if isLive { return "LIVE · \(status)" }
        if state == "post" { return status.isEmpty ? "Final" : status }
        return start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    }
}

enum FinishedGameVisibility: Int, CaseIterable, Identifiable, Sendable {
    case immediately = 0
    case oneHour = 1
    case twoHours = 2
    case threeHours = 3
    case sixHours = 6

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .immediately: "Immediately"
        case .oneHour: "1 hour"
        case .twoHours: "2 hours"
        case .threeHours: "3 hours"
        case .sixHours: "6 hours"
        }
    }
    var duration: TimeInterval { TimeInterval(rawValue * 3600) }
}

enum FinishedGameFilter {
    /// Records only a transition that ESPN reported from live to final. A game
    /// first received as final has no trustworthy end time, so it is omitted.
    static func updateObservations(
        previous: [SportsEvent],
        refreshed: [SportsEvent],
        existing: [String: Date],
        now: Date
    ) -> [String: Date] {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let refreshedIDs = Set(refreshed.map(\.id))
        var result = existing.filter { refreshedIDs.contains($0.key) }

        for event in refreshed {
            if event.state == "post" {
                if result[event.id] == nil, previousByID[event.id]?.state == "in" {
                    result[event.id] = now
                }
            } else {
                result[event.id] = nil
            }
        }
        return result
    }

    static func visible(
        _ events: [SportsEvent],
        observations: [String: Date],
        retention: FinishedGameVisibility,
        now: Date
    ) -> [SportsEvent] {
        events.filter { event in
            guard event.state == "post" else { return true }
            guard retention != .immediately, let observedAt = observations[event.id] else { return false }
            return now.timeIntervalSince(observedAt) < retention.duration
        }
    }
}

struct MatchedFeed: Identifiable, Hashable, Sendable {
    let channel: LiveChannel
    let confidence: Int
    let reason: String
    var id: Int { channel.id }

    var advertisedQuality: String {
        let value = channel.name.lowercased()
        if value.contains("4k") || value.contains("uhd") { return "4K" }
        if value.contains("fhd") || value.contains("1080") { return "FHD" }
        if value.contains("hd") || value.contains("720") { return "HD" }
        return "LIVE"
    }
}

struct SmartSelectionConfig: Codable, Equatable, Sendable {
    var countries: Set<String> = ["US", "UK", "CA"]
    var sports: Set<Sport> = [.nfl, .ncaaf, .racing, .nhl, .soccer, .nba]
    var keepUnlabeled = true

    static let `default` = SmartSelectionConfig()
}

struct SmartPreviewRow: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kept: Int
    let total: Int
    let reason: String
}

struct SmartSelectionResult: Sendable {
    let config: SmartSelectionConfig
    let excludedIDs: Set<Int>
    let rows: [SmartPreviewRow]
    let keptCount: Int
}

enum SportsText {
    static func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func contains(_ text: String, phrase: String) -> Bool {
        let phrase = normalize(phrase)
        return !phrase.isEmpty && " \(normalize(text)) ".contains(" \(phrase) ")
    }
}

enum SportsClassifier {
    private static let phrases: [Sport: [String]] = [
        .nfl: ["nfl", "nfl network", "redzone", "red zone", "sunday ticket"],
        .ncaaf: ["ncaaf", "college football", "ncaa football", "cfb", "sec network", "acc network", "big ten"],
        .racing: ["f1", "formula 1", "formula one", "nascar", "indycar", "motogp", "racing", "motorsport", "imsa", "wec"],
        .nhl: ["nhl", "hockey"],
        .soccer: ["soccer", "football", "premier league", "la liga", "champions league", "mls", "bundesliga", "serie a", "ligue 1"],
        .nba: ["nba", "basketball", "wnba"],
        .mlb: ["mlb", "baseball"],
        .other: ["ufc", "mma", "boxing", "golf", "tennis", "rugby", "cricket", "wrestling"]
    ]

    static let sharedCarriers = [
        "prime video", "amazon prime", "nbc", "cbs", "fox sports", "fs1", "fs2", "abc", "peacock",
        "paramount", "espn", "espn+", "espnu", "espnews", "dazn", "bein", "sky sports", "tnt", "tbs",
        "sportsnet", "tsn", "supersport", "fubo", "apple tv", "usa network", "bbc", "itv"
    ]

    static func sports(in text: String) -> Set<Sport> {
        Set(phrases.compactMap { sport, values in
            values.contains(where: { SportsText.contains(text, phrase: $0) }) ? sport : nil
        })
    }

    static func primarySport(for channel: LiveChannel, categoryName: String) -> Sport {
        let detected = sports(in: "\(channel.name) \(categoryName)")
        return Sport.allCases.first(where: { $0 != .all && detected.contains($0) }) ?? .other
    }

    static func region(in label: String) -> String? {
        let text = SportsText.normalize(label)
        let choices: [(String, [String])] = [
            ("US", ["us", "usa", "united states", "american"]),
            ("UK", ["uk", "gb", "united kingdom", "british"]),
            ("CA", ["ca", "can", "canada", "canadian"]),
            ("AU", ["au", "aus", "australia"]),
            ("IT", ["it", "italy", "italian"]),
            ("ES", ["es", "spain", "spanish"]),
            ("FR", ["fr", "france", "french"]),
            ("DE", ["de", "germany", "german"]),
            ("BR", ["br", "brazil"]),
            ("MX", ["mx", "mexico"])
        ]
        for (code, aliases) in choices where aliases.contains(where: { text == $0 || text.hasPrefix("\($0) ") }) {
            return code
        }
        return nil
    }

    static func classify(channel: LiveChannel, categoryName: String, config: SmartSelectionConfig) -> (Bool, String) {
        let combined = "\(channel.name) \(categoryName)"
        let place = region(in: channel.name) ?? region(in: categoryName)
        if let place, !config.countries.contains(place) { return (false, "Different country: \(place)") }
        if place == nil && !config.keepUnlabeled { return (false, "Country not labeled") }

        let detected = sports(in: combined)
        if !detected.isEmpty {
            let names = detected.map(\.rawValue).sorted().joined(separator: ", ")
            return (!detected.isDisjoint(with: config.sports), "Sport: \(names)")
        }

        if sharedCarriers.contains(where: { SportsText.contains(combined, phrase: $0) }) {
            return (!config.sports.isEmpty, "Shared sports broadcaster")
        }
        if SportsText.contains(combined, phrase: "sport") || SportsText.contains(combined, phrase: "sports") {
            return (!config.sports.isEmpty, "General sports listing")
        }
        return (false, "No selected sport recognized")
    }

    static func preview(channels: [LiveChannel], categories: [LiveCategory], config: SmartSelectionConfig) -> SmartSelectionResult {
        let categoryNames = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
        var excluded = Set<Int>()
        var totals: [String: (name: String, kept: Int, total: Int, reasons: Set<String>)] = [:]

        for channel in channels {
            let categoryID = channel.categoryID ?? ""
            let categoryName = categoryNames[categoryID] ?? "Unsorted"
            let (keep, reason) = classify(channel: channel, categoryName: categoryName, config: config)
            if !keep { excluded.insert(channel.id) }
            var row = totals[categoryID] ?? (categoryName, 0, 0, [])
            row.total += 1
            if keep { row.kept += 1 }
            row.reasons.insert(reason)
            totals[categoryID] = row
        }

        let rows = totals.map { id, row in
            SmartPreviewRow(id: id, name: row.name, kept: row.kept, total: row.total, reason: row.reasons.sorted().joined(separator: "; "))
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return SmartSelectionResult(config: config, excludedIDs: excluded, rows: rows, keptCount: channels.count - excluded.count)
    }
}

enum SportsMatcher {
    private static let nicknameAliases: [String: [String]] = [
        "buccaneers": ["bucs"],
        "49ers": ["niners", "forty niners"],
        "manchester united": ["man utd", "man united"],
        "manchester city": ["man city"]
    ]

    static func feeds(
        for event: SportsEvent,
        channels: [LiveChannel],
        categoryNames: [String: String],
        supplementalText: [Int: String] = [:]
    ) -> [MatchedFeed] {
        var matches: [MatchedFeed] = []
        let teamAliases = event.teams.prefix(2).map(aliases(for:))
        let eventWords = SportsText.normalize(event.title).split(separator: " ").map(String.init).filter {
            $0.count > 3 && !["grand", "prix", "race", "racing", "formula"].contains($0)
        }

        for channel in channels {
            let providerText = " \(SportsText.normalize("\(channel.name) \(categoryNames[channel.categoryID ?? ""] ?? "")")) "
            let guideText = " \(SportsText.normalize(supplementalText[channel.id] ?? "")) "
            let normalizedText = providerText + guideText
            if teamAliases.count >= 2 {
                let teamHits = teamAliases.map { aliases in
                    aliases.contains(where: { $0.count >= 3 && normalizedText.contains(" \($0) ") })
                }
                if teamHits.allSatisfy({ $0 }) {
                    let guideHits = teamAliases.map { aliases in
                        aliases.contains(where: { $0.count >= 3 && guideText.contains(" \($0) ") })
                    }
                    matches.append(MatchedFeed(
                        channel: channel,
                        confidence: guideHits.allSatisfy({ $0 }) ? 98 : 90,
                        reason: guideHits.allSatisfy({ $0 }) ? "TV guide matches both teams" : "Both teams appear in the provider listing"
                    ))
                } else if teamHits.contains(true) {
                    matches.append(MatchedFeed(channel: channel, confidence: 35, reason: "Other possible feed · only one team appears"))
                }
            } else {
                let hits = eventWords.filter { normalizedText.contains(" \($0) ") }.count
                if hits >= min(2, eventWords.count), !eventWords.isEmpty {
                    let guideHits = eventWords.filter { guideText.contains(" \($0) ") }.count
                    matches.append(MatchedFeed(
                        channel: channel,
                        confidence: guideHits >= min(2, eventWords.count) ? 95 : 80,
                        reason: guideHits >= min(2, eventWords.count) ? "TV guide matches this event" : "Event-specific words appear in the provider listing"
                    ))
                }
            }
        }
        return matches.sorted {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return $0.channel.name.localizedCaseInsensitiveCompare($1.channel.name) == .orderedAscending
        }
    }

    private static func aliases(for team: SportsTeam) -> [String] {
        var values = [team.name, team.shortName, team.abbreviation].filter { !$0.isEmpty }
        let normalizedName = SportsText.normalize(team.name)
        for (name, aliases) in nicknameAliases where SportsText.contains(normalizedName, phrase: name) {
            values.append(contentsOf: aliases)
        }
        return Array(Set(values.map(SportsText.normalize)))
    }
}
