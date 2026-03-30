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
            // Search + count
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Search memories", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.body)
                Spacer()
                Text("\(memoryCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            // Memory list
            if filteredMemories.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "brain")
                        .font(.system(size: 28))
                        .foregroundStyle(.quaternary)
                    Text(memories.isEmpty ? "No memories yet" : "No results")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    if memories.isEmpty {
                        Text("Majoor learns as you use it.\nTry: \"Remember that I prefer dark mode\"")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
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
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            Divider()

            // Footer
            HStack {
                Button(role: .destructive) {
                    showClearConfirmation = true
                } label: {
                    Text("Clear All...")
                }
                .disabled(memories.isEmpty)
                .buttonStyle(.plain)
                .foregroundColor(memories.isEmpty ? .secondary : .red)
                .font(.caption)

                Spacer()

                Button {
                    loadMemories()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
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

    @State private var isHovered = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(memory.category.displayName)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(categoryColor.opacity(0.12))
                .foregroundStyle(categoryColor)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(memory.content)
                    .font(.system(size: 12))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(memory.createdAt.formatted(date: .abbreviated, time: .omitted))
                    if memory.accessCount > 0 {
                        Text("\u{00B7}")
                        Text("used \(memory.accessCount)\u{00D7}")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(isHovered ? .red : .clear)
            }
            .buttonStyle(.plain)
            .alert("Delete Memory?", isPresented: $showDeleteConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { onDelete() }
            } message: {
                Text("This memory will be permanently deleted.")
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
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
