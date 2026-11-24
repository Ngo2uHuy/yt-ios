import SwiftUI

enum AppMode: String, CaseIterable, Identifiable {
    case youtube = "youtube"
    case spotify = "spotify"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .youtube: return "YouTube"
        case .spotify: return "Spotify"
        }
    }

    var iconName: String {
        switch self {
        case .youtube: return "play.rectangle.fill"
        case .spotify: return "dot.radiowaves.right"
        }
    }

    var accentColor: Color {
        switch self {
        case .youtube: return Color(red: 1.0, green: 0.0, blue: 0.0)
        case .spotify: return Color(red: 0.11, green: 0.73, blue: 0.33)
        }
    }
}

@MainActor
final class AppModeManager: ObservableObject {
    static let shared = AppModeManager()
    private static let key = "vidra_app_mode"

    @Published var currentMode: AppMode {
        didSet {
            UserDefaults.standard.set(currentMode.rawValue, forKey: Self.key)
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? AppMode.youtube.rawValue
        currentMode = AppMode(rawValue: raw) ?? .youtube
    }

    func toggle() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            currentMode = (currentMode == .youtube) ? .spotify : .youtube
        }
    }

    func switchTo(_ mode: AppMode) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            currentMode = mode
        }
    }
}

/// A luxury glassmorphic button that switches between YouTube and Spotify interfaces
struct AppModeSwitchPill: View {
    @ObservedObject private var manager = AppModeManager.shared

    var body: some View {
        Button {
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            #endif
            manager.toggle()
        } label: {
            HStack(spacing: 6) {
                let target = (manager.currentMode == .youtube) ? AppMode.spotify : AppMode.youtube

                // Pulsing dot indicator
                Circle()
                    .fill(target.accentColor)
                    .frame(width: 6, height: 6)
                    .shadow(color: target.accentColor.opacity(0.85), radius: 3)

                Image(systemName: target.iconName)
                    .font(.system(size: 11, weight: .bold))

                Text(target.title)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(-0.2)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Capsule()
                            .fill(manager.currentMode == .youtube ? Color(red: 0.11, green: 0.73, blue: 0.33).opacity(0.12) : Color.red.opacity(0.12))
                    )
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                (manager.currentMode == .youtube ? Color(red: 0.11, green: 0.73, blue: 0.33) : Color.red).opacity(0.6),
                                (manager.currentMode == .youtube ? Color(red: 0.11, green: 0.73, blue: 0.33) : Color.red).opacity(0.2)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: (manager.currentMode == .youtube ? Color(red: 0.11, green: 0.73, blue: 0.33) : Color.red).opacity(0.25), radius: 6, y: 2)
            .foregroundStyle(manager.currentMode == .youtube ? Color(red: 0.11, green: 0.73, blue: 0.33) : Color.red)
        }
        .buttonStyle(SpringPressButtonStyle())
    }
}

/// Spring scaling press button style
struct SpringPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}
