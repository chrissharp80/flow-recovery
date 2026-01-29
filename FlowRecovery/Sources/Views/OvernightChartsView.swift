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

/// Overnight visualization showing full-night HR and HRV with nadir marked
/// Welltory-style overnight graphs
struct OvernightChartsView: View {
    let session: HRVSession
    let result: HRVAnalysisResult
    var healthKitSleep: HealthKitManager.SleepData? = nil
    /// Optional callback for manual window reanalysis (timestamp in ms from session start)
    var onReanalyzeAt: ((Int64) -> Void)? = nil

    var body: some View {
        VStack(spacing: 20) {
            // Overnight stats summary
            overnightStatsSection

            // Full night HR graph
            overnightHRSection

            // Full night HRV (rolling RMSSD) graph - with reanalysis support
            overnightHRVSection
        }
    }

    // MARK: - Overnight Stats

    private var overnightStats: OvernightStats {
        computeOvernightStats()
    }

    private var overnightStatsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "moon.stars.fill")
                    .foregroundColor(AppTheme.primary)
                Text("Overnight Summary")
                    .font(.headline)
                    .foregroundColor(AppTheme.textPrimary)
            }

            // Row 1: Core metrics
            HStack(spacing: 12) {
                OvernightStatCard(
                    title: "HR Nadir",
                    value: String(format: "%.0f", overnightStats.nadirHR),
                    unit: "bpm",
                    subtitle: overnightStats.nadirTimeFormatted,
                    color: AppTheme.mist
                )

                OvernightStatCard(
                    title: "Peak HRV",
                    value: String(format: "%.0f", overnightStats.peakRMSSD),
                    unit: "ms",
                    subtitle: overnightStats.peakHRVTimeFormatted,
                    color: AppTheme.sage
                )

                OvernightStatCard(
                    title: "Avg HR",
                    value: String(format: "%.0f", overnightStats.avgHR),
                    unit: "bpm",
                    subtitle: "overnight",
                    color: AppTheme.terracotta
                )
            }

            // Row 2: Sleep metrics (from HealthKit when available, otherwise estimated from HR patterns)
            if overnightStats.estimatedSleepDurationMinutes > 0 {
                HStack(spacing: 12) {
                    OvernightStatCard(
                        title: overnightStats.isHealthKitData ? "Time Asleep" : "Est. Sleep",
                        value: overnightStats.estimatedSleepDurationFormatted,
                        unit: "",
                        subtitle: overnightStats.isHealthKitData
                            ? "from Apple Health"
                            : String(format: "%.0f%% efficiency", overnightStats.sleepEfficiency),
                        color: AppTheme.primary
                    )

                    OvernightStatCard(
                        title: overnightStats.isHealthKitData ? "Deep Sleep" : "Est. Deep",
                        value: "\(overnightStats.deepSleepMinutes / 60)h \(overnightStats.deepSleepMinutes % 60)m",
                        unit: "",
                        subtitle: overnightStats.isHealthKitData ? "Apple Watch" : "lowest HR quartile",
                        color: AppTheme.mist
                    )

                    OvernightStatCard(
                        title: "Awakenings",
                        value: "\(overnightStats.awakeningsCount)",
                        unit: "",
                        subtitle: overnightStats.isHealthKitData ? "from sleep data" : "HR spikes",
                        color: overnightStats.awakeningsCount > 3 ? AppTheme.terracotta : AppTheme.sage
                    )
                }

                // Sleep quality note
                Text(sleepQualityNote)
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
                    .padding(.top, 4)
            }
        }
        .zenCard()
    }

    private var sleepQualityNote: String {
        let stats = overnightStats
        var notes: [String] = []

        // Sleep duration assessment
        if stats.estimatedSleepDurationMinutes < 300 { // < 5 hours
            notes.append("Short sleep detected")
        } else if stats.estimatedSleepDurationMinutes >= 420 { // >= 7 hours
            notes.append("Good sleep duration")
        }

        // Deep sleep assessment
        let deepSleepPercent = stats.estimatedSleepDurationMinutes > 0 ?
            Double(stats.deepSleepMinutes) / Double(stats.estimatedSleepDurationMinutes) * 100 : 0
        if deepSleepPercent < 15 {
            notes.append("low deep sleep")
        } else if deepSleepPercent > 25 {
            notes.append("excellent deep sleep")
        }

        // Awakenings assessment
        if stats.awakeningsCount > 5 {
            notes.append("fragmented sleep")
        } else if stats.awakeningsCount <= 1 {
            notes.append("uninterrupted sleep")
        }

        return notes.isEmpty ? "Sleep metrics estimated from HR patterns" : notes.joined(separator: " • ").capitalized
    }

    // MARK: - Overnight HR Graph

    private var overnightHRSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Heart Rate Overnight")
                    .font(.headline)
                    .foregroundColor(AppTheme.textPrimary)
                Spacer()
                Text("\(Int(overnightStats.minHR))-\(Int(overnightStats.maxHR)) bpm")
                    .font(.caption.bold())
                    .foregroundColor(AppTheme.terracotta)
            }

            OvernightHRChartCanvas(
                session: session,
                result: result,
                stats: overnightStats,
                healthKitSleep: healthKitSleep
            )
            .frame(height: 180)

            // Legend
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Circle().fill(AppTheme.terracotta).frame(width: 8, height: 8)
                    Text("HR").font(.caption2).foregroundColor(AppTheme.textTertiary)
                }
                HStack(spacing: 4) {
                    Circle().fill(AppTheme.mist).frame(width: 8, height: 8)
                    Text("Nadir").font(.caption2).foregroundColor(AppTheme.textTertiary)
                }
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(AppTheme.primary.opacity(0.3))
                        .frame(width: 12, height: 8)
                    Text("Analysis Window").font(.caption2).foregroundColor(AppTheme.textTertiary)
                }
            }
        }
        .zenCard()
    }

    // MARK: - Overnight HRV Graph

    private var overnightHRVSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("HRV Overnight (Rolling RMSSD)")
                    .font(.headline)
                    .foregroundColor(AppTheme.textPrimary)
                Spacer()
                Text("Peak: \(Int(overnightStats.peakRMSSD)) ms")
                    .font(.caption.bold())
                    .foregroundColor(AppTheme.sage)
            }

            OvernightHRVChartCanvas(
                session: session,
                result: result,
                stats: overnightStats,
                healthKitSleep: healthKitSleep,
                onReanalyzeAt: onReanalyzeAt
            )
            .frame(height: 180)

            // Legend
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Circle().fill(AppTheme.sage).frame(width: 8, height: 8)
                    Text("RMSSD").font(.caption2).foregroundColor(AppTheme.textTertiary)
                }
                HStack(spacing: 4) {
                    Circle().fill(AppTheme.primary).frame(width: 8, height: 8)
                    Text("Peak HRV").font(.caption2).foregroundColor(AppTheme.textTertiary)
                }
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(AppTheme.primary.opacity(0.3))
                        .frame(width: 12, height: 8)
                    Text("Analysis Window").font(.caption2).foregroundColor(AppTheme.textTertiary)
                }
            }
        }
        .zenCard()
    }

    // MARK: - Compute Stats

    private func computeOvernightStats() -> OvernightStats {
        guard let series = session.rrSeries, !series.points.isEmpty else {
            return OvernightStats.empty
        }

        let flags = session.artifactFlags ?? []
        let points = series.points

        // Use sleep boundaries to filter pre-sleep data from stats
        // sleepStartMs is relative to recording start (in ms)
        // Only include data from actual sleep period for nadir/peak calculations
        let sleepStart = session.sleepStartMs ?? 0  // Default to recording start if no HealthKit data
        let recordingEnd = points.last?.t_ms ?? Int64.max
        // Defensive: ensure sleepEnd is valid (>= 0, > sleepStart, within recording bounds)
        let rawSleepEnd = session.sleepEndMs ?? recordingEnd
        let sleepEnd = (rawSleepEnd > sleepStart && rawSleepEnd >= 0) ? rawSleepEnd : recordingEnd

        // Compute HR values for SLEEP PERIOD ONLY using proper method
        // Check if we have stored HR from streaming (accurate)
        let hasStoredHR = points.contains { $0.hr != nil }

        var hrValues: [(index: Int, hr: Double, timeMs: Int64)] = []

        if hasStoredHR {
            // Use stored HR from Polar sensor (streaming data)
            for (i, point) in points.enumerated() {
                if point.t_ms < sleepStart || point.t_ms > sleepEnd {
                    continue
                }
                let isArtifact = i < flags.count ? flags[i].isArtifact : false
                if !isArtifact, let hr = point.hr, hr >= 30 && hr <= 200 {
                    hrValues.append((i, Double(hr), point.t_ms))
                }
            }
        } else {
            // Calculate HR using rolling 10-second windows (research best practice)
            let windowDurationMs: Int64 = 10000
            var i = 0

            while i < points.count {
                if points[i].t_ms < sleepStart {
                    i += 1
                    continue
                }
                if points[i].t_ms > sleepEnd {
                    break
                }

                // Collect beats for next 10-second window
                var windowBeats: [Int] = []
                var windowDurationActual: Int64 = 0
                var j = i

                while j < points.count && points[j].t_ms <= sleepEnd && windowDurationActual < windowDurationMs {
                    let isArtifact = j < flags.count ? flags[j].isArtifact : false
                    let rr = points[j].rr_ms
                    if !isArtifact && rr >= 300 && rr <= 2000 {
                        windowBeats.append(rr)
                        windowDurationActual += Int64(rr)
                    }
                    j += 1
                }

                // Need at least 5 beats for meaningful HR
                if windowBeats.count >= 5 && windowDurationActual > 0 {
                    let windowHR = (Double(windowBeats.count) / Double(windowDurationActual)) * 60000.0
                    if windowHR >= 30 && windowHR <= 200 {
                        hrValues.append((i, windowHR, points[i].t_ms))
                    }
                }

                // Advance by ~5 seconds (50% overlap)
                i = j > i + 5 ? i + 5 : j
            }
        }

        guard !hrValues.isEmpty else {
            return OvernightStats.empty
        }

        // Find nadir (lowest HR) - now using proper HR calculation
        let nadirPoint = hrValues.min(by: { $0.hr < $1.hr })!
        let minHR = nadirPoint.hr
        let maxHR = hrValues.max(by: { $0.hr < $1.hr })!.hr
        let avgHR = hrValues.map { $0.hr }.reduce(0, +) / Double(hrValues.count)

        // Compute rolling RMSSD (5-minute windows every 30 seconds)
        let windowSize = 300 // ~5 min worth of beats
        let stepSize = 30
        var rollingRMSSD: [(index: Int, rmssd: Double, timeMs: Int64)] = []

        // Calculate from start to end, ensuring we hit both extremes
        var i = 0
        while i <= points.count - 1 {
            // Use adaptive window: full window in the middle, partial windows at edges
            let windowStart = max(0, i - windowSize / 2)
            let windowEnd = min(points.count, i + windowSize / 2)
            let windowPoints = Array(points[windowStart..<windowEnd])
            let windowFlags = windowStart < flags.count ? Array(flags[windowStart..<min(windowEnd, flags.count)]) : []

            // Get clean RR values in window
            var cleanRRs: [Double] = []
            for (j, pt) in windowPoints.enumerated() {
                let isArtifact = j < windowFlags.count ? windowFlags[j].isArtifact : false
                if !isArtifact && pt.rr_ms > 300 && pt.rr_ms < 2000 {
                    cleanRRs.append(Double(pt.rr_ms))
                }
            }

            // Calculate RMSSD (require at least 30 beats)
            if cleanRRs.count >= 30 {
                var sumSquaredDiffs: Double = 0
                for k in 1..<cleanRRs.count {
                    let diff = cleanRRs[k] - cleanRRs[k-1]
                    sumSquaredDiffs += diff * diff
                }
                let rmssd = sqrt(sumSquaredDiffs / Double(cleanRRs.count - 1))
                if rmssd > 0 && rmssd < 200 { // Sanity check
                    let midTime = points[i].t_ms
                    rollingRMSSD.append((i, rmssd, midTime))
                }
            }

            // On the last iteration, ensure we're exactly at the end
            if i < points.count - 1 && i + stepSize > points.count - 1 {
                i = points.count - 1
            } else {
                i += stepSize
            }
        }

        // Format times
        guard let firstPoint = points.first, let lastPoint = points.last else {
            return OvernightStats.empty
        }
        let startTime = firstPoint.t_ms
        let endTime = lastPoint.t_ms
        let recordingDurationMs = endTime - startTime

        // Calculate 30-70% sleep band for constrained Peak HRV search
        // This matches WindowSelector's logic - we want Peak HRV from the same region used for analysis
        let sleepStartMs: Int64
        let sleepEndMs: Int64
        if let hkSleep = healthKitSleep,
           let sleepStart = hkSleep.sleepStart,
           let sleepEnd = hkSleep.sleepEnd {
            // Use HealthKit sleep boundaries (relative to session start)
            sleepStartMs = max(0, Int64(sleepStart.timeIntervalSince(session.startDate) * 1000))
            sleepEndMs = min(recordingDurationMs, Int64(sleepEnd.timeIntervalSince(session.startDate) * 1000))
        } else {
            // Fall back to recording boundaries
            sleepStartMs = 0
            sleepEndMs = recordingDurationMs
        }

        let sleepDurationMs = sleepEndMs - sleepStartMs
        let limitEarlyMs = sleepStartMs + Int64(Double(sleepDurationMs) * 0.30)  // 30% of sleep
        let limitLateMs = sleepStartMs + Int64(Double(sleepDurationMs) * 0.70)   // 70% of sleep

        // Find peak HRV within the 30-70% band (matches analysis window search region)
        let constrainedRMSSD = rollingRMSSD.filter { $0.timeMs >= limitEarlyMs && $0.timeMs <= limitLateMs }
        let peakHRV = constrainedRMSSD.isEmpty
            ? rollingRMSSD.max(by: { $0.rmssd < $1.rmssd })  // Fallback to global if no data in band
            : constrainedRMSSD.max(by: { $0.rmssd < $1.rmssd })
        let avgRMSSD = rollingRMSSD.isEmpty ? 0 : rollingRMSSD.map { $0.rmssd }.reduce(0, +) / Double(rollingRMSSD.count)

        _ = nadirPoint.timeMs - startTime  // nadirTimeOffset (reserved for future use)
        _ = peakHRV?.timeMs ?? startTime  // peakHRVTimeOffset (reserved for future use)

        // === SLEEP DURATION ===
        // Use HealthKit data when available (authoritative from Apple Watch)
        // Fall back to HR-based estimation only when HealthKit is unavailable

        var sleepMinutes = 0
        var deepSleepMinutes = 0
        var awakeningsCount = 0
        var sleepEfficiency = 0.0
        var sleepFormatted = ""
        var isFromHealthKit = false

        if let hkSleep = healthKitSleep, hkSleep.totalSleepMinutes > 0 {
            isFromHealthKit = true
            // Use totalSleepMinutes which is the actual sum of asleep stages
            // This excludes awake periods during the night (sleepEnd - sleepStart would include them)
            sleepMinutes = hkSleep.totalSleepMinutes
            deepSleepMinutes = hkSleep.deepSleepMinutes ?? 0
            awakeningsCount = hkSleep.awakeMinutes > 0 ? max(1, hkSleep.awakeMinutes / 10) : 0
            sleepEfficiency = hkSleep.sleepEfficiency

            let sleepHours = sleepMinutes / 60
            let sleepMins = sleepMinutes % 60
            sleepFormatted = sleepHours > 0 ? "\(sleepHours)h \(sleepMins)m" : "\(sleepMins)m"
        } else if let hkSleep = healthKitSleep,
                  let sleepStart = hkSleep.sleepStart,
                  let sleepEnd = hkSleep.sleepEnd {
            // Fallback: If no totalSleepMinutes but have boundaries, use boundary diff
            // This is less accurate as it includes awake periods
            isFromHealthKit = true
            let sleepDurationSeconds = sleepEnd.timeIntervalSince(sleepStart)
            sleepMinutes = Int(sleepDurationSeconds / 60)
            deepSleepMinutes = hkSleep.deepSleepMinutes ?? 0
            awakeningsCount = hkSleep.awakeMinutes > 0 ? max(1, hkSleep.awakeMinutes / 10) : 0
            sleepEfficiency = hkSleep.sleepEfficiency

            let sleepHours = sleepMinutes / 60
            let sleepMins = sleepMinutes % 60
            sleepFormatted = sleepHours > 0 ? "\(sleepHours)h \(sleepMins)m" : "\(sleepMins)m"
        } else {
            // Fall back to HR-based estimation when HealthKit is unavailable
            // Use recording duration as "in bed" time, estimate sleep from HR patterns

            let recordingDurationMs = (points.last?.t_ms ?? 0) - startTime
            let recordingDurationMinutes = Int(recordingDurationMs / 60000)

            // For overnight recordings, most of the time is sleep
            // Use a simple heuristic: ~90% of overnight recording is typically sleep
            // This is a rough estimate - HealthKit data is much more accurate
            if recordingDurationMinutes > 180 { // More than 3 hours = overnight
                sleepMinutes = Int(Double(recordingDurationMinutes) * 0.90)
                // Deep sleep is typically 15-25% of total sleep
                deepSleepMinutes = Int(Double(sleepMinutes) * 0.20)
                awakeningsCount = recordingDurationMinutes / 90  // ~1 awakening per sleep cycle
            } else {
                // For shorter recordings, assume nap/rest with higher sleep percentage
                sleepMinutes = Int(Double(recordingDurationMinutes) * 0.85)
                deepSleepMinutes = Int(Double(sleepMinutes) * 0.15)
                awakeningsCount = 0
            }

            sleepEfficiency = recordingDurationMinutes > 0 ? Double(sleepMinutes) / Double(recordingDurationMinutes) * 100 : 0

            let sleepHours = sleepMinutes / 60
            let sleepMins = sleepMinutes % 60
            sleepFormatted = sleepHours > 0 ? "\(sleepHours)h \(sleepMins)m" : "\(sleepMins)m"
        }

        // Calculate actual clock times using series.startDate (guaranteed to match t_ms reference)
        // BUG FIX: Previously used session.startDate which could differ from series.startDate
        let nadirActualTime = series.absoluteTime(fromRelativeMs: nadirPoint.timeMs)
        let peakHRVActualTime = series.absoluteTime(fromRelativeMs: peakHRV?.timeMs ?? 0)

        // Calculate analysis window times
        let windowStartTimeMs: Int64
        let windowEndTimeMs: Int64
        if let wsMs = result.windowStartMs, let weMs = result.windowEndMs {
            // Use exact timestamps if available
            windowStartTimeMs = wsMs
            windowEndTimeMs = weMs
        } else {
            // Fall back to calculating from indices
            windowStartTimeMs = result.windowStart < points.count ? points[result.windowStart].t_ms : 0
            windowEndTimeMs = result.windowEnd < points.count ? points[result.windowEnd].t_ms : points.last?.t_ms ?? 0
        }
        // Use series.absoluteTime() for correct time calculation
        let windowStartActualTime = series.absoluteTime(fromRelativeMs: windowStartTimeMs)
        let windowEndActualTime = series.absoluteTime(fromRelativeMs: windowEndTimeMs)

        return OvernightStats(
            nadirHR: minHR,
            nadirIndex: nadirPoint.index,
            nadirTimeMs: nadirPoint.timeMs,
            nadirTimeFormatted: formatClockTime(nadirActualTime),
            minHR: minHR,
            maxHR: maxHR,
            avgHR: avgHR,
            peakRMSSD: peakHRV?.rmssd ?? 0,
            peakHRVIndex: peakHRV?.index ?? 0,
            peakHRVTimeMs: peakHRV?.timeMs ?? 0,
            peakHRVTimeFormatted: formatClockTime(peakHRVActualTime),
            avgRMSSD: avgRMSSD,
            rollingRMSSD: rollingRMSSD.map { ($0.index, $0.rmssd) },
            hrValues: hrValues.map { ($0.index, $0.hr) },
            windowStartIndex: result.windowStart,
            windowEndIndex: result.windowEnd,
            windowStartTimeFormatted: formatClockTime(windowStartActualTime),
            windowEndTimeFormatted: formatClockTime(windowEndActualTime),
            estimatedSleepDurationMinutes: sleepMinutes,
            estimatedSleepDurationFormatted: sleepFormatted,
            deepSleepMinutes: deepSleepMinutes,
            awakeningsCount: awakeningsCount,
            sleepEfficiency: sleepEfficiency,
            isHealthKitData: isFromHealthKit
        )
    }

    /// Format a date as clock time (e.g., "2:45 AM")
    private func formatClockTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}

