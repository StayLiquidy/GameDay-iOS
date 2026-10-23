import Foundation
import CryptoKit

enum PlaybackEngine: String, CaseIterable, Identifiable {
    case ksPlayer
    case avKit

    var id: String { rawValue }
    var title: String {
        switch self {
        case .ksPlayer: "KSPlayer (Metal)"
        case .avKit: "AVKit (Native)"
        }
    }
}

private struct CachedProviderCatalog: Codable, Sendable {
    let host: String
    let username: String
    let categories: [LiveCategory]
    let channels: [LiveChannel]
}

private struct BuiltGuideIndexes: Sendable {
    let metadataByStreamID: [Int: GuideChannelMetadata]
    let programmesByChannelID: [String: [GuideProgramme]]
    let channelSearchIndex: [Int: String]
}

private actor ProviderCatalogStore {
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        fileURL = base.appendingPathComponent("GameDay", isDirectory: true).appendingPathComponent("provider-catalog.json")
    }

    func load(for credentials: ProviderCredentials) -> CachedProviderCatalog? {
        guard let data = try? Data(contentsOf: fileURL),
              let catalog = try? JSONDecoder().decode(CachedProviderCatalog.self, from: data),
              catalog.host == credentials.host.absoluteString,
              catalog.username == credentials.username else { return nil }
        return catalog
    }

    func save(categories: [LiveCategory], channels: [LiveChannel], credentials: ProviderCredentials) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let catalog = CachedProviderCatalog(
            host: credentials.host.absoluteString,
            username: credentials.username,
            categories: categories,
            channels: channels
        )
        try JSONEncoder().encode(catalog).write(to: fileURL, options: .atomic)
    }

    func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case connection
        case importing
        case ready
    }

    @Published var phase: Phase = .connection
    @Published var channels: [LiveChannel] = []
    @Published var categories: [LiveCategory] = []
    @Published var importMessage = "Checking provider details…"
    @Published var errorMessage: String?
    @Published var events: [SportsEvent] = []
    @Published var schedulesLoading = false
    @Published var scheduleError: String?
    @Published var lastScheduleRefresh: Date?
    @Published var disabledCategoryIDs = Set<String>()
    @Published var smartExcludedStreamIDs = Set<Int>()
    @Published var smartConfig = SmartSelectionConfig.default
    @Published private(set) var enabledChannelCount = 0
    @Published var scoresEnabled = true
    @Published var spoilerFree = false
    @Published var finishedGameVisibility = FinishedGameVisibility.threeHours
    @Published var preferBackup = true
    @Published var playbackEngine = PlaybackEngine.ksPlayer
    @Published var hardwareDecode = true
    @Published var asynchronousDecompression = true
    @Published var automaticDeinterlacing = false
    @Published var adaptiveFrameRate = true
    @Published var automaticPiP = true
    @Published var guideSources: [GuideSource] = []
    @Published var guideRefreshing = false
    @Published var guideStatusMessage: String?
    @Published var guideErrorMessage: String?

    private let keychain = KeychainStore(service: "com.gameday.ios.provider")
    private let catalogStore = ProviderCatalogStore()
    private let defaults = UserDefaults.standard
    private let scheduleClient = SportsScheduleClient()
    private let guideStore = GuideStore()
    private var credentials: ProviderCredentials?
    private var previousSmartExcludedStreamIDs: Set<Int>?
    private var restoreAttempted = false
    private var categoryNames: [String: String] = [:]
    private var channelCounts: [String: Int] = [:]
    private var guideCaches: [UUID: GuideCache] = [:]
    private var guideMetadataByStreamID: [Int: GuideChannelMetadata] = [:]
    private var guideProgrammesByChannelID: [String: [GuideProgramme]] = [:]
    private var channelSearchIndex: [Int: String] = [:]
    private var guideIndexRevision = 0
    private var finalObservedAt: [String: Date] = [:]
    private var liveStatusRefreshing = false

    init() {
        credentials = try? keychain.loadCredentials()
        disabledCategoryIDs = Set(defaults.stringArray(forKey: "disabledCategoryIDs") ?? [])
        smartExcludedStreamIDs = Set(defaults.array(forKey: "smartExcludedStreamIDs") as? [Int] ?? [])
        if !defaults.bool(forKey: "browserScoresDefaultV2") {
            defaults.set(true, forKey: "scoresEnabled")
            defaults.set(false, forKey: "spoilerFree")
            defaults.set(true, forKey: "browserScoresDefaultV2")
        }
        scoresEnabled = defaults.object(forKey: "scoresEnabled") as? Bool ?? true
        spoilerFree = defaults.object(forKey: "spoilerFree") as? Bool ?? false
        finishedGameVisibility = FinishedGameVisibility(rawValue: defaults.integer(forKey: "finishedGameVisibility")) ?? .threeHours
        if defaults.object(forKey: "finishedGameVisibility") == nil {
            finishedGameVisibility = .threeHours
        }
        if let data = defaults.data(forKey: "finalObservedAt"),
           let value = try? JSONDecoder().decode([String: Date].self, from: data) {
            finalObservedAt = value
        }
        preferBackup = defaults.object(forKey: "preferBackup") as? Bool ?? true
        playbackEngine = PlaybackEngine(rawValue: defaults.string(forKey: "playbackEngine") ?? "") ?? .ksPlayer
        hardwareDecode = defaults.object(forKey: "hardwareDecode") as? Bool ?? true
        asynchronousDecompression = defaults.object(forKey: "asynchronousDecompression") as? Bool ?? true
        // Reset the previously saved value because KSPlayer 2.3.4 can crash on
        // live MPEG-TS streams while automatic deinterlacing is enabled.
        automaticDeinterlacing = false
        defaults.set(false, forKey: "automaticDeinterlacing")
        adaptiveFrameRate = defaults.object(forKey: "adaptiveFrameRate") as? Bool ?? true
        automaticPiP = defaults.object(forKey: "automaticPiP") as? Bool ?? true
        if let data = defaults.data(forKey: "smartConfig"), let value = try? JSONDecoder().decode(SmartSelectionConfig.self, from: data) {
            smartConfig = value
        }
        if let data = defaults.data(forKey: "scheduleEvents"), let value = try? JSONDecoder().decode([SportsEvent].self, from: data) {
            events = value
            lastScheduleRefresh = defaults.object(forKey: "lastScheduleRefresh") as? Date
        }
        if defaults.integer(forKey: "scheduleWindowVersion") < 2 {
            lastScheduleRefresh = nil
            defaults.set(2, forKey: "scheduleWindowVersion")
        }
        if credentials != nil {
            phase = .importing
            importMessage = "Restoring your saved provider…"
        }
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--gameday-demo") {
            categories = [
                LiveCategory(id: "1", name: "US: NFL Sunday Ticket"),
                LiveCategory(id: "2", name: "US: College Football"),
                LiveCategory(id: "3", name: "UK: Sky Sports")
            ]
            channels = [
                LiveChannel(streamID: 1, name: "Baltimore Ravens vs Cincinnati Bengals FHD", categoryID: "1"),
                LiveChannel(streamID: 2, name: "Michigan Wolverines vs Texas Longhorns HD", categoryID: "2"),
                LiveChannel(streamID: 3, name: "Sky Sports F1", categoryID: "3")
            ]
            let now = Date()
            events = [
                SportsEvent(id: "demo-nfl", title: "Baltimore Ravens vs Cincinnati Bengals", sport: .nfl, league: "NFL", start: now, status: "Q3 08:42", state: "in", teams: [SportsTeam(name: "Baltimore Ravens", shortName: "Ravens", abbreviation: "BAL"), SportsTeam(name: "Cincinnati Bengals", shortName: "Bengals", abbreviation: "CIN")], broadcasts: ["CBS"], score: "BAL 17 — CIN 14"),
                SportsEvent(id: "demo-ncaaf", title: "Michigan Wolverines vs Texas Longhorns", sport: .ncaaf, league: "College Football", start: now.addingTimeInterval(3600), status: "Scheduled", state: "pre", teams: [SportsTeam(name: "Michigan Wolverines", shortName: "Michigan", abbreviation: "MICH"), SportsTeam(name: "Texas Longhorns", shortName: "Texas", abbreviation: "TEX")], broadcasts: ["FOX"], score: nil)
            ]
            rebuildCatalogIndexes()
            lastScheduleRefresh = now
            phase = .ready
        }
