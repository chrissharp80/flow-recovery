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

/// Trend visualization view for multi-session comparison
struct TrendView: View {
    let sessions: [HRVSession]
    @State private var selectedPeriod: TrendAnalyzer.TimePeriod = .twoWeeks
    @State private var selectedMetric: TrendAnalyzer.ChartMetric = .rmssd
    @State private var trendSummary: TrendAnalyzer.TrendSummary?
    @State private var includedTags: Set<ReadingTag> = []
    @State private var excludedTags: Set<ReadingTag> = []
    @State private var showingFilterSheet = false

    /// Hash of session IDs for change detection
    private var sessionsHash: Int {
        sessions.map { $0.id.hashValue }.reduce(0, ^)
    }

    private var filteredSessions: [HRVSession] {
        sessions.filter { session in
            // If no include tags specified, include all
            let passesInclude = includedTags.isEmpty || !includedTags.isDisjoint(with: Set(session.tags))
            // Exclude if any excluded tag is present
            let passesExclude = excludedTags.isEmpty || excludedTags.isDisjoint(with: Set(session.tags))
            return passesInclude && passesExclude
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Tag filter bar
                tagFilterBar

                // Period selector
                periodSelector

                if let summary = trendSummary {
                    // Overall trend card
                    overallTrendCard(summary: summary)

                    // Chart
                    trendChart(summary: summary)

                    // Statistics cards
                    statisticsGrid(summary: summary)

                    // Insights
                    insightsSection(summary: summary)
                } else {
                    noDataView
                }
            }
            .padding()
        }
        .navigationTitle("Trends")
        .onAppear { updateTrend() }
        .onChange(of: sessionsHash) { _, _ in updateTrend() }
        .onChange(of: selectedPeriod) { _, _ in updateTrend() }
        .onChange(of: includedTags) { _, _ in updateTrend() }
        .onChange(of: excludedTags) { _, _ in updateTrend() }
        .sheet(isPresented: $showingFilterSheet) {
            TagFilterSheet(
                includedTags: $includedTags,
                excludedTags: $excludedTags
            )
        }
    }

    // MARK: - Tag Filter Bar

    private var tagFilterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Filter by Tags")
                    .font(.subheadline.bold())

                Spacer()

                if !includedTags.isEmpty || !excludedTags.isEmpty {
                    Button("Clear") {
                        includedTags.removeAll()
                        excludedTags.removeAll()
                    }
                    .font(.caption)
                }

                Button {
                    showingFilterSheet = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundColor(.blue)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // "All" chip
                    Button {
                        includedTags.removeAll()
                        excludedTags.removeAll()
                    } label: {
                        Text("All")
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(includedTags.isEmpty && excludedTags.isEmpty ? Color.blue : Color.gray.opacity(0.2))
                            .foregroundColor(includedTags.isEmpty && excludedTags.isEmpty ? .white : .primary)
                            .cornerRadius(12)
                    }

                    // Quick include tags
                    ForEach(ReadingTag.systemTags.prefix(4)) { tag in
                        Button {
                            if includedTags.contains(tag) {
                                includedTags.remove(tag)
                            } else {
                                includedTags.insert(tag)
                                excludedTags.remove(tag)
                            }
                        } label: {
                            HStack(spacing: 4) {
                                if includedTags.contains(tag) {
                                    Image(systemName: "checkmark")
                                        .font(.caption2)
                                }
                                Text(tag.name)
                                    .font(.caption)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(includedTags.contains(tag) ? tag.color : tag.color.opacity(0.15))
                            .foregroundColor(includedTags.contains(tag) ? .white : tag.color)
                            .cornerRadius(12)
                        }
                    }

                    // Show excluded count
                    if !excludedTags.isEmpty {
                        Text("\(excludedTags.count) excluded")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                    }
                }
            }

            // Active filter summary
            if !includedTags.isEmpty || !excludedTags.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill")
                        .foregroundColor(.blue)
                        .font(.caption)
                    Text("\(filteredSessions.filter { $0.state == .complete }.count) of \(sessions.filter { $0.state == .complete }.count) sessions")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    // MARK: - Period Selector

    private var periodSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach([TrendAnalyzer.TimePeriod.week, .twoWeeks, .month, .threeMonths, .all], id: \.displayName) { period in
                    Button {
                        selectedPeriod = period
                    } label: {
                        Text(period.displayName)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selectedPeriod.displayName == period.displayName ? Color.blue : Color.gray.opacity(0.2))
                            .foregroundColor(selectedPeriod.displayName == period.displayName ? .white : .primary)
                            .cornerRadius(16)
                    }
                }
            }
        }
    }

    // MARK: - Overall Trend Card

    private func overallTrendCard(summary: TrendAnalyzer.TrendSummary) -> some View {
        VStack(spacing: 12) {
            HStack {
                trendIcon(for: summary.overallTrend)
                    .font(.title)

                VStack(alignment: .leading) {
                    Text("Overall Trend")
                        .font(.headline)
                    Text(summary.overallTrend.rawValue)
                        .font(.subheadline)
                        .foregroundColor(trendColor(for: summary.overallTrend))
                }

                Spacer()

                VStack(alignment: .trailing) {
                    Text("\(summary.dataPoints.count)")
                        .font(.title2.bold())
                    Text("sessions")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Date range
            HStack {
                Text(formatDateRange(summary.period))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: - Trend Chart

    private func trendChart(summary: TrendAnalyzer.TrendSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Metric selector
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(TrendAnalyzer.ChartMetric.allCases, id: \.rawValue) { metric in
                        Button {
                            selectedMetric = metric
                        } label: {
                            Text(metric.rawValue)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(selectedMetric == metric ? Color.blue : Color.gray.opacity(0.2))
                                .foregroundColor(selectedMetric == metric ? .white : .primary)
                                .cornerRadius(12)
                        }
                    }
                }
            }

            // Chart
            let chartData = TrendAnalyzer.chartData(from: summary.dataPoints, metric: selectedMetric)

            if chartData.count >= 2 {
                Chart {
                    ForEach(Array(chartData.enumerated()), id: \.offset) { _, point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value(selectedMetric.rawValue, point.value)
                        )
                        .foregroundStyle(Color.blue.gradient)

                        PointMark(
                            x: .value("Date", point.date),
                            y: .value(selectedMetric.rawValue, point.value)
                        )
                        .foregroundStyle(Color.blue)
                    }

                    // Rolling average line
                    let rollingAvg = computeRollingAverage(chartData.map { $0.value }, window: 3)
                    ForEach(Array(zip(chartData.indices, rollingAvg)), id: \.0) { index, avg in
                        LineMark(
                            x: .value("Date", chartData[index].date),
                            y: .value("Avg", avg)
                        )
                        .foregroundStyle(Color.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: max(1, chartData.count / 5))) { value in
                        if let date = value.as(Date.self) {
                            AxisValueLabel {
                                Text(date, format: .dateTime.month(.abbreviated).day())
                                    .font(.caption2)
                            }
                        }
                        AxisGridLine()
                    }
                }
                .frame(height: 200)
            } else {
                Text("Not enough data for chart")
                    .foregroundColor(.secondary)
                    .frame(height: 200)
                    .frame(maxWidth: .infinity)
            }

            // Legend
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                    Text("Value")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.orange)
                        .frame(width: 16, height: 2)
                    Text("3-day avg")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
    }

    // MARK: - Statistics Grid

    private func statisticsGrid(summary: TrendAnalyzer.TrendSummary) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatCard(stats: summary.rmssdStats, unit: "ms")
            StatCard(stats: summary.sdnnStats, unit: "ms")
            StatCard(stats: summary.hrStats, unit: "bpm")

            if let lfhf = summary.lfHfStats {
                StatCard(stats: lfhf, unit: "")
            }

            if let dfa = summary.dfaAlpha1Stats {
                StatCard(stats: dfa, unit: "")
            }

            if let stress = summary.stressStats {
                StatCard(stats: stress, unit: "")
            }

            if let readiness = summary.readinessStats {
                StatCard(stats: readiness, unit: "/10")
            }
        }
    }

    // MARK: - Insights Section

    private func insightsSection(summary: TrendAnalyzer.TrendSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Insights")
                .font(.headline)

            ForEach(Array(summary.insights.enumerated()), id: \.offset) { _, insight in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundColor(.yellow)
                        .font(.caption)
                    Text(insight)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            if summary.insights.isEmpty {
                Text("Keep recording to generate insights")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
    }

    // MARK: - No Data View

    private var noDataView: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("Not Enough Data")
                .font(.headline)

            Text("Record at least 2 sessions to see trends")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    // MARK: - Helpers

    private func updateTrend() {
        trendSummary = TrendAnalyzer.analyze(sessions: filteredSessions, period: selectedPeriod)
    }

    private func trendIcon(for trend: TrendAnalyzer.TrendDirection) -> some View {
        let (icon, color): (String, Color) = switch trend {
        case .improving: ("arrow.up.circle.fill", .green)
        case .stable: ("arrow.left.arrow.right.circle.fill", .blue)
        case .declining: ("arrow.down.circle.fill", .orange)
        case .insufficient: ("questionmark.circle.fill", .gray)
        }
        return Image(systemName: icon).foregroundColor(color)
    }

    private func trendColor(for trend: TrendAnalyzer.TrendDirection) -> Color {
        switch trend {
        case .improving: return .green
        case .stable: return .blue
        case .declining: return .orange
        case .insufficient: return .gray
        }
    }

    private func formatDateRange(_ interval: DateInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return "\(formatter.string(from: interval.start)) - \(formatter.string(from: interval.end))"
    }

    private func computeRollingAverage(_ values: [Double], window: Int) -> [Double] {
        var result = [Double]()
        for i in 0..<values.count {
            let start = max(0, i - window + 1)
            let windowValues = Array(values[start...i])
            result.append(windowValues.reduce(0, +) / Double(windowValues.count))
        }
        return result
    }
}

// MARK: - Stat Card

private struct StatCard: View {
    let stats: TrendAnalyzer.TrendStatistics
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(stats.metric)
                    .font(.caption.bold())
                Spacer()
                trendArrow
            }

            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(String(format: "%.1f", stats.mean))
                    .font(.title2.monospacedDigit().bold())
                Text(unit)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("±\(String(format: "%.1f", stats.standardDeviation))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(stats.count) sessions")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Baseline comparison
            if let deviation = stats.deviationFromBaseline {
                HStack(spacing: 2) {
                    Image(systemName: deviation >= 0 ? "arrow.up" : "arrow.down")
                        .font(.caption2)
                    Text(String(format: "%.0f%% vs baseline", abs(deviation)))
                        .font(.caption2)
                }
                .foregroundColor(deviation >= 0 ? .green : .orange)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }

    private var trendArrow: some View {
        let (icon, color): (String, Color) = switch stats.trend {
        case .improving: ("arrow.up.right", .green)
        case .stable: ("arrow.right", .blue)
        case .declining: ("arrow.down.right", .orange)
        case .insufficient: ("minus", .gray)
        }
        return Image(systemName: icon)
            .font(.caption)
            .foregroundColor(color)
    }
}

