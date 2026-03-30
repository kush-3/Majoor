// DesignTokens.swift
// Majoor — Centralized design system tokens.

import SwiftUI

enum DT {
    // MARK: - Typography
    enum Font {
        /// 10pt — timestamps, token counts, keyboard hint labels
        static let micro = SwiftUI.Font.system(size: 10)
        /// 11pt — secondary labels, section headers, step descriptions
        static let caption = SwiftUI.Font.system(size: 11)
        /// 13pt — body text, chat messages, form rows, setting descriptions
        static let body = SwiftUI.Font.system(size: 13)
        /// 14pt — panel header, confirmation title, card title
        static let headline = SwiftUI.Font.system(size: 14, weight: .semibold)
        /// 17pt — command bar input (spotlight-style)
        static let largeInput = SwiftUI.Font.system(size: 17)

        static func caption(_ weight: SwiftUI.Font.Weight) -> SwiftUI.Font {
            .system(size: 11, weight: weight)
        }
        static func body(_ weight: SwiftUI.Font.Weight) -> SwiftUI.Font {
            .system(size: 13, weight: weight)
        }
        static func micro(_ weight: SwiftUI.Font.Weight) -> SwiftUI.Font {
            .system(size: 10, weight: weight)
        }
    }

    // MARK: - Title Fonts (onboarding, about, sheets)
    enum TitleFont {
        /// 18pt — section/step titles
        static let section = SwiftUI.Font.system(size: 18, weight: .semibold)
        /// 20pt — empty state titles
        static let medium = SwiftUI.Font.system(size: 20, weight: .semibold)
        /// 24pt — app name, hero text
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
    }

    // MARK: - Corner Radii
    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
        static let pill: CGFloat = 100
    }

    // MARK: - Surface Opacities
    enum Opacity {
        /// Subtle card background
        static let cardFill: Double = 0.06
        /// Hover state fill
        static let hoverFill: Double = 0.08
        /// Pressed / active state fill
        static let pressedFill: Double = 0.12
        /// Hairline stroke border
        static let subtleBorder: Double = 0.08
    }

    // MARK: - Semantic Colors
    enum Color {
        // Text hierarchy
        static let textPrimary = SwiftUI.Color.primary
        static let textSecondary = SwiftUI.Color.secondary
        static let textTertiary = SwiftUI.Color.secondary.opacity(0.6)
        static let textQuaternary = SwiftUI.Color.secondary.opacity(0.4)

        // Surfaces
        static let surfaceCard = SwiftUI.Color.primary.opacity(0.05)
        static let surfaceHover = SwiftUI.Color.primary.opacity(0.08)
        static let surfacePressed = SwiftUI.Color.primary.opacity(0.12)
        static let surfaceBorder = SwiftUI.Color.primary.opacity(0.08)

        // Status
        static let success = SwiftUI.Color.green
        static let error = SwiftUI.Color.red
        static let warning = SwiftUI.Color.orange
        static let active = SwiftUI.Color.blue
        static let running = SwiftUI.Color.orange

        // Connection status
        static let connected = SwiftUI.Color.green
        static let disconnected = SwiftUI.Color.red
        static let pending = SwiftUI.Color.orange

        // Accent
        static let accent = SwiftUI.Color.accentColor

        // Destructive
        static let destructive = SwiftUI.Color.red
    }

    // MARK: - Animation Durations
    enum Anim {
        /// 0.1s — button press, icon state change
        static let micro: SwiftUI.Animation = .easeInOut(duration: 0.10)
        /// 0.15s — hover transitions, small state changes
        static let fast: SwiftUI.Animation = .easeInOut(duration: 0.15)
        /// 0.2s — card expand, view transitions
        static let normal: SwiftUI.Animation = .easeInOut(duration: 0.20)
        /// 0.25s — page transitions (onboarding steps)
        static let page: SwiftUI.Animation = .easeInOut(duration: 0.25)
        /// 0.3s — panel appear, larger layout shifts
        static let slow: SwiftUI.Animation = .easeInOut(duration: 0.30)
        /// Spring for bouncy interactions
        static let spring: SwiftUI.Animation = .spring(response: 0.3, dampingFraction: 0.7)
    }

    // MARK: - Layout
    enum Layout {
        static let settingsWidth: CGFloat = 560
        static let settingsHeight: CGFloat = 500
        static let onboardingWidth: CGFloat = 520
        static let onboardingHeight: CGFloat = 440
        static let panelWidth: CGFloat = 400
        static let panelHeight: CGFloat = 520
    }

    // MARK: - Shadows
    enum Shadow {
        struct Definition {
            let color: SwiftUI.Color
            let radius: CGFloat
            let x: CGFloat
            let y: CGFloat
        }
        static let card = Definition(color: SwiftUI.Color.black.opacity(0.05), radius: 4, x: 0, y: 1)
        static let toast = Definition(color: SwiftUI.Color.black.opacity(0.10), radius: 8, x: 0, y: 4)
        static let floating = Definition(color: SwiftUI.Color.black.opacity(0.18), radius: 24, x: 0, y: 12)
    }
}

// MARK: - View Extension Helpers

extension View {
    func cardShadow() -> some View {
        self.shadow(color: DT.Shadow.card.color, radius: DT.Shadow.card.radius,
                    x: DT.Shadow.card.x, y: DT.Shadow.card.y)
    }
    func toastShadow() -> some View {
        self.shadow(color: DT.Shadow.toast.color, radius: DT.Shadow.toast.radius,
                    x: DT.Shadow.toast.x, y: DT.Shadow.toast.y)
    }
    func floatingShadow() -> some View {
        self.shadow(color: DT.Shadow.floating.color, radius: DT.Shadow.floating.radius,
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
                withAnimation(.easeInOut(duration: 0.12)) { isHovered = hovering }
            }
    }
}

extension View {
    func hoverCard(cornerRadius: CGFloat = DT.Radius.medium) -> some View {
        modifier(HoverCardModifier(cornerRadius: cornerRadius))
    }
}

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
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
            .onHover { h in withAnimation(.easeInOut(duration: 0.12)) { isHovered = h } }
    }
}
