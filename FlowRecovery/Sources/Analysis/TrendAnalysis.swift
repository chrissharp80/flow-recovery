//
//  Copyright © 2024-2026 Chris Sharp. All rights reserved.
//
//  This source code is provided for reference and verification purposes only.
//  Unauthorized copying, modification, distribution, or use of this code,
//  via any medium, is strictly prohibited without prior written permission.
//
//  For licensing inquiries, contact the copyright holder.
//

import Foundation

/// Trend analysis for multi-session HRV comparison
final class TrendAnalyzer {

    // MARK: - Data Point

    /// Single data point for trend analysis
    struct TrendDataPoint: Codable, Identifiable {
        let id: UUID
        let date: Date
        let rmssd: Double
        let sdnn: Double
        let meanHR: Double
        let lfHfRatio: Double?
        let hf: Double?
        let lf: Double?
        let dfaAlpha1: Double?
        let stressIndex: Double?
        let readinessScore: Double?
        let artifactPercent: Double

        init(session: HRVSession) {
            self.id = session.id
            self.date = session.startDate

            if let result = session.analysisResult {
                self.rmssd = result.timeDomain.rmssd
                self.sdnn = result.timeDomain.sdnn
                self.meanHR = result.timeDomain.meanHR
                self.lfHfRatio = result.frequencyDomain?.lfHfRatio
                self.hf = result.frequencyDomain?.hf
                self.lf = result.frequencyDomain?.lf
                self.dfaAlpha1 = result.nonlinear.dfaAlpha1
                self.stressIndex = result.ansMetrics?.stressIndex
                self.readinessScore = result.ansMetrics?.readinessScore
                self.artifactPercent = result.artifactPercentage
            } else {
                self.rmssd = 0
                self.sdnn = 0
                self.meanHR = 0
                self.lfHfRatio = nil
                self.hf = nil
                self.lf = nil
                self.dfaAlpha1 = nil
                self.stressIndex = nil
                self.readinessScore = nil
                self.artifactPercent = 100
            }
        }
    }

    // MARK: - Trend Statistics

    /// Statistics for a metric over time
    struct TrendStatistics {
        let metric: String
        let count: Int
        let mean: Double
        let standardDeviation: Double
        let min: Double
        let max: Double
        let percentile25: Double
        let percentile75: Double
        let trend: TrendDirection
        let trendSlope: Double
        let coefficientOfVariation: Double

        /// Personal baseline (rolling 7-day average)
        let baseline: Double?

        /// Current value vs baseline
        let deviationFromBaseline: Double?
    }

    /// Trend direction
    enum TrendDirection: String {
        case improving = "Improving"
        case stable = "Stable"
        case declining = "Declining"
        case insufficient = "Insufficient Data"
    }

    // MARK: - Trend Summary

    /// Overall trend summary
    struct TrendSummary {
        let period: DateInterval
        let dataPoints: [TrendDataPoint]
        let rmssdStats: TrendStatistics
        let sdnnStats: TrendStatistics
        let hrStats: TrendStatistics
        let lfHfStats: TrendStatistics?
        let dfaAlpha1Stats: TrendStatistics?
        let stressStats: TrendStatistics?
        let readinessStats: TrendStatistics?
        let overallTrend: TrendDirection
        let insights: [String]
    }

    // MARK: - Time Periods

    enum TimePeriod {
        case week
        case twoWeeks
        case month
        case threeMonths
        case all

        var days: Int? {
            switch self {
            case .week: return 7
            case .twoWeeks: return 14
            case .month: return 30
            case .threeMonths: return 90
            case .all: return nil
            }
        }

        var displayName: String {
            switch self {
            case .week: return "7 Days"
            case .twoWeeks: return "14 Days"
            case .month: return "30 Days"
            case .threeMonths: return "90 Days"
            case .all: return "All Time"
            }
        }
    }

    // MARK: - Public API

