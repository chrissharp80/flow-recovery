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

/// Data verification per design spec v8.1
/// Validates session data quality with pass/fail and detailed reporting
///
/// This is your "credibility moat" - explicit rejection states ensure data quality
/// and make it clear WHY a session was rejected (for user understanding and debugging)
struct Verification {

    // MARK: - Types

    /// Explicit rejection reasons - each represents a distinct failure mode
    enum RejectionReason: String, Codable, CaseIterable {
        // Duration failures
        case tooShort = "too_short"           // Recording shorter than minimum duration
        case tooFewPoints = "too_few_points"  // Insufficient RR intervals captured

        // Quality failures
        case excessiveArtifacts = "excessive_artifacts"     // Artifact % above threshold
        case excessiveEctopy = "excessive_ectopy"           // Too many ectopic beats
        case excessiveDrift = "excessive_drift"             // RR intervals drifting unrealistically
        case signalLoss = "signal_loss"                     // Gaps in data suggesting sensor issues
        case outOfBoundsIntervals = "out_of_bounds"         // Too many physiologically impossible values

        // Technical failures
        case corruptedData = "corrupted_data"   // Data integrity issues
        case unknownDevice = "unknown_device"   // Unrecognized source device

        var displayName: String {
            switch self {
            case .tooShort: return "Recording Too Short"
            case .tooFewPoints: return "Insufficient Data Points"
            case .excessiveArtifacts: return "Excessive Artifacts"
            case .excessiveEctopy: return "Excessive Ectopic Beats"
            case .excessiveDrift: return "Signal Drift Detected"
            case .signalLoss: return "Signal Loss Detected"
            case .outOfBoundsIntervals: return "Out-of-Range Intervals"
            case .corruptedData: return "Data Corrupted"
            case .unknownDevice: return "Unknown Device"
            }
        }

        var explanation: String {
            switch self {
            case .tooShort:
                return "The recording duration is below the minimum required for reliable analysis."
            case .tooFewPoints:
                return "Not enough heartbeats were captured. Check chest strap contact."
            case .excessiveArtifacts:
                return "Too many detected artifacts (noise, missed beats). May indicate poor sensor contact."
            case .excessiveEctopy:
                return "High number of ectopic beats detected. This may indicate arrhythmia or sensor issues."
            case .excessiveDrift:
                return "Heart rate drifted unrealistically. This often indicates electrode movement."
            case .signalLoss:
                return "Gaps detected in the RR data. Check chest strap battery and contact."
            case .outOfBoundsIntervals:
                return "RR intervals outside physiological range (\(HRVThresholds.minimumRRIntervalMs)-\(HRVThresholds.maximumRRIntervalMs)ms) detected."
            case .corruptedData:
                return "Data integrity check failed. The recording may be incomplete."
            case .unknownDevice:
                return "Data source could not be verified."
            }
        }
    }

    struct Result: Codable {
        let passed: Bool
        let rejectionReasons: [RejectionReason]  // Explicit failure reasons
        let errors: [String]                      // Human-readable error messages
        let warnings: [String]                    // Non-fatal issues
        let metrics: Metrics

        /// Quick check if a specific rejection reason applies
        func isRejectedFor(_ reason: RejectionReason) -> Bool {
            rejectionReasons.contains(reason)
        }

        /// Summary for display
        var summary: String {
            if passed {
                return warnings.isEmpty ? "Passed verification" : "Passed with warnings"
            } else {
                let reasonNames = rejectionReasons.map { $0.displayName }.joined(separator: ", ")
                return "Rejected: \(reasonNames)"
            }
        }
    }

    struct Metrics: Codable {
        let pointCount: Int
        let nnCount: Int
        let durationHours: Double
        let artifactPercent: Double
        let ectopyCount: Int
        let outOfBoundsLowCount: Int
        let outOfBoundsHighCount: Int
        /// Maximum gap between consecutive beats (ms) - indicates signal loss
        let maxGapMs: Int64?
        /// RR interval drift over session (ms) - indicates electrode movement
        let rrDrift: Double?
    }

    // MARK: - Configuration

    struct Config {
        /// Minimum points required (~5 min at 60 bpm)
        var minPoints: Int = HRVConstants.MinimumBeats.forAnalysis
        /// Minimum duration in hours (5 minutes = 0.083 hours)
        /// Allows naps and short rest periods - window selection handles finding best 5-min segment
        var minDurationHours: Double = 0.083
        /// Maximum artifact percentage (hard fail)
        var maxArtifactPercent: Double = HRVConstants.Artifacts.maxPercentForAnalysis
        /// Warning threshold for artifacts
        var warnArtifactPercent: Double = HRVConstants.Artifacts.warnPercentThreshold

        static let `default` = Config()

        /// Strict config for when longer duration is desired (e.g. research use)
        static let strict = Config(
            minPoints: HRVConstants.MinimumBeats.forAnalysis,
            minDurationHours: 4.0,
            maxArtifactPercent: HRVConstants.Artifacts.maxPercentForAnalysis,
            warnArtifactPercent: HRVConstants.Artifacts.warnPercentThreshold
        )
    }

    private let config: Config

    init(config: Config = .default) {
        self.config = config
    }

    // MARK: - Verification

