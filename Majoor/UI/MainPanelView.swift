// MainPanelView.swift
// Majoor — Dropdown Panel

import SwiftUI

struct MainPanelView: View {
    @EnvironmentObject var taskManager: TaskManager
    @State private var selectedTab = 0
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill").font(.system(size: 14, weight: .semibold)).foregroundColor(.accentColor)
                    Text("Majoor").font(.system(size: 14, weight: .semibold))
                }
                Spacer()
                Picker("", selection: $selectedTab) {
                    Text("Activity").tag(0)
                    Text("Chat").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            
            Divider()
            
            if selectedTab == 0 {
                ActivityFeedView().environmentObject(taskManager)
            } else {
                VStack { Spacer()
                    Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 36)).foregroundColor(.secondary.opacity(0.5))
                    Text("Chat mode coming in Phase 2").font(.system(size: 13)).foregroundColor(.secondary)
                    Spacer()
                }.frame(maxWidth: .infinity)
            }
        }
        .frame(width: 380, height: 500)
        .background(.regularMaterial)
    }
}
