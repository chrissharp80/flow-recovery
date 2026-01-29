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

/// Detects positive contributing factors when HRV reading is good
/// Single Responsibility: only handles positive/recovery insights
final class PositiveCauseDetector: CauseDetectionStrategy {

    func detectCauses(in context: CauseDetectionContext) -> [DetectedCause] {
        guard context.isGoodReading || context.isExcellentReading else {
            return []
        }

        var causes: [DetectedCause] = []

        causes.append(contentsOf: detectSleepPositives(in: context))
        causes.append(contentsOf: detectTagPositives(in: context))
        causes.append(contentsOf: detectTrendPositives(in: context))

        return causes
    }

    // MARK: - Private Detection Methods

    private func detectSleepPositives(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        let sleep = context.sleepInput

        // Solid sleep duration
        if sleep.totalSleepMinutes >= HRVThresholds.sleepMinimumMinutes {
            let hours = Double(sleep.totalSleepMinutes) / 60.0
            causes.append(DetectedCause(
                cause: "Solid Sleep",
                confidence: .contributingFactor,
                explanation: "HealthKit shows \(String(format: "%.1f", hours)) hours of sleep. Getting 7+ hours is strongly associated with elevated HRV and better recovery.",
                weight: 0.8
            ))
        }

        // Excellent sleep efficiency
        if sleep.sleepEfficiency >= HRVThresholds.sleepEfficiencyGood {
            causes.append(DetectedCause(
                cause: "Excellent Sleep Quality",
                confidence: .contributingFactor,
                explanation: "HealthKit shows \(Int(sleep.sleepEfficiency))% sleep efficiency — minimal awakenings. Uninterrupted sleep allows full parasympathetic restoration.",
                weight: 0.75
            ))
        }

        // Strong deep sleep
        if let deepMins = sleep.deepSleepMinutes, sleep.totalSleepMinutes > 0 {
            let deepPercent = Double(deepMins) / Double(sleep.totalSleepMinutes) * 100
            if deepPercent >= HRVThresholds.deepSleepGoodPercent {
                causes.append(DetectedCause(
                    cause: "Strong Deep Sleep",
                    confidence: .contributingFactor,
                    explanation: "\(deepMins) minutes of deep sleep (\(Int(deepPercent))%). Deep sleep is when HRV peaks and the nervous system fully recovers.",
                    weight: 0.7
                ))
            }
        }

        return causes
    }

    private func detectTagPositives(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        let tags = context.selectedTags

        if tags.contains(where: { $0.name == "Good Sleep" }) {
            causes.append(DetectedCause(
                cause: "Restful Night",
                confidence: .high,
                explanation: "You reported good sleep. Quality sleep is the #1 factor in HRV recovery.",
                weight: 0.85
            ))
        }

        if tags.contains(where: { $0.name == "Rest Day" }) {
            causes.append(DetectedCause(
                cause: "Recovery Day",
                confidence: .moderateHigh,
                explanation: "Rest days allow accumulated training stress to dissipate, often resulting in HRV rebound.",
                weight: 0.7
            ))
        }

        return causes
    }

    private func detectTrendPositives(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        let stats = context.trendStats

        guard stats.hasData && stats.sessionCount >= 5 else {
            return causes
        }

        // Upward trend
        if let trend = stats.trend7Day, trend > HRVThresholds.trendModerateChange {
            causes.append(DetectedCause(
                cause: "Upward Trend",
                confidence: .pattern,
                explanation: "Your HRV has been climbing over the past week (+\(String(format: "%.0f", trend))%). Whatever you're doing is working — keep it up.",
                weight: 0.65
            ))
        }

        // Above baseline
        if context.rmssd > stats.avgRMSSD * 1.2 {
            let pctAbove = ((context.rmssd - stats.avgRMSSD) / stats.avgRMSSD) * 100
            causes.append(DetectedCause(
                cause: "Above Your Baseline",
                confidence: .excellent,
                explanation: "Today's HRV (\(Int(context.rmssd))ms) is \(String(format: "%.0f", pctAbove))% above your average. Your body is well-recovered and ready for challenges.",
                weight: 0.8
            ))
        }

        // Low resting HR
        if let baselineHR = stats.baselineHR {
            let hrDrop = baselineHR - context.trendStats.avgHR
            if hrDrop > 5 {
                causes.append(DetectedCause(
                    cause: "Low Resting HR",
                    confidence: .goodSign,
                    explanation: "Resting HR is \(String(format: "%.0f", hrDrop)) bpm below your baseline — indicates strong parasympathetic activity and cardiovascular efficiency.",
                    weight: 0.6
                ))
            }
        }

        return causes
    }
}
