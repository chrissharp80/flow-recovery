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

/// Shared Peak Capacity card showing highest sustained HRV metrics
/// Used by DashboardView, HistoryDetailView, and MorningResultsView
struct PeakCapacityCard: View {
    let capacity: PeakCapacity
    var showInfoButton: Bool = false

    @State private var showingInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            if showInfoButton {
                Button {
                    showingInfo = true
                } label: {
                    headerContent
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingInfo) {
                    CapacityExplanationPopover()
                }
            } else {
                headerContent
            }

            // Metrics row
            HStack(spacing: 16) {
                // Peak RMSSD
                VStack(spacing: 2) {
                    Text("Max RMSSD")
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text(String(format: "%.0f", capacity.peakRMSSD))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.sage)
                        Text("ms")
                            .font(.caption)
                            .foregroundColor(AppTheme.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity)

                Divider()
                    .frame(height: 36)

                // Peak SDNN
                VStack(spacing: 2) {
                    Text("Max SDNN")
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text(String(format: "%.0f", capacity.peakSDNN))
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.sdnnColor)
                        Text("ms")
                            .font(.caption)
                            .foregroundColor(AppTheme.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity)

                // Window HR (if available)
                if let meanHR = capacity.windowMeanHR {
                    Divider()
                        .frame(height: 36)

                    VStack(spacing: 2) {
                        Text("Window HR")
                            .font(.caption)
                            .foregroundColor(AppTheme.textSecondary)
                        HStack(alignment: .lastTextBaseline, spacing: 2) {
                            Text(String(format: "%.0f", meanHR))
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .foregroundColor(AppTheme.terracotta)
                            Text("bpm")
                                .font(.caption)
                                .foregroundColor(AppTheme.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            // Brief explanation
            Text("Highest sustained HRV during sleep — your physiological ceiling, separate from readiness.")
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .zenCard()
    }

    private var headerContent: some View {
        HStack {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.to.line")
                    .foregroundColor(AppTheme.sage)
                Text("Autonomic Capacity")
                    .font(.headline)
                    .foregroundColor(AppTheme.textPrimary)
                if showInfoButton {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundColor(AppTheme.textTertiary)
                }
            }
            Spacer()
            Text("\(String(format: "%.0f", capacity.windowDurationMinutes)) min window")
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
    }
}

/// Popover explaining autonomic capacity vs readiness
struct CapacityExplanationPopover: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Autonomic Capacity")
                    .font(.headline)
                    .foregroundColor(AppTheme.textPrimary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(AppTheme.textTertiary)
                }
            }

            Text("The highest sustained HRV values observed during your sleep — your physiological ceiling, not a readiness indicator.")
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("What it measures:")
                    .font(.caption.bold())
                    .foregroundColor(AppTheme.textPrimary)

                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundColor(AppTheme.sage)
                        .font(.caption)
                    Text("Peak parasympathetic activation during deep sleep")
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)
                }

                HStack(spacing: 8) {
                    Image(systemName: "clock.fill")
                        .foregroundColor(AppTheme.mist)
                        .font(.caption)
                    Text("Sustained window (not isolated spikes)")
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)
                }
            }

            Divider()

            Text("High capacity ≠ high readiness. Your body may achieve peak HRV during deep sleep while still being fatigued overall.")
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
                .italic()
        }
        .padding()
        .frame(width: 300)
        .background(AppTheme.cardBackground)
    }
}
