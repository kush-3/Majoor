// MemorySettingsView.swift
// Majoor — Memory Management UI

import SwiftUI

struct MemorySettingsView: View {
    @State private var memories: [Memory] = []
    @State private var searchText = ""
    @State private var showClearConfirmation = false
    @State private var memoryCount = 0

    var filteredMemories: [Memory] {
        if searchText.isEmpty { return memories }
        return memories.filter { $0.content.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                TextField("Search memories...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Text("\(memoryCount) memories")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Memory list
            if filteredMemories.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "brain")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text(memories.isEmpty ? "No memories yet" : "No matching memories")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    if memories.isEmpty {
                        Text("Majoor will remember things as you use it.\nTry: \"Remember that I prefer dark mode\"")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                Spacer()
            } else {
                List {
                    ForEach(filteredMemories) { memory in
                        MemoryRow(memory: memory, onDelete: {
                            deleteMemory(memory)
                        })
                    }
                }
                .listStyle(.plain)
            }

            // Footer
            HStack {
                Button("Clear All") { showClearConfirmation = true }
                    .disabled(memories.isEmpty)
                    .font(.caption)
                Spacer()
                Button("Refresh") { loadMemories() }
                    .font(.caption)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .onAppear { loadMemories() }
        .alert("Clear All Memories?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) { clearAll() }
        } message: {
            Text("This will permanently delete all \(memoryCount) memories. This cannot be undone.")
        }
    }

    private func loadMemories() {
        memories = (try? MemoryStore.shared.allMemories()) ?? []
        memoryCount = memories.count
    }

    private func deleteMemory(_ memory: Memory) {
        try? MemoryStore.shared.delete(id: memory.id)
        loadMemories()
    }

    private func clearAll() {
        try? MemoryStore.shared.deleteAll()
        loadMemories()
    }
}

struct MemoryRow: View {
    let memory: Memory
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Category badge
            Text(memory.category.displayName)
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(categoryColor.opacity(0.15))
                .foregroundColor(categoryColor)
                .cornerRadius(4)

            VStack(alignment: .leading, spacing: 2) {
                Text(memory.content)
                    .font(.system(size: 12))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(memory.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    if memory.accessCount > 0 {
                        Text("used \(memory.accessCount)x")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private var categoryColor: Color {
        switch memory.category {
        case .preference: return .blue
        case .fact: return .green
        case .context: return .orange
        case .habit: return .purple
        }
    }
}
