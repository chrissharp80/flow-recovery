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
import Accelerate

/// Stress and ANS Index Analysis
/// Includes Baevsky's Stress Index, PNS Index, SNS Index
final class StressAnalyzer {

    // MARK: - Stress Index (Baevsky's SI)

    /// Compute Baevsky's Stress Index
    /// SI = AMo / (2 * Mo * MxDMn)
    /// Where:
    ///   AMo = amplitude of mode (% of intervals in modal bin)
    ///   Mo = mode (most frequent RR interval)
    ///   MxDMn = difference between max and min RR
    ///
    /// - Parameter rr: RR intervals in ms
    /// - Returns: Stress Index value, or nil if insufficient data
    static func computeStressIndex(_ rr: [Double]) -> Double? {
        guard rr.count >= 20 else { return nil }

        let minRR = rr.min() ?? 0
        let maxRR = rr.max() ?? 0
        let mxdmn = (maxRR - minRR) / 1000.0  // Convert to seconds

        guard mxdmn > 0 else { return nil }

        // Histogram with 50ms bins (standard for SI)
        let binWidth = 50.0
        let binCount = Int(ceil((maxRR - minRR) / binWidth)) + 1
        guard binCount > 0 else { return nil }

        var histogram = [Int](repeating: 0, count: binCount)
        for interval in rr {
            let binIndex = Int((interval - minRR) / binWidth)
            if binIndex >= 0 && binIndex < binCount {
                histogram[binIndex] += 1
            }
        }

        // Find mode (Mo) and amplitude of mode (AMo)
        let maxBinCount = histogram.max() ?? 0
        let modalBinIndex = histogram.firstIndex(of: maxBinCount) ?? 0
        let mo = (minRR + Double(modalBinIndex) * binWidth + binWidth / 2) / 1000.0  // Mode in seconds
        let amo = Double(maxBinCount) / Double(rr.count) * 100.0  // AMo as percentage

        guard mo > 0 else { return nil }

        // SI = AMo / (2 * Mo * MxDMn)
        let si = amo / (2.0 * mo * mxdmn)

        return si
    }

    // MARK: - PNS Index (Parasympathetic)

    /// Compute PNS Index - composite parasympathetic activity score
    /// Based on z-scores of: Mean RR, RMSSD, SD1
    /// Reference values from Kubios normative data
    ///
    /// - Parameters:
    ///   - meanRR: Mean RR interval in ms
    ///   - rmssd: RMSSD in ms
    ///   - sd1: Poincaré SD1 in ms
    /// - Returns: PNS Index (typically -3 to +3)
    static func computePNSIndex(meanRR: Double, rmssd: Double, sd1: Double) -> Double {
        // Normative reference values (healthy adults, supine)
        // These are approximate - Kubios uses proprietary values
        let refMeanRR = 926.0  // ms
        let refMeanRR_SD = 90.0
        let refRMSSD = 42.0   // ms
        let refRMSSD_SD = 19.0
        let refSD1 = 29.0     // ms
        let refSD1_SD = 13.0

        // Z-scores
        let zMeanRR = (meanRR - refMeanRR) / refMeanRR_SD
        let zRMSSD = (rmssd - refRMSSD) / refRMSSD_SD
        let zSD1 = (sd1 - refSD1) / refSD1_SD

        // Weighted average (equal weights)
        let pnsIndex = (zMeanRR + zRMSSD + zSD1) / 3.0

        return pnsIndex
    }

    // MARK: - SNS Index (Sympathetic)

    /// Compute SNS Index - composite sympathetic activity score
    /// Based on z-scores of: Mean HR, Stress Index, SD2
    /// Reference values from Kubios normative data
    ///
    /// - Parameters:
    ///   - meanHR: Mean heart rate in bpm
    ///   - stressIndex: Baevsky's Stress Index
    ///   - sd2: Poincaré SD2 in ms
    /// - Returns: SNS Index (typically -3 to +3)
    static func computeSNSIndex(meanHR: Double, stressIndex: Double, sd2: Double) -> Double {
        // Normative reference values (healthy adults, supine)
        // Baevsky's Stress Index: normal resting range is 50-150, mean ~100
        let refMeanHR = 66.0   // bpm
        let refMeanHR_SD = 9.0
        let refSI = 100.0      // Stress Index (normal resting mean)
        let refSI_SD = 50.0    // Wide SD to account for individual variability
        let refSD2 = 65.0      // ms
        let refSD2_SD = 20.0

        // Z-scores (note: higher HR and SI = more sympathetic, lower SD2 = more sympathetic)
        let zMeanHR = (meanHR - refMeanHR) / refMeanHR_SD
        let zSI = (stressIndex - refSI) / refSI_SD
        let zSD2 = -(sd2 - refSD2) / refSD2_SD  // Inverted: lower SD2 = higher sympathetic

        // Weighted average
        let snsIndex = (zMeanHR + zSI + zSD2) / 3.0

        return snsIndex
    }

