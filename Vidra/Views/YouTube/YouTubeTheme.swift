import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - YouTube Color System (YTColor)

/// Official YouTube iOS Color Palette with full Dark and Light Mode support.
enum YTColor {
    /// Official YouTube Red: #FF0000
    static let brandRed = Color(red: 1.0, green: 0.0, blue: 0.0)

    /// Main canvas background: Dark (#0F0F0F), Light (#FFFFFF)
    static var background: Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 15 / 255.0, green: 15 / 255.0, blue: 15 / 255.0, alpha: 1.0)
                : UIColor.white
        })
        #else
        return Color(red: 15 / 255.0, green: 15 / 255.0, blue: 15 / 255.0)
        #endif
    }

    /// Card & surface elevation: Dark (#272727), Light (#F2F2F2)
    static var cardBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 39 / 255.0, green: 39 / 255.0, blue: 39 / 255.0, alpha: 1.0)
                : UIColor(red: 242 / 255.0, green: 242 / 255.0, blue: 242 / 255.0, alpha: 1.0)
        })
        #else
        return Color(red: 39 / 255.0, green: 39 / 255.0, blue: 39 / 255.0)
        #endif
    }

    /// Secondary surface: Dark (#1E1E1E), Light (#F8F8F8)
    static var surfaceSecondary: Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 30 / 255.0, green: 30 / 255.0, blue: 30 / 255.0, alpha: 1.0)
                : UIColor(red: 248 / 255.0, green: 248 / 255.0, blue: 248 / 255.0, alpha: 1.0)
        })
        #else
        return Color(red: 30 / 255.0, green: 30 / 255.0, blue: 30 / 255.0)
        #endif
    }

    /// Primary text: Dark (#FFFFFF), Light (#0F0F0F)
    static var textPrimary: Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white
                : UIColor(red: 15 / 255.0, green: 15 / 255.0, blue: 15 / 255.0, alpha: 1.0)
        })
        #else
        return Color.primary
        #endif
    }

    /// Secondary text: Dark (#AAAAAA), Light (#606060)
    static var textSecondary: Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 170 / 255.0, green: 170 / 255.0, blue: 170 / 255.0, alpha: 1.0)
                : UIColor(red: 96 / 255.0, green: 96 / 255.0, blue: 96 / 255.0, alpha: 1.0)
        })
        #else
        return Color(red: 170 / 255.0, green: 170 / 255.0, blue: 170 / 255.0)
        #endif
    }

    /// Category chip inactive background: Dark (#272727), Light (#F2F2F2)
    static var chipBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 39 / 255.0, green: 39 / 255.0, blue: 39 / 255.0, alpha: 1.0)
                : UIColor(red: 242 / 255.0, green: 242 / 255.0, blue: 242 / 255.0, alpha: 1.0)
        })
        #else
        return Color(red: 39 / 255.0, green: 39 / 255.0, blue: 39 / 255.0)
        #endif
    }

    /// Category chip active background: Dark (#FFFFFF), Light (#0F0F0F)
    static var chipActiveBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor.white
                : UIColor(red: 15 / 255.0, green: 15 / 255.0, blue: 15 / 255.0, alpha: 1.0)
        })
        #else
        return Color.white
        #endif
    }

    /// Category chip active text: Dark (#0F0F0F), Light (#FFFFFF)
    static var chipActiveText: Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 15 / 255.0, green: 15 / 255.0, blue: 15 / 255.0, alpha: 1.0)
                : UIColor.white
        })
        #else
        return Color.black
        #endif
    }

    /// Separator and subtle outline: Dark (#272727), Light (#E5E5E5)
    static var separator: Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 39 / 255.0, green: 39 / 255.0, blue: 39 / 255.0, alpha: 1.0)
                : UIColor(red: 229 / 255.0, green: 229 / 255.0, blue: 229 / 255.0, alpha: 1.0)
        })
        #else
        return Color(red: 39 / 255.0, green: 39 / 255.0, blue: 39 / 255.0)
        #endif
    }

    /// Video duration badge overlay background: 80% Black
    static let badgeBackground = Color.black.opacity(0.8)

    /// Live badge red
    static let liveBadgeRed = Color(red: 0.85, green: 0.0, blue: 0.0)
}

