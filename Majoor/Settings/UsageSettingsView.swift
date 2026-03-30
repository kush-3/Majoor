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
            Section {
                HStack(spacing: 12) {
                    UsageCard(title: "Today", usage: todayUsage)
                    UsageCard(title: "This Week", usage: weekUsage)
                    UsageCard(title: "This Month", usage: monthUsage)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Cost Summary")
            }

            Section {
                if modelBreakdown.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "chart.bar")
                            .font(.system(size: 24))
                            .foregroundStyle(.quaternary)
                        Text("No usage data yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else {
                    ForEach(modelBreakdown, id: \.model) { entry in
                        LabeledContent {
                            HStack(spacing: 16) {
                                Text(formatTokens(entry.tokens))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 60, alignment: .trailing)
                                Text(formatCost(entry.cost))
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .frame(width: 64, alignment: .trailing)
                            }
                        } label: {
                            Text(friendlyModel(entry.model))
                        }
                    }
                }
            } header: {
                Text("Usage by Model (30 days)")
            }
        }
        .formStyle(.grouped)
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
        VStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let usage {
                Text(usage.totalCost < 0.01 ? "< $0.01" : String(format: "$%.2f", usage.totalCost))
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                Text("\(usage.taskCount) tasks")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                Text("--")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.quaternary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: DT.Radius.small, style: .continuous)
                .fill(.primary.opacity(0.03))
        )
    }
}
