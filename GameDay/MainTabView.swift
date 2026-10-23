import SwiftUI
import UniformTypeIdentifiers

struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack { FindGamesView() }
                .tabItem { Label("Find a Game", systemImage: "sportscourt") }
            NavigationStack { CategoriesView() }
                .tabItem { Label("Categories", systemImage: "square.grid.2x2") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .toolbarBackground(GameDayTheme.surface, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}

struct FindGamesView: View {
    private enum BrowserMode: String, CaseIterable, Identifiable {
        case games = "Games"
        case channels = "Channels"
        var id: Self { self }
    }

    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var sport: Sport = .all
    @State private var browserMode: BrowserMode = .games
    @State private var displayClock = Date()

    private var filteredEvents: [SportsEvent] {
        let query = SportsText.normalize(search)
        return model.visibleEvents(at: displayClock).filter { event in
            (sport == .all || event.sport == sport) &&
            (query.isEmpty || SportsText.normalize("\(event.title) \(event.league)").contains(query))
        }
    }

    private var filteredChannels: [LiveChannel] {
        let query = SportsText.normalize(search)
        return Array(model.channels.lazy.filter { channel in
            guard model.isChannelEnabled(channel) else { return false }
            return model.channelMatchesSearch(channel, normalizedQuery: query)
        }.prefix(300))
    }

    var body: some View {
        List {
            Section {
                Picker("Browse", selection: $browserMode) {
                    ForEach(BrowserMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented)
            }

            if browserMode == .games {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Sport.allCases) { item in
                                Button(item.rawValue) { sport = item }
                                    .buttonStyle(.borderedProminent)
                                    .tint(sport == item ? GameDayTheme.purple : GameDayTheme.surfaceRaised)
                            }
                        }.padding(.vertical, 2)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 0))
                }
            }

            if browserMode == .games {
                Section("Games") {
                    if model.schedulesLoading && model.events.isEmpty {
                        HStack { ProgressView(); Text("Updating sports schedules…").foregroundStyle(.secondary) }
                    } else if let error = model.scheduleError, model.events.isEmpty {
                        ContentUnavailableView {
                            Label("Schedules unavailable", systemImage: "calendar.badge.exclamationmark")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Try Again") { Task { await model.refreshSchedules(force: true) } }
                                .buttonStyle(.borderedProminent)
                        }
                    } else if filteredEvents.isEmpty {
                        ContentUnavailableView("No matching games", systemImage: "sportscourt", description: Text("Try another sport or search."))
                    } else {
                        ForEach(filteredEvents) { event in NavigationLink(value: event) { GameRow(event: event) } }
                    }
                }
            } else {
                Section("Channels") {
                    if filteredChannels.isEmpty {
                        Text("No enabled channels match these filters.").foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredChannels) { channel in
                            NavigationLink(value: channel) { ChannelRow(channel: channel) }
                        }
                        if filteredChannels.count == 300 {
                            Text("Showing the first 300 matches. Search to narrow the catalog.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Find a Game")
        .searchable(text: $search, prompt: "Teams, leagues, channels")
        .refreshable { await model.refreshSchedules(force: true) }
        .navigationDestination(for: SportsEvent.self) { EventWatchView(event: $0) }
        .navigationDestination(for: LiveChannel.self) { WatchView(channel: $0) }
        .task {
            await model.refreshSchedules()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { break }
                await model.refreshLiveStatuses()
                displayClock = Date()
            }
        }
        .onChange(of: browserMode) { _, mode in
            if mode == .channels { sport = .all }
        }
    }
}

private struct GameRow: View {
    @EnvironmentObject private var model: AppModel
    let event: SportsEvent
    var body: some View {
        HStack(spacing: 12) {
            Text(event.sport.rawValue).font(.caption2.bold()).foregroundStyle(GameDayTheme.lightPurple)
                .frame(width: 54).padding(.vertical, 7).background(GameDayTheme.purple.opacity(0.18)).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title).font(.subheadline.bold()).lineLimit(2)
                Text(event.timeLabel).font(.caption).foregroundStyle(event.isLive ? .red : .secondary)
                if model.scoresEnabled, !model.spoilerFree, let score = event.score {
                    Text(score).font(.caption.bold()).foregroundStyle(GameDayTheme.lightPurple)
                }
            }
        }.padding(.vertical, 4)
    }
}