// MARK: - Color Convenience Extensions

extension Color {
    static let ytBrandRed = YTColor.brandRed
    static let ytBackground = YTColor.background
    static let ytCardBackground = YTColor.cardBackground
    static let ytTextPrimary = YTColor.textPrimary
    static let ytTextSecondary = YTColor.textSecondary
    static let ytChipBackground = YTColor.chipBackground
    static let ytChipActiveBackground = YTColor.chipActiveBackground
    static let ytChipActiveText = YTColor.chipActiveText
    static let ytSeparator = YTColor.separator
}

// MARK: - YouTube Logo Component

/// YouTube Brand Logo consisting of the red play button badge and bold tracked typography.
struct YouTubeLogoView: View {
    var title: String = "YouTube"
    var countryCode: String? = "VN"
    var iconScale: CGFloat = 1.0

    init(title: String = "YouTube", countryCode: String? = "VN", iconScale: CGFloat = 1.0) {
        self.title = title
        self.countryCode = countryCode
        self.iconScale = iconScale
    }

    var body: some View {
        HStack(spacing: 4) {
            // YouTube Red Play Button with Glossy Gradient & Glow
            ZStack {
                RoundedRectangle(cornerRadius: 6 * iconScale, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.16, blue: 0.16),
                                YTColor.brandRed,
                                Color(red: 0.82, green: 0.0, blue: 0.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 29 * iconScale, height: 20 * iconScale)
                    .shadow(color: YTColor.brandRed.opacity(0.35), radius: 4 * iconScale, y: 1.5 * iconScale)

                // White Play Triangle
                Image(systemName: "play.fill")
                    .font(.system(size: 9 * iconScale, weight: .black))
                    .foregroundStyle(.white)
                    .offset(x: 0.5 * iconScale)
                    .shadow(color: Color.black.opacity(0.3), radius: 0.8, y: 0.5)
            }

            // YouTube Title Text
            HStack(alignment: .top, spacing: 2) {
                Text(title)
                    .font(.system(size: 19 * iconScale, weight: .bold, design: .rounded))
                    .foregroundStyle(YTColor.textPrimary)
                    .tracking(-0.6)

                if let code = countryCode, !code.isEmpty {
                    Text(code)
                        .font(.system(size: 8 * iconScale, weight: .bold))
                        .foregroundStyle(YTColor.textSecondary)
                        .offset(y: -2 * iconScale)
                }
            }
        }
    }
}

// MARK: - YouTube Top Header Component

/// Standard top header bar for YouTube iOS with Logo, Spotify quick switcher, and action icons.
struct YouTubeHeader: View {
    var title: String = "YouTube"
    var countryCode: String? = "VN"
    var showModeSwitch: Bool = true
    var showCast: Bool = true
    var showNotifications: Bool = true
    var showSearch: Bool = true
    var notificationCount: Int = 0

    var onCast: (() -> Void)? = nil
    var onNotifications: (() -> Void)? = nil
    var onSearch: (() -> Void)? = nil
    var onLogoTap: (() -> Void)? = nil

    init(
        title: String = "YouTube",
        countryCode: String? = "VN",
        showModeSwitch: Bool = true,
        showCast: Bool = true,
        showNotifications: Bool = true,
        showSearch: Bool = true,
        notificationCount: Int = 0,
        onCast: (() -> Void)? = nil,
        onNotifications: (() -> Void)? = nil,
        onSearch: (() -> Void)? = nil,
        onLogoTap: (() -> Void)? = nil
    ) {
        self.title = title
        self.countryCode = countryCode
        self.showModeSwitch = showModeSwitch
        self.showCast = showCast
        self.showNotifications = showNotifications
        self.showSearch = showSearch
        self.notificationCount = notificationCount
        self.onCast = onCast
        self.onNotifications = onNotifications
        self.onSearch = onSearch
        self.onLogoTap = onLogoTap
    }