    /// Analyze trends from archived sessions
    /// Note: Only overnight sessions are included in trend calculations.
    /// Naps and quick readings are excluded to maintain consistent daily baselines.
    static func analyze(
        sessions: [HRVSession],
        period: TimePeriod = .month
    ) -> TrendSummary? {

        // Filter valid sessions with analysis results
        // Only include overnight sessions in trends (naps and quick readings are excluded)
        let validSessions = sessions.filter { $0.analysisResult != nil && $0.sessionType == .overnight }
        guard validSessions.count >= 2 else { return nil }

        // Convert to data points
        var dataPoints = validSessions.map { TrendDataPoint(session: $0) }

        // Filter by period
        if let days = period.days {
            let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
            dataPoints = dataPoints.filter { $0.date >= cutoff }
        }

        // Sort by date
        dataPoints.sort { $0.date < $1.date }

        guard dataPoints.count >= 2 else { return nil }

        // Compute statistics
        let rmssdStats = computeStatistics(
            metric: "RMSSD",
            values: dataPoints.map { $0.rmssd },
            dates: dataPoints.map { $0.date },
            higherIsBetter: true
        )

        let sdnnStats = computeStatistics(
            metric: "SDNN",
            values: dataPoints.map { $0.sdnn },
            dates: dataPoints.map { $0.date },
            higherIsBetter: true
        )

        let hrStats = computeStatistics(
            metric: "Mean HR",
            values: dataPoints.map { $0.meanHR },
            dates: dataPoints.map { $0.date },
            higherIsBetter: false  // Lower resting HR is generally better
        )

        let lfHfStats: TrendStatistics?
        let lfHfValues = dataPoints.compactMap { $0.lfHfRatio }
        if lfHfValues.count >= 2 {
            lfHfStats = computeStatistics(
                metric: "LF/HF",
                values: lfHfValues,
                dates: dataPoints.filter { $0.lfHfRatio != nil }.map { $0.date },
                higherIsBetter: false  // Lower ratio often indicates parasympathetic dominance
            )
        } else {
            lfHfStats = nil
        }

        let dfaStats: TrendStatistics?
        let dfaValues = dataPoints.compactMap { $0.dfaAlpha1 }
        if dfaValues.count >= 2 {
            dfaStats = computeStatistics(
                metric: "DFA α1",
                values: dfaValues,
                dates: dataPoints.filter { $0.dfaAlpha1 != nil }.map { $0.date },
                higherIsBetter: nil  // Optimal is around 1.0
            )
        } else {
            dfaStats = nil
        }

        let stressStats: TrendStatistics?
        let stressValues = dataPoints.compactMap { $0.stressIndex }
        if stressValues.count >= 2 {
            stressStats = computeStatistics(
                metric: "Stress Index",
                values: stressValues,
                dates: dataPoints.filter { $0.stressIndex != nil }.map { $0.date },
                higherIsBetter: false
            )
        } else {
            stressStats = nil
        }

        let readinessStats: TrendStatistics?
        let readinessValues = dataPoints.compactMap { $0.readinessScore }
        if readinessValues.count >= 2 {
            readinessStats = computeStatistics(
                metric: "Readiness",
                values: readinessValues,
                dates: dataPoints.filter { $0.readinessScore != nil }.map { $0.date },
                higherIsBetter: true
            )
        } else {
            readinessStats = nil
        }

        // Determine overall trend
        let overallTrend = determineOverallTrend(
            rmssd: rmssdStats,
            sdnn: sdnnStats,
            readiness: readinessStats
        )

        // Generate insights
        let insights = generateInsights(
            dataPoints: dataPoints,
            rmssd: rmssdStats,
            sdnn: sdnnStats,
            hr: hrStats,
            stress: stressStats,
            readiness: readinessStats
        )

        // Build period
        guard let firstDataPoint = dataPoints.first,
              let lastDataPoint = dataPoints.last else {
            return nil
        }
        let periodInterval = DateInterval(
            start: firstDataPoint.date,
            end: lastDataPoint.date
        )

        return TrendSummary(
            period: periodInterval,
            dataPoints: dataPoints,
            rmssdStats: rmssdStats,
            sdnnStats: sdnnStats,
            hrStats: hrStats,
            lfHfStats: lfHfStats,
            dfaAlpha1Stats: dfaStats,
            stressStats: stressStats,
            readinessStats: readinessStats,
            overallTrend: overallTrend,
            insights: insights
        )
    }

    // MARK: - Rolling Baseline

    /// Compute rolling baseline for a metric
    static func computeRollingBaseline(
        values: [Double],
        dates: [Date],
        windowDays: Int = 7
    ) -> [Double] {

        guard values.count == dates.count else { return values }

        var baselines = [Double]()

        for i in 0..<values.count {
            let currentDate = dates[i]
            let windowStart = Calendar.current.date(byAdding: .day, value: -windowDays, to: currentDate)!

            // Get values within window before current date
            var windowValues = [Double]()
            for j in 0..<i {
                if dates[j] >= windowStart && dates[j] < currentDate {
                    windowValues.append(values[j])
                }
            }

            if windowValues.isEmpty {
                // No prior data, use current value
                baselines.append(values[i])
            } else {
                baselines.append(windowValues.reduce(0, +) / Double(windowValues.count))
            }
        }

        return baselines
    }

