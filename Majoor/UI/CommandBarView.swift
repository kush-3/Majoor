// CommandBarView.swift
// Majoor — Command Bar Input

import SwiftUI

struct CommandBarView: View {
    @State private var inputText = ""
    @FocusState private var isFocused: Bool
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.accentColor)
                .frame(width: 24)
            
            TextField("What can I help with?", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused($isFocused)
                .onSubmit { submitCommand() }
                .onExitCommand { onCancel() }
            
            if !inputText.isEmpty {
                Button(action: submitCommand) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial).shadow(color: .black.opacity(0.15), radius: 20, y: 10))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.1), lineWidth: 1))
        .frame(width: 600)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { isFocused = true } }
    }
    
    private func submitCommand() {
        let t = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onSubmit(t)
        inputText = ""
    }
}
