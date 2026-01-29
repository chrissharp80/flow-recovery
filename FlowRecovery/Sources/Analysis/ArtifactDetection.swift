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

/// Artifact correction methods
enum ArtifactCorrectionMethod: String, CaseIterable, Identifiable {
    case none = "None"
    case deletion = "Deletion"
    case linearInterpolation = "Linear Interpolation"
    case cubicSpline = "Cubic Spline"
    case median = "Median Replacement"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .none:
            return "Keep artifacts in data (excluded from analysis)"
        case .deletion:
            return "Remove artifact intervals entirely"
        case .linearInterpolation:
            return "Replace with linearly interpolated values"
        case .cubicSpline:
            return "Replace with cubic spline interpolated values"
        case .median:
            return "Replace with local median value"
        }
    }
}

/// Artifact detection using rolling median and ratio-based classification
final class ArtifactDetector {

    // MARK: - Configuration

    struct Config {
        /// Window size for rolling median (beats)
        var windowSize: Int = HRVConstants.Artifacts.windowSize
        /// Threshold for ectopic detection (ratio from median)
        var ectopicThreshold: Double = 0.20
        /// Threshold for missed beat detection (ratio from median)
        var missedThreshold: Double = 0.50
        /// Threshold for extra beat detection (ratio from median)
        var extraThreshold: Double = 0.30
        /// Minimum RR interval (ms)
        var minRR: Int = HRVConstants.RRInterval.minimum
        /// Maximum RR interval (ms)
        var maxRR: Int = HRVConstants.RRInterval.maximum

        static let `default` = Config()
    }

    private let config: Config

    init(config: Config = .default) {
        self.config = config
    }

    // MARK: - Public API

    /// Detect artifacts in an RR series
    /// - Parameter series: The RR series to analyze
    /// - Returns: Array of artifact flags for each point
    func detectArtifacts(in series: RRSeries) -> [ArtifactFlags] {
        let points = series.points
        guard !points.isEmpty else { return [] }

        let rrValues = points.map { Double($0.rr_ms) }
        let medians = computeRollingMedian(rrValues, windowSize: config.windowSize)

        var flags = [ArtifactFlags]()
        flags.reserveCapacity(points.count)

        for i in 0..<points.count {
            let rr = Double(points[i].rr_ms)
            let median = medians[i]

            // Technical artifacts: out of physiological range
            if points[i].rr_ms < config.minRR || points[i].rr_ms > config.maxRR {
                flags.append(ArtifactFlags(
                    isArtifact: true,
                    type: .technical,
                    confidence: 1.0
                ))
                continue
            }

            // Calculate ratio from median
            let ratio = abs(rr - median) / median

            // Classify based on ratio thresholds
            if rr < median * (1 - config.extraThreshold) {
                // Shorter than expected - could be extra beat or ectopic
                let confidence = min(1.0, ratio / config.extraThreshold)
                if rr < median * 0.5 {
                    // Very short - likely extra detection
                    flags.append(ArtifactFlags(
                        isArtifact: true,
                        type: .extra,
                        confidence: confidence
                    ))
                } else {
                    // Moderately short - could be ectopic
                    flags.append(ArtifactFlags(
                        isArtifact: ratio > config.ectopicThreshold,
                        type: .ectopic,
                        confidence: confidence
                    ))
                }
            } else if rr > median * (1 + config.missedThreshold) {
                // Longer than expected - likely missed beat
                let confidence = min(1.0, ratio / config.missedThreshold)
                flags.append(ArtifactFlags(
                    isArtifact: true,
                    type: .missed,
                    confidence: confidence
                ))
            } else if ratio > config.ectopicThreshold {
                // General deviation beyond ectopic threshold
                flags.append(ArtifactFlags(
                    isArtifact: true,
                    type: .ectopic,
                    confidence: min(1.0, ratio / config.ectopicThreshold)
                ))
            } else {
                // Clean beat
                flags.append(.clean)
            }
        }

        return flags
    }

    /// Calculate artifact percentage for a window
    /// - Parameters:
    ///   - flags: Artifact flags array
    ///   - start: Window start index
    ///   - end: Window end index (exclusive)
    /// - Returns: Percentage of artifacts (0-100)
    func artifactPercentage(_ flags: [ArtifactFlags], start: Int, end: Int) -> Double {
        let clampedStart = max(0, start)
        let clampedEnd = min(flags.count, end)
        guard clampedEnd > clampedStart else { return 0 }

        let window = flags[clampedStart..<clampedEnd]
        let artifactCount = window.filter { $0.isArtifact }.count
        return Double(artifactCount) / Double(window.count) * 100.0
    }

    // MARK: - Private

