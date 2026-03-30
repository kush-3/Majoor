// UsageSettingsView.swift
// Majoor — Token Usage & Cost Display

import SwiftUI

struct UsageSettingsView: View {
    @State private var todayUsage: UsageStore.UsageSummary?
    @State private var weekUsage: UsageStore.UsageSummary?
    @State private var monthUsage: UsageStore.UsageSummary?
    @State private var modelBreakdown: [(model: String, tokens: Int, cost: Double)] = []

    var body: some View {
        Form {
            Section("Cost Summary") {
                HStack {
                    UsageCard(title: "Today", usage: todayUsage)
                    UsageCard(title: "This Week", usage: weekUsage)
                    UsageCard(title: "This Month", usage: monthUsage)
                }
            }

            Section("Usage by Model (30 days)") {
                if modelBreakdown.isEmpty {
                    VStack(spacing: DT.Spacing.sm) {
                        Image(systemName: "chart.bar")
                            .font(.system(size: 24))
                            .foregroundStyle(.quaternary)
                        Text("No usage data yet")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DT.Spacing.sm)
                } else {
                    ForEach(modelBreakdown, id: \.model) { entry in
                        HStack {
                            Text(friendlyModel(entry.model))
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text(formatTokens(entry.tokens))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text(formatCost(entry.cost))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { loadUsage() }
    }

    private func loadUsage() {
        todayUsage = UsageStore.shared.todayUsage()
        weekUsage = UsageStore.shared.weekUsage()
        monthUsage = UsageStore.shared.monthUsage()
        modelBreakdown = UsageStore.shared.usageByModel(days: 30)
    }

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.01 { return "< $0.01" }
        return String(format: "$%.2f", cost)
    }
}

struct UsageCard: View {
    let title: String
    let usage: UsageStore.UsageSummary?

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
            if let usage {
                Text(usage.totalCost < 0.01 ? "< $0.01" : String(format: "$%.2f", usage.totalCost))
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                Text("\(usage.taskCount) tasks")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else {
                Text("--")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: DT.Radius.small).fill(Color.primary.opacity(DT.Opacity.cardFill)))
    }
}
