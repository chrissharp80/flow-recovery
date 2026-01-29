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

/// Time-domain HRV analysis
final class TimeDomainAnalyzer {

    // MARK: - Public API

    /// Compute time-domain metrics for clean RR intervals
    /// - Parameters:
    ///   - series: The RR series
    ///   - flags: Artifact flags
    ///   - windowStart: Start index
    ///   - windowEnd: End index (exclusive)
    /// - Returns: Time domain metrics, or nil if insufficient data
    static func computeTimeDomain(
        _ series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int,
        windowEnd: Int
    ) -> TimeDomainMetrics? {

        // Extract clean RR intervals
        var cleanRR = [Double]()
        for i in windowStart..<windowEnd {
            if !flags[i].isArtifact {
                cleanRR.append(Double(series.points[i].rr_ms))
            }
        }

        guard cleanRR.count >= 10 else { return nil }

        // Mean RR
        var meanRR: Double = 0
        vDSP_meanvD(cleanRR, 1, &meanRR, vDSP_Length(cleanRR.count))

        // SDNN - Standard deviation of RR intervals
        let sdnn = standardDeviation(cleanRR, mean: meanRR)

        // Calculate successive differences for RMSSD and pNN50
        var successiveDiffs = [Double]()
        successiveDiffs.reserveCapacity(cleanRR.count - 1)

        for i in 1..<cleanRR.count {
            successiveDiffs.append(cleanRR[i] - cleanRR[i - 1])
        }

        guard !successiveDiffs.isEmpty else { return nil }

        // RMSSD - Root mean square of successive differences
        let rmssd = rootMeanSquare(successiveDiffs)

        // pNN50 - Percentage of successive differences > 50ms
        let nn50Count = successiveDiffs.filter { abs($0) > 50 }.count
        let pnn50 = Double(nn50Count) / Double(successiveDiffs.count) * 100

        // SDSD - Standard deviation of successive differences
        var meanDiff: Double = 0
        vDSP_meanvD(successiveDiffs, 1, &meanDiff, vDSP_Length(successiveDiffs.count))
        let sdsd = standardDeviation(successiveDiffs, mean: meanDiff)

        // Heart rate statistics - use rolling window calculation
        let hrStats = computeHRStatistics(series: series, flags: flags, windowStart: windowStart, windowEnd: windowEnd)
        let meanHR = hrStats.mean
        let sdHR = hrStats.sd
        let minHR = hrStats.min
        let maxHR = hrStats.max

        // HRV Triangular Index: N / max(histogram bin count)
        // Using 1/128 second (7.8125 ms) bin width per standard
        let triangularIndex = computeTriangularIndex(cleanRR)

        return TimeDomainMetrics(
            meanRR: meanRR,
            sdnn: sdnn,
            rmssd: rmssd,
            pnn50: pnn50,
            sdsd: sdsd,
            meanHR: meanHR,
            sdHR: sdHR,
            minHR: minHR,
            maxHR: maxHR,
            triangularIndex: triangularIndex
        )
    }

    /// Compute HRV Triangular Index
    /// Uses histogram with 7.8125 ms bin width (1/128 s)
    private static func computeTriangularIndex(_ rr: [Double]) -> Double? {
        guard rr.count >= HRVConstants.MinimumBeats.forTriangularIndex else { return nil }

        let binWidth = WindowConstants.triangularIndexBinWidth
        let minRR = rr.min() ?? 0
        let maxRR = rr.max() ?? 0

        guard maxRR > minRR else { return nil }

        let binCount = Int(ceil((maxRR - minRR) / binWidth)) + 1
        var histogram = [Int](repeating: 0, count: binCount)

        for interval in rr {
            let binIndex = Int((interval - minRR) / binWidth)
            if binIndex >= 0 && binIndex < binCount {
                histogram[binIndex] += 1
            }
        }

        let maxBin = histogram.max() ?? 0
        guard maxBin > 0 else { return nil }

        return Double(rr.count) / Double(maxBin)
    }

    // MARK: - Private Helpers