// MARK: - Overnight Stats Model

struct OvernightStats {
    let nadirHR: Double
    let nadirIndex: Int
    let nadirTimeMs: Int64
    let nadirTimeFormatted: String
    let minHR: Double
    let maxHR: Double
    let avgHR: Double
    let peakRMSSD: Double
    let peakHRVIndex: Int
    let peakHRVTimeMs: Int64
    let peakHRVTimeFormatted: String
    let avgRMSSD: Double
    let rollingRMSSD: [(index: Int, rmssd: Double)]
    let hrValues: [(index: Int, hr: Double)]
    let windowStartIndex: Int
    let windowEndIndex: Int
    let windowStartTimeFormatted: String  // Clock time when analysis window starts
    let windowEndTimeFormatted: String    // Clock time when analysis window ends

    // Sleep quality metrics (from HealthKit when available, otherwise estimated from HR patterns)
    let estimatedSleepDurationMinutes: Int
    let estimatedSleepDurationFormatted: String
    let deepSleepMinutes: Int  // Time in lowest HR quartile (or from HealthKit)
    let awakeningsCount: Int   // HR spikes during sleep (or estimated from awake time)
    let sleepEfficiency: Double  // % of recording that was actual sleep
    let isHealthKitData: Bool  // True if sleep data came from Apple Health

