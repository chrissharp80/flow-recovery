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

/// Dashboard showing today's summary and quick insights
struct DashboardView: View {
    let sessions: [HRVSession]
    let onStartRecording: () -> Void
    let onViewReport: (HRVSession) -> Void
    var onViewHistory: (() -> Void)? = nil
    @EnvironmentObject var settingsManager: SettingsManager

    private var todaySessions: [HRVSession] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return sessions.filter { calendar.isDate($0.startDate, inSameDayAs: today) && $0.state == .complete }
    }

    private var morningReading: HRVSession? {
        // First check for explicit morning tag
        if let tagged = todaySessions.first(where: { $0.tags.contains { $0.id == ReadingTag.morning.id } }) {
            return tagged
        }

        // Consider overnight recordings that ended today (before noon) as morning readings
        // These are typically started the previous evening and run through the night
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let noon = calendar.date(byAdding: .hour, value: 12, to: today)!

        // Look for any session that:
        // 1. Ended today before noon (covers overnight recordings)
        // 2. Or started today before noon with duration > 1 hour (covers long morning recordings)
        let overnightReading = sessions.filter { session in
            guard session.state == .complete, let endDate = session.endDate else { return false }
            // Session ended today before noon
            let endedTodayMorning = endDate >= today && endDate < noon
            // Session is long (overnight) - more than 2 hours
            let isOvernight = (session.duration ?? 0) > 7200
            return endedTodayMorning && isOvernight
        }.sorted { $0.startDate > $1.startDate }.first

        if let overnight = overnightReading {
            return overnight
        }

        // Fall back to any session completed today in the morning hours
        return todaySessions.first { session in
            guard let endDate = session.endDate else { return false }
            let hour = calendar.component(.hour, from: endDate)
            return hour < 12
        }
    }

    private var latestReading: HRVSession? {
        sessions.filter { $0.state == .complete }.sorted { $0.startDate > $1.startDate }.first
    }

    private var weekSessions: [HRVSession] {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return sessions.filter { $0.startDate >= weekAgo && $0.state == .complete }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Hero Card - Today's Morning Reading
                heroCard

                // Recovery Summary (when we have a reading)
                if let morning = morningReading, let result = morning.analysisResult {
                    recoverySummarySection(result: result)

                    // Peak Capacity (highest sustained HRV)
                    if let capacity = result.peakCapacity {
                        PeakCapacityCard(capacity: capacity)
                    }
                }

                // Quick Stats Row
                quickStatsRow

                // Recent Insights
                insightsSection

                // 7-Day Trend Sparkline
                weekTrendSection
            }
            .padding()
        }
        .navigationTitle("Dashboard")
        .background(AppTheme.background.ignoresSafeArea())
    }

    // MARK: - Hero Card

    private var heroCard: some View {
        VStack(spacing: 16) {
            if let morning = morningReading, let result = morning.analysisResult {
                // Has morning reading
                VStack(spacing: 12) {
                    HStack(alignment: .top) {
                        // Left side: HRV with baseline, HR with nadir
                        VStack(alignment: .leading, spacing: 12) {
                            // HRV block
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Morning HRV")
                                    .font(.caption.weight(.medium))
                                    .foregroundColor(.white.opacity(0.7))
                                HStack(alignment: .lastTextBaseline, spacing: 4) {
                                    Text(String(format: "%.0f", result.timeDomain.rmssd))
                                        .font(.system(size: 40, weight: .bold, design: .rounded))
                                        .foregroundColor(.white)
                                    Text("ms")
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.7))
                                    // Baseline % inline
                                    if let baseline = settingsManager.settings.baselineRMSSD {
                                        let diff = ((result.timeDomain.rmssd - baseline) / baseline) * 100
                                        HStack(spacing: 2) {
                                            Image(systemName: diff >= 0 ? "arrow.up.right" : "arrow.down.right")
                                                .font(.caption2)
                                            Text(String(format: "%+.0f%%", diff))
                                                .font(.caption.weight(.semibold))
                                        }
                                        .foregroundColor(diff >= 0 ? AppTheme.sage : AppTheme.softGold)
                                        .padding(.leading, 4)
                                    }
                                }
                            }

                            // HR block with nadir
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Resting HR")
                                    .font(.caption.weight(.medium))
                                    .foregroundColor(.white.opacity(0.7))
                                HStack(alignment: .lastTextBaseline, spacing: 8) {
                                    HStack(alignment: .lastTextBaseline, spacing: 4) {
                                        Text(String(format: "%.0f", result.timeDomain.meanHR))
                                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                                            .foregroundColor(.white)
                                        Text("bpm")
                                            .font(.caption)
                                            .foregroundColor(.white.opacity(0.7))
                                    }
                                    // Nadir (minimum HR)
                                    HStack(spacing: 3) {
                                        Image(systemName: "arrow.down")
                                            .font(.caption2)
                                        Text(String(format: "%.0f", result.timeDomain.minHR))
                                            .font(.caption.weight(.semibold))
                                        Text("min")
                                            .font(.caption2)
                                    }
                                    .foregroundColor(.white.opacity(0.6))
                                }
                            }
                        }
                        Spacer()
                        readinessIndicator(result: result)
                    }

                    // View Full Report button
                    Button(action: { onViewReport(morning) }) {
                        HStack {
                            Image(systemName: "doc.text.magnifyingglass")
                            Text("View Full Report")
                        }
                        .font(.headline)
                        .foregroundColor(AppTheme.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white)
                        .cornerRadius(AppTheme.smallCornerRadius)
                    }
                }
            } else if let latest = latestReading, let result = latest.analysisResult {
                // No morning reading but has latest
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: "sunrise.fill")
                            .foregroundColor(AppTheme.softGold)
                        Text("No morning reading yet")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.8))
                        Spacer()
                        Text(latest.startDate, style: .relative)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }

                    HStack(alignment: .bottom) {
                        // HRV
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Latest HRV")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                            HStack(alignment: .lastTextBaseline, spacing: 4) {
                                Text(String(format: "%.0f", result.timeDomain.rmssd))
                                    .font(.system(size: 36, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                Text("ms")
                                    .font(.subheadline)
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        }
                        Spacer()
                        // HR
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Resting HR")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.7))
                            HStack(alignment: .lastTextBaseline, spacing: 4) {
                                Text(String(format: "%.0f", result.timeDomain.meanHR))
                                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white)
                                Text("bpm")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        }
                    }

                    Button(action: onStartRecording) {
                        Label("Take Morning Reading", systemImage: "sunrise.fill")
                            .font(.headline)
                            .foregroundColor(AppTheme.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white)
                            .cornerRadius(AppTheme.smallCornerRadius)
                    }
                }
            } else {
                // No readings at all
                VStack(spacing: 16) {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 44))
                        .foregroundColor(.white.opacity(0.8))

                    Text("Welcome")
                        .font(.title2.weight(.semibold))
                        .foregroundColor(.white)

                    Text("Begin your journey to understanding your heart's rhythm")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.8))
                        .multilineTextAlignment(.center)

                    Button(action: onStartRecording) {
                        Label("Start First Reading", systemImage: "waveform.circle.fill")
                            .font(.headline)
                            .foregroundColor(AppTheme.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.white)
                            .cornerRadius(AppTheme.smallCornerRadius)
                    }
                }
            }
        }
        .heroCard()
    }

    private func readinessIndicator(result: HRVAnalysisResult) -> some View {
        VStack(spacing: 4) {
            if let readiness = result.ansMetrics?.readinessScore {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: readiness / 10)
                        .stroke(
                            AppTheme.readinessColor(readiness),
                            style: StrokeStyle(lineWidth: 6, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(String(format: "%.1f", readiness))
                            .font(.system(.title3, design: .rounded).bold())
                            .foregroundColor(.white)
                        Text("/10")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                .frame(width: 65, height: 65)
                Text("Readiness")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }

    // MARK: - Recovery Summary

    private func recoverySummarySection(result: HRVAnalysisResult) -> some View {
        let readiness = result.ansMetrics?.readinessScore ?? 5.0
        let insight = generateTrendInsight(result: result)

        return VStack(alignment: .leading, spacing: 14) {
            // Header
            HStack {
                Image(systemName: "brain.head.profile")
                    .foregroundColor(AppTheme.primary)
                Text("Today's Insight")
                    .font(.headline)
                    .foregroundColor(AppTheme.textPrimary)
                Spacer()
                // Readiness badge
                HStack(spacing: 4) {
                    Text(String(format: "%.1f", readiness))
                        .font(.subheadline.bold())
                    Text("/10")
                        .font(.caption)
                }
                .foregroundColor(AppTheme.readinessColor(readiness))
            }

            // Main insight paragraph - the substantial content
            Text(insight)
                .font(.subheadline)
                .foregroundColor(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)

            // HR Dip indicator (when available)
            if let hrDip = result.ansMetrics?.nocturnalHRDip {
                Divider()
                hrDipIndicator(dip: hrDip, ansMetrics: result.ansMetrics)
            }
        }
        .zenCard()
    }

    /// Generate a substantial trend insight paragraph like the full report's "AI Trend Insight"
    private func generateTrendInsight(result: HRVAnalysisResult) -> String {
        let rmssd = result.timeDomain.rmssd
        let meanHR = result.timeDomain.meanHR
        let stress = result.ansMetrics?.stressIndex
        let hrDip = result.ansMetrics?.nocturnalHRDip
        let readiness = result.ansMetrics?.readinessScore ?? 5.0

        // Calculate baselines
        let recentSessions = sessions.filter { $0.state == .complete && $0.analysisResult != nil }
            .sorted { $0.startDate > $1.startDate }
        let baseline = computeBaseline(from: recentSessions)

        var parts: [String] = []

        // Part 1: HRV comparison to baseline
        if let avgRMSSD = baseline.avgRMSSD {
            let pctDiff = ((rmssd - avgRMSSD) / avgRMSSD) * 100
            if pctDiff > 25 {
                parts.append("Your HRV is significantly elevated at \(Int(rmssd)) ms (+\(Int(pctDiff))% vs your baseline), indicating excellent parasympathetic recovery.")
            } else if pctDiff > 10 {
                parts.append("Your HRV of \(Int(rmssd)) ms is \(Int(pctDiff))% above your baseline, suggesting good recovery.")
            } else if pctDiff < -25 {
                parts.append("Your HRV is notably suppressed at \(Int(rmssd)) ms (\(Int(abs(pctDiff)))% below baseline), indicating your autonomic nervous system is under strain.")
            } else if pctDiff < -10 {
                parts.append("Your HRV of \(Int(rmssd)) ms is \(Int(abs(pctDiff)))% below your baseline.")
            } else {
                parts.append("Your HRV of \(Int(rmssd)) ms is within your normal range.")
            }
        } else {
            // No baseline yet
            if rmssd >= 50 {
                parts.append("Your HRV of \(Int(rmssd)) ms indicates strong vagal tone.")
            } else if rmssd >= 30 {
                parts.append("Your HRV of \(Int(rmssd)) ms is in a moderate range.")
            } else {
                parts.append("Your HRV of \(Int(rmssd)) ms is on the lower side, suggesting elevated physiological load.")
            }
        }

        // Part 2: HR context
        if let avgHR = baseline.avgHR {
            let hrDiff = meanHR - avgHR
            if hrDiff < -5 {
                parts.append("Resting heart rate is \(Int(abs(hrDiff))) bpm lower than your average, a positive sign of cardiovascular efficiency or deep rest.")
            } else if hrDiff > 8 {
                parts.append("Resting HR is elevated by \(Int(hrDiff)) bpm — this often indicates accumulated stress, dehydration, or your body fighting something off.")
            } else if hrDiff > 5 {
                parts.append("Resting HR is slightly elevated (+\(Int(hrDiff)) bpm vs average).")
            }
        }

        // Part 3: Stress index interpretation
        if let si = stress {
            if si < 80 && readiness >= 7 {
                parts.append("Low stress markers (SI: \(Int(si))) confirm your nervous system is well-balanced.")
            } else if si > 250 {
                parts.append("Your stress index of \(Int(si)) is elevated, indicating sympathetic nervous system activation.")
            } else if si > 180 && readiness < 6 {
                parts.append("Elevated stress index (\(Int(si))) suggests incomplete recovery.")
            }
        }

        // Part 4: HR dip context
        if let dip = hrDip {
            if dip < 8 {
                parts.append("Your HR only dropped \(Int(dip))% overnight (blunted dip), which can indicate poor sleep quality or residual stress.")
            } else if dip > 22 {
                parts.append("Deep overnight HR drop (\(Int(dip))%) suggests very relaxed sleep, though values above 20% can sometimes indicate overtraining.")
            } else if dip >= 10 && dip <= 20 {
                // Normal - only mention if we haven't said much else
                if parts.count < 2 {
                    parts.append("Your overnight HR dip of \(Int(dip))% is in the healthy range.")
                }
            }
        }

        // Part 5: Weekly trend if available
        let weekSessions = recentSessions.prefix(7)
        if weekSessions.count >= 5 {
            let weekRMSSD = weekSessions.compactMap { $0.analysisResult?.timeDomain.rmssd }
            let firstHalf = Array(weekRMSSD.suffix(3))
            let secondHalf = Array(weekRMSSD.prefix(3))
            if !firstHalf.isEmpty && !secondHalf.isEmpty {
                let oldAvg = firstHalf.reduce(0, +) / Double(firstHalf.count)
                let newAvg = secondHalf.reduce(0, +) / Double(secondHalf.count)
                let trendPct = ((newAvg - oldAvg) / oldAvg) * 100
                if trendPct > 10 {
                    parts.append("Your 7-day HRV trend is improving (+\(Int(trendPct))%) — keep doing what you're doing.")
                } else if trendPct < -15 {
                    parts.append("Your HRV has been declining over the past week (\(Int(trendPct))%). Consider prioritizing recovery.")
                }
            }
        }

        // Part 6: Actionable guidance based on readiness
        if readiness >= 7.5 {
            parts.append("You're well-recovered and ready for high-intensity training or challenging activities.")
        } else if readiness >= 6 {
            parts.append("Normal activity and moderate training should be fine today.")
        } else if readiness >= 4 {
            parts.append("Consider lighter activity today and prioritize quality sleep tonight.")
        } else {
            parts.append("Your body is signaling it needs rest. Focus on recovery — gentle movement, hydration, and early bedtime.")
        }

        return parts.joined(separator: " ")
    }

    /// HR Dip indicator showing nocturnal HR drop with interpretation
    private func hrDipIndicator(dip: Double, ansMetrics: ANSMetrics?) -> some View {
        let (label, color) = hrDipInterpretation(dip: dip)

        return HStack(spacing: 12) {
            // HR values
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill")
                        .foregroundColor(color)
                        .font(.caption)
                    Text("HR Dip")
                        .font(.caption.weight(.medium))
                        .foregroundColor(AppTheme.textSecondary)
                }

                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(format: "%.0f", dip))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundColor(color)
                    Text("%")
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)
                }
            }

            Spacer()

            // Interpretation
            VStack(alignment: .trailing, spacing: 2) {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundColor(color)

                if let daytime = ansMetrics?.daytimeRestingHR, let sleep = ansMetrics?.nocturnalMedianHR {
                    Text("\(Int(daytime)) → \(Int(sleep)) bpm")
                        .font(.caption2)
                        .foregroundColor(AppTheme.textTertiary)
                }
            }
        }
    }

    /// Interpret HR dip percentage
    /// Normal: 10-20%, Blunted: <10% (cardiovascular risk), Exaggerated: >20%
    private func hrDipInterpretation(dip: Double) -> (label: String, color: Color) {
        if dip >= 10 && dip <= 20 {
            return ("Normal", AppTheme.sage)
        } else if dip < 10 {
            return ("Blunted", AppTheme.softGold)
        } else {
            return ("Deep", AppTheme.mist)
        }
    }

    /// Compute baseline averages from recent sessions for comparison
    private func computeBaseline(from recentSessions: [HRVSession]) -> (avgRMSSD: Double?, avgHR: Double?, avgStress: Double?) {
        // Use last 7-14 days of data, excluding today
        let validSessions = recentSessions.dropFirst().prefix(14).filter { $0.analysisResult != nil }

        guard validSessions.count >= 3 else {
            return (nil, nil, nil)
        }

        let rmssdValues = validSessions.compactMap { $0.analysisResult?.timeDomain.rmssd }
        let hrValues = validSessions.compactMap { $0.analysisResult?.timeDomain.meanHR }
        let stressValues = validSessions.compactMap { $0.analysisResult?.ansMetrics?.stressIndex }

        let avgRMSSD = rmssdValues.isEmpty ? nil : rmssdValues.reduce(0, +) / Double(rmssdValues.count)
        let avgHR = hrValues.isEmpty ? nil : hrValues.reduce(0, +) / Double(hrValues.count)
        let avgStress = stressValues.isEmpty ? nil : stressValues.reduce(0, +) / Double(stressValues.count)

        return (avgRMSSD, avgHR, avgStress)
    }

    // MARK: - Quick Stats Row

    private var quickStatsRow: some View {
        HStack(spacing: 12) {
            StatTile(
                title: "7-Day Avg",
                value: weekAverageRMSSD,
                unit: "ms",
                trend: weekTrend,
                color: AppTheme.primary
            )

            StatTile(
                title: "Readings",
                value: Double(weekSessions.count),
                unit: "this week",
                trend: nil,
                color: AppTheme.sage
            )

            StatTile(
                title: "Avg HR",
                value: weekAverageHR,
                unit: "bpm",
                trend: nil,
                color: AppTheme.terracotta
            )
        }
    }

    private var weekAverageRMSSD: Double? {
        let values = weekSessions.compactMap { $0.analysisResult?.timeDomain.rmssd }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private var weekAverageHR: Double? {
        let values = weekSessions.compactMap { $0.analysisResult?.timeDomain.meanHR }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private var weekTrend: Double? {
        guard weekSessions.count >= 2 else { return nil }
        let sorted = weekSessions.sorted { $0.startDate < $1.startDate }
        let firstHalf = Array(sorted.prefix(sorted.count / 2))
        let secondHalf = Array(sorted.suffix(sorted.count / 2))

        let firstAvg = firstHalf.compactMap { $0.analysisResult?.timeDomain.rmssd }.reduce(0, +) / Double(Swift.max(1, firstHalf.count))
        let secondAvg = secondHalf.compactMap { $0.analysisResult?.timeDomain.rmssd }.reduce(0, +) / Double(Swift.max(1, secondHalf.count))

        guard firstAvg > 0 else { return nil }
        return ((secondAvg - firstAvg) / firstAvg) * 100
    }

    // MARK: - Quick Actions


    // MARK: - Insights Section

    private var insightsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Insights")
                .sectionHeader()

            if weekSessions.isEmpty {
                InsightCard(
                    type: .neutral,
                    title: "Begin Your Practice",
                    message: "Take a few readings to start seeing personalized insights about your body's rhythms."
                )
            } else {
                // Generate some basic insights
                if let trend = weekTrend {
                    if trend > 10 {
                        InsightCard(
                            type: .positive,
                            title: "Positive Momentum",
                            message: "Your HRV has been trending up \(String(format: "%.0f%%", trend)) this week. Your body is recovering well."
                        )
                    } else if trend < -10 {
                        InsightCard(
                            type: .warning,
                            title: "Rest & Restore",
                            message: "Your HRV is down \(String(format: "%.0f%%", abs(trend))) this week. Consider prioritizing rest."
                        )
                    } else {
                        InsightCard(
                            type: .neutral,
                            title: "Steady State",
                            message: "Your HRV has been consistent this week. Your routine is supporting balance."
                        )
                    }
                }

                if morningReading == nil && !todaySessions.isEmpty {
                    InsightCard(
                        type: .actionable,
                        title: "Morning Routine",
                        message: "Mark one of today's readings as your morning baseline for better tracking."
                    )
                }
            }
        }
    }

    // MARK: - Week Trend

    private var weekTrendSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("7-Day Trend")
                .sectionHeader()

            if weekSessions.count >= 2 {
                let chartData = weekSessions
                    .sorted { $0.startDate < $1.startDate }
                    .compactMap { session -> (Date, Double)? in
                        guard let rmssd = session.analysisResult?.timeDomain.rmssd else { return nil }
                        return (session.startDate, rmssd)
                    }

                Chart {
                    ForEach(Array(chartData.enumerated()), id: \.offset) { _, point in
                        AreaMark(
                            x: .value("Date", point.0),
                            y: .value("RMSSD", point.1)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [AppTheme.primary.opacity(0.3), AppTheme.primary.opacity(0.05)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                        LineMark(
                            x: .value("Date", point.0),
                            y: .value("RMSSD", point.1)
                        )
                        .foregroundStyle(AppTheme.primary)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))

                        PointMark(
                            x: .value("Date", point.0),
                            y: .value("RMSSD", point.1)
                        )
                        .foregroundStyle(AppTheme.primary)
                        .symbolSize(40)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(AppTheme.textTertiary.opacity(0.3))
                        AxisValueLabel()
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 1)) { value in
                        if let date = value.as(Date.self) {
                            AxisValueLabel {
                                Text(date, format: .dateTime.weekday(.abbreviated))
                                    .font(.caption2)
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                        }
                    }
                }
                .frame(height: 140)
                .zenCard()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.title)
                        .foregroundColor(AppTheme.textTertiary)
                    Text("Record more sessions to see trends")
                        .font(.subheadline)
                        .foregroundColor(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .zenCard()
            }
        }
    }
}

