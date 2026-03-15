// ToastOverlay.swift
// Majoor — In-App Toast Notification System
//
// Floating toast cards that appear at the top of the panel.
// Replaces macOS notifications as the primary feedback mechanism.

import SwiftUI

struct ToastOverlayView: View {
    @EnvironmentObject var taskManager: TaskManager

    var body: some View {
        VStack(spacing: 8) {
            ForEach(taskManager.toasts) { toast in
                ToastCard(toast: toast, onDismiss: {
                    withAnimation(.easeOut(duration: 0.2)) {
                        taskManager.dismissToast(id: toast.id)
                    }
                })
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.25), value: taskManager.toasts.count)
    }
}

struct ToastCard: View {
    let toast: Toast
    var onDismiss: () -> Void

    private var iconName: String {
        switch toast.type {
        case .info: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .warning: return "exclamationmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch toast.type {
        case .info: return .green
        case .error: return .red
        case .warning: return .orange
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(toast.body)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }

            Spacer(minLength: 4)

            if let actionLabel = toast.actionLabel, let action = toast.action {
                Button(actionLabel) {
                    action()
                    onDismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .font(.system(size: 10, weight: .medium))
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 16, height: 16)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
}
