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

/// Nonlinear HRV analysis (Poincaré plot metrics and entropy)
final class NonlinearAnalyzer {

    // MARK: - Public API

    /// Compute nonlinear metrics for clean RR intervals
    /// - Parameters:
    ///   - series: The RR series
    ///   - flags: Artifact flags
    ///   - windowStart: Start index
    ///   - windowEnd: End index (exclusive)
    /// - Returns: Nonlinear metrics, or nil if insufficient data
    static func computeNonlinear(
        _ series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int,
        windowEnd: Int
    ) -> NonlinearMetrics? {

        // Extract clean RR intervals
        var cleanRR = [Double]()
        for i in windowStart..<windowEnd {
            if !flags[i].isArtifact {
                cleanRR.append(Double(series.points[i].rr_ms))
            }
        }

        guard cleanRR.count >= 10 else { return nil }

        // Poincaré plot analysis
        let (sd1, sd2) = computePoincareMetrics(cleanRR)

        // Sample entropy (optional, computationally expensive)
        let sampleEntropy = computeSampleEntropy(cleanRR, m: 2, r: 0.2)

        // Approximate entropy
        let approxEntropy = computeApproxEntropy(cleanRR, m: 2, r: 0.2)

        // DFA
        let dfaResult = DFAAnalyzer.compute(cleanRR)

        return NonlinearMetrics(
            sd1: sd1,
            sd2: sd2,
            sd1Sd2Ratio: sd2 > 0 ? sd1 / sd2 : 0,
            sampleEntropy: sampleEntropy,
            approxEntropy: approxEntropy,
            dfaAlpha1: dfaResult?.alpha1,
            dfaAlpha2: dfaResult?.alpha2,
            dfaAlpha1R2: dfaResult?.alpha1R2
        )
    }

    // MARK: - Approximate Entropy

    /// Compute approximate entropy
    /// - Parameters:
    ///   - rr: RR intervals
    ///   - m: Embedding dimension (typically 2)
    ///   - r: Tolerance as fraction of SD (typically 0.2)
    /// - Returns: Approximate entropy value
    private static func computeApproxEntropy(_ rr: [Double], m: Int, r: Double) -> Double? {
        guard rr.count >= m + 2 else { return nil }

        // Compute standard deviation for tolerance
        var mean: Double = 0
        vDSP_meanvD(rr, 1, &mean, vDSP_Length(rr.count))

        var sumSq: Double = 0
        for val in rr {
            let diff = val - mean
            sumSq += diff * diff
        }
        let sd = sqrt(sumSq / Double(rr.count - 1))
        let tolerance = r * sd

        // Phi for m and m+1
        guard let phiM = computePhi(rr, templateLength: m, tolerance: tolerance),
              let phiM1 = computePhi(rr, templateLength: m + 1, tolerance: tolerance) else {
            return nil
        }

        // ApEn = Phi(m) - Phi(m+1)
        return phiM - phiM1
    }

    /// Compute Phi value for ApEn calculation
    private static func computePhi(_ data: [Double], templateLength: Int, tolerance: Double) -> Double? {
        let n = data.count
        guard n > templateLength else { return nil }

        let numTemplates = n - templateLength + 1
        var logSum: Double = 0

        for i in 0..<numTemplates {
            var count = 0

            for j in 0..<numTemplates {
                var matches = true

                for k in 0..<templateLength {
                    if abs(data[i + k] - data[j + k]) > tolerance {
                        matches = false
                        break
                    }
                }

                if matches {
                    count += 1
                }
            }

            // Include self-match, so count >= 1
            let ci = Double(count) / Double(numTemplates)
            if ci > 0 {
                logSum += log(ci)
            }
        }

        return logSum / Double(numTemplates)
    }

    // MARK: - Poincaré Plot

    /// Compute SD1 and SD2 from Poincaré plot
    /// SD1 = short-term variability (perpendicular to line of identity)
    /// SD2 = long-term variability (along line of identity)
    private static func computePoincareMetrics(_ rr: [Double]) -> (sd1: Double, sd2: Double) {
        guard rr.count >= 2 else { return (0, 0) }

        // Create RR(n) and RR(n+1) pairs
        var diffSum: Double = 0
        var diffSumSq: Double = 0

        for i in 0..<(rr.count - 1) {
            let diff = rr[i + 1] - rr[i]
            diffSum += diff
            diffSumSq += diff * diff
        }

        let n = Double(rr.count - 1)

        // SD1 = SDSD / sqrt(2)
        // Using: SDSD² = (1/n) * Σ(diff²) - ((1/n) * Σdiff)²
        let meanDiff = diffSum / n
        let varDiff = diffSumSq / n - meanDiff * meanDiff
        let sd1 = sqrt(max(0, varDiff) / 2.0)

        // SD2 requires SDNN and SD1
        // SD2² = 2 * SDNN² - SD1²
        var mean: Double = 0
        vDSP_meanvD(rr, 1, &mean, vDSP_Length(rr.count))

        var sumSq: Double = 0
        for val in rr {
            let diff = val - mean
            sumSq += diff * diff
        }
        let variance = sumSq / Double(rr.count - 1)
        let sdnn = sqrt(variance)

        let sd2Squared = 2 * sdnn * sdnn - sd1 * sd1
        let sd2 = sqrt(max(0, sd2Squared))

        return (sd1, sd2)
    }

    // MARK: - Sample Entropy

    /// Compute sample entropy
    /// - Parameters:
    ///   - rr: RR intervals
    ///   - m: Embedding dimension (typically 2)
    ///   - r: Tolerance as fraction of SD (typically 0.2)
    /// - Returns: Sample entropy value, or nil if cannot compute
    private static func computeSampleEntropy(_ rr: [Double], m: Int, r: Double) -> Double? {
        guard rr.count >= m + 2 else { return nil }

        // Compute standard deviation for tolerance
        var mean: Double = 0
        vDSP_meanvD(rr, 1, &mean, vDSP_Length(rr.count))

        var sumSq: Double = 0
        for val in rr {
            let diff = val - mean
            sumSq += diff * diff
        }
        let sd = sqrt(sumSq / Double(rr.count - 1))
        let tolerance = r * sd

        // Count template matches for length m and m+1
        let countM = countTemplateMatches(rr, templateLength: m, tolerance: tolerance)
        let countM1 = countTemplateMatches(rr, templateLength: m + 1, tolerance: tolerance)

        guard countM > 0 && countM1 > 0 else { return nil }

        // Sample entropy = -ln(countM1 / countM)
        return -log(Double(countM1) / Double(countM))
    }

    /// Count matching template pairs using Chebyshev distance
    private static func countTemplateMatches(_ data: [Double], templateLength: Int, tolerance: Double) -> Int {
        let n = data.count
        guard n > templateLength else { return 0 }

        var count = 0

        for i in 0..<(n - templateLength) {
            for j in (i + 1)..<(n - templateLength) {
                var matches = true

                for k in 0..<templateLength {
                    if abs(data[i + k] - data[j + k]) > tolerance {
                        matches = false
                        break
                    }
                }

                if matches {
                    count += 1
                }
            }
        }

        return count
    }
}
