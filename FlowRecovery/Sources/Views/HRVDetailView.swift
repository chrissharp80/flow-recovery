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

/// Detailed HRV view showing trends, history, and baseline comparison
struct HRVDetailView: View {
    let sessions: [HRVSession]
    let currentHRV: Double?
    let baselineRMSSD: Double?
    var onViewReport: ((HRVSession) -> Void)? = nil

    private var recentSessions: [HRVSession] {
        sessions
            .filter { $0.state == .complete && $0.analysisResult != nil }
            .sorted { $0.startDate > $1.startDate }
            .prefix(30)
            .reversed()
            .map { $0 }
    }

    private var todaySession: HRVSession? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return sessions
            .filter { $0.state == .complete && $0.analysisResult != nil }
            .first { calendar.isDate($0.startDate, inSameDayAs: today) }
    }

    private var hrvValues: [(date: Date, value: Double)] {
        recentSessions.compactMap { session in
            guard let rmssd = session.analysisResult?.timeDomain.rmssd else { return nil }
            return (session.startDate, rmssd)
        }
    }

    private var stats: (avg: Double, min: Double, max: Double, cv: Double)? {
        let values = hrvValues.map { $0.value }
        guard !values.isEmpty else { return nil }
        let avg = values.reduce(0, +) / Double(values.count)
        let variance = values.map { pow($0 - avg, 2) }.reduce(0, +) / Double(values.count)
        let stdDev = sqrt(variance)
        let cv = avg > 0 ? (stdDev / avg) * 100 : 0
        return (
            avg: avg,
            min: values.min() ?? 0,
            max: values.max() ?? 0,
            cv: cv
        )
    }

    /// Comprehensive averages for display
    private var averages: (avgHRV: Double, avgHR: Double, avgReadiness: Double?, sessionCount: Int)? {
        let validSessions = recentSessions.filter { $0.state == .complete && $0.analysisResult != nil }
        guard !validSessions.isEmpty else { return nil }

        let hrvValues = validSessions.compactMap { $0.analysisResult?.timeDomain.rmssd }
        let hrValues = validSessions.compactMap { $0.analysisResult?.timeDomain.meanHR }
        let readinessValues = validSessions.compactMap { $0.analysisResult?.ansMetrics?.readinessScore }

        let avgHRV = hrvValues.isEmpty ? 0 : hrvValues.reduce(0, +) / Double(hrvValues.count)
        let avgHR = hrValues.isEmpty ? 0 : hrValues.reduce(0, +) / Double(hrValues.count)
        let avgReadiness = readinessValues.isEmpty ? nil : readinessValues.reduce(0, +) / Double(readinessValues.count)

        return (avgHRV: avgHRV, avgHR: avgHR, avgReadiness: avgReadiness, sessionCount: validSessions.count)
    }

    private var readinessScore: Double? {
        todaySession?.analysisResult?.ansMetrics?.readinessScore
    }

    private var nervousSystemBalance: (sympathetic: Double, parasympathetic: Double)? {
        guard let ans = todaySession?.analysisResult?.ansMetrics,
              let sns = ans.snsIndex,
              let pns = ans.pnsIndex else { return nil }

        // Use BALANCE (PNS - SNS) to determine visualization
        // Good recovery: SNS negative, PNS positive → balance positive → parasympathetic dominant
        // Stressed: SNS positive, PNS negative → balance negative → sympathetic dominant
        //
        // balance of +2 → ~85% parasympathetic (well recovered)
        // balance of 0  → 50/50 (neutral)
        // balance of -2 → ~85% sympathetic (stressed)
        let balance = pns - sns
        let parasymPercent = max(0.1, min(0.9, 0.5 + (balance / 5.0)))
        let symPercent = 1.0 - parasymPercent

        return (symPercent, parasymPercent)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Current HRV Hero
                currentHRVCard

                // Your Averages - key reference data
                if let avgs = averages {
                    yourAveragesCard(avgs)
                }

                // View Full Report Button
                if let session = todaySession, let onViewReport = onViewReport {
                    viewReportButton(session: session, action: onViewReport)
                }

                // HRV Score & ANS Balance
                if readinessScore != nil || nervousSystemBalance != nil {
                    readinessCard
                }

                // Trend Chart
                if !hrvValues.isEmpty {
                    trendChart
                }

                // Statistics
                if let stats = stats {
                    statsCard(stats)
                }

                // Recent Readings
                recentReadingsSection

                // HRV Education
                hrvEducationCard
            }
            .padding()
        }
        .background(AppTheme.background)
        .navigationTitle("HRV Analysis")
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: - Current HRV Card

    private var currentHRVCard: some View {
        VStack(spacing: 12) {
            Text("TODAY'S HRV")
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.textTertiary)
                .tracking(1)

            if let hrv = currentHRV {
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(String(format: "%.0f", hrv))
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .foregroundColor(hrvColor(hrv, baseline: baselineRMSSD))
                    Text("ms")
                        .font(.title2)
                        .foregroundColor(AppTheme.textTertiary)
                }

                Text(hrvLabel(hrv, baseline: baselineRMSSD))
                    .font(.headline)
                    .foregroundColor(hrvColor(hrv, baseline: baselineRMSSD))

                if let baseline = baselineRMSSD, baseline > 0 {
                    let percentChange = ((hrv - baseline) / baseline) * 100
                    HStack(spacing: 4) {
                        Image(systemName: percentChange >= 0 ? "arrow.up.right" : "arrow.down.right")
                        Text(String(format: "%+.0f%% from baseline", percentChange))
                    }
                    .font(.subheadline)
                    .foregroundColor(percentChange >= 0 ? AppTheme.sage : AppTheme.terracotta)
                }
            } else {
                Text("--")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundColor(AppTheme.textTertiary)
                Text("No reading today")
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    // MARK: - Your Averages Card

    private func yourAveragesCard(_ avgs: (avgHRV: Double, avgHR: Double, avgReadiness: Double?, sessionCount: Int)) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.doc.horizontal")
                    .foregroundColor(AppTheme.primary)
                Text("YOUR AVERAGES")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.textTertiary)
                    .tracking(1)
                Spacer()
                Text("\(avgs.sessionCount) sessions")
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }

            HStack(spacing: 16) {
                // Average HRV
                VStack(spacing: 4) {
                    Text(String(format: "%.0f", avgs.avgHRV))
                        .font(.title2.weight(.bold))
                        .foregroundColor(AppTheme.primary)
                    Text("ms")
                        .font(.caption)
                        .foregroundColor(AppTheme.textTertiary)
                    Text("Avg HRV")
                        .font(.caption2)
                        .foregroundColor(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity)

                Divider()
                    .frame(height: 40)

                // Average HR
                VStack(spacing: 4) {
                    Text(String(format: "%.0f", avgs.avgHR))
                        .font(.title2.weight(.bold))
                        .foregroundColor(AppTheme.primary)
                    Text("bpm")
                        .font(.caption)
                        .foregroundColor(AppTheme.textTertiary)
                    Text("Avg HR")
                        .font(.caption2)
                        .foregroundColor(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity)

                if let avgReadiness = avgs.avgReadiness {
                    Divider()
                        .frame(height: 40)

                    // Average Readiness
                    VStack(spacing: 4) {
                        Text(String(format: "%.1f", avgReadiness))
                            .font(.title2.weight(.bold))
                            .foregroundColor(AppTheme.primary)
                        Text("/10")
                            .font(.caption)
                            .foregroundColor(AppTheme.textTertiary)
                        Text("Avg Score")
                            .font(.caption2)
                            .foregroundColor(AppTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 8)

            // Baseline note if available
            if let baseline = baselineRMSSD {
                HStack(spacing: 4) {
                    Image(systemName: "target")
                        .font(.caption2)
                    Text("Your baseline: \(String(format: "%.0f", baseline))ms")
                        .font(.caption)
                }
                .foregroundColor(AppTheme.textSecondary)
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    // MARK: - View Report Button

    private func viewReportButton(session: HRVSession, action: @escaping (HRVSession) -> Void) -> some View {
        Button {
            action(session)
        } label: {
            HStack {
                Image(systemName: "doc.text.fill")
                Text("View Full HRV Report")
                    .fontWeight(.semibold)
                Spacer()
                Image(systemName: "chevron.right")
            }
            .padding()
            .background(AppTheme.primary)
            .foregroundColor(.white)
            .cornerRadius(14)
        }
    }

    // MARK: - HRV Score Card

    private var readinessCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "heart.circle.fill")
                    .foregroundColor(AppTheme.primary)
                Text("NERVOUS SYSTEM")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.textTertiary)
                    .tracking(1)
                Spacer()
            }

            HStack(spacing: 16) {
                // HRV Score (1-10)
                if let readiness = readinessScore {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .stroke(readinessColor(readiness).opacity(0.2), lineWidth: 8)
                            Circle()
                                .trim(from: 0, to: CGFloat(readiness) / 10)
                                .stroke(readinessColor(readiness), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(Int(readiness))")
                                .font(.title2.weight(.bold))
                                .foregroundColor(readinessColor(readiness))
                        }
                        .frame(width: 70, height: 70)

                        Text("HRV Score")
                            .font(.caption)
                            .foregroundColor(AppTheme.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                }

                // ANS Balance
                if let balance = nervousSystemBalance {
                    VStack(spacing: 12) {
                        ANSBalanceBar(
                            sympathetic: balance.sympathetic,
                            parasympathetic: balance.parasympathetic
                        )

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sympathetic")
                                    .font(.caption2)
                                    .foregroundColor(AppTheme.textTertiary)
                                Text(String(format: "%.0f%%", balance.sympathetic * 100))
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(AppTheme.terracotta)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("Parasympathetic")
                                    .font(.caption2)
                                    .foregroundColor(AppTheme.textTertiary)
                                Text(String(format: "%.0f%%", balance.parasympathetic * 100))
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(AppTheme.sage)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            // Balance interpretation
            if let balance = nervousSystemBalance {
                let dominance = balance.parasympathetic > balance.sympathetic ? "parasympathetic" : "sympathetic"
                let interpretation = dominance == "parasympathetic"
                    ? "Your nervous system is well recovered - ready for training."
                    : "Your nervous system is activated - watch for overtraining signs."

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(AppTheme.primary)
                    Text(interpretation)
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    // MARK: - Trend Chart

    private var trendChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundColor(AppTheme.primary)
                Text("30-DAY TREND")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.textTertiary)
                    .tracking(1)
                Spacer()

                if let stats = stats {
                    Text("CV: \(String(format: "%.0f%%", stats.cv))")
                        .font(.caption.weight(.medium))
                        .foregroundColor(stats.cv < 10 ? AppTheme.sage : (stats.cv < 20 ? AppTheme.softGold : AppTheme.terracotta))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AppTheme.sectionTint)
                        .cornerRadius(8)
                }
            }

            Chart {
                ForEach(hrvValues, id: \.date) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("RMSSD", point.value)
                    )
                    .foregroundStyle(AppTheme.primary)
                    .lineStyle(StrokeStyle(lineWidth: 2))

                    AreaMark(
                        x: .value("Date", point.date),
                        y: .value("RMSSD", point.value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [AppTheme.primary.opacity(0.3), AppTheme.primary.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    PointMark(
                        x: .value("Date", point.date),
                        y: .value("RMSSD", point.value)
                    )
                    .foregroundStyle(AppTheme.primary)
                    .symbolSize(30)
                }

                if let baseline = baselineRMSSD {
                    RuleMark(y: .value("Baseline", baseline))
                        .foregroundStyle(AppTheme.textTertiary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("Baseline: \(Int(baseline))")
                                .font(.caption2)
                                .foregroundColor(AppTheme.textTertiary)
                        }
                }
            }
            .frame(height: 200)
            .chartYAxis {
                AxisMarks(position: .leading)
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    // MARK: - Stats Card

    private func statsCard(_ stats: (avg: Double, min: Double, max: Double, cv: Double)) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(AppTheme.primary)
                Text("STATISTICS")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.textTertiary)
                    .tracking(1)
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                HRVStatCell(
                    label: "30-Day Average",
                    value: String(format: "%.0f", stats.avg),
                    unit: "ms",
                    icon: "number"
                )
                HRVStatCell(
                    label: "Range",
                    value: "\(Int(stats.min))-\(Int(stats.max))",
                    unit: "ms",
                    icon: "arrow.up.arrow.down"
                )
                HRVStatCell(
                    label: "Variability (CV)",
                    value: String(format: "%.0f", stats.cv),
                    unit: "%",
                    icon: "waveform.path",
                    status: stats.cv < 10 ? .good : (stats.cv < 20 ? .fair : .elevated)
                )
                if let baseline = baselineRMSSD {
                    HRVStatCell(
                        label: "Your Baseline",
                        value: String(format: "%.0f", baseline),
                        unit: "ms",
                        icon: "line.horizontal.star.fill.line.horizontal"
                    )
                }
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    // MARK: - Recent Readings

    private var recentReadingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock.fill")
                    .foregroundColor(AppTheme.primary)
                Text("RECENT READINGS")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.textTertiary)
                    .tracking(1)
                Spacer()
            }

            ForEach(Array(recentSessions.suffix(7).reversed().enumerated()), id: \.element.id) { index, session in
                if let rmssd = session.analysisResult?.timeDomain.rmssd {
                    if let onViewReport = onViewReport {
                        Button {
                            onViewReport(session)
                        } label: {
                            recentReadingRow(session: session, rmssd: rmssd)
                        }
                        .buttonStyle(.plain)
                    } else {
                        recentReadingRow(session: session, rmssd: rmssd)
                    }

                    if index < recentSessions.suffix(7).count - 1 {
                        Divider()
                    }
                }
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    private func recentReadingRow(session: HRVSession, rmssd: Double) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.startDate, style: .date)
                    .font(.subheadline)
                    .foregroundColor(AppTheme.textPrimary)
                if let readiness = session.analysisResult?.ansMetrics?.readinessScore {
                    Text("HRV: \(Int(readiness))/10")
                        .font(.caption)
                        .foregroundColor(AppTheme.textTertiary)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Text(String(format: "%.0f ms", rmssd))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(hrvColor(rmssd))
                if onViewReport != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(AppTheme.textTertiary)
                }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Education Card

    private var hrvEducationCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(AppTheme.softGold)
                Text("UNDERSTANDING HRV")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.textTertiary)
                    .tracking(1)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                EducationRow(
                    icon: "arrow.up.circle.fill",
                    iconColor: AppTheme.sage,
                    text: "Higher HRV generally indicates better recovery and cardiovascular fitness"
                )
                EducationRow(
                    icon: "chart.line.downtrend.xyaxis",
                    iconColor: AppTheme.terracotta,
                    text: "Declining trends may signal accumulated fatigue or illness"
                )
                EducationRow(
                    icon: "waveform.path",
                    iconColor: AppTheme.primary,
                    text: "Low day-to-day variability (CV) suggests consistent recovery patterns"
                )
                EducationRow(
                    icon: "moon.stars.fill",
                    iconColor: .indigo,
                    text: "Morning readings after overnight recording are most reliable"
                )
            }
        }
        .padding()
        .background(AppTheme.cardBackground)
        .cornerRadius(16)
    }

    // MARK: - Helpers

    private func hrvLabel(_ hrv: Double, baseline: Double? = nil) -> String {
        // Use baseline-relative assessment when available
        if let baseline = baseline, baseline > 0 {
            let percentChange = ((hrv - baseline) / baseline) * 100
            if percentChange >= 10 { return "Excellent" }
            if percentChange >= -10 { return "Good" }  // Within 10% of baseline
            if percentChange >= -25 { return "Fair" }
            return "Low"
        }
        // Fall back to absolute thresholds
        if hrv >= 60 { return "Excellent" }
        if hrv >= 45 { return "Good" }
        if hrv >= 30 { return "Fair" }
        return "Low"
    }

    private func hrvColor(_ hrv: Double, baseline: Double? = nil) -> Color {
        // Use baseline-relative coloring when available
        if let baseline = baseline, baseline > 0 {
            let percentChange = ((hrv - baseline) / baseline) * 100
            if percentChange >= 10 { return AppTheme.sage }      // Above baseline
            if percentChange >= -10 { return AppTheme.sage }     // At baseline (within 10%)
            if percentChange >= -25 { return AppTheme.softGold } // Slightly below
            return AppTheme.terracotta                           // Significantly below
        }
        // Fall back to absolute thresholds
        if hrv >= 60 { return AppTheme.sage }
        if hrv >= 45 { return AppTheme.softGold }
        if hrv >= 30 { return AppTheme.terracotta }
        return AppTheme.dustyRose
    }

    private func readinessColor(_ score: Double) -> Color {
        // HRV Score is 1-10 scale
        if score >= 8 { return AppTheme.sage }
        if score >= 6 { return AppTheme.softGold }
        if score >= 4 { return AppTheme.terracotta }
        return AppTheme.dustyRose
    }
}