    // MARK: - Readiness Score

    /// Compute a recovery/readiness score based on HRV metrics and training context
    /// Higher = better recovered
    /// Based on resting HRV compared to baseline, adjusted for recent training load
    ///
    /// - Parameters:
    ///   - rmssd: Current RMSSD
    ///   - baselineRMSSD: Baseline RMSSD (7-day average or user-set)
    ///   - alpha1: DFA α1 value
    ///   - pnsIndex: Parasympathetic index (optional)
    ///   - snsIndex: Sympathetic index (optional)
    ///   - trainingLoadAdjustment: Adjustment based on recent workout intensity (-2 to +1)
    ///     - Negative values indicate recent hard training (expect lower HRV, adjust score up)
    ///     - Zero means no adjustment needed
    ///   - vo2Max: User's VO2max for fitness-adjusted baseline (optional)
    /// - Returns: Readiness score 1-10
    static func computeReadinessScore(
        rmssd: Double,
        baselineRMSSD: Double?,
        alpha1: Double?,
        pnsIndex: Double? = nil,
        snsIndex: Double? = nil,
        trainingLoadAdjustment: Double = 0,
        vo2Max: Double? = nil
    ) -> Double {
        var score = 5.0  // Neutral baseline

        // Adjust baseline for fitness level if VO2max is available
        let adjustedBaseline: Double?
        if let baseline = baselineRMSSD, let vo2 = vo2Max {
            // Higher VO2max = expect higher HRV baseline
            // Elite athletes (VO2max 60+) might have 20-30% higher RMSSD
            let fitnessMultiplier = 1.0 + ((vo2 - 40) / 100.0)  // Centered around VO2max of 40
            adjustedBaseline = baseline * max(0.8, min(1.3, fitnessMultiplier))
        } else {
            adjustedBaseline = baselineRMSSD
        }

        // RMSSD component
        if let baseline = adjustedBaseline, baseline > 0 {
            let rmssdRatio = rmssd / baseline
            // Optimal: ratio around 1.0, penalize large deviations
            if rmssdRatio >= 0.85 && rmssdRatio <= 1.15 {
                score += 2.0
            } else if rmssdRatio >= 0.70 && rmssdRatio <= 1.30 {
                score += 1.0
            } else if rmssdRatio < 0.60 || rmssdRatio > 1.50 {
                score -= 2.0
            }
        } else {
            // Without baseline, use absolute RMSSD (adjusted for fitness if available)
            let rmssdThresholdHigh: Double
            let rmssdThresholdMid: Double
            let rmssdThresholdLow: Double

            if let vo2 = vo2Max, vo2 > 50 {
                // Fit individuals: higher thresholds
                rmssdThresholdHigh = 60
                rmssdThresholdMid = 40
                rmssdThresholdLow = 25
            } else {
                // Standard thresholds
                rmssdThresholdHigh = 50
                rmssdThresholdMid = 30
                rmssdThresholdLow = 20
            }

            if rmssd > rmssdThresholdHigh { score += 1.5 }
            else if rmssd > rmssdThresholdMid { score += 0.5 }
            else if rmssd < rmssdThresholdLow { score -= 1.5 }
        }

        // DFA α1 component (optimal range 0.75-1.0 for recovery)
        if let a1 = alpha1 {
            if a1 >= 0.75 && a1 <= 1.0 {
                score += 2.0
            } else if a1 >= 0.5 && a1 <= 1.25 {
                score += 0.5
            } else {
                score -= 1.0
            }
        }

        // ANS Balance component - penalize sympathetic dominance
        // If SNS >> PNS, the body is in a stressed/activated state, not fully recovered
        if let sns = snsIndex, let pns = pnsIndex {
            let balance = pns - sns  // Positive = parasympathetic dominant (good), negative = sympathetic dominant
            if balance >= 1.0 {
                // Strong parasympathetic dominance - excellent recovery
                score += 1.5
            } else if balance >= 0 {
                // Balanced or slight parasympathetic - good
                score += 0.5
            } else if balance >= -1.0 {
                // Mild sympathetic dominance - some stress present
                score -= 0.5
            } else {
                // Strong sympathetic dominance - not well recovered
                score -= 1.5
            }
        }

        // Training load adjustment
        // If user had a hard workout recently, expect lower HRV - don't penalize
        // This effectively shifts the interpretation: low HRV after hard workout = normal recovery
        if trainingLoadAdjustment < 0 {
            // Recent hard training: boost score since low HRV is expected
            score -= trainingLoadAdjustment  // Subtracting negative = adding
        }

        // Clamp to 1-10
        return max(1.0, min(10.0, score))
    }
}
