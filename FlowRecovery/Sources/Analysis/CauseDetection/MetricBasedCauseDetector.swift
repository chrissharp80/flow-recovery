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

/// Detects causes based on HRV metrics (without user tags)
/// Single Responsibility: only handles metric-based cause detection
final class MetricBasedCauseDetector: CauseDetectionStrategy {

    func detectCauses(in context: CauseDetectionContext) -> [DetectedCause] {
        // Skip for good readings
        if context.isGoodReading || context.isExcellentReading {
            return []
        }

        var causes: [DetectedCause] = []

        causes.append(contentsOf: detectPossibleIllness(in: context))
        causes.append(contentsOf: detectUntaggedStress(in: context))
        causes.append(contentsOf: detectPossibleSleepDebt(in: context))
        causes.append(contentsOf: detectTrainingLoad(in: context))
        causes.append(contentsOf: detectDehydration(in: context))

        return causes
    }

    // MARK: - Illness Detection

    private func detectPossibleIllness(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        // Skip if user already tagged illness
        if context.selectedTags.contains(where: { $0.name == "Illness" }) {
            return causes
        }

        let illnessSignals = detectIllnessPattern(in: context)

        // Strong illness pattern: 3+ consecutive declines with low HRV and high stress
        if illnessSignals.consecutiveDeclines >= 3 &&
           context.rmssd < HRVThresholds.rmssdGood &&
           context.stressIndex > HRVThresholds.stressIndexElevated {
            causes.append(DetectedCause(
                cause: "Likely Getting Sick",
                confidence: .high,
                explanation: "Your HRV has declined for \(illnessSignals.consecutiveDeclines) consecutive days (\(String(format: "%.0f", illnessSignals.totalDeclinePercent))% total drop). This pattern strongly suggests your immune system is fighting something. Monitor closely for symptoms.",
                weight: 0.88
            ))
        }
        // Moderate illness pattern: 2+ declines with low HRV or elevated HR
        else if illnessSignals.consecutiveDeclines >= 2 &&
                (context.rmssd < HRVThresholds.rmssdReduced || illnessSignals.hrElevated) {
            var explanation = "Your HRV has dropped for \(illnessSignals.consecutiveDeclines) days in a row"
            if illnessSignals.hrElevated {
                explanation += " and your resting HR is elevated (+\(String(format: "%.0f", illnessSignals.hrIncrease)) bpm)"
            }
            explanation += ". This often precedes illness symptoms by 1-2 days."

            causes.append(DetectedCause(
                cause: "Possible Illness Coming On",
                confidence: .moderateHigh,
                explanation: explanation,
                weight: 0.72
            ))
        }
        // Very low HRV with high stress
        else if context.rmssd < HRVThresholds.rmssdLow && context.stressIndex > 250 {
            causes.append(DetectedCause(
                cause: "Possible Immune Response",
                confidence: .high,
                explanation: "Very low HRV + high stress often precedes illness by 1-2 days. Monitor for symptoms.",
                weight: 0.75
            ))
        }
        // Elevated HR with high stress
        else if illnessSignals.hrElevated && context.stressIndex > HRVThresholds.stressIndexElevated && context.rmssd < HRVThresholds.rmssdGood {
            causes.append(DetectedCause(
                cause: "Elevated Resting HR",
                confidence: .moderate,
                explanation: "Your resting HR is \(String(format: "%.0f", illnessSignals.hrIncrease)) bpm above your average. Combined with elevated stress, this can indicate your body is fighting something or under significant strain.",
                weight: 0.55
            ))
        }
        // Low HRV with elevated stress
        else if context.rmssd < HRVThresholds.rmssdReduced && context.stressIndex > 220 {
            causes.append(DetectedCause(
                cause: "Possible Illness Coming On",
                confidence: .moderate,
                explanation: "This pattern sometimes appears before cold/flu symptoms manifest.",
                weight: 0.45
            ))
        }

        return causes
    }

