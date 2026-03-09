// ActivityFeedView.swift
// Majoor — Activity Feed

import SwiftUI

struct ActivityFeedView: View {
    @EnvironmentObject var taskManager: TaskManager
    
    var body: some View {
        if taskManager.tasks.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "tray").font(.system(size: 36)).foregroundColor(.secondary.opacity(0.5))
                Text("No tasks yet").font(.system(size: 13)).foregroundColor(.secondary)
                Text("Press ⌘+Shift+Space to get started").font(.system(size: 11)).foregroundColor(.secondary.opacity(0.7))
                Spacer()
            }.frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(taskManager.tasks) { task in
                        TaskCardView(task: task)
                    }
                }.padding(12)
            }
        }
    }
}

struct TaskCardView: View {
    @ObservedObject var task: AgentTask
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 4) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(task.status.rawValue).font(.system(size: 11, weight: .medium)).foregroundColor(statusColor)
                }
                Spacer()
                Text(task.createdAt.timeAgo()).font(.system(size: 11)).foregroundColor(.secondary)
            }
            
            Text(task.userInput).font(.system(size: 13, weight: .medium)).lineLimit(isExpanded ? nil : 2)
            
            if !task.summary.isEmpty && task.status == .completed {
                Text(task.summary).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(isExpanded ? nil : 2)
            }
            
            if isExpanded {
                Divider()
                ForEach(task.steps) { step in
                    HStack(alignment: .top, spacing: 8) {
                        stepIcon(step.type).frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.description).font(.system(size: 11)).lineLimit(3)
                            if let d = step.detail { Text(d).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).lineLimit(4) }
                        }
                    }
                }
            }
            
            HStack {
                if !task.steps.isEmpty {
                    Button(isExpanded ? "Collapse" : "View Details") { withAnimation { isExpanded.toggle() } }
                        .font(.system(size: 11)).buttonStyle(.plain).foregroundColor(.accentColor)
                }
                Spacer()
                if task.tokensUsed > 0 {
                    Text("\(task.modelUsed) · \(task.tokensUsed) tokens").font(.system(size: 10)).foregroundColor(.secondary.opacity(0.7))
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }
    
    private var statusColor: Color {
        switch task.status {
        case .running: return .orange
        case .completed: return .green
        case .failed: return .red
        case .waiting: return .blue
        }
    }
    
    private func stepIcon(_ type: TaskStep.StepType) -> some View {
        switch type {
        case .thinking: return Image(systemName: "brain").font(.system(size: 10)).foregroundColor(.purple)
        case .toolCall: return Image(systemName: "wrench").font(.system(size: 10)).foregroundColor(.orange)
        case .toolResult: return Image(systemName: "checkmark.circle").font(.system(size: 10)).foregroundColor(.green)
        case .response: return Image(systemName: "text.bubble").font(.system(size: 10)).foregroundColor(.blue)
        case .error: return Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundColor(.red)
        }
    }
}

extension Date {
    func timeAgo() -> String {
        let s = Int(-timeIntervalSinceNow)
        if s < 60 { return "Just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}
