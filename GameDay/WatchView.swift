import AVKit
@preconcurrency import KSPlayer
import SwiftUI

private enum PlayerSurfaceState: Equatable {
    case loading
    case playing
    case paused
    case failed
}

private struct KSPlayerSurface: UIViewRepresentable {
    let url: URL
    let hardwareDecode: Bool
    let asynchronousDecompression: Bool
    let adaptiveFrameRate: Bool
    let nativeFallback: Bool
    let fillVideo: Bool
    let automaticPiP: Bool
    let pipCommand: Int
    @Binding var state: PlayerSurfaceState
    @Binding var controlsVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(state: $state, controlsVisible: $controlsVisible)
    }

    func makeUIView(context: Context) -> IOSVideoPlayerView {
        let playerView = IOSVideoPlayerView()
        // GameDay owns the centered loading overlay and PiP control.
        playerView.loadingIndector.alpha = 0
        playerView.toolBar.removeArrangedSubview(playerView.toolBar.pipButton)
        playerView.toolBar.pipButton.removeFromSuperview()
        playerView.toolBar.removeArrangedSubview(playerView.landscapeButton)
        playerView.landscapeButton.removeFromSuperview()
        playerView.navigationBar.removeArrangedSubview(playerView.backButton)
        playerView.backButton.removeFromSuperview()
        playerView.delegate = context.coordinator
        context.coordinator.playerView = playerView
        context.coordinator.currentURL = url
        context.coordinator.isFillingVideo = fillVideo
        context.coordinator.lastPiPCommand = pipCommand
        configure(playerView)
        applyContentMode(to: playerView)
        return playerView
    }

    func updateUIView(_ playerView: IOSVideoPlayerView, context: Context) {
        if context.coordinator.currentURL != url {
            context.coordinator.currentURL = url
            state = .loading
            playerView.resetPlayer()
            playerView.playerLayer = nil
            configure(playerView)
        }
        if context.coordinator.isFillingVideo != fillVideo {
            context.coordinator.isFillingVideo = fillVideo
            applyContentMode(to: playerView)
        }
        if context.coordinator.lastPiPCommand != pipCommand {
            context.coordinator.lastPiPCommand = pipCommand
            playerView.playerLayer?.isPipActive = true
        }
    }

    private func configure(_ playerView: IOSVideoPlayerView) {
        KSOptions.firstPlayerType = KSMEPlayer.self
        KSOptions.secondPlayerType = nativeFallback ? KSAVPlayer.self : nil
        KSOptions.preferredFrame = adaptiveFrameRate

        let options = KSOptions()
        options.hardwareDecode = hardwareDecode
        options.asynchronousDecompression = asynchronousDecompression
        // KSPlayer 2.3.4 can crash on some live MPEG-TS feeds when this is enabled.
        // Keep it off until the upstream implementation is safe for those streams.
        options.autoDeInterlace = false
        options.isSecondOpen = true
        options.preferredForwardBufferDuration = 2
        options.canStartPictureInPictureAutomaticallyFromInline = automaticPiP

        playerView.set(url: url, options: options)
        playerView.play()
    }

    private func applyContentMode(to playerView: IOSVideoPlayerView) {
        playerView.playerLayer?.player.contentMode = fillVideo ? .scaleAspectFill : .scaleAspectFit
        playerView.clipsToBounds = true
    }

    static func dismantleUIView(_ playerView: IOSVideoPlayerView, coordinator: Coordinator) {
        playerView.pause()
        playerView.delegate = nil
        playerView.playerLayer = nil
        coordinator.playerView = nil
        coordinator.currentURL = nil
    }

    final class Coordinator: NSObject, PlayerControllerDelegate {
        weak var playerView: IOSVideoPlayerView?
        var currentURL: URL?
        var isFillingVideo = false
        var lastPiPCommand = 0
        private var state: Binding<PlayerSurfaceState>
        private var controlsVisible: Binding<Bool>

        init(state: Binding<PlayerSurfaceState>, controlsVisible: Binding<Bool>) {
            self.state = state
            self.controlsVisible = controlsVisible
        }

        func playerController(state playerState: KSPlayerState) {
            playerView?.playerLayer?.player.contentMode = isFillingVideo ? .scaleAspectFill : .scaleAspectFit
            switch playerState {
            case .bufferFinished: state.wrappedValue = .playing
            case .paused: state.wrappedValue = .paused
            case .error: state.wrappedValue = .failed
            default: state.wrappedValue = .loading
            }
        }

        func playerController(currentTime: TimeInterval, totalTime: TimeInterval) {}
        func playerController(finish error: Error?) {
            if error != nil { state.wrappedValue = .failed }
        }
        func playerController(maskShow: Bool) {
            DispatchQueue.main.async { [controlsVisible] in
                controlsVisible.wrappedValue = maskShow
            }
        }
        func playerController(action: PlayerButtonType) {}
        func playerController(bufferedCount: Int, consumeTime: TimeInterval) {}
        func playerController(seek: TimeInterval) {}
    }
}

