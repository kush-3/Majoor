// DesignTokens.swift
// Majoor — Apple-grade design system.
//
// Every value here matches Apple HIG patterns observed in
// Spotlight, Messages, Notification Center, and System Settings.
// No magic numbers anywhere else in the codebase.

import SwiftUI

// MARK: - Design Tokens

enum DT {

    // MARK: - Typography
    //
    // Apple uses SF Pro with a strict 4-size hierarchy per surface.
    // Weights are deliberate: regular for body, medium for labels,
    // semibold for emphasis only.

    enum Font {
        /// 10pt — timestamps, token counts, metadata badges
        static let micro = SwiftUI.Font.system(size: 10)
        /// 11pt — secondary labels, section headers, captions
        static let caption = SwiftUI.Font.system(size: 11)
        /// 13pt — body text, chat messages, form rows
        static let body = SwiftUI.Font.system(size: 13)
        /// 15pt semibold — panel titles, card titles
        static let headline = SwiftUI.Font.system(size: 15, weight: .semibold)
        /// 18pt — command bar input (Spotlight uses ~18pt)
        static let largeInput = SwiftUI.Font.system(size: 18, weight: .light)

        static func micro(_ weight: SwiftUI.Font.Weight) -> SwiftUI.Font {
            .system(size: 10, weight: weight)
        }
        static func caption(_ weight: SwiftUI.Font.Weight) -> SwiftUI.Font {
            .system(size: 11, weight: weight)
        }
        static func body(_ weight: SwiftUI.Font.Weight) -> SwiftUI.Font {
            .system(size: 13, weight: weight)
        }
    }

    // MARK: - Title Fonts (onboarding, about, sheets)
    enum TitleFont {
        static let section = SwiftUI.Font.system(size: 18, weight: .semibold)
        static let medium = SwiftUI.Font.system(size: 20, weight: .semibold)
        static let hero = SwiftUI.Font.system(size: 24, weight: .bold)
    }

    // MARK: - Spacing (4pt base grid)

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: - Corner Radii
    //
    // Apple macOS uses 10pt for cards, 12pt for panels,
    // continuous corners everywhere.

    enum Radius {
        /// 6pt — chips, keyboard hint badges, small controls
        static let small: CGFloat = 6
        /// 10pt — cards, inputs, toast notifications
        static let medium: CGFloat = 10
        /// 12pt — panels, sheets, large surfaces
        static let large: CGFloat = 12
        /// 16pt — chat bubbles (Messages.app style)
        static let bubble: CGFloat = 16
        /// Capsule shape
        static let pill: CGFloat = 100
    }

    // MARK: - Semantic Colors
    //
    // Apple approach: system semantic colors everywhere.
    // Interactive elements use .accentColor.
    // Text hierarchy uses .primary / .secondary / .tertiary.

    enum Color {
        // Text hierarchy
        static let textPrimary = SwiftUI.Color.primary
        static let textSecondary = SwiftUI.Color.secondary
        static let textTertiary = SwiftUI.Color.secondary.opacity(0.6)
        static let textQuaternary = SwiftUI.Color.secondary.opacity(0.35)

        // Surfaces — prefer materials; these are for layered opaque fills
        static let surfaceCard = SwiftUI.Color.primary.opacity(0.04)
        static let surfaceHover = SwiftUI.Color.primary.opacity(0.06)
        static let surfacePressed = SwiftUI.Color.primary.opacity(0.10)
        static let surfaceBorder = SwiftUI.Color.primary.opacity(0.06)

        // Status — standard macOS semantic colors
        static let success = SwiftUI.Color.green
        static let error = SwiftUI.Color.red
        static let warning = SwiftUI.Color.orange
        static let active = SwiftUI.Color.blue
        static let running = SwiftUI.Color.orange

        // Connection status
        static let connected = SwiftUI.Color.green
        static let disconnected = SwiftUI.Color.red
        static let pending = SwiftUI.Color.orange

        // Accent — user's system accent color
        static let accent = SwiftUI.Color.accentColor

        // Destructive
        static let destructive = SwiftUI.Color.red
    }

    // MARK: - Animations
    //
    // Apple favours spring animations with moderate damping.
    // Spotlight uses ~0.3s, Messages uses ~0.25s for bubbles.

