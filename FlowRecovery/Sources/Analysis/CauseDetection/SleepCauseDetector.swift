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

/// Detects causes based on HealthKit sleep data
/// Single Responsibility: only handles sleep-related cause detection
final class SleepCauseDetector: CauseDetectionStrategy {

    func detectCauses(in context: CauseDetectionContext) -> [DetectedCause] {
        // Skip positive causes for good readings (handled elsewhere)
        if context.isGoodReading || context.isExcellentReading {
            return detectPositiveSleepCauses(in: context)
        }

        var causes: [DetectedCause] = []
        let sleep = context.sleepInput

        guard sleep.totalSleepMinutes > 0 else {
            return causes
        }

        causes.append(contentsOf: detectInsufficientSleep(sleep: sleep))
        causes.append(contentsOf: detectFragmentedSleep(sleep: sleep))
        causes.append(contentsOf: detectLowDeepSleep(sleep: sleep, context: context))
        causes.append(contentsOf: detectSleepTrendIssues(in: context))

        return causes
    }

    // MARK: - Positive Sleep Detection

    private func detectPositiveSleepCauses(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        if let trends = context.sleepTrend, trends.nightsAnalyzed >= 3 {
            let sleep = context.sleepInput
            let tonightHours = Double(sleep.totalSleepMinutes) / 60.0

            let sleepDiffPercent = trends.averageSleepMinutes > 0 ?
                ((Double(sleep.totalSleepMinutes) - trends.averageSleepMinutes) / trends.averageSleepMinutes) * 100 : 0

            if sleepDiffPercent > HRVThresholds.trendSignificantChange {
                causes.append(DetectedCause(
                    cause: "Above Your Sleep Average",
                    confidence: .high,
                    explanation: "Tonight's \(String(format: "%.1f", tonightHours))h is \(Int(sleepDiffPercent))% above your recent average. Extra sleep pays immediate dividends in HRV recovery.",
                    weight: 0.78
                ))
            }

            if trends.trend == .improving {
                causes.append(DetectedCause(
                    cause: "Improving Sleep Pattern",
                    confidence: .moderateHigh,
                    explanation: "Your sleep has been improving over the past week. Consistent sleep improvements compound - expect HRV to continue rising if you maintain this pattern.",
                    weight: 0.7
                ))
            }
        }

        return causes
    }

    // MARK: - Negative Sleep Detection

    private func detectInsufficientSleep(sleep: AnalysisSummaryGenerator.SleepInput) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        if sleep.totalSleepMinutes < HRVThresholds.sleepVeryShortMinutes {
            let isSeverelShort = sleep.totalSleepMinutes < Int(HRVThresholds.sleepShortMinutes)
            let confidence: DetectedCause.CauseConfidence = isSeverelShort ? .veryHigh : .high
            let weight = isSeverelShort ? 0.92 : 0.82
            let hours = Double(sleep.totalSleepMinutes) / 60.0

            causes.append(DetectedCause(
                cause: "Insufficient Sleep",
                confidence: confidence,
                explanation: "HealthKit shows only \(String(format: "%.1f", hours)) hours of sleep. Research shows HRV drops significantly with less than 7 hours. This is likely the primary factor.",
                weight: weight
            ))
        }

        return causes
    }

    private func detectFragmentedSleep(sleep: AnalysisSummaryGenerator.SleepInput) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        let hasLowEfficiency = sleep.sleepEfficiency < HRVThresholds.sleepEfficiencyAcceptable
        let hasAdequateTime = sleep.inBedMinutes > Int(HRVThresholds.sleepShortMinutes)

        if hasLowEfficiency && hasAdequateTime {
            let isVeryLow = sleep.sleepEfficiency < HRVThresholds.sleepEfficiencyLow
            let confidence: DetectedCause.CauseConfidence = isVeryLow ? .high : .moderateHigh
            let weight = isVeryLow ? 0.78 : 0.65

            causes.append(DetectedCause(
                cause: "Fragmented Sleep",
                confidence: confidence,
                explanation: "HealthKit shows \(Int(sleep.sleepEfficiency))% sleep efficiency with \(sleep.awakeMinutes) minutes awake. Fragmented sleep reduces HRV even when total time is adequate.",
                weight: weight
            ))
        }

        return causes
    }

    private func detectLowDeepSleep(sleep: AnalysisSummaryGenerator.SleepInput, context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        guard let deepMins = sleep.deepSleepMinutes,
              deepMins < Int(HRVThresholds.deepSleepMinimumMinutes),
              sleep.totalSleepMinutes > Int(HRVThresholds.sleepShortMinutes) else {
            return causes
        }

        let deepPercent = Double(deepMins) / Double(sleep.totalSleepMinutes) * 100

        if deepPercent < HRVThresholds.deepSleepLowPercent {
            causes.append(DetectedCause(
                cause: "Low Deep Sleep",
                confidence: .moderateHigh,
                explanation: "Only \(deepMins) minutes of deep sleep (\(Int(deepPercent))%). Deep sleep is when HRV-restoring parasympathetic activity peaks. Alcohol, late meals, and stress reduce deep sleep.",
                weight: 0.7
            ))
        }

        return causes
    }

    private func detectSleepTrendIssues(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        guard let trends = context.sleepTrend, trends.nightsAnalyzed >= 3 else {
            return causes
        }

        let sleep = context.sleepInput
        let avgHours = trends.averageSleepMinutes / 60.0
        let tonightHours = Double(sleep.totalSleepMinutes) / 60.0

        let sleepDiffPercent = trends.averageSleepMinutes > 0 ?
            ((Double(sleep.totalSleepMinutes) - trends.averageSleepMinutes) / trends.averageSleepMinutes) * 100 : 0

        // Below average tonight
        if sleepDiffPercent < -HRVThresholds.trendSignificantChange && context.rmssd < HRVThresholds.rmssdGood {
            causes.append(DetectedCause(
                cause: "Below Your Sleep Average",
                confidence: .high,
                explanation: "Tonight's \(String(format: "%.1f", tonightHours))h is \(Int(abs(sleepDiffPercent)))% below your 7-day average of \(String(format: "%.1f", avgHours))h. Consistently getting less sleep than usual impacts HRV.",
                weight: 0.75
            ))
        }

        // Declining trend
        if trends.trend == .declining && context.rmssd < HRVThresholds.rmssdGood {
            causes.append(DetectedCause(
                cause: "Declining Sleep Pattern",
                confidence: .moderateHigh,
                explanation: "Your sleep duration has been trending downward over the past week (avg \(trends.averageSleepFormatted)). Cumulative sleep debt suppresses HRV even before you feel tired.",
                weight: 0.72
            ))
        }

        return causes
    }
}
