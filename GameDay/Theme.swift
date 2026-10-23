import SwiftUI

enum GameDayTheme {
    static let background = Color(red: 0.03, green: 0.03, blue: 0.05)
    static let surface = Color(red: 0.08, green: 0.075, blue: 0.10)
    static let surfaceRaised = Color(red: 0.12, green: 0.11, blue: 0.15)
    static let purple = Color(red: 0.49, green: 0.32, blue: 0.85)
    static let lightPurple = Color(red: 0.68, green: 0.52, blue: 1.0)
    static let muted = Color(red: 0.58, green: 0.57, blue: 0.64)
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background(GameDayTheme.purple.opacity(configuration.isPressed ? 0.75 : 1))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}