private struct ChannelRow: View {
    @EnvironmentObject private var model: AppModel
    let channel: LiveChannel
    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: model.logoURL(for: channel)) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit().padding(4)
                } else {
                    RoundedRectangle(cornerRadius: 10).fill(GameDayTheme.purple.opacity(0.22))
                        .overlay(Image(systemName: "play.fill").foregroundStyle(GameDayTheme.lightPurple))
                }
            }
            .frame(width: 46, height: 46)
            .background(GameDayTheme.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(model.displayName(for: channel)).font(.subheadline.bold()).lineLimit(2)
                if let programme = model.currentProgramme(for: channel) {
                    Text("NOW · \(programme.title)").font(.caption).foregroundStyle(GameDayTheme.lightPurple).lineLimit(1)
                }
                Text(model.displayCategory(for: channel)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }.padding(.vertical, 3)
    }
}

struct CategoriesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var showingSmartDisable = false

    private var filtered: [LiveCategory] {
        search.isEmpty ? model.categories : model.categories.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            Section {
                Button { showingSmartDisable = true } label: { Label("Smart Disable", systemImage: "wand.and.stars") }
                HStack {
                    Button("Enable all") { model.setAllCategories(enabled: true) }.buttonStyle(.borderless)
                    Spacer()
                    Button("Disable all") { model.setAllCategories(enabled: false) }.buttonStyle(.borderless)
                }
                if model.canUndoSmartSelection { Button("Undo last Smart Disable") { model.undoSmartSelection() } }
                Text("\(model.categories.count - model.disabledCategoryIDs.count) of \(model.categories.count) categories enabled · \(model.enabledChannelCount.formatted()) channels included")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Provider categories") {
                ForEach(filtered) { category in
                    Toggle(isOn: Binding(
                        get: { !model.disabledCategoryIDs.contains(category.id) },
                        set: { model.setCategory(category.id, enabled: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(category.name).font(.subheadline.bold())
                            Text("\(model.channelCount(in: category.id)) channels").font(.caption).foregroundStyle(.secondary)
                        }
                    }.tint(GameDayTheme.purple)
                }
            }
        }
        .navigationTitle("Categories")
        .searchable(text: $search, prompt: "US, NFL, DAZN…")
        .sheet(isPresented: $showingSmartDisable) { SmartDisableView() }
    }
}

struct SmartDisableView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var config = SmartSelectionConfig.default
    @State private var preview: SmartSelectionResult?
    @State private var isWorking = false
    private let countries = ["US", "UK", "CA", "AU", "IT", "ES", "FR", "DE", "BR", "MX"]

    var body: some View {
        NavigationStack {
            List {
                Section("Countries") {
                    ForEach(countries, id: \.self) { country in Toggle(country, isOn: membershipBinding(country, in: $config.countries)) }
                    Toggle("Keep sports channels without a country label", isOn: $config.keepUnlabeled)
                }
                Section("Sports") {
                    ForEach(Sport.allCases.filter { $0 != .all }) { item in Toggle(item.rawValue, isOn: membershipBinding(item, in: $config.sports)) }
                }
                Section {
                    Button {
                        Task {
                            isWorking = true
                            preview = await model.previewSmartSelection(config)
                            isWorking = false
                        }
                    } label: { if isWorking { ProgressView() } else { Label("Preview selection", systemImage: "eye") } }
                }
                if let preview {
                    Section("Preview") {
                        Text("Keep \(preview.keptCount.formatted()) of \(model.channels.count.formatted()) channels across \(preview.rows.filter { $0.kept > 0 }.count) categories.")
                        ForEach(preview.rows.prefix(100)) { row in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.name).font(.subheadline.bold())
                                Text("\(row.kept) of \(row.total) kept · \(row.reason)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Smart Disable")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { if let preview { model.applySmartSelection(preview); dismiss() } }.disabled(preview == nil)
                }
            }
            .onAppear { config = model.smartConfig }
            .onChange(of: config) { _, _ in preview = nil }
        }
    }

    private func membershipBinding<T: Hashable>(_ value: T, in set: Binding<Set<T>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(value) }, set: { enabled in
            if enabled { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) }
        })
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "Version \(version) · Build \(build)"
    }

    var body: some View {
        List {
            Section {
                NavigationLink { ConnectionsSettingsView() } label: { SettingsRow(icon: "link", title: "Connections", detail: "Connected · \(model.channels.count.formatted()) channels") }
                NavigationLink { ScoresSettingsView() } label: { SettingsRow(icon: "sportscourt", title: "Scores", detail: model.scoresEnabled ? "On" : "Off") }
                NavigationLink { PlaybackSettingsView() } label: { SettingsRow(icon: "play.rectangle", title: "Playback", detail: model.playbackEngine.title) }
                NavigationLink { TVGuideSettingsView() } label: { SettingsRow(icon: "calendar", title: "TV Guide", detail: model.guideSummary) }
            }
            Section {
                Text("GameDay · Provider credentials are stored only in this iPhone's Keychain and are never sent to score sources.")
                Text(versionLabel)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }.navigationTitle("Settings")
    }
}