    private static func standardDeviation(_ values: [Double], mean: Double) -> Double {
        guard values.count > 1 else { return 0 }

        var sumSquares: Double = 0
        for value in values {
            let diff = value - mean
            sumSquares += diff * diff
        }
        return sqrt(sumSquares / Double(values.count - 1))
    }

    private static func rootMeanSquare(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }

        var sumSquares: Double = 0
        vDSP_dotprD(values, 1, values, 1, &sumSquares, vDSP_Length(values.count))
        return sqrt(sumSquares / Double(values.count))
    }

    /// Compute HR statistics using rolling 10-second windows
    /// This is the correct method - NOT instantaneous HR from single RR intervals
    private static func computeHRStatistics(
        series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int,
        windowEnd: Int
    ) -> (mean: Double, sd: Double, min: Double, max: Double) {

        let points = series.points

        // First, check if we have stored HR data from streaming
        let hasStoredHR = points[windowStart..<windowEnd].contains { $0.hr != nil }

        if hasStoredHR {
            // Use stored HR from Polar sensor (streaming data)
            var hrValues: [Double] = []
            for i in windowStart..<windowEnd {
                if !flags[i].isArtifact, let hr = points[i].hr {
                    hrValues.append(Double(hr))
                }
            }

            guard !hrValues.isEmpty else {
                return (mean: 60.0, sd: 0, min: 60.0, max: 60.0)
            }

            var mean: Double = 0
            vDSP_meanvD(hrValues, 1, &mean, vDSP_Length(hrValues.count))
            let sd = standardDeviation(hrValues, mean: mean)
            let min = hrValues.min() ?? mean
            let max = hrValues.max() ?? mean

            return (mean: mean, sd: sd, min: min, max: max)
        }

        // No stored HR - calculate using rolling 10-second windows
        // Standard practice for irregular rhythms (sleep HRV)
        var hrSamples: [Double] = []

        let windowDurationMs: Int64 = 10000 // 10 seconds
        var i = windowStart

        while i < windowEnd {
            // Collect beats for next 10-second window
            var windowBeats: [Int] = []
            var windowDurationActual: Int64 = 0
            var j = i

            while j < windowEnd && windowDurationActual < windowDurationMs {
                if !flags[j].isArtifact {
                    windowBeats.append(points[j].rr_ms)
                    windowDurationActual += Int64(points[j].rr_ms)
                }
                j += 1
            }

            // Need at least 5 beats for meaningful HR calculation
            if windowBeats.count >= 5 && windowDurationActual > 0 {
                // HR = (number of beats / duration in ms) * 60000
                let windowHR = (Double(windowBeats.count) / Double(windowDurationActual)) * 60000.0

                // Sanity check: 30-200 bpm
                if windowHR >= 30 && windowHR <= 200 {
                    hrSamples.append(windowHR)
                }
            }

            // Advance by ~5 seconds (50% overlap for smoothness)
            i = j > i + 5 ? i + 5 : j
        }

        guard !hrSamples.isEmpty else {
            // Fallback: use mean RR to estimate
            var cleanRR = [Double]()
            for i in windowStart..<windowEnd {
                if !flags[i].isArtifact {
                    cleanRR.append(Double(points[i].rr_ms))
                }
            }
            if !cleanRR.isEmpty {
                var meanRR: Double = 0
                vDSP_meanvD(cleanRR, 1, &meanRR, vDSP_Length(cleanRR.count))
                let meanHR = 60000.0 / meanRR
                return (mean: meanHR, sd: 0, min: meanHR, max: meanHR)
            }
            return (mean: 60.0, sd: 0, min: 60.0, max: 60.0)
        }

        var mean: Double = 0
        vDSP_meanvD(hrSamples, 1, &mean, vDSP_Length(hrSamples.count))
        let sd = standardDeviation(hrSamples, mean: mean)
        let min = hrSamples.min() ?? mean
        let max = hrSamples.max() ?? mean

        return (mean: mean, sd: sd, min: min, max: max)
    }
}
