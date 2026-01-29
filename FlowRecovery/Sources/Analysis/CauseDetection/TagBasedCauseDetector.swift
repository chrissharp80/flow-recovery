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

/// Detects causes based on user-reported tags
/// Single Responsibility: only handles tag-based cause detection
final class TagBasedCauseDetector: CauseDetectionStrategy {

    func detectCauses(in context: CauseDetectionContext) -> [DetectedCause] {
        // Skip for good readings (positive causes handled elsewhere)
        if context.isGoodReading || context.isExcellentReading {
            return []
        }

        var causes: [DetectedCause] = []
        let tags = context.selectedTags

        causes.append(contentsOf: detectAlcoholCause(tags: tags, context: context))
        causes.append(contentsOf: detectSleepTags(tags: tags, context: context))
        causes.append(contentsOf: detectDietTags(tags: tags, context: context))
        causes.append(contentsOf: detectLifestyleTags(tags: tags, context: context))
        causes.append(contentsOf: detectHealthTags(tags: tags, context: context))

        return causes
    }

    // MARK: - Private Detection Methods

    private func detectAlcoholCause(tags: Set<ReadingTag>, context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        if tags.contains(where: { $0.name == "Alcohol" }) {
            let isLowHRV = context.rmssd < HRVThresholds.rmssdReduced
            let confidence: DetectedCause.CauseConfidence = isLowHRV ? .veryHigh : .high
            let weight = isLowHRV ? 0.95 : 0.85

            causes.append(DetectedCause(
                cause: "Alcohol Consumption",
                confidence: confidence,
                explanation: "You tagged alcohol. Even moderate drinking suppresses HRV for 24-48 hours by disrupting sleep architecture and increasing sympathetic tone.",
                weight: weight
            ))
        }

        return causes
    }

    private func detectSleepTags(tags: Set<ReadingTag>, context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        if tags.contains(where: { $0.name == "Poor Sleep" }) {
            let hasFatigueSignal = context.dfaAlpha1 > HRVThresholds.dfaAlpha1HighVariability
            let confidence: DetectedCause.CauseConfidence = hasFatigueSignal ? .veryHigh : .high
            let weight = hasFatigueSignal ? 0.92 : 0.82

            causes.append(DetectedCause(
                cause: "Poor Sleep Quality",
                confidence: confidence,
                explanation: "You tagged poor sleep. Sleep debt is one of the strongest suppressors of HRV. Your DFA α1 pattern confirms reduced recovery.",
                weight: weight
            ))
        }

        return causes
    }

    private func detectDietTags(tags: Set<ReadingTag>, context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        if tags.contains(where: { $0.name == "Late Meal" }) {
            causes.append(DetectedCause(
                cause: "Late Night Eating",
                confidence: .moderateHigh,
                explanation: "You tagged a late meal. Digestion during sleep elevates metabolism and heart rate, reducing vagal tone and HRV.",
                weight: 0.7
            ))
        }

        if tags.contains(where: { $0.name == "Caffeine" }) {
            causes.append(DetectedCause(
                cause: "Caffeine Effect",
                confidence: .moderate,
                explanation: "You tagged caffeine. Caffeine's half-life is 5-6 hours—late consumption can disrupt deep sleep even if you fall asleep fine.",
                weight: 0.6
            ))
        }

        return causes
    }

    private func detectLifestyleTags(tags: Set<ReadingTag>, context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        if tags.contains(where: { $0.name == "Travel" }) {
            causes.append(DetectedCause(
                cause: "Travel Stress / Jet Lag",
                confidence: .moderateHigh,
                explanation: "You tagged travel. Travel disrupts circadian rhythm, sleep, and hydration—all of which lower HRV.",
                weight: 0.75
            ))
        }

        if tags.contains(where: { $0.name == "Stressed" }) {
            let hasSympatheticActivation = context.lfHfRatio > HRVThresholds.lfHfModerateSympatheticUpper
            let confidence: DetectedCause.CauseConfidence = hasSympatheticActivation ? .veryHigh : .high
            let weight = hasSympatheticActivation ? 0.9 : 0.8

            causes.append(DetectedCause(
                cause: "Psychological Stress",
                confidence: confidence,
                explanation: "You tagged feeling stressed. Your LF/HF ratio confirms elevated sympathetic activity consistent with mental/emotional load.",
                weight: weight
            ))
        }

        if tags.contains(where: { $0.name == "Post-Exercise" }) {
            let isLowHRV = context.rmssd < HRVThresholds.rmssdReduced
            let confidence: DetectedCause.CauseConfidence = isLowHRV ? .high : .moderate
            let weight = isLowHRV ? 0.85 : 0.65

            causes.append(DetectedCause(
                cause: "Exercise Recovery",
                confidence: confidence,
                explanation: "You tagged post-exercise. HRV is suppressed for 24-72 hours after intense training while your body repairs and adapts.",
                weight: weight
            ))
        }

        return causes
    }

    private func detectHealthTags(tags: Set<ReadingTag>, context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        if tags.contains(where: { $0.name == "Illness" }) {
            causes.append(DetectedCause(
                cause: "Active Illness",
                confidence: .veryHigh,
                explanation: "You tagged illness. Your immune system is active, which dramatically increases sympathetic tone and suppresses HRV.",
                weight: 0.98
            ))
        }

        if tags.contains(where: { $0.name == "Menstrual" }) {
            causes.append(DetectedCause(
                cause: "Menstrual Cycle Phase",
                confidence: .moderate,
                explanation: "You tagged menstrual. HRV naturally varies across the cycle, often dipping during menstruation due to hormonal shifts.",
                weight: 0.6
            ))
        }

        return causes
    }
}
