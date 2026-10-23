import Foundation
import zlib

enum GuideSourceKind: String, Codable, Sendable {
    case localFile
    case remoteURL

    var title: String {
        switch self {
        case .localFile: "Imported file"
        case .remoteURL: "Auto-updating URL"
        }
    }
}

struct GuideSource: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let providerID: String
    var name: String
    let kind: GuideSourceKind
    var playlistLocation: String
    var epgURL: String?
    var enabled: Bool
    var priority: Int
    var channelCount: Int
    var matchedChannelCount: Int
    var programmeCount: Int
    var lastPlaylistRefresh: Date?
    var lastGuideRefresh: Date?
    var errorMessage: String?
}

struct GuideChannelMetadata: Codable, Hashable, Sendable {
    let streamID: Int
    let tvgID: String?
    let name: String
    let logoURL: String?
    let groupTitle: String?
}

struct GuideProgramme: Identifiable, Codable, Hashable, Sendable {
    let channelID: String
    let start: Date
    let stop: Date
    let title: String
    let subtitle: String?
    let description: String?
    let iconURL: String?

    var id: String { "\(channelID)|\(start.timeIntervalSince1970)|\(title)" }
    var isLive: Bool { start <= Date() && stop > Date() }
}

struct GuideCache: Codable, Sendable {
    let sourceID: UUID
    let channels: [GuideChannelMetadata]
    let programmes: [GuideProgramme]
}

struct GuideRefreshResult: Sendable {
    let source: GuideSource
    let cache: GuideCache
}

enum GuideError: LocalizedError {
    case invalidPlaylist
    case invalidURL
    case downloadFailed
    case fileTooLarge
    case invalidGuide
    case decompressionFailed

    var errorDescription: String? {
        switch self {
        case .invalidPlaylist: "This file does not appear to be a supported M3U playlist."
        case .invalidURL: "Enter a valid HTTP or HTTPS playlist URL."
        case .downloadFailed: "GameDay could not download this guide source."
        case .fileTooLarge: "This guide source is too large to import safely."
        case .invalidGuide: "The linked XMLTV guide could not be read."
        case .decompressionFailed: "The compressed XMLTV guide could not be opened."
        }
    }
}

enum M3UPlaylistParser {
    struct Result: Sendable {
        let channels: [GuideChannelMetadata]
        let epgURL: URL?
    }

    static func parse(_ data: Data) throws -> Result {
        guard data.count <= 32 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else {
            throw GuideError.invalidPlaylist
        }

        let lines = text.components(separatedBy: .newlines)
        let epgURL = lines.first.flatMap(extractEPGURL)
        var channels: [GuideChannelMetadata] = []
        var pendingAttributes: [String: String]?
        var pendingDisplayName: String?

        for rawLine in lines.dropFirst() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXTINF:") {
                let attributes = parseAttributes(line)
                pendingAttributes = attributes
                pendingDisplayName = attributes["tvg-name"].nonEmpty ?? displayName(from: line)
                continue
            }