    /// Verify session data quality
    /// - Parameters:
    ///   - series: The RR series
    ///   - flags: Artifact flags for each point
    /// - Returns: Verification result with pass/fail, explicit rejection reasons, and metrics
    func verify(_ series: RRSeries, flags: [ArtifactFlags]) -> Result {
        var rejectionReasons: [RejectionReason] = []
        var errors: [String] = []
        var warnings: [String] = []

        let points = series.points

        // 1. Minimum points check
        guard points.count >= config.minPoints else {
            return Result(
                passed: false,
                rejectionReasons: [.tooFewPoints],
                errors: ["Too few points: \(points.count) (minimum \(config.minPoints) required)"],
                warnings: [],
                metrics: Metrics(
                    pointCount: points.count,
                    nnCount: 0,
                    durationHours: 0,
                    artifactPercent: 0,
                    ectopyCount: 0,
                    outOfBoundsLowCount: 0,
                    outOfBoundsHighCount: 0,
                    maxGapMs: nil,
                    rrDrift: nil
                )
            )
        }

        // 2. Duration check - use endMs of last point
        let durationMs = points.last.map { $0.t_ms + Int64($0.rr_ms) } ?? 0
        let durationHours = Double(durationMs) / 3_600_000.0

        if durationHours < config.minDurationHours {
            rejectionReasons.append(.tooShort)
            errors.append(String(format: "Duration %.2fh < %.1fh minimum", durationHours, config.minDurationHours))
        }

        // 3. Artifact analysis
        let artifactCount = flags.filter { $0.isArtifact }.count
        let artifactPercent = Double(artifactCount) / Double(points.count) * 100

        // Count by type
        var ectopyCount = 0
        var oobLowCount = 0
        var oobHighCount = 0

        for i in 0..<points.count {
            if flags[i].isArtifact {
                switch flags[i].type {
                case .some(.ectopic), .some(.extra), .some(.missed):
                    ectopyCount += 1
                case .some(.technical):
                    if points[i].rr_ms < HRVThresholds.minimumRRIntervalMs {
                        oobLowCount += 1
                    } else if points[i].rr_ms > HRVThresholds.maximumRRIntervalMs {
                        oobHighCount += 1
                    }
                case .some(ArtifactFlags.ArtifactType.none), nil:
                    break
                }
            }
        }

        // 4. Gap analysis - detect signal loss
        var maxGapMs: Int64 = 0
        for i in 1..<points.count {
            let gap = points[i].t_ms - points[i-1].endMs
            if gap > maxGapMs {
                maxGapMs = gap
            }
        }
        // Signal loss if gap > threshold (indicates strap lost contact)
        // Using 5 seconds as max acceptable gap for overnight recordings
        let maxAcceptableGapMs: Int64 = 5000
        if maxGapMs > maxAcceptableGapMs {
            rejectionReasons.append(.signalLoss)
            errors.append(String(format: "Signal gap detected: %.1fs", Double(maxGapMs) / 1000.0))
        }

        // 5. RR drift analysis - detect electrode movement
        // Compare first 10% mean RR to last 10% mean RR
        let tenPercent = max(10, points.count / 10)
        let firstChunk = points.prefix(tenPercent)
        let lastChunk = points.suffix(tenPercent)
        let firstMeanRR = Double(firstChunk.map { $0.rr_ms }.reduce(0, +)) / Double(firstChunk.count)
        let lastMeanRR = Double(lastChunk.map { $0.rr_ms }.reduce(0, +)) / Double(lastChunk.count)
        let rrDrift = lastMeanRR - firstMeanRR

        // Drift > 200ms (20bpm at 60bpm) is suspicious
        if abs(rrDrift) > 200 {
            warnings.append(String(format: "RR drift detected: %.0fms", rrDrift))
        }
        // Drift > 400ms (extreme) is rejection-worthy
        if abs(rrDrift) > 400 {
            rejectionReasons.append(.excessiveDrift)
            errors.append(String(format: "Excessive RR drift: %.0fms (electrode movement suspected)", rrDrift))
        }

        // 6. Artifact threshold checks
        if artifactPercent > config.maxArtifactPercent {
            rejectionReasons.append(.excessiveArtifacts)
            errors.append(String(format: "Artifacts %.1f%% > %.0f%% limit", artifactPercent, config.maxArtifactPercent))
        } else if artifactPercent > config.warnArtifactPercent {
            warnings.append(String(format: "Artifacts %.1f%%", artifactPercent))
        }

        // 7. Ectopy check
        let ectopyPercent = Double(ectopyCount) / Double(points.count) * 100
        if ectopyPercent > 10.0 {  // > 10% ectopic beats is concerning
            rejectionReasons.append(.excessiveEctopy)
            errors.append(String(format: "Ectopic beats %.1f%% (>\(ectopyCount) beats)", ectopyPercent))
        } else if ectopyCount > 100 {
            warnings.append("Elevated ectopy count: \(ectopyCount)")
        }

        // 8. Out of bounds check
        let oobTotal = oobLowCount + oobHighCount
        let oobPercent = Double(oobTotal) / Double(points.count) * 100
        if oobPercent > 5.0 {  // > 5% out of physiological range
            rejectionReasons.append(.outOfBoundsIntervals)
            errors.append(String(format: "Out-of-range intervals: %.1f%% (%d low, %d high)", oobPercent, oobLowCount, oobHighCount))
        } else {
            if oobLowCount > 50 {
                warnings.append("Many short intervals (<300ms): \(oobLowCount)")
            }
            if oobHighCount > 50 {
                warnings.append("Many long intervals (>2500ms): \(oobHighCount)")
            }
        }

        // 9. NN count
        let nnCount = points.count - artifactCount

        let metrics = Metrics(
            pointCount: points.count,
            nnCount: nnCount,
            durationHours: durationHours,
            artifactPercent: artifactPercent,
            ectopyCount: ectopyCount,
            outOfBoundsLowCount: oobLowCount,
            outOfBoundsHighCount: oobHighCount,
            maxGapMs: maxGapMs,
            rrDrift: rrDrift
        )

        return Result(
            passed: rejectionReasons.isEmpty,
            rejectionReasons: rejectionReasons,
            errors: errors,
            warnings: warnings,
            metrics: metrics
        )
    }
}