private struct GameDayPlayerSurface: View {
    @EnvironmentObject private var model: AppModel
    let url: URL
    let engine: PlaybackEngine
    let isFullscreen: Bool
    let toggleFullscreen: () -> Void
    @State private var nativePlayer: AVPlayer?
    @State private var state = PlayerSurfaceState.loading
    @State private var pipCommand = 0
    @State private var controlsVisible = true
    @State private var fillVideo = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
            if engine == .ksPlayer {
                KSPlayerSurface(
                    url: url,
                    hardwareDecode: model.hardwareDecode,
                    asynchronousDecompression: model.asynchronousDecompression,
                    adaptiveFrameRate: model.adaptiveFrameRate,
                    nativeFallback: model.preferBackup,
                    fillVideo: fillVideo,
                    automaticPiP: model.automaticPiP,
                    pipCommand: pipCommand,
                    state: $state,
                    controlsVisible: $controlsVisible
                )
            } else if let nativePlayer {
                VideoPlayer(player: nativePlayer)
            }

            if state == .loading {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(engine == .ksPlayer ? "Opening with KSPlayer…" : "Opening with AVKit…")
                        .font(.caption).foregroundStyle(.white.opacity(0.8))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .allowsHitTesting(false)
            } else if state == .failed {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2).foregroundStyle(GameDayTheme.lightPurple)
                    Text("This feed could not be played")
                        .font(.subheadline.bold()).foregroundStyle(.white)
                    Text(engine == .ksPlayer && !model.preferBackup ? "Try enabling AVKit fallback in Playback settings." : "Try another provider feed.")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            HStack(spacing: 10) {
                if engine == .ksPlayer, isFullscreen {
                    Button { fillVideo.toggle() } label: {
                        Image(systemName: fillVideo ? "rectangle.inset.filled" : "rectangle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(.black.opacity(0.62), in: Circle())
                    }
                    .accessibilityLabel(fillVideo ? "Fit video to screen" : "Fill screen with video")
                }
                if engine == .ksPlayer {
                    Button { pipCommand += 1 } label: {
                        Image(systemName: "pip.enter")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(.black.opacity(0.62), in: Circle())
                    }
                    .accessibilityLabel("Start Picture in Picture")
                }
                Button(action: toggleFullscreen) {
                    Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.black.opacity(0.62), in: Circle())
                }
                .accessibilityLabel(isFullscreen ? "Exit full screen" : "Enter full screen")
            }
            .buttonStyle(.plain)
            .padding(12)
            .zIndex(10)
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
            .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        }
        .onAppear {
            guard engine == .avKit else { return }
            let player = AVPlayer(url: url)
            nativePlayer = player
            player.play()
            state = .playing
        }
        .onDisappear {
            nativePlayer?.pause()
            nativePlayer?.replaceCurrentItem(with: nil)
            nativePlayer = nil
        }
    }
}

struct WatchView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let channel: LiveChannel
    @State private var activeURL: URL?
    @State private var activeEngine: PlaybackEngine?
    @State private var status = "Ready to play"

    private var fullscreen: Bool { activeURL != nil && verticalSizeClass == .compact }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let activeURL, let activeEngine {
                        GameDayPlayerSurface(
                            url: activeURL,
                            engine: activeEngine,
                            isFullscreen: fullscreen,
                            toggleFullscreen: { AppOrientation.toggleFullscreen(isCurrentlyLandscape: fullscreen) }
                        )
                        .id("\(activeEngine.rawValue)-\(activeURL.absoluteString)")
                    } else {
                        VStack(spacing: 9) {
                            Image(systemName: "play.rectangle.fill").font(.system(size: 38)).foregroundStyle(GameDayTheme.lightPurple)
                            Text(status).font(.subheadline.bold())
                            Text("Tap Play to open this provider feed").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: geometry.size.width, height: fullscreen ? geometry.size.height : geometry.size.width * 9 / 16)

                if !fullscreen {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(model.displayName(for: channel)).font(.title3.bold())
                        if let programme = model.currentProgramme(for: channel) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("NOW · \(programme.title)").font(.subheadline.bold()).foregroundStyle(GameDayTheme.lightPurple)
                                if let description = programme.description {
                                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                }
                            }
                        }
                        if let next = model.nextProgramme(for: channel) {
                            Text("NEXT · \(next.start.formatted(date: .omitted, time: .shortened)) · \(next.title)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        HStack {
                            VStack(alignment: .leading) {
                                Text("PROVIDER FEED").font(.caption2.bold()).tracking(1.4).foregroundStyle(GameDayTheme.lightPurple)
                                Text(channel.containerExtension?.uppercased() ?? "LIVE").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(activeURL == nil ? "Play" : "Stop") { activeURL == nil ? startPlayback() : stopPlayback() }
                                .buttonStyle(.borderedProminent).tint(GameDayTheme.purple)
                        }
                        Text(activeEngine?.title ?? "Default player: \(model.playbackEngine.title)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(18)
                }
            }
        }
        .toolbar(fullscreen ? .hidden : .visible, for: .navigationBar)
        .toolbar(fullscreen ? .hidden : .visible, for: .tabBar)
        .ignoresSafeArea(.container, edges: fullscreen ? .all : [])
        .background(GameDayTheme.background)
        .navigationTitle("Watch")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: activeURL) { _, value in AppOrientation.setPlayerActive(value != nil) }
        .onDisappear {
            AppOrientation.setPlayerActive(false)
            stopPlayback()
        }
    }

    private func startPlayback() {
        guard let url = model.streamURL(for: channel) else { status = "This feed URL is unavailable"; return }
        activeEngine = model.playbackEngine
        activeURL = url
    }

    private func stopPlayback() {
        AppOrientation.setPlayerActive(false)
        activeURL = nil
        activeEngine = nil
    }
}