    enum Anim {
        /// Instant feedback — button press, icon swap
        static let micro: SwiftUI.Animation = .spring(response: 0.15, dampingFraction: 0.9)
        /// Quick state change — hover, toggle
        static let fast: SwiftUI.Animation = .spring(response: 0.2, dampingFraction: 0.85)
        /// Standard transition — card expand, view switch
        static let normal: SwiftUI.Animation = .spring(response: 0.3, dampingFraction: 0.82)
        /// Page transition (onboarding)
        static let page: SwiftUI.Animation = .spring(response: 0.35, dampingFraction: 0.82)
        /// Larger layout shift — panel appear
        static let slow: SwiftUI.Animation = .spring(response: 0.4, dampingFraction: 0.78)
        /// Bouncy spring for playful interactions
        static let spring: SwiftUI.Animation = .spring(response: 0.35, dampingFraction: 0.7)
        /// Smooth ease for scroll/position changes
        static let smooth: SwiftUI.Animation = .smooth(duration: 0.25)
    }

    // MARK: - Layout

    enum Layout {
        static let settingsWidth: CGFloat = 620
        static let settingsHeight: CGFloat = 520
        static let onboardingWidth: CGFloat = 560
        static let onboardingHeight: CGFloat = 480
        static let panelWidth: CGFloat = 380
        static let panelHeight: CGFloat = 500
        static let commandBarWidth: CGFloat = 620
    }

    // MARK: - Shadows
    //
    // Apple uses very soft, diffuse shadows. Never harsh.

    enum Shadow {
        struct Definition {
            let color: SwiftUI.Color
            let radius: CGFloat
            let x: CGFloat
            let y: CGFloat
        }
        /// Subtle card elevation
        static let card = Definition(color: .black.opacity(0.04), radius: 3, x: 0, y: 1)
        /// Toast / floating card
        static let toast = Definition(color: .black.opacity(0.08), radius: 12, x: 0, y: 4)
        /// Panel / command bar — macOS floating window shadow
        static let floating = Definition(color: .black.opacity(0.15), radius: 30, x: 0, y: 10)
    }

    // MARK: - Opacity (backward-compat alias)

    enum Opacity {
        static let cardFill: Double = 0.04
        static let hoverFill: Double = 0.06
        static let pressedFill: Double = 0.10
        static let subtleBorder: Double = 0.06
    }
}

// MARK: - View Extension Helpers

extension View {
    func cardShadow() -> some View {
        shadow(color: DT.Shadow.card.color, radius: DT.Shadow.card.radius,
               x: DT.Shadow.card.x, y: DT.Shadow.card.y)
    }
    func toastShadow() -> some View {
        shadow(color: DT.Shadow.toast.color, radius: DT.Shadow.toast.radius,
               x: DT.Shadow.toast.x, y: DT.Shadow.toast.y)
    }
    func floatingShadow() -> some View {
        shadow(color: DT.Shadow.floating.color, radius: DT.Shadow.floating.radius,
               x: DT.Shadow.floating.x, y: DT.Shadow.floating.y)
    }
}

// MARK: - Hover State Modifier

struct HoverCardModifier: ViewModifier {
    @State private var isHovered = false
    var cornerRadius: CGFloat = DT.Radius.medium

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? DT.Opacity.hoverFill : 0))
            )
            .onHover { hovering in
                withAnimation(DT.Anim.fast) { isHovered = hovering }
            }
    }
}

extension View {
    func hoverCard(cornerRadius: CGFloat = DT.Radius.medium) -> some View {
        modifier(HoverCardModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - Button Styles

struct HoverButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, DT.Spacing.sm)
            .padding(.vertical, DT.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DT.Radius.small, style: .continuous)
                    .fill(Color.primary.opacity(
                        configuration.isPressed ? DT.Opacity.pressedFill :
                        isHovered ? DT.Opacity.hoverFill : 0
                    ))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(DT.Anim.micro, value: configuration.isPressed)
            .onHover { h in withAnimation(DT.Anim.fast) { isHovered = h } }
    }
}

/// Apple-style pill button (like toolbar actions in macOS apps)
struct PillButtonStyle: ButtonStyle {
    var isActive: Bool = false
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DT.Font.caption(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(isActive
                          ? Color.primary.opacity(0.10)
                          : Color.primary.opacity(
                              configuration.isPressed ? 0.08 :
                              isHovered ? 0.05 : 0
                          ))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(DT.Anim.micro, value: configuration.isPressed)
            .onHover { h in withAnimation(DT.Anim.fast) { isHovered = h } }
    }
}