// MARK: - Supporting Views

private struct ANSBalanceBar: View {
    let sympathetic: Double
    let parasympathetic: Double

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Rectangle()
                    .fill(AppTheme.terracotta)
                    .frame(width: geo.size.width * CGFloat(sympathetic))
                Rectangle()
                    .fill(AppTheme.sage)
                    .frame(width: geo.size.width * CGFloat(parasympathetic))
            }
            .cornerRadius(4)
        }
        .frame(height: 8)
    }
}

private struct HRVStatCell: View {
    let label: String
    let value: String
    let unit: String
    let icon: String
    var status: Status = .neutral

    enum Status {
        case good, fair, elevated, neutral

        var color: Color {
            switch self {
            case .good: return AppTheme.sage
            case .fair: return AppTheme.softGold
            case .elevated: return AppTheme.terracotta
            case .neutral: return AppTheme.textPrimary
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(AppTheme.textTertiary)

            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title3.weight(.bold))
                    .foregroundColor(status.color)
                Text(unit)
                    .font(.caption)
                    .foregroundColor(AppTheme.textTertiary)
            }

            Text(label)
                .font(.caption)
                .foregroundColor(AppTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(AppTheme.sectionTint)
        .cornerRadius(12)
    }
}

private struct EducationRow: View {
    let icon: String
    let iconColor: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(iconColor)
                .frame(width: 20)
            Text(text)
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
        }
    }
}

#Preview {
    NavigationStack {
        HRVDetailView(
            sessions: [],
            currentHRV: 67,
            baselineRMSSD: 55
        )
    }
}