// MARK: - Supporting Views

private struct StatTile: View {
    let title: String
    let value: Double?
    let unit: String
    let trend: Double?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)

            if let value = value {
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text(String(format: title == "Readings" ? "%.0f" : "%.1f", value))
                        .font(.system(.title3, design: .rounded).bold())
                        .foregroundColor(color)

                    if let trend = trend {
                        Image(systemName: trend >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption2)
                            .foregroundColor(trend >= 0 ? AppTheme.sage : AppTheme.softGold)
                    }
                }
            } else {
                Text("--")
                    .font(.system(.title3, design: .rounded).bold())
                    .foregroundColor(AppTheme.textTertiary)
            }

            Text(unit)
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .zenCard()
    }
}

struct InsightCard: View {
    enum InsightType {
        case positive
        case warning
        case neutral
        case actionable

        var icon: String {
            switch self {
            case .positive: return "leaf.fill"
            case .warning: return "moon.zzz.fill"
            case .neutral: return "circle.grid.cross.fill"
            case .actionable: return "sparkles"
            }
        }

        var color: Color {
            switch self {
            case .positive: return AppTheme.sage
            case .warning: return AppTheme.softGold
            case .neutral: return AppTheme.mist
            case .actionable: return AppTheme.dustyRose
            }
        }
    }

    let type: InsightType
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(type.color.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: type.icon)
                    .foregroundColor(type.color)
                    .font(.body)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.bold())
                    .foregroundColor(AppTheme.textPrimary)
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .zenCard()
    }
}

#Preview {
    NavigationStack {
        DashboardView(sessions: [], onStartRecording: {}, onViewReport: { _ in })
            .environmentObject(SettingsManager.shared)
    }
}