    var body: some View {
        HStack(spacing: 8) {
            // Leading Logo
            Button {
                onLogoTap?()
            } label: {
                YouTubeLogoView(title: title, countryCode: countryCode)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 4)

            // Spotify Mode Switcher Pill
            if showModeSwitch {
                AppModeSwitchPill()
            }

            // Cast Action Button
            if showCast {
                YouTubeHeaderIconButton(iconName: "airplayvideo", accessibilityLabel: "Truyền tới thiết bị") {
                    onCast?()
                }
            }

            // Notification Bell with Badge
            if showNotifications {
                ZStack(alignment: .topTrailing) {
                    YouTubeHeaderIconButton(iconName: "bell", accessibilityLabel: "Thông báo") {
                        onNotifications?()
                    }

                    if notificationCount > 0 {
                        Text(notificationCount > 9 ? "9+" : "\(notificationCount)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(YTColor.brandRed, in: Capsule())
                            .offset(x: 2, y: 4)
                    }
                }
            }

            // Search Action Button
            if showSearch {
                YouTubeHeaderIconButton(iconName: "magnifyingglass", accessibilityLabel: "Tìm kiếm") {
                    onSearch?()
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(YTColor.background)
    }
}

// MARK: - Header Icon Button

/// Circular tap-target button matching YouTube iOS top bar style.
struct YouTubeHeaderIconButton: View {
    let iconName: String
    var accessibilityLabel: String? = nil
    let action: () -> Void

    init(iconName: String, accessibilityLabel: String? = nil, action: @escaping () -> Void) {
        self.iconName = iconName
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(YTColor.textPrimary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(SpringPressButtonStyle())
        .accessibilityLabel(accessibilityLabel ?? iconName)
    }
}

// MARK: - YouTube Category Chips Component

/// Horizontal scrolling capsule chips bar mimicking YouTube iOS feed filtering.
struct YouTubeCategoryChips: View {
    static let defaultCategories = [
        "Tất cả",
        "Âm nhạc",
        "Trò chơi",
        "Tin tức",
        "Bóng đá",
        "Podcasts",
        "Hoạt hình",
        "Mới tải lên",
        "Đã xem",
        "Học tập",
        "Công nghệ",
        "Nấu ăn",
        "Du lịch"
    ]

    let categories: [String]
    @Binding var selectedCategory: String
    var showExploreButton: Bool
    var onExploreTap: (() -> Void)?
    var onSelect: ((String) -> Void)?

    init(
        categories: [String] = YouTubeCategoryChips.defaultCategories,
        selectedCategory: Binding<String>,
        showExploreButton: Bool = true,
        onExploreTap: (() -> Void)? = nil,
        onSelect: ((String) -> Void)? = nil
    ) {
        self.categories = categories
        self._selectedCategory = selectedCategory
        self.showExploreButton = showExploreButton
        self.onExploreTap = onExploreTap
        self.onSelect = onSelect
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Explore / Compass Leading Chip (like YouTube iOS)
                if showExploreButton {
                    Button {
                        onExploreTap?()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "safari")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Khám phá")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(YTColor.chipBackground, in: Capsule())
                        .foregroundStyle(YTColor.textPrimary)
                    }
                    .buttonStyle(.plain)

                    // Vertical separator between Explore and Categories
                    Rectangle()
                        .fill(YTColor.separator)
                        .frame(width: 1, height: 20)
                        .padding(.trailing, 2)
                }

                // Category Chips
                ForEach(categories, id: \.self) { category in
                    let isSelected = selectedCategory == category

                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                            selectedCategory = category
                        }
                        onSelect?(category)
                    } label: {
                        Text(category)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                isSelected ? YTColor.chipActiveBackground : YTColor.chipBackground,
                                in: Capsule()
                            )
                            .foregroundStyle(isSelected ? YTColor.chipActiveText : YTColor.textPrimary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(YTColor.background)
    }
}

// MARK: - YouTube Bottom Bar & Tab Items

/// Standard navigation tabs in the YouTube iOS application.
enum YouTubeTab: String, CaseIterable, Identifiable {
    case home = "home"
    case shorts = "shorts"
    case create = "create"
    case subscriptions = "subscriptions"
    case you = "you"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Trang chủ"
        case .shorts: return "Shorts"
        case .create: return ""
        case .subscriptions: return "Đăng ký"
        case .you: return "Bạn"
        }
    }

    var iconName: String {
        switch self {
        case .home: return "house"
        case .shorts: return "play.square.stack"
        case .create: return "plus"
        case .subscriptions: return "play.rectangle.on.rectangle"
        case .you: return "person.crop.circle"
        }
    }

    var selectedIconName: String {
        switch self {
        case .home: return "house.fill"
        case .shorts: return "play.square.stack.fill"
        case .create: return "plus"
        case .subscriptions: return "play.rectangle.on.rectangle.fill"
        case .you: return "person.crop.circle.fill"
        }
    }
}

/// Custom Bottom TabBar styled exactly like YouTube iOS with badges and active indicators.
struct YouTubeBottomBar: View {
    @Binding var selectedTab: YouTubeTab
    var tabs: [YouTubeTab]
    var unreadSubscriptionsCount: Int
    var hasYouDot: Bool
    var onCreateTap: (() -> Void)?

    init(
        selectedTab: Binding<YouTubeTab>,
        tabs: [YouTubeTab] = [.home, .shorts, .create, .subscriptions, .you],
        unreadSubscriptionsCount: Int = 0,
        hasYouDot: Bool = false,
        onCreateTap: (() -> Void)? = nil
    ) {
        self._selectedTab = selectedTab
        self.tabs = tabs
        self.unreadSubscriptionsCount = unreadSubscriptionsCount
        self.hasYouDot = hasYouDot
        self.onCreateTap = onCreateTap
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top hairline border with subtle opacity
            Rectangle()
                .fill(YTColor.separator.opacity(0.6))
                .frame(height: 0.5)

            // Tab bar items
            HStack(spacing: 0) {
                ForEach(tabs) { tab in
                    if tab == .create {
                        // YouTube Plus / Create button with luxury gradient & spring feedback
                        Button {
                            onCreateTap?()
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                YTColor.cardBackground.opacity(0.7),
                                                YTColor.cardBackground
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                    .frame(width: 36, height: 36)
                                    .overlay(
                                        Circle()
                                            .strokeBorder(
                                                LinearGradient(
                                                    colors: [
                                                        YTColor.textPrimary.opacity(0.85),
                                                        YTColor.textPrimary.opacity(0.4)
                                                    ],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                ),
                                                lineWidth: 1.5
                                            )
                                    )
                                    .shadow(color: Color.black.opacity(0.25), radius: 4, y: 2)

                                Image(systemName: "plus")
                                    .font(.system(size: 19, weight: .semibold))
                                    .foregroundStyle(YTColor.textPrimary)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                        }
                        .buttonStyle(SpringPressButtonStyle())
                    } else {
                        // Standard tab button with spring scale & tactile press
                        let isSelected = selectedTab == tab
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                                selectedTab = tab
                            }
                        } label: {
                            VStack(spacing: 3) {
                                ZStack(alignment: .topTrailing) {
                                    Image(systemName: isSelected ? tab.selectedIconName : tab.iconName)
                                        .font(.system(size: 20, weight: isSelected ? .medium : .regular))
                                        .foregroundStyle(isSelected ? YTColor.textPrimary : YTColor.textSecondary)
                                        .scaleEffect(isSelected ? 1.08 : 1.0)
                                        .frame(height: 24)

                                    // Subscriptions unread badge
                                    if tab == .subscriptions && unreadSubscriptionsCount > 0 {
                                        Circle()
                                            .fill(YTColor.brandRed)
                                            .frame(width: 7, height: 7)
                                            .shadow(color: YTColor.brandRed.opacity(0.6), radius: 2)
                                            .offset(x: 6, y: -2)
                                    }

                                    // "You" tab notification indicator
                                    if tab == .you && hasYouDot {
                                        Circle()
                                            .fill(YTColor.brandRed)
                                            .frame(width: 7, height: 7)
                                            .shadow(color: YTColor.brandRed.opacity(0.6), radius: 2)
                                            .offset(x: 6, y: -2)
                                    }
                                }

                                Text(tab.title)
                                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                                    .foregroundStyle(isSelected ? YTColor.textPrimary : YTColor.textSecondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(SpringPressButtonStyle())
                    }
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 2)
        }
        .background(
            ZStack {
                YTColor.background.opacity(0.92)
                Rectangle().fill(.ultraThinMaterial)
            }
            .ignoresSafeArea(edges: .bottom)
        )
    }
}

// MARK: - Additional YouTube UI Components

/// Reusable Duration Badge (e.g. "12:34") displayed over video thumbnails.
struct YouTubeDurationBadge: View {
    let duration: String

    init(_ duration: String) {
        self.duration = duration
    }

    var body: some View {
        Text(duration)
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(YTColor.badgeBackground, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .foregroundStyle(.white)
    }
}

/// "TRỰC TIẾP" (LIVE) badge for live broadcasts.
struct YouTubeLiveBadge: View {
    var text: String = "TRỰC TIẾP"

    init(_ text: String = "TRỰC TIẾP") {
        self.text = text
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 8, weight: .bold))
            Text(text)
                .font(.system(size: 10, weight: .heavy))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(YTColor.liveBadgeRed, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        .foregroundStyle(.white)
    }
}

/// Standard YouTube Video Feed Card layout with 16:9 thumbnail, duration, avatar, and metadata.
struct YouTubeFeedCard: View {
    let thumbnailURL: URL?
    let title: String
    let channelTitle: String
    var channelAvatarURL: URL? = nil
    var duration: String? = nil
    var views: String? = nil
    var published: String? = nil
    var progress: Double? = nil
    var onMoreTap: (() -> Void)? = nil

    init(
        thumbnailURL: URL?,
        title: String,
        channelTitle: String,
        channelAvatarURL: URL? = nil,
        duration: String? = nil,
        views: String? = nil,
        published: String? = nil,
        progress: Double? = nil,
        onMoreTap: (() -> Void)? = nil
    ) {
        self.thumbnailURL = thumbnailURL
        self.title = title
        self.channelTitle = channelTitle
        self.channelAvatarURL = channelAvatarURL
        self.duration = duration
        self.views = views
        self.published = published
        self.progress = progress
        self.onMoreTap = onMoreTap
    }

    private var subtitle: String {
        [channelTitle, views, published].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Thumbnail container
            ZStack(alignment: .bottomTrailing) {
                Color(.secondarySystemFill)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        CachedAsyncImage(url: thumbnailURL, targetSize: CGSize(width: 480, height: 270)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color(.secondarySystemFill)
                        }
                    }
                    .clipped()

                // Bottom progress bar
                if let progress = progress, progress > 0 {
                    GeometryReader { geo in
                        Rectangle()
                            .fill(YTColor.brandRed)
                            .frame(width: geo.size.width * min(progress, 1), height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }

                // Duration badge
                if let duration = duration, !duration.isEmpty {
                    YouTubeDurationBadge(duration)
                        .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            // Details row: Avatar + Title & Meta + More Button
            HStack(alignment: .top, spacing: 12) {
                // Channel Avatar
                ZStack {
                    Circle()
                        .fill(YTColor.cardBackground)
                        .frame(width: 36, height: 36)

                    if let avatar = channelAvatarURL {
                        CachedAsyncImage(url: avatar, targetSize: CGSize(width: 36, height: 36)) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "person.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(YTColor.textSecondary)
                        }
                        .clipShape(Circle())
                        .frame(width: 36, height: 36)
                    } else {
                        Text(String(channelTitle.prefix(1)).uppercased())
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(YTColor.textPrimary)
                    }
                }

                // Title and Meta
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(YTColor.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(YTColor.textSecondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)

                // 3-dots Menu Button
                Button {
                    onMoreTap?()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(YTColor.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
        }
        .padding(.bottom, 8)
        .background(YTColor.background)
    }
}

// MARK: - YouTube Create Sheet (Nút "+" Tạo nội dung)

struct YouTubeCreateSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header: Title "Tạo" & Close Button
            HStack {
                Text("Tạo")
                    .font(.title2.bold())
                    .foregroundStyle(YTColor.textPrimary)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(YTColor.textPrimary)
                        .frame(width: 36, height: 36)
                        .background(YTColor.cardBackground, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // Options List
            VStack(spacing: 8) {
                createOptionRow(
                    icon: "play.square.stack",
                    title: "Tạo một video ngắn",
                    subtitle: "Quay video ngắn hoặc phối lại nội dung hiện có"
                ) {
                    dismiss()
                }

                createOptionRow(
                    icon: "arrow.up.circle",
                    title: "Tải video lên",
                    subtitle: "Chia sẻ video dài đầy đủ tính năng từ thiết bị của bạn"
                ) {
                    dismiss()
                }

                createOptionRow(
                    icon: "dot.radiowaves.left.and.right",
                    title: "Phát trực tiếp",
                    subtitle: "Bắt đầu phát video trực tiếp cho người xem"
                ) {
                    dismiss()
                }

                createOptionRow(
                    icon: "square.and.pencil",
                    title: "Tạo bài đăng",
                    subtitle: "Chia sẻ hình ảnh, khảo sát hoặc cập nhật trạng thái"
                ) {
                    dismiss()
                }
            }
            .padding(.horizontal, 16)

            Spacer(minLength: 0)
        }
        .background(YTColor.background)
    }

    private func createOptionRow(
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(YTColor.cardBackground)
                        .frame(width: 44, height: 44)

                    Image(systemName: icon)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(YTColor.textPrimary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(YTColor.textPrimary)

                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(YTColor.textSecondary)
                        .lineLimit(1)
                }

                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Previews

#if DEBUG
struct YouTubeTheme_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            VStack(spacing: 0) {
                YouTubeHeader(
                    notificationCount: 3,
                    onCast: {},
                    onNotifications: {},
                    onSearch: {}
                )
                YouTubeCategoryChips(
                    selectedCategory: .constant("Tất cả")
                )
                Spacer()
                YouTubeBottomBar(
                    selectedTab: .constant(.home),
                    unreadSubscriptionsCount: 1
                )
            }
            .background(YTColor.background)
            .preferredColorScheme(.dark)
            .previewDisplayName("YouTube Dark Mode")

            VStack(spacing: 0) {
                YouTubeHeader(
                    notificationCount: 0,
                    onCast: {},
                    onNotifications: {},
                    onSearch: {}
                )
                YouTubeCategoryChips(
                    selectedCategory: .constant("Âm nhạc")
                )
                Spacer()
                YouTubeBottomBar(
                    selectedTab: .constant(.subscriptions),
                    unreadSubscriptionsCount: 0
                )
            }
            .background(YTColor.background)
            .preferredColorScheme(.light)
            .previewDisplayName("YouTube Light Mode")
        }
    }
}
#endif
