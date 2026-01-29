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

/// View for managing deleted sessions (trash bin)
/// Shows sessions that were intentionally deleted and can be restored or permanently removed
struct TrashView: View {
    @EnvironmentObject var collector: RRCollector
    @State private var deletedSessions: [(id: UUID, date: Date, beatCount: Int)] = []
    @State private var isRestoring = false
    @State private var restoringId: UUID?
    @State private var showingClearAllConfirmation = false
    @State private var statusMessage: String?

    var body: some View {
        List {
            if deletedSessions.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "trash.slash")
                            .font(.system(size: 48))
                            .foregroundColor(AppTheme.textTertiary)
                        Text("Trash is Empty")
                            .font(.headline)
                            .foregroundColor(AppTheme.textSecondary)
                        Text("Deleted sessions will appear here for recovery")
                            .font(.caption)
                            .foregroundColor(AppTheme.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                }
            } else {
                Section {
                    ForEach(deletedSessions, id: \.id) { session in
                        deletedSessionRow(session)
                    }
                } header: {
                    Text("\(deletedSessions.count) Deleted Sessions")
                } footer: {
                    Text("Deleted sessions are kept until permanently removed or until backups are purged (90 days).")
                }

                Section {
                    Button(role: .destructive) {
                        showingClearAllConfirmation = true
                    } label: {
                        HStack {
                            Image(systemName: "trash.fill")
                            Text("Permanently Delete All")
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            if let message = statusMessage {
                Section {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(AppTheme.sage)
                }
            }
        }
        .navigationTitle("Trash")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadDeletedSessions()
        }
        .confirmationDialog(
            "Permanently Delete All?",
            isPresented: $showingClearAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) {
                permanentlyDeleteAll()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently remove all \(deletedSessions.count) deleted sessions. This cannot be undone.")
        }
    }

    // MARK: - Deleted Session Row

    private func deletedSessionRow(_ session: (id: UUID, date: Date, beatCount: Int)) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(formatDate(session.date))
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(AppTheme.textPrimary)
                Text("\(session.beatCount) beats")
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }

            Spacer()

            if isRestoring && restoringId == session.id {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                HStack(spacing: 16) {
                    // Restore button
                    Button {
                        restoreSession(session.id)
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .font(.title2)
                            .foregroundColor(AppTheme.sage)
                    }
                    .buttonStyle(.plain)

                    // Permanent delete button
                    Button {
                        permanentlyDelete(session.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(AppTheme.terracotta)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func loadDeletedSessions() {
        deletedSessions = collector.checkForDeletedSessions()
    }

    private func restoreSession(_ id: UUID) {
        isRestoring = true
        restoringId = id

        Task {
            if let _ = await collector.restoreFromTrash(id) {
                await MainActor.run {
                    statusMessage = "Session restored successfully"
                    loadDeletedSessions()
                    isRestoring = false
                    restoringId = nil

                    // Clear message after delay
                    Task {
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                        await MainActor.run {
                            statusMessage = nil
                        }
                    }
                }
            } else {
                await MainActor.run {
                    statusMessage = "Failed to restore session"
                    isRestoring = false
                    restoringId = nil
                }
            }
        }
    }

    private func permanentlyDelete(_ id: UUID) {
        collector.permanentlyDelete(id)
        loadDeletedSessions()
    }

    private func permanentlyDeleteAll() {
        for session in deletedSessions {
            collector.permanentlyDelete(session.id)
        }
        loadDeletedSessions()
        statusMessage = "All deleted sessions permanently removed"

        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await MainActor.run {
                statusMessage = nil
            }
        }
    }

    // MARK: - Helpers

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

#Preview {
    NavigationStack {
        TrashView()
            .environmentObject(RRCollector())
    }
}
