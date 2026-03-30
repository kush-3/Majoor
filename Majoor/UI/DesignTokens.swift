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

    // MARK: - Spacing (8pt grid)
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
    }

    // MARK: - Corner Radii
    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
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

    // MARK: - Shadows
    enum Shadow {
        struct Definition {
            let color: Color
            let radius: CGFloat
            let x: CGFloat
            let y: CGFloat
        }
        static let card = Definition(color: .black.opacity(0.05), radius: 4, x: 0, y: 1)
        static let toast = Definition(color: .black.opacity(0.10), radius: 8, x: 0, y: 4)
        static let floating = Definition(color: .black.opacity(0.18), radius: 24, x: 0, y: 12)
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
