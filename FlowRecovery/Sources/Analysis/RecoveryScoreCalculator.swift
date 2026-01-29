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

/// Unified recovery score calculator combining HRV, sleep, training load, and vitals
/// Used by both MorningResultsView and RecoveryDashboardView for consistent scoring
struct RecoveryScoreCalculator {

    /// Calculate composite recovery score (0-100) from all available data
    /// - Parameters:
    ///   - hrvReadiness: HRV-based readiness score (1-10), optional
    ///   - rmssd: Raw RMSSD value as fallback if no readiness score
    ///   - sleepData: Last night's sleep data
    ///   - trainingMetrics: Current training load metrics
    ///   - vitals: Recovery vitals (respiratory, SpO2, temp)
    ///   - typicalSleepHours: User's typical sleep duration for comparison
    /// - Returns: Composite recovery score 0-100
    static func calculate(
        hrvReadiness: Double?,
        rmssd: Double?,
        sleepData: HealthKitManager.SleepData?,
        trainingMetrics: HealthKitManager.TrainingMetrics?,
        vitals: HealthKitManager.RecoveryVitals?,
        typicalSleepHours: Double
    ) -> Double {
        var score: Double

        // === HRV Component (Primary - 60% weight conceptually) ===
        if let readiness = hrvReadiness {
            // Direct conversion: readiness 1-10 → score 10-100
            score = readiness * 10
        } else if let hrv = rmssd {
            // Fallback: estimate from raw RMSSD
            if hrv >= 60 { score = 85 }
            else if hrv >= 45 { score = 70 }
            else if hrv >= 30 { score = 55 }
            else if hrv >= 20 { score = 40 }
            else { score = 25 }
        } else {
            score = 50 // No HRV data - neutral
        }

        // === Sleep Component (+/- 13 points max) ===
        if let sleep = sleepData {
            let sleepHours = Double(sleep.totalSleepMinutes) / 60.0
            let sleepRatio = sleepHours / typicalSleepHours

            // Duration adjustment
            if sleepRatio >= 1.0 { score += 5 }
            else if sleepRatio >= 0.85 { /* neutral */ }
            else if sleepRatio >= 0.7 { score -= 5 }
            else { score -= 10 }

            // Efficiency adjustment
            let efficiency = min(100, sleep.sleepEfficiency)
            if efficiency >= 90 { score += 3 }
            else if efficiency < 75 { score -= 3 }
        }

        // === Training Load Component (+/- 10 points max) ===
        if let metrics = trainingMetrics, let acr = metrics.acuteChronicRatio {
            if acr >= 0.8 && acr <= 1.1 { score += 3 }      // Optimal
            else if acr > 1.5 { score -= 10 }               // Injury risk
            else if acr > 1.3 { score -= 5 }                // Overreaching
            // Under-training doesn't penalize recovery
        }

        // === Vitals Component (deductions only) ===
        if let vitals = vitals {
            if vitals.isRespiratoryElevated { score -= 5 }
            if vitals.isTemperatureElevated { score -= 5 }
            if vitals.isSpO2Concerning { score -= 10 }
        }

        return min(100, max(0, score))
    }

    /// Convenience overload using TrainingContext instead of TrainingMetrics
    static func calculate(
        hrvReadiness: Double?,
        rmssd: Double?,
        sleepData: HealthKitManager.SleepData?,
        trainingContext: TrainingContext?,
        vitals: HealthKitManager.RecoveryVitals?,
        typicalSleepHours: Double
    ) -> Double {
        // Convert TrainingContext to the ACR we need
        let acr = trainingContext?.acuteChronicRatio

        var score: Double

        // === HRV Component ===
        if let readiness = hrvReadiness {
            score = readiness * 10
        } else if let hrv = rmssd {
            if hrv >= 60 { score = 85 }
            else if hrv >= 45 { score = 70 }
            else if hrv >= 30 { score = 55 }
            else if hrv >= 20 { score = 40 }
            else { score = 25 }
        } else {
            score = 50
        }

        // === Sleep Component ===
        if let sleep = sleepData {
            let sleepHours = Double(sleep.totalSleepMinutes) / 60.0
            let sleepRatio = sleepHours / typicalSleepHours

            if sleepRatio >= 1.0 { score += 5 }
            else if sleepRatio >= 0.85 { }
            else if sleepRatio >= 0.7 { score -= 5 }
            else { score -= 10 }

            let efficiency = min(100, sleep.sleepEfficiency)
            if efficiency >= 90 { score += 3 }
            else if efficiency < 75 { score -= 3 }
        }

        // === Training Load Component ===
        if let acr = acr {
            if acr >= 0.8 && acr <= 1.1 { score += 3 }
            else if acr > 1.5 { score -= 10 }
            else if acr > 1.3 { score -= 5 }
        }

        // === Vitals Component ===
        if let vitals = vitals {
            if vitals.isRespiratoryElevated { score -= 5 }
            if vitals.isTemperatureElevated { score -= 5 }
            if vitals.isSpO2Concerning { score -= 10 }
        }

        return min(100, max(0, score))
    }

    // MARK: - Display Helpers

    static func label(for score: Double) -> String {
        if score >= 80 { return "Excellent" }
        if score >= 60 { return "Good" }
        if score >= 40 { return "Fair" }
        return "Low"
    }

    static func message(for score: Double) -> String {
        if score >= 80 { return "You're well recovered. Great day for intense training." }
        if score >= 60 { return "Decent recovery. Moderate training recommended." }
        if score >= 40 { return "Incomplete recovery. Consider light activity." }
        return "Recovery needed. Rest or very light activity only."
    }

    /// Convert 0-100 score to 1-10 scale for display
    static func toTenScale(_ score: Double) -> Double {
        return score / 10.0
    }
}
