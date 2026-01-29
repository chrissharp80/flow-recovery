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

/// Detrended Fluctuation Analysis (DFA)
/// Computes α1 (short-term) and α2 (long-term) fractal scaling exponents
final class DFAAnalyzer {

    // MARK: - Public API

    struct DFAResult {
        /// Short-term scaling exponent (4-16 beats)
        let alpha1: Double
        /// Long-term scaling exponent (16-64 beats)
        let alpha2: Double?
        /// R² fit quality for α1
        let alpha1R2: Double
        /// R² fit quality for α2
        let alpha2R2: Double?
    }

    /// Compute DFA α1 and α2 from clean RR intervals
    /// - Parameters:
    ///   - rr: Array of RR intervals in ms
    ///   - alpha1Range: Box sizes for α1 (default 4-16)
    ///   - alpha2Range: Box sizes for α2 (default 16-64)
    /// - Returns: DFA result with scaling exponents, or nil if insufficient data
    static func compute(
        _ rr: [Double],
        alpha1Range: ClosedRange<Int> = HRVConstants.DFA.alpha1ScaleMin...HRVConstants.DFA.alpha1ScaleMax,
        alpha2Range: ClosedRange<Int> = HRVConstants.DFA.alpha2ScaleMin...HRVConstants.DFA.alpha2ScaleMax
    ) -> DFAResult? {

        guard rr.count >= HRVConstants.DFA.alpha2ScaleMax else { return nil }

        // Step 1: Integrate the series (cumulative sum of deviations from mean)
        var mean: Double = 0
        vDSP_meanvD(rr, 1, &mean, vDSP_Length(rr.count))

        var integrated = [Double](repeating: 0, count: rr.count)
        var cumSum: Double = 0
        for i in 0..<rr.count {
            cumSum += rr[i] - mean
            integrated[i] = cumSum
        }

        // Step 2: Compute fluctuation for each box size
        let alpha1Sizes = Array(stride(from: alpha1Range.lowerBound, through: min(alpha1Range.upperBound, rr.count / 4), by: 1))
        let alpha2Sizes = Array(stride(from: alpha2Range.lowerBound, through: min(alpha2Range.upperBound, rr.count / 4), by: 2))

        guard alpha1Sizes.count >= 3 else { return nil }

        let alpha1Fluctuations = alpha1Sizes.map { computeFluctuation(integrated, boxSize: $0) }

        // Step 3: Log-log regression for α1
        let (alpha1, alpha1R2) = logLogRegression(sizes: alpha1Sizes, fluctuations: alpha1Fluctuations)

        // Step 4: α2 if we have enough data
        var alpha2: Double? = nil
        var alpha2R2: Double? = nil

        if alpha2Sizes.count >= 3 && rr.count >= HRVConstants.MinimumBeats.forDFA {
            let alpha2Fluctuations = alpha2Sizes.map { computeFluctuation(integrated, boxSize: $0) }
            let (a2, r2) = logLogRegression(sizes: alpha2Sizes, fluctuations: alpha2Fluctuations)
            alpha2 = a2
            alpha2R2 = r2
        }

        return DFAResult(
            alpha1: alpha1,
            alpha2: alpha2,
            alpha1R2: alpha1R2,
            alpha2R2: alpha2R2
        )
    }

    // MARK: - Private Helpers

    /// Compute RMS fluctuation for a given box size
    private static func computeFluctuation(_ integrated: [Double], boxSize: Int) -> Double {
        let n = integrated.count
        let numBoxes = n / boxSize
        guard numBoxes > 0 else { return 0 }

        var totalFluctuation: Double = 0

        for boxIdx in 0..<numBoxes {
            let start = boxIdx * boxSize
            let end = start + boxSize

            // Extract box segment
            let segment = Array(integrated[start..<end])

            // Linear detrend (least squares fit)
            let detrended = linearDetrend(segment)

            // RMS of detrended segment
            var sumSq: Double = 0
            vDSP_dotprD(detrended, 1, detrended, 1, &sumSq, vDSP_Length(detrended.count))
            totalFluctuation += sumSq
        }

        // RMS fluctuation
        let rms = sqrt(totalFluctuation / Double(numBoxes * boxSize))
        return rms
    }

    /// Remove linear trend from segment
    private static func linearDetrend(_ segment: [Double]) -> [Double] {
        let n = segment.count
        guard n >= 2 else { return segment }

        // Linear regression: y = a + b*x
        var sumX: Double = 0
        var sumY: Double = 0
        var sumXY: Double = 0
        var sumX2: Double = 0

        for i in 0..<n {
            let x = Double(i)
            let y = segment[i]
            sumX += x
            sumY += y
            sumXY += x * y
            sumX2 += x * x
        }

        let nD = Double(n)
        let denom = nD * sumX2 - sumX * sumX
        guard abs(denom) > 1e-10 else { return segment }

        let b = (nD * sumXY - sumX * sumY) / denom
        let a = (sumY - b * sumX) / nD

        // Subtract trend
        var detrended = [Double](repeating: 0, count: n)
        for i in 0..<n {
            detrended[i] = segment[i] - (a + b * Double(i))
        }

        return detrended
    }

    /// Log-log linear regression to find scaling exponent
    private static func logLogRegression(sizes: [Int], fluctuations: [Double]) -> (slope: Double, r2: Double) {
        let n = sizes.count
        guard n >= 2 else { return (0, 0) }

        var logN = [Double](repeating: 0, count: n)
        var logF = [Double](repeating: 0, count: n)

        for i in 0..<n {
            logN[i] = log(Double(sizes[i]))
            logF[i] = fluctuations[i] > 0 ? log(fluctuations[i]) : -10
        }

        // Linear regression
        var sumX: Double = 0, sumY: Double = 0, sumXY: Double = 0, sumX2: Double = 0, sumY2: Double = 0

        for i in 0..<n {
            sumX += logN[i]
            sumY += logF[i]
            sumXY += logN[i] * logF[i]
            sumX2 += logN[i] * logN[i]
            sumY2 += logF[i] * logF[i]
        }

        let nD = Double(n)
        let denom = nD * sumX2 - sumX * sumX
        guard abs(denom) > 1e-10 else { return (0, 0) }

        let slope = (nD * sumXY - sumX * sumY) / denom

        // R² calculation
        let ssTotal = sumY2 - (sumY * sumY) / nD
        let intercept = (sumY - slope * sumX) / nD
        var ssResidual: Double = 0
        for i in 0..<n {
            let predicted = intercept + slope * logN[i]
            let residual = logF[i] - predicted
            ssResidual += residual * residual
        }

        let r2 = ssTotal > 0 ? 1.0 - ssResidual / ssTotal : 0

        return (slope, max(0, min(1, r2)))
    }
}