// MARK: - Session History List

struct SessionHistoryView: View {
    let sessions: [HRVSession]
    let onSelect: (HRVSession) -> Void

    var body: some View {
        List {
            ForEach(sessions.filter { $0.state == .complete }.sorted { $0.startDate > $1.startDate }) { session in
                Button {
                    onSelect(session)
                } label: {
                    SessionRow(session: session)
                }
            }
        }
        .navigationTitle("History")
    }
}

private struct SessionRow: View {
    let session: HRVSession

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.startDate, style: .date)
                    .font(.headline)
                Text(session.startDate, style: .time)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if let result = session.analysisResult {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 4) {
                        Text(String(format: "%.0f", result.timeDomain.rmssd))
                            .font(.title3.monospacedDigit().bold())
                        Text("ms")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let readiness = result.ansMetrics?.readinessScore {
                        HStack(spacing: 2) {
                            Image(systemName: readinessIcon(for: readiness))
                                .foregroundColor(readinessColor(for: readiness))
                            Text(String(format: "%.1f", readiness))
                                .font(.caption)
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

    private func readinessIcon(for score: Double) -> String {
        if score >= 7 { return "checkmark.circle.fill" }
        if score >= 5 { return "minus.circle.fill" }
        return "xmark.circle.fill"
    }

    private func readinessColor(for score: Double) -> Color {
        if score >= 7 { return .green }
        if score >= 5 { return .yellow }
        return .orange
    }
}

// MARK: - Tag Filter Sheet

private struct TagFilterSheet: View {
    @Binding var includedTags: Set<ReadingTag>
    @Binding var excludedTags: Set<ReadingTag>
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Select tags to include or exclude from trend analysis. Including a tag shows only sessions with that tag. Excluding hides sessions with that tag.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Include These Tags") {
                    ForEach(ReadingTag.systemTags) { tag in
                        Button {
                            toggleInclude(tag)
                        } label: {
                            HStack {
                                Circle()
                                    .fill(tag.color)
                                    .frame(width: 12, height: 12)
                                Text(tag.name)
                                    .foregroundColor(.primary)
                                Spacer()
                                if includedTags.contains(tag) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                }
                            }
                        }
                    }
                }

                Section("Exclude These Tags") {
                    ForEach(ReadingTag.systemTags) { tag in
                        Button {
                            toggleExclude(tag)
                        } label: {
                            HStack {
                                Circle()
                                    .fill(tag.color)
                                    .frame(width: 12, height: 12)
                                Text(tag.name)
                                    .foregroundColor(.primary)
                                Spacer()
                                if excludedTags.contains(tag) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                }
                            }
                        }
                    }
                }

                Section {
                    Button("Clear All Filters") {
                        includedTags.removeAll()
                        excludedTags.removeAll()
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle("Filter Trends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func toggleInclude(_ tag: ReadingTag) {
        if includedTags.contains(tag) {
            includedTags.remove(tag)
        } else {
            includedTags.insert(tag)
            excludedTags.remove(tag)  // Can't be both included and excluded
        }
    }

    private func toggleExclude(_ tag: ReadingTag) {
        if excludedTags.contains(tag) {
            excludedTags.remove(tag)
        } else {
            excludedTags.insert(tag)
            includedTags.remove(tag)  // Can't be both included and excluded
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        TrendView(sessions: [])
    }
}
