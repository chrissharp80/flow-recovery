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

/// Detailed sleep view showing stages, efficiency, and breakdown
struct SleepDetailView: View {
    let sleepData: HealthKitManager.SleepData?
    let typicalSleepHours: Double

    private var sleepHours: Double {
        guard let sleep = sleepData else { return 0 }
        return Double(sleep.totalSleepMinutes) / 60.0
    }

    private var sleepCompletion: Double {
        guard typicalSleepHours > 0 else { return 0 }
        return min(1.0, sleepHours / typicalSleepHours)
    }

    /// Calculate a composite sleep score (0-100)
    private var sleepScore: Int {
        guard let sleep = sleepData else { return 0 }

        var score: Double = 0

        // Duration (40 points max)
        let durationScore = min(40, (sleepHours / typicalSleepHours) * 40)
        score += durationScore

        // Efficiency (30 points max)
        let efficiency = min(100, sleep.sleepEfficiency)
        let efficiencyScore = (efficiency / 100) * 30
        score += efficiencyScore

        // Deep sleep (15 points max) - ideal is 15-20% of total
        if let deep = sleep.deepSleepMinutes, sleep.totalSleepMinutes > 0 {
            let deepPercent = Double(deep) / Double(sleep.totalSleepMinutes) * 100
            let deepScore = min(15, (deepPercent / 20) * 15)
            score += deepScore
        } else {
            score += 7.5 // Partial credit if no stage data
        }

        // REM sleep (15 points max) - ideal is 20-25% of total
        if let rem = sleep.remSleepMinutes, sleep.totalSleepMinutes > 0 {
            let remPercent = Double(rem) / Double(sleep.totalSleepMinutes) * 100
            let remScore = min(15, (remPercent / 25) * 15)
            score += remScore
        } else {
            score += 7.5 // Partial credit if no stage data
        }

        return Int(min(100, max(0, score)))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Sleep Score Hero
                sleepScoreCard

                // Sleep Duration
                sleepDurationCard

                // Sleep Timing
                if let sleep = sleepData, sleep.sleepStart != nil {
                    sleepTimingCard(sleep)
                }

                // Sleep Stages
                if let sleep = sleepData {
                    sleepStagesCard(sleep)
                }

                // Sleep Metrics Grid
                if let sleep = sleepData {
                    sleepMetricsGrid(sleep)
                }

                // Sleep Quality Assessment
                sleepQualityCard

                // Tips
                sleepTipsCard
            }
            .padding()
        }
        .background(AppTheme.background)
        .navigationTitle("Sleep Analysis")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Sleep Score Card

    private var sleepScoreCard: some View {
        VStack(spacing: 16) {
            Text("SLEEP SCORE")
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.textTertiary)
                .tracking(1)

            ZStack {
                // Background ring
                Circle()
                    .stroke(scoreColor.opacity(0.2), lineWidth: 12)

                // Progress ring
                Circle()
                    .trim(from: 0, to: CGFloat(sleepScore) / 100)
                    .stroke(
                        AngularGradient(
                            colors: [scoreColor.opacity(0.6), scoreColor],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 4) {
                    Text("\(sleepScore)")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundColor(scoreColor)
                    Text(scoreLabel)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(AppTheme.textSecondary)
                }
            }
            .frame(width: 140, height: 140)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    private var scoreColor: Color {
        if sleepScore >= 85 { return AppTheme.sage }
        if sleepScore >= 70 { return AppTheme.softGold }
        if sleepScore >= 50 { return AppTheme.terracotta }
        return AppTheme.dustyRose
    }

    private var scoreLabel: String {
        if sleepScore >= 85 { return "Excellent" }
        if sleepScore >= 70 { return "Good" }
        if sleepScore >= 50 { return "Fair" }
        return "Poor"
    }

    // MARK: - Sleep Duration Card

    private var sleepDurationCard: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "moon.fill")
                    .foregroundColor(AppTheme.primary)
                Text("DURATION")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.textTertiary)
                    .tracking(1)
                Spacer()
            }

            if let sleep = sleepData {
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(String(format: "%.1f", sleepHours))
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundColor(sleepColor)
                    Text("hrs")
                        .font(.title3)
                        .foregroundColor(AppTheme.textTertiary)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text("In Bed")
                            .font(.caption)
                            .foregroundColor(AppTheme.textTertiary)
                        Text(formatMinutes(sleep.inBedMinutes))
                            .font(.headline)
                    }
                }

                // Progress toward goal
                VStack(spacing: 8) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(AppTheme.sectionTint)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(sleepColor)
                                .frame(width: geo.size.width * sleepCompletion)

                            // Goal marker
                            if sleepCompletion < 1.0 {
                                Rectangle()
                                    .fill(AppTheme.textTertiary)
                                    .frame(width: 2)
                                    .offset(x: geo.size.width - 1)
                            }
                        }
                    }
                    .frame(height: 8)

                    HStack {
                        Text(String(format: "%.0f%% of %.0fh goal", sleepCompletion * 100, typicalSleepHours))
                            .font(.caption)
                            .foregroundColor(AppTheme.textSecondary)
                        Spacer()
                        if sleepCompletion >= 1.0 {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(AppTheme.sage)
                                Text("Goal met!")
                                    .foregroundColor(AppTheme.sage)
                            }
                            .font(.caption.weight(.medium))
                        }
                    }
                }
            } else {
                Text("No Data")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.textTertiary)
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    // MARK: - Sleep Timing Card

    private func sleepTimingCard(_ sleep: HealthKitManager.SleepData) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "clock.fill")
                    .foregroundColor(AppTheme.primary)
                Text("SLEEP WINDOW")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.textTertiary)
                    .tracking(1)
                Spacer()
            }

            HStack {
                // Bedtime
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "bed.double.fill")
                            .font(.caption)
                            .foregroundColor(AppTheme.textTertiary)
                        Text("Asleep")
                            .font(.caption)
                            .foregroundColor(AppTheme.textTertiary)
                    }
                    if let start = sleep.sleepStart {
                        Text(start, style: .time)
                            .font(.title2.weight(.semibold))
                    } else {
                        Text("--:--")
                            .font(.title2.weight(.semibold))
                            .foregroundColor(AppTheme.textTertiary)
                    }
                }

                Spacer()

                // Duration in middle
                VStack(spacing: 4) {
                    Image(systemName: "arrow.right")
                        .foregroundColor(AppTheme.textTertiary)
                    Text(formatMinutes(sleep.totalSleepMinutes))
                        .font(.caption.weight(.medium))
                        .foregroundColor(AppTheme.textSecondary)
                }

                Spacer()

                // Wake time
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Awake")
                            .font(.caption)
                            .foregroundColor(AppTheme.textTertiary)
                        Image(systemName: "sun.max.fill")
                            .font(.caption)
                            .foregroundColor(AppTheme.softGold)
                    }
                    if let end = sleep.sleepEnd {
                        Text(end, style: .time)
                            .font(.title2.weight(.semibold))
                    } else {
                        Text("--:--")
                            .font(.title2.weight(.semibold))
                            .foregroundColor(AppTheme.textTertiary)
                    }
                }
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    // MARK: - Sleep Stages Card

    private func sleepStagesCard(_ sleep: HealthKitManager.SleepData) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(AppTheme.primary)
                Text("SLEEP STAGES")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.textTertiary)
                    .tracking(1)
                Spacer()
            }

            let hasStages = sleep.deepSleepMinutes != nil || sleep.remSleepMinutes != nil

            if hasStages {
                let deep = sleep.deepSleepMinutes ?? 0
                let rem = sleep.remSleepMinutes ?? 0
                let light = max(0, sleep.totalSleepMinutes - deep - rem)
                let awake = sleep.awakeMinutes
                let total = sleep.inBedMinutes

                // Visual bar
                HStack(spacing: 0) {
                    if deep > 0 { stageBar(minutes: deep, total: total, color: .indigo) }
                    if light > 0 { stageBar(minutes: light, total: total, color: .blue) }
                    if rem > 0 { stageBar(minutes: rem, total: total, color: .cyan) }
                    if awake > 0 { stageBar(minutes: awake, total: total, color: .orange) }
                }
                .frame(height: 24)
                .cornerRadius(12)

                // Stage details
                VStack(spacing: 12) {
                    StageRow(
                        color: .indigo,
                        label: "Deep Sleep",
                        minutes: deep,
                        percent: sleep.totalSleepMinutes > 0 ? Double(deep) / Double(sleep.totalSleepMinutes) * 100 : 0,
                        idealRange: "15-20%",
                        icon: "powersleep"
                    )
                    StageRow(
                        color: .blue,
                        label: "Light Sleep",
                        minutes: light,
                        percent: sleep.totalSleepMinutes > 0 ? Double(light) / Double(sleep.totalSleepMinutes) * 100 : 0,
                        idealRange: "40-50%",
                        icon: "moon.haze"
                    )
                    StageRow(
                        color: .cyan,
                        label: "REM Sleep",
                        minutes: rem,
                        percent: sleep.totalSleepMinutes > 0 ? Double(rem) / Double(sleep.totalSleepMinutes) * 100 : 0,
                        idealRange: "20-25%",
                        icon: "brain.head.profile"
                    )
                    StageRow(
                        color: .orange,
                        label: "Awake",
                        minutes: awake,
                        percent: total > 0 ? Double(awake) / Double(total) * 100 : 0,
                        idealRange: "<10%",
                        icon: "eye"
                    )
                }
            } else {
                // No stage data
                VStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle")
                        Text("Sleep stage data requires Apple Watch")
                    }
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textTertiary)

                    HStack(spacing: 16) {
                        BasicStatCell(label: "Asleep", value: formatMinutes(sleep.totalSleepMinutes))
                        BasicStatCell(label: "Awake", value: formatMinutes(sleep.awakeMinutes))
                        BasicStatCell(label: "In Bed", value: formatMinutes(sleep.inBedMinutes))
                    }
                }
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    @ViewBuilder
    private func stageBar(minutes: Int, total: Int, color: Color) -> some View {
        let fraction = total > 0 ? CGFloat(minutes) / CGFloat(total) : 0
        Rectangle()
            .fill(color)
            .frame(width: nil)
            .layoutPriority(Double(fraction))
    }

    // MARK: - Sleep Metrics Grid

    private func sleepMetricsGrid(_ sleep: HealthKitManager.SleepData) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .foregroundColor(AppTheme.primary)
                Text("KEY METRICS")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.textTertiary)
                    .tracking(1)
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                MetricCell(
                    icon: "percent",
                    label: "Efficiency",
                    value: String(format: "%.0f%%", min(100, sleep.sleepEfficiency)),
                    status: sleep.sleepEfficiency >= 85 ? .good : (sleep.sleepEfficiency >= 75 ? .fair : .poor),
                    detail: "Time asleep vs in bed"
                )

                MetricCell(
                    icon: "clock.badge.exclamationmark",
                    label: "Awake Time",
                    value: formatMinutes(sleep.awakeMinutes),
                    status: sleep.awakeMinutes < 20 ? .good : (sleep.awakeMinutes < 40 ? .fair : .poor),
                    detail: "WASO"
                )

                MetricCell(
                    icon: "moon.zzz",
                    label: "Sleep Time",
                    value: formatMinutes(sleep.totalSleepMinutes),
                    status: sleep.totalSleepMinutes >= Int(typicalSleepHours * 60 * 0.9) ? .good : (sleep.totalSleepMinutes >= Int(typicalSleepHours * 60 * 0.75) ? .fair : .poor),
                    detail: "Actual sleep"
                )

                MetricCell(
                    icon: "bed.double",
                    label: "Time in Bed",
                    value: formatMinutes(sleep.inBedMinutes),
                    status: .neutral,
                    detail: "Total window"
                )

                if let latency = sleep.sleepLatencyMinutes {
                    MetricCell(
                        icon: "hourglass",
                        label: "Sleep Latency",
                        value: formatMinutes(latency),
                        status: sleepLatencyStatus(latency),
                        detail: "Time to fall asleep"
                    )
                }
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    // MARK: - Sleep Quality Card

    private var sleepQualityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checklist")
                    .foregroundColor(AppTheme.primary)
                Text("QUALITY CHECK")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.textTertiary)
                    .tracking(1)
                Spacer()
            }

            if let sleep = sleepData {
                VStack(spacing: 8) {
                    QualityCheckRow(
                        label: "Duration",
                        status: sleepHours >= typicalSleepHours ? "Goal met" : String(format: "%.1f hrs short", typicalSleepHours - sleepHours),
                        isGood: sleepHours >= typicalSleepHours * 0.9
                    )
                    QualityCheckRow(
                        label: "Efficiency",
                        status: "\(Int(min(100, sleep.sleepEfficiency)))% (target: 85%+)",
                        isGood: sleep.sleepEfficiency >= 85
                    )
                    QualityCheckRow(
                        label: "Interruptions",
                        status: sleep.awakeMinutes < 20 ? "Minimal (\(sleep.awakeMinutes)m)" : "\(sleep.awakeMinutes) min awake",
                        isGood: sleep.awakeMinutes < 30
                    )

                    if let deep = sleep.deepSleepMinutes, sleep.totalSleepMinutes > 0 {
                        let deepPercent = Double(deep) / Double(sleep.totalSleepMinutes) * 100
                        QualityCheckRow(
                            label: "Deep Sleep",
                            status: String(format: "%.0f%% (target: 15-20%%)", deepPercent),
                            isGood: deepPercent >= 13 && deepPercent <= 23
                        )
                    }

                    if let rem = sleep.remSleepMinutes, sleep.totalSleepMinutes > 0 {
                        let remPercent = Double(rem) / Double(sleep.totalSleepMinutes) * 100
                        QualityCheckRow(
                            label: "REM Sleep",
                            status: String(format: "%.0f%% (target: 20-25%%)", remPercent),
                            isGood: remPercent >= 18 && remPercent <= 28
                        )
                    }
                }
            } else {
                Text("No sleep data available")
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textTertiary)
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    // MARK: - Sleep Tips Card

    private var sleepTipsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(AppTheme.softGold)
                Text("SLEEP INSIGHTS")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.textTertiary)
                    .tracking(1)
                Spacer()
            }

            ForEach(generateSleepInsights(), id: \.self) { insight in
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(AppTheme.primary)
                        .frame(width: 6, height: 6)
                        .padding(.top, 6)
                    Text(insight)
                        .font(.subheadline)
                        .foregroundColor(AppTheme.textSecondary)
                }
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    private func generateSleepInsights() -> [String] {
        var insights: [String] = []

        guard let sleep = sleepData else {
            insights.append("Record sleep data to get personalized insights.")
            return insights
        }

        // Duration insights
        if sleepHours < typicalSleepHours * 0.75 {
            insights.append("Your sleep was significantly shorter than your goal. Try to get to bed earlier tonight to recover.")
        } else if sleepHours >= typicalSleepHours {
            insights.append("Great job meeting your sleep goal!")
        }

        // Efficiency insights
        if sleep.sleepEfficiency < 75 {
            insights.append("Low sleep efficiency suggests difficulty staying asleep. Limit caffeine and screen time before bed.")
        } else if sleep.sleepEfficiency >= 90 {
            insights.append("Excellent sleep efficiency! You're sleeping well for the time spent in bed.")
        }

        // Stage insights
        if let deep = sleep.deepSleepMinutes, sleep.totalSleepMinutes > 0 {
            let deepPercent = Double(deep) / Double(sleep.totalSleepMinutes) * 100
            if deepPercent < 10 {
                insights.append("Low deep sleep affects physical recovery. Avoid alcohol and exercise earlier in the day.")
            }
        }

        if let rem = sleep.remSleepMinutes, sleep.totalSleepMinutes > 0 {
            let remPercent = Double(rem) / Double(sleep.totalSleepMinutes) * 100
            if remPercent < 15 {
                insights.append("Low REM sleep affects memory and learning. Try to maintain consistent sleep times.")
            }
        }

        // Awake time
        if sleep.awakeMinutes > 45 {
            insights.append("High wake time during the night. Consider addressing environmental factors (temperature, noise, light).")
        }

        if insights.isEmpty {
            insights.append("Your sleep metrics look balanced. Keep up the good habits!")
        }

        return insights
    }

    // MARK: - Helpers

    /// Sleep latency status: falling asleep too fast (<5 min) indicates sleep deprivation,
    /// ideal is 10-20 minutes, too slow (>30 min) indicates difficulty falling asleep
    private func sleepLatencyStatus(_ latency: Int) -> MetricCell.MetricStatus {
        if latency < 5 {
            return .poor  // Sleep deprivation - falling asleep too fast
        } else if latency < 10 {
            return .fair  // Slightly fast, may indicate tiredness
        } else if latency <= 20 {
            return .good  // Ideal range
        } else if latency <= 30 {
            return .fair  // Slightly slow
        } else {
            return .poor  // Difficulty falling asleep
        }
    }

    private var sleepColor: Color {
        if sleepCompletion >= 1.0 { return AppTheme.sage }
        if sleepCompletion >= 0.85 { return AppTheme.softGold }
        return AppTheme.terracotta
    }

    private func formatMinutes(_ minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 {
            return "\(hours)h \(mins)m"
        }
        return "\(mins)m"
    }
}