            guard !line.isEmpty, !line.hasPrefix("#"), let attributes = pendingAttributes else { continue }
            defer {
                pendingAttributes = nil
                pendingDisplayName = nil
            }
            // EPGenius includes a playable tutorial as its first row. It is not a
            // provider channel and its demo URL could otherwise collide with stream 1.
            if attributes["tvg-id"]?.caseInsensitiveCompare("EPGenius") == .orderedSame { continue }
            guard let streamID = streamID(from: line) else { continue }
            channels.append(GuideChannelMetadata(
                streamID: streamID,
                tvgID: attributes["tvg-id"].nonEmpty,
                name: pendingDisplayName.nonEmpty ?? "Channel \(streamID)",
                logoURL: attributes["tvg-logo"].nonEmpty,
                groupTitle: attributes["group-title"].nonEmpty
            ))
        }

        guard !channels.isEmpty else { throw GuideError.invalidPlaylist }
        var unique: [Int: GuideChannelMetadata] = [:]
        for channel in channels { unique[channel.streamID] = channel }
        return Result(channels: Array(unique.values), epgURL: epgURL)
    }

    private static func extractEPGURL(from header: String) -> URL? {
        let attributes = parseAttributes(header)
        return (attributes["url-tvg"] ?? attributes["x-tvg-url"])
            .flatMap { $0.split(separator: ",").first.map(String.init) }
            .flatMap(URL.init(string:))
    }

    private static func parseAttributes(_ line: String) -> [String: String] {
        let pattern = #"([A-Za-z0-9_-]+)="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.matches(in: line, range: range).reduce(into: [:]) { result, match in
            guard let keyRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 2), in: line) else { return }
            result[String(line[keyRange]).lowercased()] = String(line[valueRange])
        }
    }

    private static func displayName(from line: String) -> String? {
        var quoted = false
        for index in line.indices {
            if line[index] == "\"" { quoted.toggle() }
            if line[index] == ",", !quoted {
                return String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func streamID(from line: String) -> Int? {
        let path = line.split(separator: "?", maxSplits: 1).first.map(String.init) ?? line
        let component = path.split(separator: "/").last.map(String.init) ?? path
        let stem = component.split(separator: ".", maxSplits: 1).first.map(String.init) ?? component
        if let value = Int(stem), value > 0 { return value }

        let pattern = #"(?:stream_id=|/)([0-9]+)(?:\.[A-Za-z0-9]+)?(?:[?&]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.matches(in: line, range: range).last,
              let idRange = Range(match.range(at: 1), in: line),
              let value = Int(line[idRange]), value > 0 else { return nil }
        return value
    }
}

private final class XMLTVParserDelegate: NSObject, XMLParserDelegate {
    private struct Builder {
        let channelID: String
        let start: Date
        let stop: Date
        var title = ""
        var subtitle = ""
        var description = ""
        var iconURL: String?
    }

    private let allowedChannelIDs: Set<String>
    private let earliestDate: Date
    private let latestDate: Date
    private var builder: Builder?
    private var activeElement: String?
    private var text = ""
    private(set) var programmes: [GuideProgramme] = []

    init(channelIDs: Set<String>, now: Date = Date()) {
        allowedChannelIDs = channelIDs
        earliestDate = now.addingTimeInterval(-6 * 3600)
        latestDate = now.addingTimeInterval(72 * 3600)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "programme":
            guard let channelID = attributeDict["channel"], allowedChannelIDs.contains(channelID),
                  let start = XMLTVDateParser.date(from: attributeDict["start"]),
                  let stop = XMLTVDateParser.date(from: attributeDict["stop"]),
                  stop >= earliestDate, start <= latestDate else {
                builder = nil
                return
            }
            builder = Builder(channelID: channelID, start: start, stop: stop)
        case "title", "sub-title", "desc":
            guard builder != nil else { return }
            activeElement = elementName
            text = ""
        case "icon":
            if builder != nil { builder?.iconURL = attributeDict["src"] }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if activeElement != nil { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if activeElement != nil, let value = String(data: CDATABlock, encoding: .utf8) { text += value }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "title": builder?.title = value
        case "sub-title": builder?.subtitle = value
        case "desc": builder?.description = value
        case "programme":
            if let builder, !builder.title.isEmpty {
                programmes.append(GuideProgramme(
                    channelID: builder.channelID,
                    start: builder.start,
                    stop: builder.stop,
                    title: builder.title,
                    subtitle: builder.subtitle.nonEmpty,
                    description: builder.description.nonEmpty,
                    iconURL: builder.iconURL
                ))
            }
            builder = nil
        default: break
        }
        if activeElement == elementName {
            activeElement = nil
            text = ""
        }
    }
}

enum XMLTVDateParser {
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    static func date(from value: String?) -> Date? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmed.split(whereSeparator: { $0.isWhitespace })
        guard let timestamp = pieces.first else { return nil }
        let bytes = Array(timestamp.utf8)
        guard bytes.count >= 12 else { return nil }

        func integer(at start: Int, count: Int) -> Int? {
            guard start + count <= bytes.count else { return nil }
            var value = 0
            for byte in bytes[start..<(start + count)] {
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }

        guard let year = integer(at: 0, count: 4),
              let month = integer(at: 4, count: 2),
              let day = integer(at: 6, count: 2),
              let hour = integer(at: 8, count: 2),
              let minute = integer(at: 10, count: 2) else { return nil }
        let second = integer(at: 12, count: 2) ?? 0
        let components = DateComponents(
            calendar: utcCalendar, timeZone: utcCalendar.timeZone,
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        )
        guard let utcDate = utcCalendar.date(from: components) else { return nil }

        guard pieces.count > 1 else { return utcDate }
        let zone = Array(pieces[1].utf8)
        guard zone.count >= 5, zone[0] == 43 || zone[0] == 45 else { return utcDate }
        let sign = zone[0] == 45 ? -1 : 1
        func zoneInteger(at start: Int) -> Int? {
            guard start + 2 <= zone.count, zone[start] >= 48, zone[start] <= 57,
                  zone[start + 1] >= 48, zone[start + 1] <= 57 else { return nil }
            return Int(zone[start] - 48) * 10 + Int(zone[start + 1] - 48)
        }
        guard let zoneHours = zoneInteger(at: 1), let zoneMinutes = zoneInteger(at: 3) else { return utcDate }
        let offset = sign * (zoneHours * 3600 + zoneMinutes * 60)
        return utcDate.addingTimeInterval(TimeInterval(-offset))
    }
}

enum XMLTVParser {
    static func parse(_ data: Data, channelIDs: Set<String>) throws -> [GuideProgramme] {
        let xmlData = try GzipDecoder.decompressIfNeeded(data)
        guard xmlData.count <= 256 * 1024 * 1024 else { throw GuideError.fileTooLarge }
        let delegate = XMLTVParserDelegate(channelIDs: channelIDs)
        let parser = XMLParser(data: xmlData)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw GuideError.invalidGuide }
        return delegate.programmes.sorted { $0.start < $1.start }
    }
}

enum GzipDecoder {
    static func decompressIfNeeded(_ data: Data) throws -> Data {
        guard data.count >= 2, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else { return data }
        var stream = z_stream()
        let status = inflateInit2_(&stream, 47, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw GuideError.decompressionFailed }
        defer { inflateEnd(&stream) }

        return try data.withUnsafeBytes { rawBuffer in
            guard let input = rawBuffer.bindMemory(to: Bytef.self).baseAddress else { throw GuideError.decompressionFailed }
            stream.next_in = UnsafeMutablePointer(mutating: input)
            stream.avail_in = uInt(data.count)
            var result = Data()
            let chunkSize = 64 * 1024
            var status: Int32 = Z_OK

            repeat {
                var chunk = [UInt8](repeating: 0, count: chunkSize)
                let produced: Int = chunk.withUnsafeMutableBytes { output in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return chunkSize - Int(stream.avail_out)
                }
                if produced > 0 { result.append(contentsOf: chunk.prefix(produced)) }
                if result.count > 256 * 1024 * 1024 { throw GuideError.fileTooLarge }
                if status != Z_OK && status != Z_STREAM_END { throw GuideError.decompressionFailed }
            } while status != Z_STREAM_END
            return result
        }
    }
}

actor GuideStore {
    private let baseURL: URL
    private let sourcesURL: URL
    private let session: URLSession
    private let urlKeychain = KeychainStore(service: "com.gameday.ios.guide-urls")

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        baseURL = appSupport.appendingPathComponent("GameDay/Guides", isDirectory: true)
        sourcesURL = baseURL.appendingPathComponent("sources.json")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 180
        configuration.waitsForConnectivity = true
        configuration.httpAdditionalHeaders = ["User-Agent": "GameDay/0.8 (iPhone; XMLTV Client)"]
        session = URLSession(configuration: configuration)
    }

    func load(providerID: String) -> ([GuideSource], [GuideCache]) {
        let sources = loadAllSources().filter { $0.providerID == providerID }.sorted { $0.priority < $1.priority }
        let caches = sources.compactMap(loadCache)
        return (sources, caches)
    }

    func importLocal(data: Data, fileName: String, providerID: String, existingStreamIDs: Set<Int>) async throws -> GuideRefreshResult {
        let parsed = try M3UPlaylistParser.parse(data)
        try prepareDirectory()
        let id = UUID()
        let source = GuideSource(
            id: id,
            providerID: providerID,
            name: fileName.replacingOccurrences(of: ".m3u", with: "", options: [.caseInsensitive]),
            kind: .localFile,
            playlistLocation: "",
            epgURL: parsed.epgURL?.absoluteString,
            enabled: true,
            priority: nextPriority(providerID: providerID),
            channelCount: 0,
            matchedChannelCount: 0,
            programmeCount: 0,
            lastPlaylistRefresh: nil,
            lastGuideRefresh: nil,
            errorMessage: nil
        )
        return try await refresh(source, existingStreamIDs: existingStreamIDs, suppliedPlaylist: data)
    }

    func addRemote(urlString: String, name: String, providerID: String, existingStreamIDs: Set<Int>) async throws -> GuideRefreshResult {
        guard let url = validatedRemoteURL(urlString) else { throw GuideError.invalidURL }
        let id = UUID()
        try urlKeychain.saveString(url.absoluteString, account: id.uuidString)
        let source = GuideSource(
            id: id, providerID: providerID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? url.host ?? "Remote guide",
            kind: .remoteURL, playlistLocation: "keychain", epgURL: nil,
            enabled: true, priority: nextPriority(providerID: providerID),
            channelCount: 0, matchedChannelCount: 0, programmeCount: 0,
            lastPlaylistRefresh: nil, lastGuideRefresh: nil, errorMessage: nil
        )
        do {
            return try await refresh(source, existingStreamIDs: existingStreamIDs)
        } catch {
            try? urlKeychain.delete(account: id.uuidString)
            throw error
        }
    }

    func refresh(_ original: GuideSource, existingStreamIDs: Set<Int>, suppliedPlaylist: Data? = nil) async throws -> GuideRefreshResult {
        var source = original
        let oldCache = loadCache(source)
        let parsed: M3UPlaylistParser.Result
        if source.kind == .localFile, suppliedPlaylist == nil {
            guard let oldCache else { throw GuideError.invalidPlaylist }
            parsed = M3UPlaylistParser.Result(
                channels: oldCache.channels,
                epgURL: source.epgURL.flatMap(URL.init(string:))
            )
        } else {
            let playlistData: Data
            if let suppliedPlaylist {
                playlistData = suppliedPlaylist
            } else {
                guard let storedURL = try urlKeychain.loadString(account: source.id.uuidString),
                      let url = validatedRemoteURL(storedURL) else { throw GuideError.invalidURL }
                playlistData = try await download(url, maximumSize: 32 * 1024 * 1024)
            }
            parsed = try M3UPlaylistParser.parse(playlistData)
        }

        source.epgURL = parsed.epgURL?.absoluteString ?? source.epgURL
        source.channelCount = parsed.channels.count
        source.matchedChannelCount = parsed.channels.lazy.filter { existingStreamIDs.contains($0.streamID) }.count
        source.lastPlaylistRefresh = Date()
        source.errorMessage = nil

        var programmes = oldCache?.programmes ?? []
        if let epgString = source.epgURL, let epgURL = validatedRemoteURL(epgString) {
            do {
                let guideData = try await download(epgURL, maximumSize: 96 * 1024 * 1024)
                let ids = Set(parsed.channels.compactMap(\.tvgID).filter { !$0.isEmpty })
                programmes = try XMLTVParser.parse(guideData, channelIDs: ids)
                source.programmeCount = programmes.count
                source.lastGuideRefresh = Date()
            } catch {
                source.errorMessage = "Channel metadata updated, but the XMLTV schedule failed: \(error.localizedDescription)"
                source.programmeCount = programmes.count
            }
        } else {
            source.errorMessage = "Channel metadata imported, but this playlist does not include an XMLTV URL."
            source.programmeCount = programmes.count
        }

        let cache = GuideCache(sourceID: source.id, channels: parsed.channels, programmes: programmes)
        try save(source: source, cache: cache)
        return GuideRefreshResult(source: source, cache: cache)
    }

    func setEnabled(_ enabled: Bool, source: GuideSource) throws -> GuideSource {
        var updated = source
        updated.enabled = enabled
        try saveSource(updated)
        return updated
    }

    func saveOrder(_ orderedSources: [GuideSource]) throws -> [GuideSource] {
        var updated: [GuideSource] = []
        for (index, var source) in orderedSources.enumerated() {
            source.priority = index
            try saveSource(source)
            updated.append(source)
        }
        return updated
    }

    func delete(_ source: GuideSource) throws {
        var sources = loadAllSources()
        sources.removeAll { $0.id == source.id }
        try prepareDirectory()
        try JSONEncoder.guideEncoder.encode(sources).write(to: sourcesURL, options: .atomic)
        if source.kind == .remoteURL { try? urlKeychain.delete(account: source.id.uuidString) }
        try? FileManager.default.removeItem(at: cacheURL(for: source.id))
    }

    private func download(_ url: URL, maximumSize: Int) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw GuideError.downloadFailed }
        guard data.count <= maximumSize else { throw GuideError.fileTooLarge }
        if let mime = response.mimeType?.lowercased(), mime.contains("html"), data.starts(with: Data("<!DOCTYPE html".utf8)) {
            throw GuideError.invalidPlaylist
        }
        return data
    }

    private func validatedRemoteURL(_ string: String) -> URL? {
        guard let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host != nil else { return nil }
        return components.url
    }

    private func save(source: GuideSource, cache: GuideCache) throws {
        try prepareDirectory()
        try saveSource(source)
        try JSONEncoder.guideEncoder.encode(cache).write(to: cacheURL(for: source.id), options: .atomic)
    }

    private func saveSource(_ source: GuideSource) throws {
        try prepareDirectory()
        var sources = loadAllSources()
        if let index = sources.firstIndex(where: { $0.id == source.id }) { sources[index] = source }
        else { sources.append(source) }
        try JSONEncoder.guideEncoder.encode(sources).write(to: sourcesURL, options: .atomic)
    }

    private func loadAllSources() -> [GuideSource] {
        guard let data = try? Data(contentsOf: sourcesURL) else { return [] }
        return (try? JSONDecoder.guideDecoder.decode([GuideSource].self, from: data)) ?? []
    }

    private func loadCache(_ source: GuideSource) -> GuideCache? {
        guard let data = try? Data(contentsOf: cacheURL(for: source.id)) else { return nil }
        return try? JSONDecoder.guideDecoder.decode(GuideCache.self, from: data)
    }

    private func nextPriority(providerID: String) -> Int {
        (loadAllSources().filter { $0.providerID == providerID }.map(\.priority).max() ?? -1) + 1
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    private func cacheURL(for id: UUID) -> URL { baseURL.appendingPathComponent("\(id.uuidString).json") }
}

private extension JSONEncoder {
    static var guideEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var guideDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
