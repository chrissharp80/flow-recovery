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
import Charts

/// Detailed training load view showing ATL/CTL trends and workout history
struct TrainingDetailView: View {
    let trainingMetrics: HealthKitManager.TrainingMetrics?
    let trainingContext: TrainingContext?

    private var metrics: (atl: Double, ctl: Double, tsb: Double, acr: Double?)? {
        if let m = trainingMetrics {
            return (m.atl, m.ctl, m.tsb, m.acuteChronicRatio)
        }
        if let c = trainingContext {
            return (c.atl, c.ctl, c.tsb, c.acuteChronicRatio)
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // ACR Gauge Hero
                acrCard

                // ATL/CTL/TSB Stats
                metricsCard

                // Training Zones Explanation
                zonesExplanation

                // Recent Workouts
                if let context = trainingContext, let workouts = context.recentWorkouts, !workouts.isEmpty {
                    recentWorkoutsCard(workouts)
                }
            }
            .padding()
        }
        .background(AppTheme.background)
        .navigationTitle("Training Load")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - ACR Card

    private var acrCard: some View {
        VStack(spacing: 16) {
            Text("ACUTE:CHRONIC RATIO")
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.textTertiary)
                .tracking(1)

            if let m = metrics, let acr = m.acr {
                // Large ACR display
                Text(String(format: "%.2f", acr))
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundColor(acrColor(acr))

                Text(acrLabel(acr))
                    .font(.headline)
                    .foregroundColor(acrColor(acr))

                // Gauge bar
                ACRGaugeBar(acr: acr)
                    .padding(.horizontal)
            } else {
                Text("--")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    // MARK: - Metrics Card

    private var metricsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("TRAINING METRICS")
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.textTertiary)
                .tracking(1)

            if let m = metrics {
                HStack(spacing: 16) {
                    MetricColumn(
                        label: "ATL",
                        value: String(format: "%.0f", m.atl),
                        subtitle: "Fatigue (7-day)",
                        color: AppTheme.terracotta
                    )
                    MetricColumn(
                        label: "CTL",
                        value: String(format: "%.0f", m.ctl),
                        subtitle: "Fitness (42-day)",
                        color: AppTheme.sage
                    )
                    MetricColumn(
                        label: "TSB",
                        value: String(format: "%+.0f", m.tsb),
                        subtitle: "Form",
                        color: m.tsb >= 0 ? AppTheme.sage : AppTheme.terracotta
                    )
                }
            } else {
                Text("No training data available")
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    // MARK: - Zones Explanation

    private var zonesExplanation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ACR TRAINING ZONES")
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.textTertiary)
                .tracking(1)

            VStack(spacing: 8) {
                ZoneRow(range: "< 0.8", label: "Undertraining", description: "Fitness declining", color: .blue)
                ZoneRow(range: "0.8 - 1.0", label: "Maintenance", description: "Maintaining fitness", color: .green.opacity(0.7))
                ZoneRow(range: "1.0 - 1.3", label: "Optimal", description: "Building fitness safely", color: .green)
                ZoneRow(range: "1.3 - 1.5", label: "Overreaching", description: "High load, monitor recovery", color: .yellow)
                ZoneRow(range: "> 1.5", label: "Injury Risk", description: "Reduce training load", color: .red)
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    // MARK: - Recent Workouts

    private func recentWorkoutsCard(_ workouts: [WorkoutSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("RECENT WORKOUTS")
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.textTertiary)
                .tracking(1)

            ForEach(workouts.prefix(7), id: \.date) { workout in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(workout.type)
                            .font(.subheadline.weight(.medium))
                        Text(workout.date, style: .date)
                            .font(.caption)
                            .foregroundColor(AppTheme.textTertiary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(workout.durationMinutes) min")
                            .font(.subheadline)
                            .foregroundColor(AppTheme.textSecondary)
                        Text("TRIMP: \(Int(workout.trimp))")
                            .font(.caption)
                            .foregroundColor(AppTheme.primary)
                    }
                }
                .padding(.vertical, 8)

                if workout.date != workouts.prefix(7).last?.date {
                    Divider()
                }
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    // MARK: - Helpers

    private func acrColor(_ acr: Double) -> Color {
        if acr < 0.8 { return .blue }
        if acr <= 1.0 { return .green.opacity(0.8) }
        if acr <= 1.3 { return AppTheme.sage }
        if acr <= 1.5 { return AppTheme.softGold }
        return AppTheme.dustyRose
    }

    private func acrLabel(_ acr: Double) -> String {
        if acr < 0.8 { return "Undertraining" }
        if acr <= 1.0 { return "Maintenance" }
        if acr <= 1.3 { return "Optimal Load" }
        if acr <= 1.5 { return "High Load" }
        return "Injury Risk"
    }
}

// MARK: - Supporting Views

private struct MetricColumn: View {
    let label: String
    let value: String
    let subtitle: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.textTertiary)
            Text(value)
                .font(.title.weight(.bold))
                .foregroundColor(color)
            Text(subtitle)
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ACRGaugeBar: View {
    let acr: Double

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background zones
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.blue.opacity(0.4))
                            .frame(width: geo.size.width * 0.25)
                        Rectangle().fill(Color.green.opacity(0.4))
                            .frame(width: geo.size.width * 0.25)
                        Rectangle().fill(Color.yellow.opacity(0.4))
                            .frame(width: geo.size.width * 0.25)
                        Rectangle().fill(Color.red.opacity(0.4))
                            .frame(width: geo.size.width * 0.25)
                    }
                    .cornerRadius(8)

                    // Indicator
                    let position = min(max((acr - 0.5) / 1.2, 0), 1)
                    Circle()
                        .fill(.white)
                        .frame(width: 20, height: 20)
                        .shadow(radius: 2)
                        .offset(x: geo.size.width * position - 10)
                }
            }
            .frame(height: 20)

            // Labels
            HStack {
                Text("0.5")
                    .font(.caption2)
                    .foregroundColor(AppTheme.textTertiary)
                Spacer()
                Text("1.0")
                    .font(.caption2)
                    .foregroundColor(AppTheme.textTertiary)
                Spacer()
                Text("1.5")
                    .font(.caption2)
                    .foregroundColor(AppTheme.textTertiary)
            }
        }
    }
}

private struct ZoneRow: View {
    let range: String
    let label: String
    let description: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color)
                .frame(width: 4, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(range)
                        .font(.caption.monospaced())
                        .foregroundColor(AppTheme.textTertiary)
                    Text(label)
                        .font(.subheadline.weight(.medium))
                }
                Text(description)
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }

            Spacer()
        }
    }
}

#Preview {
    NavigationStack {
        TrainingDetailView(
            trainingMetrics: nil,
            trainingContext: nil
        )
    }
}