#endif
    }

    var savedHost: String { credentials?.host.absoluteString ?? "" }
    var savedUsername: String { credentials?.username ?? "" }
    var hasSavedProvider: Bool { credentials != nil }
    var guideSummary: String {
        let enabled = guideSources.filter(\.enabled)
        guard !enabled.isEmpty else { return "Not configured" }
        let matched = enabled.reduce(0) { $0 + $1.matchedChannelCount }
        return "\(enabled.count) source\(enabled.count == 1 ? "" : "s") · \(matched.formatted()) matches"
    }

    func restoreProviderIfNeeded() async {
        guard !restoreAttempted, let credentials else { return }
        restoreAttempted = true
        phase = .importing
        importMessage = "Restoring your saved provider…"

        if let catalog = await catalogStore.load(for: credentials), !catalog.channels.isEmpty {
            categories = catalog.categories
            channels = catalog.channels
            rebuildCatalogIndexes()
            phase = .ready
            Task {
                await loadGuideState()
                await refreshGuidesIfNeeded()
            }
            Task { await refreshSchedules() }
            return
        }

        await importProvider(credentials, saveCredentials: false)
    }

    func retrySavedProvider() async {
        guard let credentials else { return }
        await importProvider(credentials, saveCredentials: false)
    }

    func connect(host: String, username: String, password: String) async {
        errorMessage = nil
        do {
            let credentials = try ProviderCredentials(host: host, username: username, password: password)
            await importProvider(credentials, saveCredentials: true)
        } catch {
            errorMessage = ProviderError.userMessage(for: error)
            phase = .connection
        }
    }

    private func importProvider(_ credentials: ProviderCredentials, saveCredentials: Bool) async {
        errorMessage = nil
        phase = .importing
        importMessage = "Validating your subscription…"
        do {
            let client = XtreamProviderClient(credentials: credentials)
            try await client.validateAccount()
            importMessage = "Importing categories…"
            let importedCategories = (try? await client.fetchCategories()) ?? []
            importMessage = "Importing live channels…"
            let importedChannels = try await client.fetchLiveChannels()
            if saveCredentials { try keychain.save(credentials) }
            self.credentials = credentials
            categories = importedCategories.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            channels = importedChannels.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            importMessage = "Saving your lineup…"
            try await catalogStore.save(categories: categories, channels: channels, credentials: credentials)
            rebuildCatalogIndexes()
            phase = .ready
            Task {
                await loadGuideState()
                await refreshGuidesIfNeeded()
            }
            Task { await refreshSchedules(force: true) }
        } catch {
            errorMessage = ProviderError.userMessage(for: error)
            phase = .connection
        }
    }

    func streamURL(for channel: LiveChannel) -> URL? {
        credentials?.liveStreamURL(streamID: channel.streamID, extension: channel.containerExtension)
    }

    func categoryName(for channel: LiveChannel) -> String {
        categoryNames[channel.categoryID ?? ""] ?? "Unsorted"
    }

    func displayName(for channel: LiveChannel) -> String {
        guideMetadataByStreamID[channel.streamID].flatMap { $0.name.nonEmpty } ?? channel.name
    }

    func displayCategory(for channel: LiveChannel) -> String {
        guideMetadataByStreamID[channel.streamID]?.groupTitle.flatMap { $0.nonEmpty } ?? categoryName(for: channel)
    }

    func logoURL(for channel: LiveChannel) -> URL? {
        guideMetadataByStreamID[channel.streamID]?.logoURL.flatMap(URL.init(string:))
    }

    func currentProgramme(for channel: LiveChannel, at date: Date = Date()) -> GuideProgramme? {
        programmes(for: channel).first { $0.start <= date && $0.stop > date }
    }

    func nextProgramme(for channel: LiveChannel, after date: Date = Date()) -> GuideProgramme? {
        programmes(for: channel).first { $0.start > date }
    }

    func channelMatchesSearch(_ channel: LiveChannel, normalizedQuery: String) -> Bool {
        guard !normalizedQuery.isEmpty else { return true }
        if let indexed = channelSearchIndex[channel.id] { return indexed.contains(normalizedQuery) }
        return SportsText.normalize("\(channel.name) \(categoryName(for: channel))").contains(normalizedQuery)
    }

    func channelCount(in categoryID: String) -> Int { channelCounts[categoryID, default: 0] }

    func isChannelEnabled(_ channel: LiveChannel) -> Bool {
        !disabledCategoryIDs.contains(channel.categoryID ?? "") && !smartExcludedStreamIDs.contains(channel.id)
    }

    func setCategory(_ categoryID: String, enabled: Bool) {
        if enabled {
            disabledCategoryIDs.remove(categoryID)
            let categoryStreamIDs = Set(channels.lazy.filter { $0.categoryID == categoryID }.map(\.id))
            smartExcludedStreamIDs.subtract(categoryStreamIDs)
        } else {
            disabledCategoryIDs.insert(categoryID)
        }
        persistLineupPreferences()
        rebuildEnabledChannelCount()
    }

    func setAllCategories(enabled: Bool) {
        disabledCategoryIDs = enabled ? [] : Set(categories.map(\.id))
        persistLineupPreferences()
        rebuildEnabledChannelCount()
    }

    func previewSmartSelection(_ config: SmartSelectionConfig) async -> SmartSelectionResult {
        let channels = channels
        let categories = categories
        return await Task.detached(priority: .userInitiated) {
            SportsClassifier.preview(channels: channels, categories: categories, config: config)
        }.value
    }

    func applySmartSelection(_ result: SmartSelectionResult) {
        previousSmartExcludedStreamIDs = smartExcludedStreamIDs
        smartExcludedStreamIDs = result.excludedIDs
        smartConfig = result.config
        persistLineupPreferences()
        rebuildEnabledChannelCount()
    }

    var canUndoSmartSelection: Bool { previousSmartExcludedStreamIDs != nil }

    func undoSmartSelection() {
        guard let previous = previousSmartExcludedStreamIDs else { return }
        smartExcludedStreamIDs = previous
        previousSmartExcludedStreamIDs = nil
        persistLineupPreferences()
        rebuildEnabledChannelCount()
    }

    func matchedFeeds(for event: SportsEvent) async -> [MatchedFeed] {
        let enabled = channels.filter(isChannelEnabled)
        var names = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
        for channel in enabled where guideMetadataByStreamID[channel.id] != nil {
            names[channel.categoryID ?? ""] = names[channel.categoryID ?? ""] ?? displayCategory(for: channel)
        }
        let supplemental = Dictionary(uniqueKeysWithValues: enabled.map { channel in
            let relevant = programmes(for: channel).filter {
                $0.stop >= event.start.addingTimeInterval(-2 * 3600) && $0.start <= event.start.addingTimeInterval(5 * 3600)
            }
            return (channel.id, ([displayName(for: channel), displayCategory(for: channel)] + relevant.flatMap { [$0.title, $0.subtitle ?? "", $0.description ?? ""] }).joined(separator: " "))
        })
        return await Task.detached(priority: .userInitiated) {
            SportsMatcher.feeds(for: event, channels: enabled, categoryNames: names, supplementalText: supplemental)
        }.value
    }

    func importGuideFile(_ url: URL) async {
        guideErrorMessage = nil
        guideStatusMessage = "Importing playlist…"
        guideRefreshing = true
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
            guideRefreshing = false
        }
        do {
            guard let providerID = currentProviderID else { throw GuideError.invalidPlaylist }
            let data = try Data(contentsOf: url)
            let result = try await guideStore.importLocal(
                data: data,
                fileName: url.lastPathComponent,
                providerID: providerID,
                existingStreamIDs: Set(channels.map(\.id))
            )
            install(result)
            await rebuildGuideIndexes()
            guideStatusMessage = "Imported \(result.source.channelCount.formatted()) curated channels and \(result.source.programmeCount.formatted()) schedule entries."
        } catch {
            guideErrorMessage = error.localizedDescription
            guideStatusMessage = nil
        }
    }

    func addRemoteGuide(url: String, name: String) async -> Bool {
        guideErrorMessage = nil
        guideStatusMessage = "Downloading playlist…"
        guideRefreshing = true
        defer { guideRefreshing = false }
        do {
            guard let providerID = currentProviderID else { throw GuideError.invalidPlaylist }
            let result = try await guideStore.addRemote(
                urlString: url,
                name: name,
                providerID: providerID,
                existingStreamIDs: Set(channels.map(\.id))
            )
            install(result)
            await rebuildGuideIndexes()
            guideStatusMessage = "Added an auto-updating guide with \(result.source.matchedChannelCount.formatted()) provider matches."
            return true
        } catch {
            guideErrorMessage = error.localizedDescription
            guideStatusMessage = nil
            return false
        }
    }

    func refreshGuides(force: Bool = true) async {
        guard !guideRefreshing, !guideSources.isEmpty else { return }
        guideRefreshing = true
        guideErrorMessage = nil
        guideStatusMessage = "Refreshing guide sources…"
        defer { guideRefreshing = false }
        var failures: [String] = []
        for source in guideSources {
            guard source.enabled else { continue }
            if !force, let last = source.lastGuideRefresh ?? source.lastPlaylistRefresh,
               Date().timeIntervalSince(last) < 6 * 3600 { continue }
            do {
                let result = try await guideStore.refresh(source, existingStreamIDs: Set(channels.map(\.id)))
                install(result)
                if let message = result.source.errorMessage { failures.append(message) }
            } catch {
                failures.append("\(source.name): \(error.localizedDescription)")
            }
        }
        await rebuildGuideIndexes()
        if failures.isEmpty {
            guideStatusMessage = "Guide sources are up to date."
        } else {
            guideStatusMessage = "Guide refresh completed with some warnings."
            guideErrorMessage = failures.joined(separator: "\n")
        }
    }

    func refreshGuide(_ source: GuideSource) async {
        guard !guideRefreshing else { return }
        guideRefreshing = true
        guideErrorMessage = nil
        guideStatusMessage = "Refreshing \(source.name)…"
        defer { guideRefreshing = false }
        do {
            let result = try await guideStore.refresh(source, existingStreamIDs: Set(channels.map(\.id)))
            install(result)
            await rebuildGuideIndexes()
            guideStatusMessage = "\(source.name) is up to date."
            guideErrorMessage = result.source.errorMessage
        } catch {
            guideStatusMessage = nil
            guideErrorMessage = error.localizedDescription
        }
    }

    func refreshGuidesIfNeeded() async { await refreshGuides(force: false) }

    func setGuideSource(_ source: GuideSource, enabled: Bool) async {
        do {
            let updated = try await guideStore.setEnabled(enabled, source: source)
            if let index = guideSources.firstIndex(where: { $0.id == source.id }) { guideSources[index] = updated }
            await rebuildGuideIndexes()
        } catch { guideErrorMessage = error.localizedDescription }
    }

    func moveGuideSources(from offsets: IndexSet, to destination: Int) {
        guideSources.move(fromOffsets: offsets, toOffset: destination)
        let reordered = guideSources
        Task {
            do {
                guideSources = try await guideStore.saveOrder(reordered)
                await rebuildGuideIndexes()
            } catch { guideErrorMessage = error.localizedDescription }
        }
    }

    func deleteGuideSources(at offsets: IndexSet) {
        let removed = offsets.map { guideSources[$0] }
        guideSources.remove(atOffsets: offsets)
        for source in removed {
            guideCaches[source.id] = nil
            Task { try? await guideStore.delete(source) }
        }
        guideIndexRevision &+= 1
        Task { await rebuildGuideIndexes() }
    }

    func refreshSchedules(force: Bool = false) async {
        if schedulesLoading { return }
        if !force, let lastScheduleRefresh, Date().timeIntervalSince(lastScheduleRefresh) < 6 * 3600, !events.isEmpty { return }
        schedulesLoading = true
        scheduleError = nil
        let refreshed = await scheduleClient.fetchEvents()
        schedulesLoading = false
        guard !refreshed.isEmpty else {
            if events.isEmpty { scheduleError = "Schedules are temporarily unavailable. Pull to refresh and try again." }
            return
        }
        let now = Date()
        finalObservedAt = FinishedGameFilter.updateObservations(
            previous: events, refreshed: refreshed, existing: finalObservedAt, now: now
        )
        events = refreshed
        lastScheduleRefresh = now
        defaults.set(try? JSONEncoder().encode(refreshed), forKey: "scheduleEvents")
        defaults.set(lastScheduleRefresh, forKey: "lastScheduleRefresh")
        saveFinalObservations()
    }

    func refreshLiveStatuses() async {
        guard !liveStatusRefreshing else { return }
        liveStatusRefreshing = true
        let current = await scheduleClient.fetchCurrentEvents()
        liveStatusRefreshing = false
        guard !current.isEmpty else { return }

        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        var merged = events.map { currentByID[$0.id] ?? $0 }
        let knownIDs = Set(merged.map(\.id))
        merged.append(contentsOf: current.filter { !knownIDs.contains($0.id) })
        merged.sort { $0.start < $1.start }
        finalObservedAt = FinishedGameFilter.updateObservations(
            previous: events, refreshed: merged, existing: finalObservedAt, now: Date()
        )
        events = merged
        defaults.set(try? JSONEncoder().encode(merged), forKey: "scheduleEvents")
        saveFinalObservations()
    }

    func visibleEvents(at date: Date = Date()) -> [SportsEvent] {
        FinishedGameFilter.visible(
            events, observations: finalObservedAt, retention: finishedGameVisibility, now: date
        )
    }

    func setFinishedGameVisibility(_ value: FinishedGameVisibility) {
        finishedGameVisibility = value
        defaults.set(value.rawValue, forKey: "finishedGameVisibility")
    }

    private func saveFinalObservations() {
        defaults.set(try? JSONEncoder().encode(finalObservedAt), forKey: "finalObservedAt")
    }

    func setScoresEnabled(_ enabled: Bool) {
        scoresEnabled = enabled
        defaults.set(enabled, forKey: "scoresEnabled")
        if enabled { Task { await refreshSchedules(force: true) } }
    }

    func setSpoilerFree(_ enabled: Bool) {
        spoilerFree = enabled
        defaults.set(enabled, forKey: "spoilerFree")
    }

    func setPreferBackup(_ enabled: Bool) {
        preferBackup = enabled
        defaults.set(enabled, forKey: "preferBackup")
    }

    func setPlaybackEngine(_ engine: PlaybackEngine) {
        playbackEngine = engine
        defaults.set(engine.rawValue, forKey: "playbackEngine")
    }

    func setHardwareDecode(_ enabled: Bool) {
        hardwareDecode = enabled
        defaults.set(enabled, forKey: "hardwareDecode")
    }

    func setAsynchronousDecompression(_ enabled: Bool) {
        asynchronousDecompression = enabled
        defaults.set(enabled, forKey: "asynchronousDecompression")
    }

    func setAutomaticDeinterlacing(_ enabled: Bool) {
        automaticDeinterlacing = false
        defaults.set(false, forKey: "automaticDeinterlacing")
    }

    func setAdaptiveFrameRate(_ enabled: Bool) {
        adaptiveFrameRate = enabled
        defaults.set(enabled, forKey: "adaptiveFrameRate")
    }

    func setAutomaticPiP(_ enabled: Bool) {
        automaticPiP = enabled
        defaults.set(enabled, forKey: "automaticPiP")
    }

    func disconnect() {
        try? keychain.deleteCredentials()
        Task { await catalogStore.delete() }
        credentials = nil
        channels = []
        categories = []
        events = []
        guideSources = []
        guideCaches = [:]
        guideMetadataByStreamID = [:]
        guideProgrammesByChannelID = [:]
        channelSearchIndex = [:]
        guideIndexRevision &+= 1
        errorMessage = nil
        restoreAttempted = false
        phase = .connection
    }

    private func persistLineupPreferences() {
        defaults.set(Array(disabledCategoryIDs), forKey: "disabledCategoryIDs")
        defaults.set(Array(smartExcludedStreamIDs), forKey: "smartExcludedStreamIDs")
        defaults.set(try? JSONEncoder().encode(smartConfig), forKey: "smartConfig")
    }

    private func rebuildCatalogIndexes() {
        categoryNames = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0.name) })
        channelCounts = channels.reduce(into: [:]) { counts, channel in
            counts[channel.categoryID ?? "", default: 0] += 1
        }
        channelSearchIndex = Dictionary(uniqueKeysWithValues: channels.map { channel in
            (channel.id, SportsText.normalize("\(channel.name) \(categoryNames[channel.categoryID ?? ""] ?? "")"))
        })
        rebuildEnabledChannelCount()
    }

    private func rebuildEnabledChannelCount() {
        enabledChannelCount = channels.lazy.filter { self.isChannelEnabled($0) }.count
    }

    private var currentProviderID: String? {
        guard let credentials else { return nil }
        let value = "\(credentials.host.absoluteString.lowercased())|\(credentials.username.lowercased())"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func loadGuideState() async {
        guard let providerID = currentProviderID else { return }
        let loaded = await guideStore.load(providerID: providerID)
        guideSources = loaded.0
        guideCaches = Dictionary(uniqueKeysWithValues: loaded.1.map { ($0.sourceID, $0) })
        await rebuildGuideIndexes()
    }

    private func install(_ result: GuideRefreshResult) {
        if let index = guideSources.firstIndex(where: { $0.id == result.source.id }) { guideSources[index] = result.source }
        else { guideSources.append(result.source) }
        guideSources.sort { $0.priority < $1.priority }
        guideCaches[result.source.id] = result.cache
    }

    private func programmes(for channel: LiveChannel) -> [GuideProgramme] {
        guard let tvgID = guideMetadataByStreamID[channel.streamID]?.tvgID else { return [] }
        return guideProgrammesByChannelID[tvgID] ?? []
    }

    private func rebuildGuideIndexes() async {
        guideIndexRevision &+= 1
        let revision = guideIndexRevision
        let sources = guideSources
        let caches = guideCaches
        let channels = channels
        let categoryNames = categoryNames

        let built = await Task.detached(priority: .userInitiated) {
            var metadata: [Int: GuideChannelMetadata] = [:]
            var programmes: [String: [GuideProgramme]] = [:]
            for source in sources.sorted(by: { $0.priority < $1.priority }) where source.enabled {
                guard let cache = caches[source.id] else { continue }
                for channel in cache.channels where metadata[channel.streamID] == nil {
                    metadata[channel.streamID] = channel
                }
                for programme in cache.programmes {
                    programmes[programme.channelID, default: []].append(programme)
                }
            }
            for key in Array(programmes.keys) {
                var seen = Set<String>()
                programmes[key] = programmes[key]?
                    .filter { seen.insert($0.id).inserted }
                    .sorted { $0.start < $1.start }
            }

            let now = Date()
            var searchIndex: [Int: String] = [:]
            searchIndex.reserveCapacity(channels.count)
            for channel in channels {
                let guide = metadata[channel.id]
                let schedule = guide?.tvgID.flatMap { programmes[$0] } ?? []
                let nearby = schedule.lazy.filter { $0.stop >= now }.prefix(3)
                let parts = [channel.name, categoryNames[channel.categoryID ?? ""] ?? "", guide?.name ?? "", guide?.groupTitle ?? ""]
                    + nearby.flatMap { [$0.title, $0.subtitle ?? ""] }
                searchIndex[channel.id] = SportsText.normalize(parts.joined(separator: " "))
            }
            return BuiltGuideIndexes(
                metadataByStreamID: metadata,
                programmesByChannelID: programmes,
                channelSearchIndex: searchIndex
            )
        }.value

        guard revision == guideIndexRevision else { return }
        guideMetadataByStreamID = built.metadataByStreamID
        guideProgrammesByChannelID = built.programmesByChannelID
        channelSearchIndex = built.channelSearchIndex
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