struct EventWatchView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    let event: SportsEvent
    @State private var feeds: [MatchedFeed] = []
    @State private var selectedFeed: MatchedFeed?
    @State private var activeURL: URL?
    @State private var activeEngine: PlaybackEngine?
    @State private var loadingFeeds = true

    private var fullscreen: Bool { activeURL != nil && verticalSizeClass == .compact }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let activeURL, let activeEngine {
                        GameDayPlayerSurface(
                            url: activeURL,
                            engine: activeEngine,
                            isFullscreen: fullscreen,
                            toggleFullscreen: { AppOrientation.toggleFullscreen(isCurrentlyLandscape: fullscreen) }
                        )
                        .id("\(activeEngine.rawValue)-\(activeURL.absoluteString)")
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "play.rectangle.fill").font(.system(size: 36)).foregroundStyle(GameDayTheme.lightPurple)
                            Text(selectedFeed == nil ? "Select a feed below" : "Ready to play").font(.subheadline.bold())
                        }
                    }
                }
                .frame(width: geometry.size.width, height: fullscreen ? geometry.size.height : geometry.size.width * 9 / 16)

                if !fullscreen {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(event.title).font(.headline).lineLimit(2)
                        HStack {
                            Text(event.timeLabel).font(.caption).foregroundStyle(event.isLive ? .red : .secondary)
                            Spacer()
                            if model.scoresEnabled, let score = event.score { Text(score).font(.caption.bold()).foregroundStyle(GameDayTheme.lightPurple) }
                        }
                        if let selectedFeed {
                            HStack {
                                Text(model.displayName(for: selectedFeed.channel)).font(.caption).lineLimit(1)
                                Spacer()
                                Button(activeURL == nil ? "Play" : "Stop") { activeURL == nil ? play(selectedFeed) : stop() }
                                    .buttonStyle(.borderedProminent).tint(GameDayTheme.purple)
                                Button("Next") { playNext() }.buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(14)

                    List {
                        Section("Available Feeds · \(feeds.count)") {
                            if loadingFeeds {
                                HStack { ProgressView(); Text("Matching provider feeds…").foregroundStyle(.secondary) }
                            } else if feeds.isEmpty {
                                ContentUnavailableView("No confirmed feeds", systemImage: "tv.slash", description: Text("A broadcaster name alone is not treated as proof for this game. Try channel search instead."))
                            } else {
                                ForEach(feeds) { feed in
                                    Button { select(feed) } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: selectedFeed?.id == feed.id ? "play.circle.fill" : "play.circle")
                                                .foregroundStyle(GameDayTheme.lightPurple)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(model.displayName(for: feed.channel)).font(.subheadline.bold()).foregroundStyle(.primary)
                                                if let programme = model.currentProgramme(for: feed.channel) {
                                                    Text("NOW · \(programme.title)").font(.caption).foregroundStyle(GameDayTheme.lightPurple).lineLimit(1)
                                                }
                                                Text(feed.reason).font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Text(feed.advertisedQuality).font(.caption2.bold()).foregroundStyle(GameDayTheme.lightPurple)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
        .toolbar(fullscreen ? .hidden : .visible, for: .navigationBar)
        .toolbar(fullscreen ? .hidden : .visible, for: .tabBar)
        .ignoresSafeArea(.container, edges: fullscreen ? .all : [])
        .background(GameDayTheme.background)
        .navigationTitle(event.league)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            feeds = await model.matchedFeeds(for: event)
            selectedFeed = feeds.first
            loadingFeeds = false
        }
        .onChange(of: activeURL) { _, value in AppOrientation.setPlayerActive(value != nil) }
        .onDisappear {
            AppOrientation.setPlayerActive(false)
            stop()
        }
    }

    private func select(_ feed: MatchedFeed) {
        stop()
        selectedFeed = feed
        play(feed)
    }

    private func play(_ feed: MatchedFeed) {
        stop()
        guard let url = model.streamURL(for: feed.channel) else { return }
        activeEngine = model.playbackEngine
        activeURL = url
    }

    private func playNext() {
        guard !feeds.isEmpty else { return }
        let current = selectedFeed.flatMap { selected in feeds.firstIndex(where: { $0.id == selected.id }) } ?? -1
        let next = feeds[(current + 1) % feeds.count]
        select(next)
    }

    private func stop() {
        AppOrientation.setPlayerActive(false)
        activeURL = nil
        activeEngine = nil
    }
}