private struct SettingsRow: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        Label { HStack { Text(title); Spacer(); Text(detail).font(.caption).foregroundStyle(.secondary) } }
        icon: { Image(systemName: icon).foregroundStyle(GameDayTheme.lightPurple) }
    }
}

struct ConnectionsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List {
            Section("Provider") {
                LabeledContent("Host", value: model.savedHost)
                LabeledContent("Channels", value: model.channels.count.formatted())
                LabeledContent("Categories", value: model.categories.count.formatted())
            }
            Section { Button("Disconnect Provider", role: .destructive) { model.disconnect() } }
        }.navigationTitle("Connections")
    }
}

struct ScoresSettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List {
            Section {
                Toggle("Show live scores", isOn: Binding(get: { model.scoresEnabled }, set: { model.setScoresEnabled($0) }))
                Toggle("Hide scores in game browser", isOn: Binding(get: { model.spoilerFree }, set: { model.setSpoilerFree($0) }))
            }
            Section("Finished games") {
                Picker("Keep after Final", selection: Binding(
                    get: { model.finishedGameVisibility },
                    set: { model.setFinishedGameVisibility($0) }
                )) {
                    ForEach(FinishedGameVisibility.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                Text("The timer starts when ESPN changes a game from live to Final. Games that are already Final when first received are hidden immediately instead of estimating when they ended.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section { Text("Scores come from public sports schedule sources. They never receive provider credentials and may be delayed or unavailable.").font(.caption).foregroundStyle(.secondary) }
        }.navigationTitle("Scores")
    }
}

struct PlaybackSettingsView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List {
            Section("Engine") {
                Picker("Player", selection: Binding(get: { model.playbackEngine }, set: { model.setPlaybackEngine($0) })) {
                    ForEach(PlaybackEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                Toggle("Fall back to AVKit on failure", isOn: Binding(get: { model.preferBackup }, set: { model.setPreferBackup($0) }))
                    .disabled(model.playbackEngine == .avKit)
            }
            Section("KSPlayer decoding") {
                Toggle("Hardware decoding", isOn: Binding(get: { model.hardwareDecode }, set: { model.setHardwareDecode($0) }))
                Toggle("Asynchronous decompression", isOn: Binding(get: { model.asynchronousDecompression }, set: { model.setAsynchronousDecompression($0) }))
                Toggle("Automatic deinterlacing", isOn: .constant(false))
                    .disabled(true)
                Toggle("Adaptive frame rate", isOn: Binding(get: { model.adaptiveFrameRate }, set: { model.setAdaptiveFrameRate($0) }))
                Toggle("Automatic Picture in Picture", isOn: Binding(get: { model.automaticPiP }, set: { model.setAutomaticPiP($0) }))
            }
            .disabled(model.playbackEngine == .avKit)
            Section {
                Text("Changes apply the next time a feed starts. Automatic deinterlacing is temporarily disabled because it can crash KSPlayer 2.3.4 on some live feeds. Automatic Picture in Picture also depends on the iPhone's Start PiP Automatically setting. AVKit remains available as a manual engine and an optional automatic fallback.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Playback")
    }
}

struct TVGuideSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingFileImporter = false
    @State private var showingURLImporter = false

    var body: some View {
        List {
            Section("Sports schedule") {
                LabeledContent("Last refresh", value: model.lastScheduleRefresh?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                Button { Task { await model.refreshSchedules(force: true) } } label: {
                    if model.schedulesLoading { ProgressView() } else { Label("Refresh schedules", systemImage: "arrow.clockwise") }
                }
            }
            Section("Guide sources") {
                Button { showingFileImporter = true } label: { Label("Import M3U from Files", systemImage: "doc.badge.plus") }
                Button { showingURLImporter = true } label: { Label("Add auto-updating M3U URL", systemImage: "link.badge.plus") }
                Button { Task { await model.refreshGuides() } } label: {
                    if model.guideRefreshing { HStack { ProgressView(); Text("Refreshing guides…") } }
                    else { Label("Refresh all guides", systemImage: "arrow.clockwise") }
                }
                .disabled(model.guideRefreshing || model.guideSources.isEmpty)
            }

            if !model.guideSources.isEmpty {
                Section("Assigned to this provider") {
                    ForEach(model.guideSources) { source in
                        GuideSourceRow(source: source)
                    }
                    .onDelete(perform: model.deleteGuideSources)
                    .onMove(perform: model.moveGuideSources)
                }
            }

            if let status = model.guideStatusMessage {
                Section { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            if let error = model.guideErrorMessage {
                Section("Guide warnings") { Text(error).font(.caption).foregroundStyle(.orange) }
            }

            Section("How matching works") {
                Text("GameDay uses exact stream IDs to apply curated channel names, logos, groups, and EPG IDs without saving playlist stream URLs. Exact EPG IDs are used for schedules; higher guide sources take priority when sources overlap.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Local files keep provider credentials entirely on-device. URL sources refresh both channel mappings and XMLTV schedules automatically when the app opens and at least six hours have passed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("TV Guide")
        .toolbar { EditButton().disabled(model.guideSources.count < 2) }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [UTType(filenameExtension: "m3u") ?? .plainText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await model.importGuideFile(url) }
            } else if case .failure(let error) = result {
                model.guideErrorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $showingURLImporter) { GuideURLImportView() }
    }
}

private struct GuideSourceRow: View {
    @EnvironmentObject private var model: AppModel
    let source: GuideSource

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle(isOn: Binding(
                get: { source.enabled },
                set: { enabled in Task { await model.setGuideSource(source, enabled: enabled) } }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.name).font(.subheadline.bold())
                    Text(source.kind.title).font(.caption).foregroundStyle(.secondary)
                }
            }
            .tint(GameDayTheme.purple)

            HStack(spacing: 12) {
                Label("\(source.matchedChannelCount.formatted()) matched", systemImage: "checkmark.circle")
                Label("\(source.programmeCount.formatted()) listings", systemImage: "calendar")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if let date = source.lastGuideRefresh ?? source.lastPlaylistRefresh {
                Text("Updated \(date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let error = source.errorMessage {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }

            Button("Refresh this source") {
                Task { await model.refreshGuide(source) }
            }
            .font(.caption)
            .disabled(model.guideRefreshing)
        }
        .padding(.vertical, 4)
    }
}

private struct GuideURLImportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Auto-updating playlist") {
                    TextField("Name, such as Dream4K EPGenius", text: $name)
                    TextField("Direct M3U URL", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section {
                    Text("Paste the playlist URL supplied by EPGenius after its Google Drive setup, or another direct M3U URL. GameDay discovers the linked XMLTV guide automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = model.guideErrorMessage {
                    Section { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add Guide URL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task { if await model.addRemoteGuide(url: url, name: name) { dismiss() } }
                    }
                    .disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.guideRefreshing)
                }
            }
        }
    }
}
