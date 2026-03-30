// ToastOverlay.swift
// Majoor — In-App Toast Notification System
//
// Design reference: macOS notification banners.
// Frosted material, gentle shadow, swipe-to-dismiss.
// Compact, non-intrusive, auto-dismissing.

import SwiftUI

struct ToastOverlayView: View {
    @EnvironmentObject var taskManager: TaskManager

    var body: some View {
        VStack(spacing: 6) {
            ForEach(taskManager.toasts) { toast in
                ToastCard(toast: toast, onDismiss: {
                    taskManager.dismissToast(id: toast.id)
                })
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.95)),
                        removal: .move(edge: .top).combined(with: .opacity)
                    )
                )
            }
        }
        .padding(.horizontal, DT.Spacing.md)
        .padding(.top, DT.Spacing.sm)
        .animation(DT.Anim.normal, value: taskManager.toasts.count)
    }
}

struct ToastCard: View {
    let toast: Toast
    var onDismiss: () -> Void
    @State private var dragOffset: CGFloat = 0
    @State private var isHovered = false

    private var iconConfig: (name: String, color: Color) {
        switch toast.type {
        case .info:    return ("checkmark.circle.fill", .green)
        case .error:   return ("exclamationmark.triangle.fill", .red)
        case .warning: return ("exclamationmark.circle.fill", .orange)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: DT.Spacing.sm) {
            Image(systemName: iconConfig.name)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(iconConfig.color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: DT.Spacing.xxs) {
                Text(toast.title)
                    .font(DT.Font.caption(.semibold))
                    .lineLimit(1)
                Text(toast.body)
                    .font(DT.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: DT.Spacing.xs)

            if let actionLabel = toast.actionLabel, let action = toast.action {
                Button(actionLabel) {
                    action()
                    onDismiss()
                }
                .font(DT.Font.caption(.medium))
                .foregroundStyle(Color.accentColor)
                .buttonStyle(.plain)
            }

            // Dismiss button — only on hover to reduce visual noise
            if isHovered {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, DT.Spacing.md)
        .padding(.vertical, DT.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DT.Radius.medium, style: .continuous)
                .fill(.thinMaterial)
        )
        .toastShadow()
        .overlay(
            RoundedRectangle(cornerRadius: DT.Radius.medium, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.04), lineWidth: 0.5)
        )
        .offset(x: dragOffset)
        .opacity(dragOffset > 0 ? Double(max(0, 1.0 - dragOffset / 120.0)) : 1.0)
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragOffset = max(0, value.translation.width)
                }
                .onEnded { value in
                    if value.translation.width > 60 {
                        withAnimation(DT.Anim.fast) { onDismiss() }
                    } else {
                        withAnimation(DT.Anim.spring) { dragOffset = 0 }
                    }
                }
        )
        .onHover { hovering in
            withAnimation(DT.Anim.fast) { isHovered = hovering }
        }
    }
}