    static let empty = OvernightStats(
        nadirHR: 0, nadirIndex: 0, nadirTimeMs: 0, nadirTimeFormatted: "",
        minHR: 0, maxHR: 0, avgHR: 0,
        peakRMSSD: 0, peakHRVIndex: 0, peakHRVTimeMs: 0, peakHRVTimeFormatted: "",
        avgRMSSD: 0, rollingRMSSD: [], hrValues: [],
        windowStartIndex: 0, windowEndIndex: 0,
        windowStartTimeFormatted: "", windowEndTimeFormatted: "",
        estimatedSleepDurationMinutes: 0, estimatedSleepDurationFormatted: "",
        deepSleepMinutes: 0, awakeningsCount: 0, sleepEfficiency: 0,
        isHealthKitData: false
    )
}

// MARK: - Stat Card

private struct OvernightStatCard: View {
    let title: String
    let value: String
    let unit: String
    let subtitle: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)

            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(.title2, design: .rounded).bold())
                    .foregroundColor(color)
                Text(unit)
                    .font(.caption2)
                    .foregroundColor(AppTheme.textTertiary)
            }

            Text(subtitle)
                .font(.caption2)
                .foregroundColor(AppTheme.textTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(AppTheme.sectionTint)
        .cornerRadius(AppTheme.smallCornerRadius)
    }
}

