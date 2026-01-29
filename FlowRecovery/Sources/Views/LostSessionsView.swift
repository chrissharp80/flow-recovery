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

/// View for displaying and recovering lost sessions from backups
struct LostSessionsView: View {
    @EnvironmentObject var collector: RRCollector
    @Environment(\.dismiss) private var dismiss
    @Environment(\.editMode) private var editMode

    @State private var lostSessions: [(id: UUID, date: Date, beatCount: Int)] = []
    @State private var isLoading = true
    @State private var isRecovering = false
    @State private var recoveryProgress: (current: Int, total: Int)?
    @State private var currentSessionDate: Date?
    @State private var recoveredCount = 0
    @State private var failedCount = 0
    @State private var showingResult = false
    @State private var resultMessage = ""
    @State private var selectedSessions: Set<UUID> = []
    @State private var showingDeleteConfirmation = false

    private var isEditing: Bool {
        editMode?.wrappedValue.isEditing ?? false
    }

    var body: some View {
        List(selection: $selectedSessions) {
            if isLoading {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Scanning backups...")
                                .font(.subheadline)
                                .foregroundColor(AppTheme.textSecondary)
                        }
                        .padding()
                        Spacer()
                    }
                }
            } else if lostSessions.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 40))
                                .foregroundColor(AppTheme.sage)
                            Text("No Lost Sessions")
                                .font(.headline)
                                .foregroundColor(AppTheme.textPrimary)
                            Text("All backup sessions are already in your archive.")
                                .font(.subheadline)
                                .foregroundColor(AppTheme.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        Spacer()
                    }
                }
            } else {
                // Header with explanation
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("\(lostSessions.count) Lost Sessions Found")
                                .font(.headline)
                        }
                        Text("These sessions have raw RR data backups but are missing from your archive. This can happen if the app was reinstalled or if data was corrupted.")
                            .font(.caption)
                            .foregroundColor(AppTheme.textSecondary)
                    }
                    .padding(.vertical, 4)
                }

                // Session list
                Section("Sessions") {
                    ForEach(lostSessions, id: \.id) { session in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(formatDate(session.date))
                                    .font(.subheadline)
                                    .foregroundColor(AppTheme.textPrimary)
                                Text("\(session.beatCount) RR intervals")
                                    .font(.caption)
                                    .foregroundColor(AppTheme.textSecondary)
                            }
                            Spacer()
                            Text(formatDuration(session.beatCount))
                                .font(.caption)
                                .foregroundColor(AppTheme.textTertiary)
                        }
                        .tag(session.id)
                    }
                    .onDelete(perform: deleteSessionsAtOffsets)
                }

                // Recovery progress or button
                Section {
                    if isRecovering {
                        VStack(spacing: 12) {
                            if let progress = recoveryProgress {
                                ProgressView(value: Double(progress.current), total: Double(progress.total))
                                    .tint(AppTheme.primary)

                                HStack {
                                    Text("Recovering \(progress.current) of \(progress.total)...")
                                        .font(.subheadline)
                                        .foregroundColor(AppTheme.textSecondary)
                                    Spacer()
                                    if recoveredCount > 0 || failedCount > 0 {
                                        Text("\(recoveredCount) OK, \(failedCount) failed")
                                            .font(.caption)
                                            .foregroundColor(AppTheme.textTertiary)
                                    }
                                }

                                if let date = currentSessionDate {
                                    Text("Processing: \(formatDate(date))")
                                        .font(.caption)
                                        .foregroundColor(AppTheme.textTertiary)
                                }
                            } else {
                                ProgressView()
                                Text("Starting recovery...")
                                    .font(.subheadline)
                                    .foregroundColor(AppTheme.textSecondary)
                            }
                        }
                        .padding(.vertical, 8)
                    } else {
                        Button {
                            recoverAllSessions()
                        } label: {
                            HStack {
                                Spacer()
                                Image(systemName: "arrow.counterclockwise.circle.fill")
                                Text("Recover All \(lostSessions.count) Sessions")
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }
                        .tint(AppTheme.primary)
                    }
                }
            }
        }
        .navigationTitle("Lost Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !lostSessions.isEmpty && !isRecovering {
                    EditButton()
                }
            }
            ToolbarItem(placement: .bottomBar) {
                if isEditing && !selectedSessions.isEmpty {
                    Button(role: .destructive) {
                        showingDeleteConfirmation = true
                    } label: {
                        Label("Delete \(selectedSessions.count) Selected", systemImage: "trash")
                    }
                }
            }
        }
        .task {
            await loadLostSessions()
        }
        .alert("Recovery Complete", isPresented: $showingResult) {
            Button("OK") {
                if recoveredCount > 0 {
                    dismiss()
                }
            }
        } message: {
            Text(resultMessage)
        }
        .confirmationDialog(
            "Delete \(selectedSessions.count) Session\(selectedSessions.count == 1 ? "" : "s")?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deleteSelectedSessions()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These sessions will be removed from the lost sessions list. The raw backup data will be kept for 90 days.")
        }
    }

    private func loadLostSessions() async {
        // Get collector reference on main actor, then run check
        let collectorRef = collector
        let sessions = await Task.detached(priority: .userInitiated) {
            await collectorRef.checkForLostSessions()
        }.value

        // Sort by date, newest first
        lostSessions = sessions.sorted { $0.date > $1.date }
        isLoading = false
    }

    private func deleteSessionsAtOffsets(_ offsets: IndexSet) {
        let idsToDelete = offsets.map { lostSessions[$0].id }
        collector.deleteLostSessions(idsToDelete)
        lostSessions.remove(atOffsets: offsets)
    }

    private func deleteSelectedSessions() {
        let idsToDelete = Array(selectedSessions)
        collector.deleteLostSessions(idsToDelete)
        lostSessions.removeAll { selectedSessions.contains($0.id) }
        selectedSessions.removeAll()
        editMode?.wrappedValue = .inactive
    }

    private func recoverAllSessions() {
        isRecovering = true
        recoveredCount = 0
        failedCount = 0

        Task {
            let total = lostSessions.count

            for (index, session) in lostSessions.enumerated() {
                await MainActor.run {
                    recoveryProgress = (index + 1, total)
                    currentSessionDate = session.date
                }

                // Recover on background thread
                let recovered = await collector.recoverFromBackup(session.id)

                await MainActor.run {
                    if recovered != nil {
                        recoveredCount += 1
                    } else {
                        failedCount += 1
                    }
                }

                // Small yield to keep UI responsive
                await Task.yield()
            }

            await MainActor.run {
                isRecovering = false
                recoveryProgress = nil
                currentSessionDate = nil

                if recoveredCount == total {
                    resultMessage = "Successfully recovered all \(recoveredCount) sessions."
                } else if recoveredCount > 0 {
                    resultMessage = "Recovered \(recoveredCount) of \(total) sessions. \(failedCount) could not be recovered (may have insufficient data)."
                } else {
                    resultMessage = "Could not recover any sessions. The backup data may be incomplete or corrupted."
                }
                showingResult = true

                // Refresh the list
                Task {
                    await loadLostSessions()
                }
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatDuration(_ beatCount: Int) -> String {
        // Rough estimate: ~60 bpm average = 1 beat per second
        let minutes = beatCount / 60
        if minutes < 60 {
            return "~\(minutes) min"
        } else {
            let hours = minutes / 60
            let remainingMins = minutes % 60
            return "~\(hours)h \(remainingMins)m"
        }
    }
}

#Preview {
    NavigationStack {
        LostSessionsView()
            .environmentObject(RRCollector())
    }
}