// MARK: - Supporting Views

private struct StageRow: View {
    let color: Color
    let label: String
    let minutes: Int
    let percent: Double
    let idealRange: String
    let icon: String

    private var isInRange: Bool {
        // Simplified check based on label
        switch label {
        case "Deep Sleep": return percent >= 13 && percent <= 23
        case "Light Sleep": return percent >= 35 && percent <= 55
        case "REM Sleep": return percent >= 18 && percent <= 28
        case "Awake": return percent < 12
        default: return true
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)

            Image(systemName: icon)
                .font(.subheadline)
                .foregroundColor(color)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                Text("Ideal: \(idealRange)")
                    .font(.caption2)
                    .foregroundColor(AppTheme.textTertiary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(String(format: "%.0f%%", percent))
                    .font(.headline)
                    .foregroundColor(isInRange ? AppTheme.sage : AppTheme.terracotta)
                Text("\(minutes / 60)h \(minutes % 60)m")
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct BasicStatCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
            Text(value)
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MetricCell: View {
    let icon: String
    let label: String
    let value: String
    let status: MetricStatus
    let detail: String

    enum MetricStatus {
        case good, fair, poor, neutral

        var color: Color {
            switch self {
            case .good: return AppTheme.sage
            case .fair: return AppTheme.softGold
            case .poor: return AppTheme.terracotta
            case .neutral: return AppTheme.textPrimary
            }
        }

        var icon: String? {
            switch self {
            case .good: return "checkmark.circle.fill"
            case .fair: return "minus.circle.fill"
            case .poor: return "exclamationmark.circle.fill"
            case .neutral: return nil
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(AppTheme.textTertiary)
                Spacer()
                if let statusIcon = status.icon {
                    Image(systemName: statusIcon)
                        .foregroundColor(status.color)
                }
            }

            Text(value)
                .font(.title2.weight(.bold))
                .foregroundColor(status.color)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.medium))
                Text(detail)
                    .font(.caption2)
                    .foregroundColor(AppTheme.textTertiary)
            }
        }
        .padding()
        .background(AppTheme.sectionTint)
        .cornerRadius(12)
    }
}

private struct QualityCheckRow: View {
    let label: String
    let status: String
    let isGood: Bool

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: isGood ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundColor(isGood ? AppTheme.sage : AppTheme.terracotta)
                Text(status)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(isGood ? AppTheme.sage : AppTheme.terracotta)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        SleepDetailView(
            sleepData: nil,
            typicalSleepHours: 8.0
        )
    }
}