    /// Compute rolling median for each position
    /// O(n log w) implementation using sorted window
    private func computeRollingMedian(_ values: [Double], windowSize: Int) -> [Double] {
        guard !values.isEmpty else { return [] }

        var medians = [Double]()
        medians.reserveCapacity(values.count)

        // Use centered window
        let halfWindow = windowSize / 2

        for i in 0..<values.count {
            // Calculate window bounds
            let start = max(0, i - halfWindow)
            let end = min(values.count, i + halfWindow + 1)

            // Extract and sort window
            var window = Array(values[start..<end])
            window.sort()

            // Get median
            let mid = window.count / 2
            if window.count % 2 == 0 {
                medians.append((window[mid - 1] + window[mid]) / 2.0)
            } else {
                medians.append(window[mid])
            }
        }

        return medians
    }
}

// MARK: - Artifact Correction

/// Artifact correction algorithms
final class ArtifactCorrector {

    /// Apply artifact correction to RR intervals
    /// - Parameters:
    ///   - rrValues: Original RR intervals in ms
    ///   - flags: Artifact flags for each interval
    ///   - method: Correction method to apply
    /// - Returns: Corrected RR intervals and updated flags
    static func correct(
        rrValues: [Int],
        flags: [ArtifactFlags],
        method: ArtifactCorrectionMethod
    ) -> (corrected: [Int], flags: [ArtifactFlags]) {

        guard rrValues.count == flags.count else {
            return (rrValues, flags)
        }

        switch method {
        case .none:
            return (rrValues, flags)

        case .deletion:
            return deletionCorrection(rrValues: rrValues, flags: flags)

        case .linearInterpolation:
            return linearInterpolationCorrection(rrValues: rrValues, flags: flags)

        case .cubicSpline:
            return cubicSplineCorrection(rrValues: rrValues, flags: flags)

        case .median:
            return medianCorrection(rrValues: rrValues, flags: flags)
        }
    }

    // MARK: - Deletion Method

    /// Remove artifacts entirely from the series
    private static func deletionCorrection(
        rrValues: [Int],
        flags: [ArtifactFlags]
    ) -> (corrected: [Int], flags: [ArtifactFlags]) {

        var corrected = [Int]()
        var newFlags = [ArtifactFlags]()

        for i in 0..<rrValues.count {
            if !flags[i].isArtifact {
                corrected.append(rrValues[i])
                newFlags.append(.clean)
            }
        }

        return (corrected, newFlags)
    }

    // MARK: - Linear Interpolation

    /// Replace artifacts with linearly interpolated values
    private static func linearInterpolationCorrection(
        rrValues: [Int],
        flags: [ArtifactFlags]
    ) -> (corrected: [Int], flags: [ArtifactFlags]) {

        var corrected = rrValues
        var newFlags = flags

        // Find artifact segments and interpolate
        var i = 0
        while i < corrected.count {
            if flags[i].isArtifact {
                // Find start of clean segment before
                let beforeIdx = (0..<i).reversed().first { !flags[$0].isArtifact }
                // Find end of artifact segment
                var endIdx = i
                while endIdx < corrected.count && flags[endIdx].isArtifact {
                    endIdx += 1
                }
                // Find start of clean segment after
                let afterIdx = (endIdx..<corrected.count).first { !flags[$0].isArtifact }

                // Interpolate
                if let before = beforeIdx, let after = afterIdx {
                    let startVal = Double(corrected[before])
                    let endVal = Double(corrected[after])
                    let span = after - before

                    for j in i..<endIdx {
                        let frac = Double(j - before) / Double(span)
                        corrected[j] = Int(round(startVal + frac * (endVal - startVal)))
                        newFlags[j] = ArtifactFlags(
                            isArtifact: false,
                            type: flags[j].type,
                            confidence: flags[j].confidence,
                            corrected: true
                        )
                    }
                } else if let before = beforeIdx {
                    // No clean after, use last clean value
                    for j in i..<endIdx {
                        corrected[j] = corrected[before]
                        newFlags[j] = ArtifactFlags(
                            isArtifact: false,
                            type: flags[j].type,
                            confidence: flags[j].confidence,
                            corrected: true
                        )
                    }
                } else if let after = afterIdx {
                    // No clean before, use first clean value
                    for j in i..<endIdx {
                        corrected[j] = corrected[after]
                        newFlags[j] = ArtifactFlags(
                            isArtifact: false,
                            type: flags[j].type,
                            confidence: flags[j].confidence,
                            corrected: true
                        )
                    }
                }

                i = endIdx
            } else {
                i += 1
            }
        }

        return (corrected, newFlags)
    }

    // MARK: - Cubic Spline Interpolation

