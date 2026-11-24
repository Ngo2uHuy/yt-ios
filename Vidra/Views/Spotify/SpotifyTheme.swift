import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Spotify Color System (SpotifyColor)

/// Official Spotify iOS Color Palette with iconic dark canvas, surface elevations, and Spotify Green.
enum SpotifyColor {
    /// Canvas background: #121212 (Iconic Spotify deep dark canvas)
    static let background = Color(red: 18 / 255.0, green: 18 / 255.0, blue: 18 / 255.0)

    /// Surface & card background: #282828 (Standard Spotify card, bottom sheet & floating surface)
    static let surface = Color(red: 40 / 255.0, green: 40 / 255.0, blue: 40 / 255.0)

    /// Surface highlight: #3E3E3E (Inactive chips, active touch feedback, slider track)
    static let surfaceHighlight = Color(red: 62 / 255.0, green: 62 / 255.0, blue: 62 / 255.0)

    /// Spotify Brand Green: #1DB954 (Primary action buttons, active toggles, liked heart, progress)
    static let brandGreen = Color(red: 29 / 255.0, green: 185 / 255.0, blue: 84 / 255.0)

    /// Primary text: #FFFFFF (Titles, headings, primary actions)
    static let textPrimary = Color.white

    /// Secondary text: #B3B3B3 (Subtitles, artist names, timestamps, inactive icons)
    static let textSecondary = Color(red: 179 / 255.0, green: 179 / 255.0, blue: 179 / 255.0)

    // MARK: Additional Spotify Design System Constants
    /// Deeper card background: #181818
    static let cardBackground = Color(red: 24 / 255.0, green: 24 / 255.0, blue: 24 / 255.0)

    /// Subtle background: #202020
    static let surfaceSubtle = Color(red: 32 / 255.0, green: 32 / 255.0, blue: 32 / 255.0)

    /// Subtle border & divider
    static let divider = Color.white.opacity(0.08)

    /// Play button drop shadow
    static let playButtonShadow = Color.black.opacity(0.45)

    /// Green neon glow for prominent controls
    static let greenGlow = Color(red: 29 / 255.0, green: 185 / 255.0, blue: 84 / 255.0).opacity(0.4)
}

// MARK: - SwiftUI Color Convenience Extensions

extension Color {
    static let spotifyBackground = SpotifyColor.background
    static let spotifySurface = SpotifyColor.surface
    static let spotifySurfaceHighlight = SpotifyColor.surfaceHighlight
    static let spotifyBrandGreen = SpotifyColor.brandGreen
    static let spotifyTextPrimary = SpotifyColor.textPrimary
    static let spotifyTextSecondary = SpotifyColor.textSecondary
    static let spotifyCardBackground = SpotifyColor.cardBackground
}

// MARK: - Filter Chips Model

/// Category filter chips for Spotify top header.
enum SpotifyFilter: String, CaseIterable, Identifiable {
    case all = "Tất cả"
    case music = "Âm nhạc"
    case podcast = "Podcast"

    var id: String { rawValue }
    var title: String { rawValue }
}

// MARK: - Component: SpotifyHeader

/// Spotify top navigation header featuring user avatar, category filter chips, and mode switch pill.
struct SpotifyHeader: View {
    @Binding var selectedFilter: SpotifyFilter
    var avatarURL: URL?
    var onAvatarTap: (() -> Void)?
    var onFilterChange: ((SpotifyFilter) -> Void)?

    init(
        selectedFilter: Binding<SpotifyFilter>,
        avatarURL: URL? = nil,
        onAvatarTap: (() -> Void)? = nil,
        onFilterChange: ((SpotifyFilter) -> Void)? = nil
    ) {
        self._selectedFilter = selectedFilter
        self.avatarURL = avatarURL
        self.onAvatarTap = onAvatarTap
        self.onFilterChange = onFilterChange
    }

    /// Convenience initializer with internal static filter state
    init(
        avatarURL: URL? = nil,
        onAvatarTap: (() -> Void)? = nil
    ) {
        self._selectedFilter = .constant(.all)
        self.avatarURL = avatarURL
        self.onAvatarTap = onAvatarTap
        self.onFilterChange = nil
    }

    var body: some View {
        HStack(spacing: 10) {
            // 1. Profile Avatar
            Button {
                onAvatarTap?()
            } label: {
                if let avatarURL {
                    AsyncImage(url: avatarURL) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        avatarPlaceholder
                    }
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
                } else {
                    avatarPlaceholder
                }
            }
            .buttonStyle(.plain)

            // 2. Filter Chips ("Tất cả", "Âm nhạc", "Podcast")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SpotifyFilter.allCases) { filter in
                        let isSelected = selectedFilter == filter
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                                selectedFilter = filter
                            }
                            onFilterChange?(filter)
                        } label: {
                            Text(filter.title)
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule()
                                        .fill(isSelected ? SpotifyColor.brandGreen : SpotifyColor.surfaceHighlight)
                                )
                                .foregroundColor(isSelected ? .black : SpotifyColor.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            Spacer(minLength: 4)

            // 3. App Mode Switch Pill (Spotify <-> YouTube)
            AppModeSwitchPill()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(SpotifyColor.background.opacity(0.96))
    }

    private var avatarPlaceholder: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.25, green: 0.35, blue: 0.85),
                            Color(red: 0.65, green: 0.20, blue: 0.75)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 32, height: 32)

            Text("V")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
        }
    }
}

// MARK: - Component: SpotifyPlayButton

/// Official Spotify circular green play button with black centered triangle and dynamic shadow.
struct SpotifyPlayButton: View {
    var isPlaying: Bool
    var size: CGFloat
    var action: () -> Void

    init(
        isPlaying: Bool = false,
        size: CGFloat = 52,
        action: @escaping () -> Void = {}
    ) {
        self.isPlaying = isPlaying
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                // Spotify signature circular green background
                Circle()
                    .fill(SpotifyColor.brandGreen)
                    .frame(width: size, height: size)
                    // High-elevation dual shadow
                    .shadow(color: SpotifyColor.greenGlow, radius: 10, x: 0, y: 5)
                    .shadow(color: SpotifyColor.playButtonShadow, radius: 6, x: 0, y: 3)

                // Black center play / pause icon
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.42, weight: .black))
                    .foregroundColor(.black)
                    // Optical center correction for the play triangle
                    .offset(x: isPlaying ? 0 : (size * 0.03))
            }
        }
        .buttonStyle(SpotifyPlayButtonPressStyle())
    }
}

/// Spring scaling interaction style for Spotify buttons.
struct SpotifyPlayButtonPressStyle: ButtonStyle {
    init() {}

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Spotify UI Helpers & Modifiers

struct SpotifyCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .background(SpotifyColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func spotifyCard(cornerRadius: CGFloat = 8) -> some View {
        modifier(SpotifyCardModifier(cornerRadius: cornerRadius))
    }
}