    private func detectIllnessPattern(in context: CauseDetectionContext) -> IllnessSignals {
        let recentSessions = context.recentSessions

        guard recentSessions.count >= 3 else {
            return IllnessSignals(consecutiveDeclines: 0, totalDeclinePercent: 0, hrElevated: false, hrIncrease: 0)
        }

        let sortedSessions = recentSessions
            .filter { $0.state == .complete && $0.analysisResult != nil }
            .sorted { $0.startDate > $1.startDate }

        guard sortedSessions.count >= 3 else {
            return IllnessSignals(consecutiveDeclines: 0, totalDeclinePercent: 0, hrElevated: false, hrIncrease: 0)
        }

        var consecutiveDeclines = 0
        var totalDeclinePercent = 0.0
        var previousRMSSD: Double?

        for session in sortedSessions.prefix(7) {
            guard let rmssd = session.analysisResult?.timeDomain.rmssd else { continue }

            if let prev = previousRMSSD {
                if rmssd < prev * HRVThresholds.illnessDeclineThreshold {
                    consecutiveDeclines += 1
                    totalDeclinePercent += ((prev - rmssd) / prev) * 100
                } else {
                    break
                }
            }
            previousRMSSD = rmssd
        }

        // Check HR elevation
        let hrValues = sortedSessions.prefix(14).compactMap { $0.analysisResult?.timeDomain.meanHR }
        let avgHR = hrValues.isEmpty ? 0 : hrValues.reduce(0, +) / Double(hrValues.count)
        let currentHR = context.trendStats.avgHR
        let hrIncrease = currentHR - avgHR
        let hrElevated = hrIncrease > HRVThresholds.hrElevationThreshold

        return IllnessSignals(
            consecutiveDeclines: consecutiveDeclines,
            totalDeclinePercent: totalDeclinePercent,
            hrElevated: hrElevated,
            hrIncrease: hrIncrease
        )
    }

    // MARK: - Stress Detection

    private func detectUntaggedStress(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        // Skip if user already tagged stress
        if context.selectedTags.contains(where: { $0.name == "Stressed" }) {
            return causes
        }

        if context.lfHfRatio > HRVThresholds.lfHfSympatheticDominance && context.stressIndex > HRVThresholds.stressIndexElevated {
            causes.append(DetectedCause(
                cause: "Unidentified Stress",
                confidence: .moderateHigh,
                explanation: "High sympathetic activation without tagged cause. Consider what might be weighing on you mentally.",
                weight: 0.65
            ))
        }

        return causes
    }

    // MARK: - Sleep Debt Detection

    private func detectPossibleSleepDebt(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        // Skip if user tagged poor sleep
        if context.selectedTags.contains(where: { $0.name == "Poor Sleep" }) {
            return causes
        }

        if context.rmssd < HRVThresholds.rmssdReduced && context.dfaAlpha1 > HRVThresholds.dfaAlpha1HighVariability {
            causes.append(DetectedCause(
                cause: "Possible Sleep Debt",
                confidence: .moderate,
                explanation: "Reduced HRV with elevated DFA α1 is characteristic of insufficient sleep.",
                weight: 0.55
            ))
        }

        return causes
    }

    // MARK: - Training Load Detection

    private func detectTrainingLoad(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        // Skip if user tagged post-exercise
        if context.selectedTags.contains(where: { $0.name == "Post-Exercise" }) {
            return causes
        }

        if context.rmssd < HRVThresholds.rmssdGood &&
           context.pnn50 < HRVThresholds.pnn50Low &&
           context.dfaAlpha1 > 1.1 {
            causes.append(DetectedCause(
                cause: "Accumulated Training Load",
                confidence: .lowModerate,
                explanation: "If you've been training hard recently, your body may need extra recovery time.",
                weight: 0.4
            ))
        }

        return causes
    }

    // MARK: - Dehydration Detection

    private func detectDehydration(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        if context.rmssd < HRVThresholds.rmssdGood &&
           context.stressIndex > 180 &&
           context.lfHfRatio < HRVThresholds.lfHfOptimalUpper {
            causes.append(DetectedCause(
                cause: "Dehydration or Fasting",
                confidence: .lowModerate,
                explanation: "Low HRV without strong sympathetic shift can indicate dehydration or low blood sugar.",
                weight: 0.35
            ))
        }

        return causes
    }
}

// MARK: - Supporting Types

private struct IllnessSignals {
    let consecutiveDeclines: Int
    let totalDeclinePercent: Double
    let hrElevated: Bool
    let hrIncrease: Double
}