    /// Replace artifacts with cubic spline interpolated values
    /// Provides smoother correction than linear interpolation
    private static func cubicSplineCorrection(
        rrValues: [Int],
        flags: [ArtifactFlags]
    ) -> (corrected: [Int], flags: [ArtifactFlags]) {

        // Get indices and values of clean beats
        var cleanIndices = [Int]()
        var cleanValues = [Double]()

        for i in 0..<rrValues.count where !flags[i].isArtifact {
            cleanIndices.append(i)
            cleanValues.append(Double(rrValues[i]))
        }

        guard cleanIndices.count >= 4 else {
            // Not enough points for spline, fall back to linear
            return linearInterpolationCorrection(rrValues: rrValues, flags: flags)
        }

        // Compute natural cubic spline coefficients
        let n = cleanIndices.count
        let x = cleanIndices.map { Double($0) }
        let y = cleanValues

        // Compute h values (spacing)
        var h = [Double](repeating: 0, count: n - 1)
        for i in 0..<n-1 {
            h[i] = x[i + 1] - x[i]
        }

        // Build tridiagonal system for second derivatives
        var alpha = [Double](repeating: 0, count: n)
        for i in 1..<n-1 {
            guard h[i-1] > 0 && h[i] > 0 else { continue }
            alpha[i] = 3.0 / h[i] * (y[i+1] - y[i]) - 3.0 / h[i-1] * (y[i] - y[i-1])
        }

        // Thomas algorithm
        var l = [Double](repeating: 1, count: n)
        var mu = [Double](repeating: 0, count: n)
        var z = [Double](repeating: 0, count: n)
        var c = [Double](repeating: 0, count: n)

        for i in 1..<n-1 {
            l[i] = 2.0 * (x[i+1] - x[i-1]) - h[i-1] * mu[i-1]
            guard l[i] != 0 else { continue }
            mu[i] = h[i] / l[i]
            z[i] = (alpha[i] - h[i-1] * z[i-1]) / l[i]
        }

        for j in stride(from: n-2, through: 0, by: -1) {
            c[j] = z[j] - mu[j] * c[j+1]
        }

        // Compute b and d coefficients
        var b = [Double](repeating: 0, count: n-1)
        var d = [Double](repeating: 0, count: n-1)

        for i in 0..<n-1 {
            guard h[i] > 0 else { continue }
            b[i] = (y[i+1] - y[i]) / h[i] - h[i] * (c[i+1] + 2.0 * c[i]) / 3.0
            d[i] = (c[i+1] - c[i]) / (3.0 * h[i])
        }

        // Interpolate artifact points
        var corrected = rrValues
        var newFlags = flags

        for i in 0..<rrValues.count where flags[i].isArtifact {
            let xi = Double(i)

            // Find segment
            var segIdx = 0
            for j in 0..<n-1 {
                if x[j] <= xi && xi <= x[j+1] {
                    segIdx = j
                    break
                } else if x[j] > xi {
                    segIdx = max(0, j - 1)
                    break
                } else if j == n - 2 {
                    segIdx = j
                }
            }

            // Evaluate spline
            let dt = xi - x[segIdx]
            let interpolated = y[segIdx] + b[segIdx] * dt + c[segIdx] * dt * dt + d[segIdx] * dt * dt * dt

            corrected[i] = Int(round(max(300, min(2000, interpolated))))
            newFlags[i] = ArtifactFlags(
                isArtifact: false,
                type: flags[i].type,
                confidence: flags[i].confidence,
                corrected: true
            )
        }

        return (corrected, newFlags)
    }

    // MARK: - Median Replacement

    /// Replace artifacts with local median value
    /// Simple and robust method, good for isolated artifacts
    private static func medianCorrection(
        rrValues: [Int],
        flags: [ArtifactFlags],
        windowSize: Int = 11
    ) -> (corrected: [Int], flags: [ArtifactFlags]) {

        var corrected = rrValues
        var newFlags = flags
        let halfWindow = windowSize / 2

        for i in 0..<rrValues.count where flags[i].isArtifact {
            // Collect clean values in window
            let start = max(0, i - halfWindow)
            let end = min(rrValues.count, i + halfWindow + 1)

            var windowClean = [Int]()
            for j in start..<end where !flags[j].isArtifact {
                windowClean.append(rrValues[j])
            }

            if !windowClean.isEmpty {
                // Use median of clean values
                windowClean.sort()
                let mid = windowClean.count / 2
                let median: Int
                if windowClean.count % 2 == 0 {
                    median = (windowClean[mid - 1] + windowClean[mid]) / 2
                } else {
                    median = windowClean[mid]
                }

                corrected[i] = median
                newFlags[i] = ArtifactFlags(
                    isArtifact: false,
                    type: flags[i].type,
                    confidence: flags[i].confidence,
                    corrected: true
                )
            }
            // If no clean values in window, leave as artifact
        }

        return (corrected, newFlags)
    }
}

