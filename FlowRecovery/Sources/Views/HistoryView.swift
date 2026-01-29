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
import QuickLook

/// History view showing all recorded sessions with filtering and delete
struct HistoryView: View {
    @EnvironmentObject var collector: RRCollector

    let sessions: [HRVSession]
    let onDelete: (HRVSession) -> Void
    let onUpdateTags: (HRVSession, [ReadingTag], String?) -> Void
    var onReanalyze: ((HRVSession, WindowSelectionMethod) async -> HRVSession?)? = nil

    @State private var selectedTags: Set<ReadingTag> = []
    @State private var searchText = ""
    @State private var sessionToDelete: HRVSession?
    @State private var showingDeleteConfirmation = false
    @State private var selectedSession: HRVSession?
    @State private var selectedSessionType: SessionType? = nil  // nil = All

    private var filteredSessions: [HRVSession] {
        var result = sessions.filter { $0.state == .complete }

        // Filter by session type
        if let typeFilter = selectedSessionType {
            result = result.filter { $0.sessionType == typeFilter }
        }

        // Filter by tags
        if !selectedTags.isEmpty {
            result = result.filter { session in
                !selectedTags.isDisjoint(with: Set(session.tags))
            }
        }

        // Filter by search text
        if !searchText.isEmpty {
            result = result.filter { session in
                let dateFormatter = DateFormatter()
                dateFormatter.dateStyle = .medium
                let dateString = dateFormatter.string(from: session.startDate)
                return dateString.localizedCaseInsensitiveContains(searchText) ||
                    session.tags.contains { $0.name.localizedCaseInsensitiveContains(searchText) } ||
                    (session.notes?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }

        return result.sorted { $0.startDate > $1.startDate }
    }

    private var groupedSessions: [(String, [HRVSession])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredSessions) { session -> String in
            if calendar.isDateInToday(session.startDate) {
                return "Today"
            } else if calendar.isDateInYesterday(session.startDate) {
                return "Yesterday"
            } else if calendar.isDate(session.startDate, equalTo: Date(), toGranularity: .weekOfYear) {
                return "This Week"
            } else if let weekAgo = calendar.date(byAdding: .weekOfYear, value: -1, to: Date()),
                      calendar.isDate(session.startDate, equalTo: weekAgo, toGranularity: .weekOfYear) {
                return "Last Week"
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "MMMM yyyy"
                return formatter.string(from: session.startDate)
            }
        }

        let order = ["Today", "Yesterday", "This Week", "Last Week"]
        return grouped.sorted { first, second in
            let idx1 = order.firstIndex(of: first.key) ?? Int.max
            let idx2 = order.firstIndex(of: second.key) ?? Int.max
            if idx1 != idx2 {
                return idx1 < idx2
            }
            // For months, sort by date descending
            if let date1 = first.value.first?.startDate,
               let date2 = second.value.first?.startDate {
                return date1 > date2
            }
            return first.key < second.key
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Session Type Filter
            sessionTypeFilterBar
                .padding(.horizontal)
                .padding(.top, 8)

            // Tag Filter Bar
            tagFilterBar
                .padding(.horizontal)
                .padding(.vertical, 8)

            if filteredSessions.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(groupedSessions, id: \.0) { section, sessions in
                        Section(section) {
                            ForEach(sessions) { session in
                                SessionHistoryRow(session: session)
                                    // Force re-render when analysis changes (uses analysisDate as version)
                                    .id("\(session.id)-\(session.analysisResult?.analysisDate.timeIntervalSince1970 ?? 0)")
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedSession = session
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            sessionToDelete = session
                                            showingDeleteConfirmation = true
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                    .swipeActions(edge: .leading) {
                                        Button {
                                            selectedSession = session
                                        } label: {
                                            Label("Edit Tags", systemImage: "tag")
                                        }
                                        .tint(.blue)
                                    }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("History")
        .searchable(text: $searchText, prompt: "Search readings")
        .onAppear {
            logSessionCounts()
        }
        .onChange(of: sessions.count) { _, _ in
            logSessionCounts()
        }
        .confirmationDialog(
            "Delete Reading",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let session = sessionToDelete {
                    onDelete(session)
                }
                sessionToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                sessionToDelete = nil
            }
        } message: {
            Text("This will permanently delete this HRV reading. This action cannot be undone.")
        }
        .sheet(item: $selectedSession) { session in
            sessionDetailSheet(for: session)
        }
    }

    // MARK: - Session Detail Sheet

    @ViewBuilder
    private func sessionDetailSheet(for session: HRVSession) -> some View {
        if let result = session.analysisResult {
            NavigationStack {
                sessionDetailContent(session: session, result: result)
            }
        } else {
            VStack {
                Text("No analysis data available")
                    .foregroundColor(AppTheme.textSecondary)
                Button("Close") { selectedSession = nil }
                    .buttonStyle(.zen())
            }
            .padding()
        }
    }

    private func sessionDetailContent(session: HRVSession, result: HRVAnalysisResult) -> some View {
        MorningResultsView(
            session: session,
            result: result,
            recentSessions: sessions.filter { $0.state == .complete },
            onDiscard: { selectedSession = nil },
            onDelete: {
                onDelete(session)
                selectedSession = nil
            },
            onReanalyze: onReanalyze,
            onUpdateTags: { tags, notes in
                onUpdateTags(session, tags, notes)
            }
        )
        .navigationTitle("HRV Report")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { selectedSession = nil }
            }
        }
    }

    // MARK: - Session Type Filter Bar

    private var sessionTypeFilterBar: some View {
        HStack(spacing: 8) {
            // All types
            SessionTypeFilterButton(
                title: "All",
                icon: "list.bullet",
                isSelected: selectedSessionType == nil,
                color: AppTheme.primary
            ) {
                selectedSessionType = nil
            }

            // Overnight
            SessionTypeFilterButton(
                title: "Overnight",
                icon: SessionType.overnight.icon,
                isSelected: selectedSessionType == .overnight,
                color: AppTheme.primary
            ) {
                selectedSessionType = .overnight
            }

            // Naps
            SessionTypeFilterButton(
                title: "Naps",
                icon: SessionType.nap.icon,
                isSelected: selectedSessionType == .nap,
                color: AppTheme.mist
            ) {
                selectedSessionType = .nap
            }

            // Quick
            SessionTypeFilterButton(
                title: "Quick",
                icon: SessionType.quick.icon,
                isSelected: selectedSessionType == .quick,
                color: AppTheme.sage
            ) {
                selectedSessionType = .quick
            }
        }
    }

    // MARK: - Tag Filter Bar

    private var tagFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // All filter
                Button {
                    selectedTags.removeAll()
                } label: {
                    Text("All")
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(selectedTags.isEmpty ? Color.blue : Color.gray.opacity(0.2))
                        .foregroundColor(selectedTags.isEmpty ? .white : .primary)
                        .cornerRadius(16)
                }

                ForEach(ReadingTag.systemTags) { tag in
                    Button {
                        if selectedTags.contains(tag) {
                            selectedTags.remove(tag)
                        } else {
                            selectedTags.insert(tag)
                        }
                    } label: {
                        Text(tag.name)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedTags.contains(tag) ? tag.color : tag.color.opacity(0.15))
                            .foregroundColor(selectedTags.contains(tag) ? .white : tag.color)
                            .cornerRadius(16)
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            if sessions.filter({ $0.state == .complete }).isEmpty {
                Text("No Readings Yet")
                    .font(.headline)
                Text("Your HRV readings will appear here")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Text("No Matching Readings")
                    .font(.headline)
                Text("Try adjusting your filters")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Button("Clear Filters") {
                    selectedTags.removeAll()
                    searchText = ""
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
    }

    // MARK: - Logging

    private func logSessionCounts() {
        debugLog("[HistoryView] === SESSION COUNTS ===")
        debugLog("[HistoryView] Total sessions passed: \(sessions.count)")

        // Count by state
        let completeSessions = sessions.filter { $0.state == .complete }
        let collectingSessions = sessions.filter { $0.state == .collecting }
        let analyzingSessions = sessions.filter { $0.state == .analyzing }
        let failedSessions = sessions.filter { $0.state == .failed }

        debugLog("[HistoryView] By state: complete=\(completeSessions.count), collecting=\(collectingSessions.count), analyzing=\(analyzingSessions.count), failed=\(failedSessions.count)")

        // Count by analysis result
        let withAnalysis = sessions.filter { $0.analysisResult != nil }
        let withoutAnalysis = sessions.filter { $0.analysisResult == nil }
        debugLog("[HistoryView] With analysis: \(withAnalysis.count), Without: \(withoutAnalysis.count)")

        // Show filtered count
        debugLog("[HistoryView] Filtered sessions (shown in list): \(filteredSessions.count)")

        // Log the complete sessions
        for (i, session) in completeSessions.prefix(10).enumerated() {
            let dateStr = ISO8601DateFormatter().string(from: session.startDate)
            let rmssd = session.analysisResult?.timeDomain.rmssd ?? -1
            debugLog("[HistoryView] Complete[\(i)]: \(dateStr) RMSSD=\(String(format: "%.1f", rmssd)) ID=\(session.id.uuidString.prefix(8))")
        }
        if completeSessions.count > 10 {
            debugLog("[HistoryView] ... and \(completeSessions.count - 10) more complete sessions")
        }

        // Also log archive info from collector
        debugLog("[HistoryView] Collector archive entries: \(collector.archive.entries.count)")
        debugLog("[HistoryView] Collector archivedSessions: \(collector.archivedSessions.count)")
    }
}

// MARK: - Session Type Filter Button

private struct SessionTypeFilterButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.subheadline)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? color : color.opacity(0.15))
            .foregroundColor(isSelected ? .white : color)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Session History Row

private struct SessionHistoryRow: View {
    let session: HRVSession

    private var sessionTypeColor: Color {
        switch session.sessionType {
        case .overnight: return AppTheme.primary
        case .nap: return AppTheme.mist
        case .quick: return AppTheme.sage
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Session type indicator
            Image(systemName: session.sessionType.icon)
                .font(.title3)
                .foregroundColor(sessionTypeColor)
                .frame(width: 28)

            // Date and Time
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    // Show analysis window end time if available, otherwise session start time
                    if let result = session.analysisResult,
                       let windowEndMs = result.windowEndMs,
                       let series = session.rrSeries {
                        Text(series.absoluteTime(fromRelativeMs: windowEndMs), style: .time)
                            .font(.headline)
                    } else {
                        Text(session.startDate, style: .time)
                            .font(.headline)
                    }

                    // Show "Nap" label for nap sessions
                    if session.sessionType == .nap {
                        Text("Nap")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.mist.opacity(0.2))
                            .foregroundColor(AppTheme.mist)
                            .cornerRadius(4)
                    } else if session.sessionType == .quick {
                        Text("Quick")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppTheme.sage.opacity(0.2))
                            .foregroundColor(AppTheme.sage)
                            .cornerRadius(4)
                    }
                }

                Text(session.startDate, style: .date)
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Tags
                if !session.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(session.tags.prefix(3)) { tag in
                            Text(tag.name)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(tag.color.opacity(0.2))
                                .foregroundColor(tag.color)
                                .cornerRadius(4)
                        }
                        if session.tags.count > 3 {
                            Text("+\(session.tags.count - 3)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Spacer()

            // Metrics
            if let result = session.analysisResult {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(String(format: "%.0f", result.timeDomain.rmssd))
                            .font(.system(.title2, design: .rounded).bold())
                        Text("ms")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let readiness = result.ansMetrics?.readinessScore {
                        HStack(spacing: 4) {
                            Image(systemName: readinessIcon(readiness))
                                .foregroundColor(readinessColor(readiness))
                                .font(.caption)
                            Text(String(format: "%.1f", readiness))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func readinessIcon(_ score: Double) -> String {
        if score >= 7 { return "checkmark.circle.fill" }
        if score >= 5 { return "minus.circle.fill" }
        return "exclamationmark.circle.fill"
    }

    private func readinessColor(_ score: Double) -> Color {
        if score >= 7 { return .green }
        if score >= 5 { return .yellow }
        return .orange
    }
}

// PDFPreviewView is defined in Sources/Views/Utilities/PDFPreviewView.swift

#Preview {
    NavigationStack {
        HistoryView(
            sessions: [],
            onDelete: { _ in },
            onUpdateTags: { _, _, _ in },
            onReanalyze: nil
        )
    }
}