    // MARK: - Private Methods

    private static func computeStatistics(
        metric: String,
        values: [Double],
        dates: [Date],
        higherIsBetter: Bool?
    ) -> TrendStatistics {

        let n = values.count
        guard n >= 2 else {
            return TrendStatistics(
                metric: metric,
                count: n,
                mean: values.first ?? 0,
                standardDeviation: 0,
                min: values.first ?? 0,
                max: values.first ?? 0,
                percentile25: values.first ?? 0,
                percentile75: values.first ?? 0,
                trend: .insufficient,
                trendSlope: 0,
                coefficientOfVariation: 0,
                baseline: nil,
                deviationFromBaseline: nil
            )
        }

        // Basic statistics
        let mean = values.reduce(0, +) / Double(n)
        let variance = values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(n - 1)
        let sd = sqrt(variance)
        let cv = mean > 0 ? sd / mean * 100 : 0

        let sorted = values.sorted()
        guard let minVal = sorted.first, let maxVal = sorted.last else {
            return TrendStatistics(
                metric: metric,
                count: n,
                mean: mean,
                standardDeviation: sd,
                min: 0,
                max: 0,
                percentile25: 0,
                percentile75: 0,
                trend: .insufficient,
                trendSlope: 0,
                coefficientOfVariation: cv,
                baseline: nil,
                deviationFromBaseline: nil
            )
        }

        // Percentiles
        let p25Index = Int(Double(n) * 0.25)
        let p75Index = Int(Double(n) * 0.75)
        let p25 = sorted[Swift.min(p25Index, n - 1)]
        let p75 = sorted[Swift.min(p75Index, n - 1)]

        // Linear regression for trend
        let slope = linearRegressionSlope(values: values)

        // Determine trend direction
        let trend: TrendDirection
        let slopeThreshold = sd * 0.1  // Significant if slope > 10% of SD

        if abs(slope) < slopeThreshold {
            trend = .stable
        } else if let better = higherIsBetter {
            trend = (slope > 0) == better ? .improving : .declining
        } else {
            // For metrics like DFA where optimal is ~1.0
            trend = abs(slope) < slopeThreshold ? .stable : (slope > 0 ? .improving : .declining)
        }

        // Compute baseline (rolling 7-day average)
        let baselines = computeRollingBaseline(values: values, dates: dates, windowDays: 7)
        let currentBaseline = baselines.last
        let currentValue = values.last ?? mean
        let deviation = currentBaseline.map { (currentValue - $0) / $0 * 100 }

        return TrendStatistics(
            metric: metric,
            count: n,
            mean: mean,
            standardDeviation: sd,
            min: minVal,
            max: maxVal,
            percentile25: p25,
            percentile75: p75,
            trend: trend,
            trendSlope: slope,
            coefficientOfVariation: cv,
            baseline: currentBaseline,
            deviationFromBaseline: deviation
        )
    }

    private static func linearRegressionSlope(values: [Double]) -> Double {
        let n = Double(values.count)
        guard n >= 2 else { return 0 }

        // Use index as x (0, 1, 2, ...)
        let xMean = (n - 1) / 2
        let yMean = values.reduce(0, +) / n

        var numerator = 0.0
        var denominator = 0.0

        for (i, y) in values.enumerated() {
            let x = Double(i)
            numerator += (x - xMean) * (y - yMean)
            denominator += (x - xMean) * (x - xMean)
        }

        return denominator > 0 ? numerator / denominator : 0
    }

    private static func determineOverallTrend(
        rmssd: TrendStatistics,
        sdnn: TrendStatistics,
        readiness: TrendStatistics?
    ) -> TrendDirection {

        var improvingCount = 0
        var decliningCount = 0

        for stat in [rmssd, sdnn] {
            switch stat.trend {
            case .improving: improvingCount += 1
            case .declining: decliningCount += 1
            default: break
            }
        }

        if let r = readiness {
            switch r.trend {
            case .improving: improvingCount += 2  // Weight readiness more
            case .declining: decliningCount += 2
            default: break
            }
        }

        if improvingCount > decliningCount + 1 {
            return .improving
        } else if decliningCount > improvingCount + 1 {
            return .declining
        } else {
            return .stable
        }
    }

