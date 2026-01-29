//
//  Copyright © 2024-2026 Chris Sharp. All rights reserved.
//

import SwiftUI

/// Card displaying sleep summary from HealthKit
struct SleepSummaryCard: View {
    let sleep: HealthKitManager.SleepData
    let typicalSleepHours: Double

    init(sleep: HealthKitManager.SleepData, typicalSleepHours: Double = 7.5) {
        self.sleep = sleep
        self.typicalSleepHours = typicalSleepHours
    }

    private var sleepDurationColor: Color {
        let hours = Double(sleep.totalSleepMinutes) / 60.0
        if hours >= typicalSleepHours { return AppTheme.success }
        if hours >= typicalSleepHours - 1 { return AppTheme.mist }
        if hours >= typicalSleepHours - 2 { return AppTheme.warning }
        return AppTheme.alert
    }

    private var efficiencyColor: Color {
        if sleep.sleepEfficiency >= SleepConstants.goodEfficiency { return AppTheme.success }
        if sleep.sleepEfficiency >= SleepConstants.poorEfficiency { return AppTheme.mist }
        return AppTheme.warning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Total sleep
            HStack {
                Image(systemName: "bed.double.fill")
                    .foregroundColor(AppTheme.primary)
                Text("Sleep")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(sleep.totalSleepFormatted)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(sleepDurationColor)
            }

            Divider()

            // Metrics grid
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                metricCell(
                    icon: "chart.bar.fill",
                    label: "Efficiency",
                    value: "\(Int(sleep.sleepEfficiency))%",
                    color: efficiencyColor
                )

                if let deep = sleep.deepSleepMinutes {
                    metricCell(
                        icon: "moon.zzz.fill",
                        label: "Deep",
                        value: deep.minutesAsHoursMinutes
                    )
                }

                if let rem = sleep.remSleepMinutes {
                    metricCell(
                        icon: "brain.head.profile",
                        label: "REM",
                        value: rem.minutesAsHoursMinutes
                    )
                }

                if sleep.awakeMinutes > 0 {
                    metricCell(
                        icon: "eye.fill",
                        label: "Awake",
                        value: sleep.awakeMinutes.minutesAsHoursMinutes,
                        color: sleep.awakeMinutes > 30 ? AppTheme.warning : AppTheme.textPrimary
                    )
                }
            }

            // Sleep latency if available
            if let latency = sleep.sleepLatencyMinutes, latency > 0 {
                Divider()

                HStack {
                    Text("Time to fall asleep")
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)
                    Spacer()
                    Text("\(latency) min")
                        .font(.subheadline)
                        .foregroundColor(latency > 30 ? AppTheme.warning : AppTheme.textPrimary)
                }
            }

            // Sleep window
            if let start = sleep.sleepStart, let end = sleep.sleepEnd {
                HStack {
                    Text("Sleep window")
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)
                    Spacer()
                    Text("\(formatTime(start)) - \(formatTime(end))")
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)
                }
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(AppTheme.cornerRadius)
    }

    private func metricCell(icon: String, label: String, value: String, color: Color = AppTheme.textPrimary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(color)
                Text(label)
                    .font(.caption2)
                    .foregroundColor(AppTheme.textTertiary)
            }
            Spacer()
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}

#Preview {
    SleepSummaryCard(sleep: HealthKitManager.SleepData(
        date: Date(),
        inBedStart: Date().addingTimeInterval(-8 * 3600),
        sleepStart: Date().addingTimeInterval(-7.5 * 3600),
        sleepEnd: Date(),
        totalSleepMinutes: 420,
        inBedMinutes: 480,
        deepSleepMinutes: 90,
        remSleepMinutes: 105,
        awakeMinutes: 25,
        sleepEfficiency: 87.5,
        boundarySource: .healthKit
    ))
    .padding()
}
