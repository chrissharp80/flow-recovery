//
//  Copyright © 2024-2026 Chris Sharp. All rights reserved.
//
//  This source code is provided for reference and verification purposes only.
//  Unauthorized copying, modification, distribution, or use of this code,
//  via any medium, is strictly prohibited without prior written permission.
//
//  For licensing inquiries, contact the copyright holder.
//

import SwiftUI

/// Main tab-based navigation for the app
struct MainTabView: View {
    @EnvironmentObject var collector: RRCollector
    @StateObject private var settingsManager = SettingsManager.shared
    @State private var selectedTab: Tab = .dashboard
    @State private var sessions: [HRVSession] = []
    @State private var selectedReportSession: HRVSession?

    enum Tab: String, CaseIterable {
        case dashboard = "Recovery"
        case record = "Record"
        case history = "History"
        case trends = "Trends"
        case settings = "Settings"

        var icon: String {
            switch self {
            case .dashboard: return "heart.text.square"
            case .record: return "waveform.circle"
            case .history: return "list.bullet.rectangle"
            case .trends: return "chart.line.uptrend.xyaxis"
            case .settings: return "gearshape"
            }
        }

        var iconFilled: String {
            switch self {
            case .dashboard: return "heart.text.square.fill"
            case .record: return "waveform.circle.fill"
            case .history: return "list.bullet.rectangle.fill"
            case .trends: return "chart.line.uptrend.xyaxis"
            case .settings: return "gearshape.fill"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            // Dashboard Tab (Recovery Dashboard)
            NavigationStack {
                RecoveryDashboardView(
                    sessions: sessions,
                    onStartRecording: { startRecording() },
                    onViewReport: { session in
                        selectedReportSession = session
                    }
                )
                .navigationTitle("Recovery")
            }
            .tabItem {
                Label(Tab.dashboard.rawValue, systemImage: selectedTab == .dashboard ? Tab.dashboard.iconFilled : Tab.dashboard.icon)
            }
            .tag(Tab.dashboard)

            // Record Tab
            NavigationStack {
                RecordView(selectedTab: $selectedTab)
            }
            .tabItem {
                Label(Tab.record.rawValue, systemImage: selectedTab == .record ? Tab.record.iconFilled : Tab.record.icon)
            }
            .tag(Tab.record)

            // History Tab
            NavigationStack {
                HistoryView(
                    sessions: sessions,
                    onDelete: { session in
                        deleteSession(session)
                    },
                    onUpdateTags: { session, tags, notes in
                        updateTags(session: session, tags: tags, notes: notes)
                    },
                    onReanalyze: { session, method in
                        await reanalyzeSession(session, method: method)
                    }
                )
            }
            .tabItem {
                Label(Tab.history.rawValue, systemImage: selectedTab == .history ? Tab.history.iconFilled : Tab.history.icon)
            }
            .tag(Tab.history)

            // Trends Tab
            NavigationStack {
                TrendView(sessions: sessions)
            }
            .tabItem {
                Label(Tab.trends.rawValue, systemImage: Tab.trends.icon)
            }
            .tag(Tab.trends)

            // Settings Tab
            NavigationStack {
                SettingsView()
            }
            .tabItem {
                Label(Tab.settings.rawValue, systemImage: selectedTab == .settings ? Tab.settings.iconFilled : Tab.settings.icon)
            }
            .tag(Tab.settings)
        }
        .tint(.blue)
        .environmentObject(settingsManager)
        .onAppear {
            debugLog("[MainTabView] onAppear - refreshing sessions")
            refreshSessions()
        }
        .onChange(of: collector.archiveVersion) { _, newValue in
            debugLog("[MainTabView] archiveVersion changed to \(newValue) - refreshing sessions")
            refreshSessions()
        }
        .sheet(item: $selectedReportSession) { session in
            if let result = session.analysisResult {
                NavigationStack {
                    MorningResultsView(
                        session: session,
                        result: result,
                        recentSessions: sessions,
                        onDiscard: { selectedReportSession = nil }
                    )
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Done") {
                                selectedReportSession = nil
                            }
                        }
                    }
                }
            }
        }
    }

    private func refreshSessions() {
        debugLog("[MainTabView] refreshSessions: fetching from collector.archivedSessions")
        sessions = collector.archivedSessions
        debugLog("[MainTabView] refreshSessions: got \(sessions.count) sessions")
        let completeSessions = sessions.filter { $0.state == .complete }
        debugLog("[MainTabView] refreshSessions: \(completeSessions.count) are complete")
    }

    private func startRecording() {
        selectedTab = .record
    }

    private func deleteSession(_ session: HRVSession) {
        do {
            try collector.archive.delete(session.id)
            collector.notifyArchiveChanged()
        } catch {
            debugLog("Failed to delete session: \(error)")
        }
    }

    private func updateTags(session: HRVSession, tags: [ReadingTag], notes: String?) {
        do {
            try collector.archive.updateTags(session.id, tags: tags, notes: notes)
            collector.notifyArchiveChanged()
        } catch {
            debugLog("Failed to update tags: \(error)")
        }
    }

    private func reanalyzeSession(_ session: HRVSession, method: WindowSelectionMethod) async -> HRVSession? {
        let updated = await collector.reanalyzeSession(session, method: method)
        if updated != nil {
            // Refresh sessions list to reflect updated analysis
            await MainActor.run {
                sessions = collector.archivedSessions
            }
        }
        return updated
    }
}

#Preview {
    MainTabView()
        .environmentObject(RRCollector())
}
