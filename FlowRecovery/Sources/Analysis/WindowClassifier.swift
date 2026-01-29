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

/// Classifies HRV windows based on physiological metrics
/// Following Single Responsibility Principle: classification is separate from window selection
enum WindowClassifier {

    /// Classification of a recovery window based on DFA α1 and other metrics
    /// Based on research: DFA α1 indicates quality of autonomic control
    enum Classification: String, Codable {
        /// α1 ≈ 0.75-1.0: Organized, adaptive parasympathetic control - readiness indicator
        case organizedRecovery = "Organized Recovery"

        /// α1 ≈ 0.6-0.75: High flexibility but not yet settled - capacity, not readiness
        case flexibleUnconsolidated = "Flexible / Unconsolidated"

        /// α1 > 1.0 or < 0.6: Constrained or random - neither readiness nor clean capacity
        case highVariability = "High Variability"

        /// Insufficient data for classification
        case insufficient = "Insufficient Data"
    }

    /// Metrics used for window classification
    struct WindowMetrics {
        let cleanBeatCount: Int
        let dfaAlpha1: Double?
        let lfHfRatio: Double?
        let hrCoefficientOfVariation: Double
    }

    /// Result of window classification
    struct ClassificationResult {
        let classification: Classification
        let isOrganizedRecovery: Bool
        let isConsolidated: Bool
        let explanation: String
    }

    // MARK: - Public API

    /// Classify a window based on its physiological metrics
    static func classify(_ metrics: WindowMetrics) -> ClassificationResult {
        let classification = determineClassification(metrics)
        let isOrganized = isOrganizedRecovery(metrics)
        let isConsolidated = isOrganized && metrics.hrCoefficientOfVariation < HRVThresholds.windowUnstableCVThreshold

        let explanation = generateExplanation(
            classification: classification,
            metrics: metrics,
            isConsolidated: isConsolidated
        )

        return ClassificationResult(
            classification: classification,
            isOrganizedRecovery: isOrganized,
            isConsolidated: isConsolidated,
            explanation: explanation
        )
    }

    /// Quick check if a window represents organized recovery
    static func isOrganizedRecovery(_ metrics: WindowMetrics) -> Bool {
        guard let alpha1 = metrics.dfaAlpha1 else {
            // Without DFA, use HR stability as proxy
            return metrics.hrCoefficientOfVariation < HRVThresholds.windowUnstableCVThreshold
        }

        let alpha1InOptimalRange = isInOptimalAlpha1Range(alpha1)
        let lfHfAcceptable = isLfHfAcceptable(metrics.lfHfRatio)
        let hrStable = metrics.hrCoefficientOfVariation < HRVThresholds.windowUnstableCVThreshold

        // Organized if α1 is good AND (LF/HF is good OR HR is stable)
        return alpha1InOptimalRange && (lfHfAcceptable || hrStable)
    }

    // MARK: - Private Methods

    private static func determineClassification(_ metrics: WindowMetrics) -> Classification {
        guard metrics.cleanBeatCount >= 60 else {
            return .insufficient
        }

        guard let alpha1 = metrics.dfaAlpha1 else {
            // Without DFA, use HR stability as proxy
            return metrics.hrCoefficientOfVariation < HRVThresholds.windowUnstableCVThreshold
                ? .organizedRecovery
                : .highVariability
        }

        // Three-tier classification based on α1
        if isInOptimalAlpha1Range(alpha1) {
            return .organizedRecovery
        } else if isInFlexibleAlpha1Range(alpha1) {
            return .flexibleUnconsolidated
        } else {
            return .highVariability
        }
    }

    private static func isInOptimalAlpha1Range(_ alpha1: Double) -> Bool {
        alpha1 >= HRVThresholds.dfaAlpha1OptimalLower && alpha1 <= HRVThresholds.dfaAlpha1OptimalUpper
    }

    private static func isInFlexibleAlpha1Range(_ alpha1: Double) -> Bool {
        alpha1 >= HRVThresholds.dfaAlpha1FlexibleLower && alpha1 < HRVThresholds.dfaAlpha1OptimalLower
    }

    private static func isLfHfAcceptable(_ ratio: Double?) -> Bool {
        guard let ratio = ratio else { return true }  // If unavailable, don't penalize
        return ratio <= HRVThresholds.windowMaxOrganizedLfHf
    }

    private static func generateExplanation(
        classification: Classification,
        metrics: WindowMetrics,
        isConsolidated: Bool
    ) -> String {
        let alpha1Str = metrics.dfaAlpha1.map { String(format: "%.2f", $0) } ?? "N/A"
        let cvPercent = metrics.hrCoefficientOfVariation * 100

        switch classification {
        case .organizedRecovery:
            if isConsolidated {
                return "Organized parasympathetic control (α1=\(alpha1Str), CV=\(String(format: "%.1f", cvPercent))%). Recovery is consolidated and load-bearing."
            } else {
                return "Organized control detected (α1=\(alpha1Str)) but HR variability (CV=\(String(format: "%.1f", cvPercent))%) suggests incomplete consolidation."
            }

        case .flexibleUnconsolidated:
            return "High autonomic flexibility (α1=\(alpha1Str)) but not yet organized. This represents capacity, not load-bearing readiness."

        case .highVariability:
            return "Disorganized autonomic pattern (α1=\(alpha1Str)). High variability without coherent control."

        case .insufficient:
            return "Insufficient data for reliable classification (\(metrics.cleanBeatCount) beats)."
        }
    }
}

// MARK: - Window Stability Assessment

extension WindowClassifier {

    /// Assess overall window stability for readiness determination
    struct StabilityAssessment {
        let isStable: Bool
        let hasUnstableWindow: Bool
        let hasFatigueSignal: Bool
        let hasSympatheticDominance: Bool
        let shouldNotPush: Bool
        let reason: String?
    }

    /// Assess window stability to determine if it's safe to recommend high intensity
    static func assessStability(
        windowCV: Double,
        dfaAlpha1: Double?,
        lfHfRatio: Double?,
        isConsolidated: Bool,
        isShortSleep: Bool
    ) -> StabilityAssessment {
        let hasUnstableWindow = windowCV > HRVThresholds.windowUnstableCVThreshold
        let hasFatigueSignal = (dfaAlpha1 ?? 0) > HRVThresholds.dfaAlpha1Fatigue
        let hasSympatheticDominance = (lfHfRatio ?? 0) > HRVThresholds.lfHfSympatheticDominance

        let shouldNotPush = isShortSleep || hasUnstableWindow || hasFatigueSignal ||
                           hasSympatheticDominance || !isConsolidated

        let reason: String?
        if shouldNotPush {
            if !isConsolidated && !hasUnstableWindow && !hasFatigueSignal && !hasSympatheticDominance && !isShortSleep {
                reason = "Recovery pattern wasn't sustained long enough"
            } else if isShortSleep {
                reason = "Short sleep limits load-bearing readiness"
            } else if hasUnstableWindow {
                reason = "Variable HR during sleep indicates incomplete consolidation"
            } else if hasFatigueSignal {
                reason = "DFA pattern suggests underlying fatigue"
            } else if hasSympatheticDominance {
                reason = "Nervous system still activated"
            } else {
                reason = nil
            }
        } else {
            reason = nil
        }

        return StabilityAssessment(
            isStable: !hasUnstableWindow,
            hasUnstableWindow: hasUnstableWindow,
            hasFatigueSignal: hasFatigueSignal,
            hasSympatheticDominance: hasSympatheticDominance,
            shouldNotPush: shouldNotPush,
            reason: reason
        )
    }
}