    private static func generateInsights(
        dataPoints: [TrendDataPoint],
        rmssd: TrendStatistics,
        sdnn: TrendStatistics,
        hr: TrendStatistics,
        stress: TrendStatistics?,
        readiness: TrendStatistics?
    ) -> [String] {

        var insights = [String]()

        // RMSSD trend insight
        switch rmssd.trend {
        case .improving:
            insights.append("Your parasympathetic activity (RMSSD) is trending upward, indicating improving recovery capacity.")
        case .declining:
            insights.append("Your RMSSD is declining. Consider reducing training load or improving sleep quality.")
        case .stable:
            insights.append("Your HRV (RMSSD) is stable, suggesting consistent recovery patterns.")
        case .insufficient:
            break
        }

        // Variability insight
        if rmssd.coefficientOfVariation > 25 {
            insights.append("High day-to-day HRV variability detected. This could indicate inconsistent sleep or recovery patterns.")
        }

        // Baseline deviation
        if let deviation = rmssd.deviationFromBaseline {
            if deviation < -15 {
                insights.append(String(format: "Today's HRV is %.0f%% below your baseline. Consider a rest day.", abs(deviation)))
            } else if deviation > 15 {
                insights.append(String(format: "Today's HRV is %.0f%% above your baseline. Good day for harder training.", deviation))
            }
        }

        // Stress insight
        if let s = stress {
            if s.mean > 150 {
                insights.append("Your average Stress Index is elevated. Focus on stress management and recovery.")
            } else if s.mean < 50 && s.trend != .declining {
                insights.append("Your Stress Index is in a healthy range, indicating good autonomic balance.")
            }
        }

        // Readiness insight
        if let r = readiness {
            if r.trend == .improving {
                insights.append("Your Readiness Score is improving. Training adaptations are progressing well.")
            } else if r.mean < 5 {
                insights.append("Your average Readiness is below optimal. Prioritize recovery strategies.")
            }
        }

        // Heart rate trend
        if hr.trend == .declining && hr.trendSlope < -0.5 {
            insights.append("Your resting heart rate is decreasing, a positive sign of cardiovascular adaptation.")
        }

        // Data quality
        let highArtifactSessions = dataPoints.filter { $0.artifactPercent > 5 }.count
        if highArtifactSessions > dataPoints.count / 3 {
            insights.append("Several sessions have elevated artifact levels. Ensure proper sensor contact during recordings.")
        }

        return insights
    }

    // MARK: - Comparison

    /// Compare two time periods
    static func comparePeriods(
        current: TrendSummary,
        previous: TrendSummary
    ) -> [String] {

        var comparisons = [String]()

        // RMSSD change
        let rmssdChange = (current.rmssdStats.mean - previous.rmssdStats.mean) / previous.rmssdStats.mean * 100
        if abs(rmssdChange) > 5 {
            let direction = rmssdChange > 0 ? "increased" : "decreased"
            comparisons.append(String(format: "RMSSD has %@ by %.1f%% compared to the previous period.", direction, abs(rmssdChange)))
        }

        // Readiness change
        if let currentReadiness = current.readinessStats, let prevReadiness = previous.readinessStats {
            let change = currentReadiness.mean - prevReadiness.mean
            if abs(change) > 0.5 {
                let direction = change > 0 ? "improved" : "declined"
                comparisons.append(String(format: "Average Readiness has %@ by %.1f points.", direction, abs(change)))
            }
        }

        return comparisons
    }
}

// MARK: - Chart Data Helpers

extension TrendAnalyzer {

    /// Get chart-ready data for a specific metric
    static func chartData(
        from dataPoints: [TrendDataPoint],
        metric: ChartMetric
    ) -> [(date: Date, value: Double)] {

        return dataPoints.compactMap { point -> (Date, Double)? in
            let value: Double?
            switch metric {
            case .rmssd: value = point.rmssd
            case .sdnn: value = point.sdnn
            case .meanHR: value = point.meanHR
            case .lfHfRatio: value = point.lfHfRatio
            case .hf: value = point.hf
            case .lf: value = point.lf
            case .dfaAlpha1: value = point.dfaAlpha1
            case .stressIndex: value = point.stressIndex
            case .readiness: value = point.readinessScore
            }
            guard let v = value else { return nil }
            return (point.date, v)
        }
    }

    enum ChartMetric: String, CaseIterable {
        case rmssd = "RMSSD"
        case sdnn = "SDNN"
        case meanHR = "Mean HR"
        case lfHfRatio = "LF/HF"
        case hf = "HF Power"
        case lf = "LF Power"
        case dfaAlpha1 = "DFA α1"
        case stressIndex = "Stress Index"
        case readiness = "Readiness"
    }
}
