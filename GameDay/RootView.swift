import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            GameDayTheme.background.ignoresSafeArea()
            switch model.phase {
            case .connection: ConnectionView()
            case .importing: ImportingView()
            case .ready: MainTabView()
            }
        }
        .tint(GameDayTheme.lightPurple)
        .task { await model.restoreProviderIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.phase == .ready {
                Task { await model.refreshGuidesIfNeeded() }
            }
        }
    }
}

struct ConnectionView: View {
    @EnvironmentObject private var model: AppModel
    @State private var host = ""
    @State private var username = ""
    @State private var password = ""
    @State private var showForm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 40)
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(LinearGradient(colors: [GameDayTheme.lightPurple, GameDayTheme.purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 84, height: 84)
                    Image(systemName: "play.rectangle.fill").font(.system(size: 37)).foregroundStyle(.white)
                }
                Text("GAMEDAY").font(.caption.bold()).tracking(2).foregroundStyle(.secondary)
                Text(showForm ? "Connect Provider" : "Your games.\nYour feeds.")
                    .font(.system(size: showForm ? 30 : 43, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                Text(showForm ? "Enter the Xtream details supplied by your provider." : "Connect your TV provider to import live channels and choose the feed that works best.")
                    .foregroundStyle(GameDayTheme.muted).multilineTextAlignment(.center)

                if showForm {
                    VStack(spacing: 14) {
                        field("Host URL", text: $host, contentType: .URL, secure: false)
                        field("Username", text: $username, contentType: .username, secure: false)
                        field("Password", text: $password, contentType: .password, secure: true)
                        if let error = model.errorMessage {
                            Text(error).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button("Validate & Import") {
                            Task { await model.connect(host: host, username: username, password: password) }
                        }.buttonStyle(PrimaryButtonStyle())
                    }
                } else {
                    if model.hasSavedProvider {
                        Button("Reconnect Saved Provider") {
                            Task { await model.retrySavedProvider() }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }
                    Button("Connect Provider") { showForm = true }.buttonStyle(PrimaryButtonStyle())
                }
                Label("Credentials are stored in this iPhone’s Keychain", systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
        }
        .onAppear {
            if model.errorMessage != nil || !model.savedHost.isEmpty {
                host = model.savedHost
                username = model.savedUsername
                showForm = true
            }
        }
    }

    @ViewBuilder
    private func field(_ title: String, text: Binding<String>, contentType: UITextContentType, secure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            Group {
                if secure { SecureField(title, text: text) }
                else { TextField(title, text: text) }
            }
            .textContentType(contentType)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(14)
            .background(GameDayTheme.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
    }
}

struct ImportingView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large).tint(GameDayTheme.lightPurple)
            Text("Building your lineup").font(.title.bold())
            Text(model.importMessage).foregroundStyle(GameDayTheme.muted)
            Text("Large providers may take a moment.").font(.caption).foregroundStyle(.secondary)
        }.padding(30)
    }
}