// MARK: - Interactive Chart Tooltip

private struct ChartTooltip: View {
    let value: String
    let unit: String
    let time: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(.headline, design: .rounded).bold())
                    .foregroundColor(color)
                Text(unit)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Text(time)
                .font(.caption2.bold())
                .foregroundColor(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
        )
    }
}

// MARK: - HR Chart Canvas

private struct OvernightHRChartCanvas: View {
    let session: HRVSession
    let result: HRVAnalysisResult
    let stats: OvernightStats
    var healthKitSleep: HealthKitManager.SleepData? = nil

    @State private var touchLocation: CGPoint? = nil
    @State private var isDragging = false

    // Reserve space for X-axis labels
    private let xAxisHeight: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let chartHeight = geo.size.height - xAxisHeight
            ZStack {
                VStack(spacing: 0) {
                    // Main chart canvas
                    chartCanvas(size: CGSize(width: geo.size.width, height: chartHeight))
                        .frame(height: chartHeight)

                    // X-axis time labels
                    xAxisLabels(width: geo.size.width)
                        .frame(height: xAxisHeight)
                }

                // Touch interaction overlay
                if let touch = touchLocation, isDragging {
                    // Vertical indicator line
                    Rectangle()
                        .fill(Color.white.opacity(0.8))
                        .frame(width: 1, height: chartHeight)
                        .position(x: touch.x, y: chartHeight / 2)

                    // Tooltip
                    if let (hr, time) = hrAtLocation(touch.x, size: CGSize(width: geo.size.width, height: chartHeight)) {
                        ChartTooltip(
                            value: String(format: "%.0f", hr),
                            unit: "bpm",
                            time: time,
                            color: AppTheme.terracotta
                        )
                        .position(x: tooltipX(touch.x, size: geo.size), y: 30)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        touchLocation = value.location
                        isDragging = true
                    }
                    .onEnded { _ in
                        isDragging = false
                        touchLocation = nil
                    }
            )
        }
    }

    /// X-axis labels showing clock times
    /// Always uses recording times (from RRSeries) since that's what the plotted data represents
    private func xAxisLabels(width: CGFloat) -> some View {
        guard let series = session.rrSeries, !series.points.isEmpty,
              let lastPoint = series.points.last else {
            return AnyView(EmptyView())
        }

        // IMPORTANT: X-axis must match the plotted data, which uses RRSeries timestamps
        // HealthKit sleep times are used for window selection, NOT for x-axis display
        // The plotted HR/HRV data spans the recording period, not the sleep period
        let recordingStart = series.startDate
        let recordingEnd = series.absoluteTime(fromRelativeMs: lastPoint.endMs)

        // Calculate time labels (show ~5 labels)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        // Generate label positions at regular intervals across the recording period
        let labelCount = 5
        var labels: [(String, CGFloat)] = []
        let totalDuration = recordingEnd.timeIntervalSince(recordingStart)

        for i in 0..<labelCount {
            let fraction = CGFloat(i) / CGFloat(labelCount - 1)
            let x = fraction * width
            let timeOffset = totalDuration * Double(fraction)
            let actualTime = recordingStart.addingTimeInterval(timeOffset)
            let timeStr = formatter.string(from: actualTime)
            labels.append((timeStr, x))
        }

        return AnyView(
            ZStack {
                ForEach(0..<labels.count, id: \.self) { i in
                    Text(labels[i].0)
                        .font(.system(size: 9))
                        .foregroundColor(AppTheme.textTertiary)
                        .position(x: labels[i].1, y: 10)
                }
            }
        )
    }

    private func tooltipX(_ x: CGFloat, size: CGSize) -> CGFloat {
        // Keep tooltip within bounds
        let padding: CGFloat = 50
        if x < padding {
            return padding
        } else if x > size.width - padding {
            return size.width - padding
        }
        return x
    }

    private func hrAtLocation(_ x: CGFloat, size: CGSize) -> (Double, String)? {
        let points = session.rrSeries?.points ?? []
        guard !points.isEmpty, !stats.hrValues.isEmpty else { return nil }

        let totalPoints = points.count
        let normalizedX = x / size.width
        let targetIndex = Int(normalizedX * CGFloat(totalPoints))

        // Find closest HR value
        var closestHR: (index: Int, hr: Double)? = nil
        var minDist = Int.max

        for (index, hr) in stats.hrValues {
            let dist = abs(index - targetIndex)
            if dist < minDist {
                minDist = dist
                closestHR = (index, hr)
            }
        }

        guard let hrPoint = closestHR, hrPoint.index < points.count else { return nil }

        // Calculate clock time using HealthKit sleep times when available
        let sleepStart: Date
        let sleepEnd: Date

        if let hkSleep = healthKitSleep, let hkStart = hkSleep.sleepStart, let hkEnd = hkSleep.sleepEnd {
            sleepStart = hkStart
            sleepEnd = hkEnd
        } else if let firstPoint = points.first, let lastPoint = points.last {
            let startTimeMs = firstPoint.t_ms
            let endTimeMs = lastPoint.t_ms
            let durationMs = endTimeMs - startTimeMs
            sleepStart = session.startDate
            sleepEnd = session.startDate.addingTimeInterval(Double(durationMs) / 1000.0)
        } else {
            return nil
        }

        // Map point index to time within the sleep period
        let totalDuration = sleepEnd.timeIntervalSince(sleepStart)
        let fraction = Double(hrPoint.index) / Double(totalPoints)
        let actualTime = sleepStart.addingTimeInterval(totalDuration * fraction)

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let timeString = formatter.string(from: actualTime)

        return (hrPoint.hr, timeString)
    }

    private func chartCanvas(size: CGSize) -> some View {
        Canvas { context, size in
                guard !stats.hrValues.isEmpty else { return }

                let points = session.rrSeries?.points ?? []
                guard !points.isEmpty else { return }

                let totalPoints = points.count

                // Y-axis range
                let minY = stats.minHR - 5
                let maxY = stats.maxHR + 5
                let yRange = maxY - minY

                // Draw analysis window highlight with border lines
                let windowStartX = CGFloat(stats.windowStartIndex) / CGFloat(totalPoints) * size.width
                let windowEndX = CGFloat(stats.windowEndIndex) / CGFloat(totalPoints) * size.width
                let windowRect = CGRect(x: windowStartX, y: 0, width: windowEndX - windowStartX, height: size.height)
                context.fill(Path(windowRect), with: .color(AppTheme.primary.opacity(0.2)))

                // Draw vertical border lines for the analysis window
                var startLine = Path()
                startLine.move(to: CGPoint(x: windowStartX, y: 0))
                startLine.addLine(to: CGPoint(x: windowStartX, y: size.height))
                context.stroke(startLine, with: .color(AppTheme.primary.opacity(0.8)), lineWidth: 2)

                var endLine = Path()
                endLine.move(to: CGPoint(x: windowEndX, y: 0))
                endLine.addLine(to: CGPoint(x: windowEndX, y: size.height))
                context.stroke(endLine, with: .color(AppTheme.primary.opacity(0.8)), lineWidth: 2)

                // Draw time labels at top of analysis window with background for visibility
                if !stats.windowStartTimeFormatted.isEmpty || !stats.windowEndTimeFormatted.isEmpty {
                    // Draw time range label centered in the window
                    let timeRangeText = Text("\(stats.windowStartTimeFormatted) - \(stats.windowEndTimeFormatted)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)

                    let centerX = (windowStartX + windowEndX) / 2

                    // Draw background pill behind the text
                    let pillRect = CGRect(x: centerX - 50, y: 4, width: 100, height: 18)
                    let pill = RoundedRectangle(cornerRadius: 9).path(in: pillRect)
                    context.fill(pill, with: .color(AppTheme.primary.opacity(0.9)))

                    context.draw(timeRangeText, at: CGPoint(x: centerX, y: 13), anchor: .center)
                }

                // Draw grid
                let gridColor = Color.gray.opacity(0.2)
                for i in 0...4 {
                    let y = size.height * CGFloat(i) / 4
                    var gridPath = Path()
                    gridPath.move(to: CGPoint(x: 0, y: y))
                    gridPath.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(gridPath, with: .color(gridColor), lineWidth: 0.5)
                }

                // Draw HR line
                var hrPath = Path()
                var first = true

                for (index, hr) in stats.hrValues {
                    let x = CGFloat(index) / CGFloat(totalPoints) * size.width
                    let y = size.height - CGFloat((hr - minY) / yRange) * size.height

                    if first {
                        hrPath.move(to: CGPoint(x: x, y: y))
                        first = false
                    } else {
                        hrPath.addLine(to: CGPoint(x: x, y: y))
                    }
                }

                // Fill under curve
                var fillPath = hrPath
                if let last = stats.hrValues.last {
                    let lastX = CGFloat(last.index) / CGFloat(totalPoints) * size.width
                    fillPath.addLine(to: CGPoint(x: lastX, y: size.height))
                    fillPath.addLine(to: CGPoint(x: 0, y: size.height))
                    fillPath.closeSubpath()
                }

                let gradient = Gradient(colors: [AppTheme.terracotta.opacity(0.3), AppTheme.terracotta.opacity(0.05)])
                context.fill(fillPath, with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(hrPath, with: .color(AppTheme.terracotta), lineWidth: 1.5)

                // Draw nadir marker
                let nadirX = CGFloat(stats.nadirIndex) / CGFloat(totalPoints) * size.width
                let nadirY = size.height - CGFloat((stats.nadirHR - minY) / yRange) * size.height

                // Vertical line at nadir
                var nadirLine = Path()
                nadirLine.move(to: CGPoint(x: nadirX, y: 0))
                nadirLine.addLine(to: CGPoint(x: nadirX, y: size.height))
                context.stroke(nadirLine, with: .color(AppTheme.mist.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                // Circle at nadir point
                let nadirCircle = Path(ellipseIn: CGRect(x: nadirX - 6, y: nadirY - 6, width: 12, height: 12))
                context.fill(nadirCircle, with: .color(AppTheme.mist))
                context.stroke(nadirCircle, with: .color(.white), lineWidth: 2)

                // Nadir label
                let nadirText = Text("\(Int(stats.nadirHR))")
                    .font(.caption.bold())
                    .foregroundColor(AppTheme.mist)
                context.draw(nadirText, at: CGPoint(x: nadirX, y: nadirY - 16))

                // Y-axis labels
                let topLabel = "\(Int(maxY))"
                let bottomLabel = "\(Int(minY))"
                context.draw(Text(topLabel).font(.system(size: 9)).foregroundColor(.gray), at: CGPoint(x: 15, y: 8))
                context.draw(Text(bottomLabel).font(.system(size: 9)).foregroundColor(.gray), at: CGPoint(x: 15, y: size.height - 22))
            }
    }
}

// MARK: - HRV Chart Canvas

private struct OvernightHRVChartCanvas: View {
    let session: HRVSession
    let result: HRVAnalysisResult
    let stats: OvernightStats
    var healthKitSleep: HealthKitManager.SleepData? = nil
    var onReanalyzeAt: ((Int64) -> Void)? = nil

    @State private var touchLocation: CGPoint? = nil
    @State private var isDragging = false
    @State private var selectedTimestampMs: Int64? = nil

    // Draggable window state (for future implementation)
    @State private var showDraggableWindow = false

    // Reserve space for X-axis labels
    private let xAxisHeight: CGFloat = 20

    // For now, just use the stats window indices directly
    private var effectiveWindowStartIndex: Int {
        stats.windowStartIndex
    }

    private var effectiveWindowEndIndex: Int {
        stats.windowEndIndex
    }

    var body: some View {
        GeometryReader { geo in
            let chartHeight = geo.size.height - xAxisHeight
            ZStack {
                VStack(spacing: 0) {
                    // Main chart canvas
                    chartCanvas(size: CGSize(width: geo.size.width, height: chartHeight))
                        .frame(height: chartHeight)

                    // X-axis time labels
                    xAxisLabels(width: geo.size.width)
                        .frame(height: xAxisHeight)
                }

                // Touch interaction overlay
                if let touch = touchLocation, isDragging {
                    // Vertical indicator line
                    Rectangle()
                        .fill(Color.white.opacity(0.8))
                        .frame(width: 1, height: chartHeight)
                        .position(x: touch.x, y: chartHeight / 2)

                    // Tooltip with optional "Analyze Here" button
                    if let (rmssd, time) = rmssdAtLocation(touch.x, size: CGSize(width: geo.size.width, height: chartHeight)) {
                        VStack(spacing: 4) {
                            ChartTooltip(
                                value: String(format: "%.0f", rmssd),
                                unit: "ms",
                                time: time,
                                color: AppTheme.sage
                            )

                            // Show "Analyze Here" button if reanalysis is available
                            if onReanalyzeAt != nil, let tsMs = timestampAtLocation(touch.x, size: CGSize(width: geo.size.width, height: chartHeight)) {
                                Button {
                                    onReanalyzeAt?(tsMs)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "scope")
                                            .font(.caption2)
                                        Text("Analyze Here")
                                            .font(.caption2.bold())
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(AppTheme.primary)
                                    .foregroundColor(.white)
                                    .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .position(x: tooltipX(touch.x, size: geo.size), y: 45)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        touchLocation = value.location
                        isDragging = true
                    }
                    .onEnded { _ in
                        isDragging = false
                        touchLocation = nil
                    }
            )
        }
    }

    /// Get timestamp in ms from session start for a given x position
    private func timestampAtLocation(_ x: CGFloat, size: CGSize) -> Int64? {
        let points = session.rrSeries?.points ?? []
        guard let firstPoint = points.first, let lastPoint = points.last else { return nil }

        let startMs = firstPoint.t_ms
        let endMs = lastPoint.t_ms
        let durationMs = endMs - startMs

        let normalizedX = max(0, min(1, x / size.width))
        return startMs + Int64(Double(durationMs) * normalizedX)
    }

    /// X-axis labels showing clock times
    /// Always uses recording times (from RRSeries) since that's what the plotted data represents
    private func xAxisLabels(width: CGFloat) -> some View {
        guard let series = session.rrSeries, !series.points.isEmpty,
              let lastPoint = series.points.last else {
            return AnyView(EmptyView())
        }

        // IMPORTANT: X-axis must match the plotted data, which uses RRSeries timestamps
        // HealthKit sleep times are used for window selection, NOT for x-axis display
        // The plotted HR/HRV data spans the recording period, not the sleep period
        let recordingStart = series.startDate
        let recordingEnd = series.absoluteTime(fromRelativeMs: lastPoint.endMs)

        // Calculate time labels (show ~5 labels)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        // Generate label positions at regular intervals across the recording period
        let labelCount = 5
        var labels: [(String, CGFloat)] = []
        let totalDuration = recordingEnd.timeIntervalSince(recordingStart)

        for i in 0..<labelCount {
            let fraction = CGFloat(i) / CGFloat(labelCount - 1)
            let x = fraction * width
            let timeOffset = totalDuration * Double(fraction)
            let actualTime = recordingStart.addingTimeInterval(timeOffset)
            let timeStr = formatter.string(from: actualTime)
            labels.append((timeStr, x))
        }

        return AnyView(
            ZStack {
                ForEach(0..<labels.count, id: \.self) { i in
                    Text(labels[i].0)
                        .font(.system(size: 9))
                        .foregroundColor(AppTheme.textTertiary)
                        .position(x: labels[i].1, y: 10)
                }
            }
        )
    }

    private func tooltipX(_ x: CGFloat, size: CGSize) -> CGFloat {
        let padding: CGFloat = 50
        if x < padding {
            return padding
        } else if x > size.width - padding {
            return size.width - padding
        }
        return x
    }

    private func rmssdAtLocation(_ x: CGFloat, size: CGSize) -> (Double, String)? {
        let points = session.rrSeries?.points ?? []
        guard !points.isEmpty, !stats.rollingRMSSD.isEmpty else { return nil }

        let totalPoints = points.count
        let normalizedX = x / size.width
        let targetIndex = Int(normalizedX * CGFloat(totalPoints))

        // Find closest RMSSD value
        var closestRMSSD: (index: Int, rmssd: Double)? = nil
        var minDist = Int.max

        for (index, rmssd) in stats.rollingRMSSD {
            let dist = abs(index - targetIndex)
            if dist < minDist {
                minDist = dist
                closestRMSSD = (index, rmssd)
            }
        }

        guard let rmssdPoint = closestRMSSD, rmssdPoint.index < points.count else { return nil }

        // Calculate clock time using HealthKit sleep times when available
        let sleepStart: Date
        let sleepEnd: Date

        if let hkSleep = healthKitSleep, let hkStart = hkSleep.sleepStart, let hkEnd = hkSleep.sleepEnd {
            sleepStart = hkStart
            sleepEnd = hkEnd
        } else if let firstPoint = points.first, let lastPoint = points.last {
            let startTimeMs = firstPoint.t_ms
            let endTimeMs = lastPoint.t_ms
            let durationMs = endTimeMs - startTimeMs
            sleepStart = session.startDate
            sleepEnd = session.startDate.addingTimeInterval(Double(durationMs) / 1000.0)
        } else {
            return nil
        }

        // Map point index to time within the sleep period
        let totalDuration = sleepEnd.timeIntervalSince(sleepStart)
        let fraction = Double(rmssdPoint.index) / Double(totalPoints)
        let actualTime = sleepStart.addingTimeInterval(totalDuration * fraction)

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let timeString = formatter.string(from: actualTime)

        return (rmssdPoint.rmssd, timeString)
    }

    private func chartCanvas(size: CGSize) -> some View {
        Canvas { context, size in
                guard !stats.rollingRMSSD.isEmpty else { return }

                let points = session.rrSeries?.points ?? []
                guard !points.isEmpty else { return }

                let totalPoints = points.count

                // Y-axis range
                let minY: Double = 0
                let maxY = max(stats.peakRMSSD * 1.2, 100)
                let yRange = maxY - minY

                // Draw analysis window highlight with border lines (use effective indices)
                let windowStartX = CGFloat(effectiveWindowStartIndex) / CGFloat(totalPoints) * size.width
                let windowEndX = CGFloat(effectiveWindowEndIndex) / CGFloat(totalPoints) * size.width
                let windowRect = CGRect(x: windowStartX, y: 0, width: windowEndX - windowStartX, height: size.height)
                context.fill(Path(windowRect), with: .color(AppTheme.primary.opacity(0.2)))

                // Draw vertical border lines for the analysis window
                var startLine = Path()
                startLine.move(to: CGPoint(x: windowStartX, y: 0))
                startLine.addLine(to: CGPoint(x: windowStartX, y: size.height))
                context.stroke(startLine, with: .color(AppTheme.primary.opacity(0.8)), lineWidth: 2)

                var endLine = Path()
                endLine.move(to: CGPoint(x: windowEndX, y: 0))
                endLine.addLine(to: CGPoint(x: windowEndX, y: size.height))
                context.stroke(endLine, with: .color(AppTheme.primary.opacity(0.8)), lineWidth: 2)

                // Draw time labels at top of analysis window with background for visibility
                if !stats.windowStartTimeFormatted.isEmpty || !stats.windowEndTimeFormatted.isEmpty {
                    // Draw time range label centered in the window
                    let timeRangeText = Text("\(stats.windowStartTimeFormatted) - \(stats.windowEndTimeFormatted)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)

                    let centerX = (windowStartX + windowEndX) / 2

                    // Draw background pill behind the text
                    let pillRect = CGRect(x: centerX - 50, y: 4, width: 100, height: 18)
                    let pill = RoundedRectangle(cornerRadius: 9).path(in: pillRect)
                    context.fill(pill, with: .color(AppTheme.primary.opacity(0.9)))

                    context.draw(timeRangeText, at: CGPoint(x: centerX, y: 13), anchor: .center)
                }

                // Draw grid
                let gridColor = Color.gray.opacity(0.2)
                for i in 0...4 {
                    let y = size.height * CGFloat(i) / 4
                    var gridPath = Path()
                    gridPath.move(to: CGPoint(x: 0, y: y))
                    gridPath.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(gridPath, with: .color(gridColor), lineWidth: 0.5)
                }

                // Draw HRV line
                var hrvPath = Path()
                var first = true

                for (index, rmssd) in stats.rollingRMSSD {
                    let x = CGFloat(index) / CGFloat(totalPoints) * size.width
                    let y = size.height - CGFloat((rmssd - minY) / yRange) * size.height

                    if first {
                        hrvPath.move(to: CGPoint(x: x, y: y))
                        first = false
                    } else {
                        hrvPath.addLine(to: CGPoint(x: x, y: y))
                    }
                }

                // Fill under curve
                var fillPath = hrvPath
                if let last = stats.rollingRMSSD.last {
                    let lastX = CGFloat(last.index) / CGFloat(totalPoints) * size.width
                    fillPath.addLine(to: CGPoint(x: lastX, y: size.height))
                    if let firstItem = stats.rollingRMSSD.first {
                        let firstX = CGFloat(firstItem.index) / CGFloat(totalPoints) * size.width
                        fillPath.addLine(to: CGPoint(x: firstX, y: size.height))
                    }
                    fillPath.closeSubpath()
                }

                let gradient = Gradient(colors: [AppTheme.sage.opacity(0.3), AppTheme.sage.opacity(0.05)])
                context.fill(fillPath, with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(hrvPath, with: .color(AppTheme.sage), lineWidth: 1.5)

                // Draw peak HRV marker
                let peakX = CGFloat(stats.peakHRVIndex) / CGFloat(totalPoints) * size.width
                let peakY = size.height - CGFloat((stats.peakRMSSD - minY) / yRange) * size.height

                // Vertical line at peak
                var peakLine = Path()
                peakLine.move(to: CGPoint(x: peakX, y: 0))
                peakLine.addLine(to: CGPoint(x: peakX, y: size.height))
                context.stroke(peakLine, with: .color(AppTheme.primary.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

                // Circle at peak point
                let peakCircle = Path(ellipseIn: CGRect(x: peakX - 6, y: peakY - 6, width: 12, height: 12))
                context.fill(peakCircle, with: .color(AppTheme.primary))
                context.stroke(peakCircle, with: .color(.white), lineWidth: 2)

                // Peak label
                let peakText = Text("\(Int(stats.peakRMSSD))")
                    .font(.caption.bold())
                    .foregroundColor(AppTheme.primary)
                context.draw(peakText, at: CGPoint(x: peakX, y: peakY - 16))

                // Y-axis labels
                context.draw(Text("\(Int(maxY))").font(.system(size: 9)).foregroundColor(.gray), at: CGPoint(x: 15, y: 8))
                context.draw(Text("0").font(.system(size: 9)).foregroundColor(.gray), at: CGPoint(x: 10, y: size.height - 22))
            }
    }
}

#Preview {
    OvernightChartsView(
        session: HRVSession(),
        result: HRVAnalysisResult(
            windowStart: 0,
            windowEnd: 100,
            timeDomain: TimeDomainMetrics(
                meanRR: 900,
                sdnn: 50,
                rmssd: 45,
                pnn50: 20,
                sdsd: 35,
                meanHR: 65,
                sdHR: 8,
                minHR: 52,
                maxHR: 78,
                triangularIndex: 12
            ),
            frequencyDomain: nil,
            nonlinear: NonlinearMetrics(
                sd1: 30,
                sd2: 50,
                sd1Sd2Ratio: 0.6,
                sampleEntropy: nil,
                approxEntropy: nil,
                dfaAlpha1: 0.95,
                dfaAlpha2: nil,
                dfaAlpha1R2: nil
            ),
            ansMetrics: nil,
            artifactPercentage: 2,
            cleanBeatCount: 300,
            analysisDate: Date()
        )
    )
}
