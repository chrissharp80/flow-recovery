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

/// Recovery window selection - finds best ORGANIZED recovery window
/// Algorithm:
/// 1. Build all windows within 30-70% of sleep (anchored to actual sleep, not recording)
/// 2. Filter ISOLATED SPIKES only (temporal discontinuity: much higher than BOTH neighbors)
/// 3. Compute organization metrics for each window: DFA α1, LF/HF, HR CV
/// 4. Classify windows as "Organized Recovery" vs "High Variability"
/// 5. Select highest RMSSD among ORGANIZED windows (prefer quality over quantity)
/// 6. If no organized windows, select best high-variability window (mark as capacity)
///
/// Key principles (research-backed):
/// - High HRV values are VALID if organized (DFA α1 ~0.75-1.0, low LF/HF, stable HR)
/// - High RMSSD with disorganization = capacity, not recovery
/// - "Abrupt" = temporal/structural discontinuity, NOT magnitude
/// - NO baseline-relative rejection (no percentile caps, no "95% of neighbor" rules)
/// - NO magnitude-based rejection ("too good to be true" has no scientific basis)
/// - Organized Recovery: DFA α1 ≈ 0.75-1.0, LF/HF < 1.5, low HR CV
/// - High Variability: high RMSSD but elevated α1 or LF/HF or unstable HR
final class WindowSelector {

    // MARK: - Types

    /// Selected recovery window for analysis
    struct RecoveryWindow: Codable {
        let startIndex: Int
        let endIndex: Int
        let startMs: Int64
        let endMs: Int64
        let beatCount: Int
        let nnCount: Int
        let qualityScore: Double
        let artifactRate: Double
        /// Mean HR during this window (bpm)
        let meanHR: Double
        /// HR stability score (lower = more stable, coefficient of variation)
        let hrStability: Double
        /// Reason this window was selected
        let selectionReason: String
        /// Relative position of window midpoint within sleep episode (0.0 = sleep start, 1.0 = wake)
        /// Used for temporal representativeness - ideally between 0.30 and 0.70
        let relativePosition: Double?
        /// Consolidated recovery score (RMSSD weighted by stability)
        let recoveryScore: Double?
        /// Whether this window represents consolidated recovery (sustained plateau AND stable HR)
        /// vs just high HRV capacity. Consolidated recovery is more load-bearing for readiness.
        /// A window is consolidated if: (1) it passed persistence/plateau check, AND (2) CV < 8%
        let isConsolidated: Bool

        // MARK: - Organization Metrics (NEW)

        /// DFA α1 for this window (optimal recovery: 0.75-1.0)
        let dfaAlpha1: Double?
        /// LF/HF ratio for this window (recovery: < 1.5, sympathetic: > 2.0)
        let lfHfRatio: Double?
        /// Whether this window shows organized parasympathetic control
        /// Organized = DFA α1 ~0.75-1.0, LF/HF < 1.5, stable HR
        /// High Variability = high RMSSD but disorganized metrics
        let isOrganizedRecovery: Bool
        /// Classification label for reporting
        let windowClassification: WindowClassification

        /// Window classification for reporting
        /// Based on DFA α1 physiological interpretation:
        /// - Organized Recovery (α1 ≈ 0.75-1.0): adaptive, coherent control - readiness indicator
        /// - Flexible Unconsolidated (α1 ≈ 0.6-0.75): high flexibility, not yet settled - capacity only
        /// - High Variability (α1 > 1.0 or < 0.6): constrained/random - neither readiness nor clean capacity
        enum WindowClassification: String, Codable {
            case organizedRecovery = "Organized Recovery"
            case flexibleUnconsolidated = "Flexible / Unconsolidated"
            case highVariability = "High Variability"
            case insufficient = "Insufficient Data"
        }

        /// Threshold for "unstable" HR coefficient of variation (8% = 0.08)
        /// Windows with CV above this are considered unstable and represent capacity, not readiness
        static let unstableCVThreshold: Double = 0.08

        /// Optimal DFA α1 range for organized recovery (readiness)
        static let optimalAlpha1Range: ClosedRange<Double> = 0.75...1.0
        /// Flexible but unconsolidated range (capacity, not readiness)
        /// High flexibility, not yet coherently regulated - valid physiology, not load-bearing
        static let flexibleAlpha1Range: ClosedRange<Double> = 0.60...0.75
        /// Extended acceptable α1 range (legacy - covers both organized and flexible)
        static let acceptableAlpha1Range: ClosedRange<Double> = 0.65...1.15
        /// Maximum LF/HF for organized recovery (parasympathetic dominance)
        static let maxOrganizedLfHf: Double = 1.5
    }

    /// Complete result including both recovery window and peak capacity
    /// Recovery window may be nil if no organized parasympathetic plateau occurred
    /// Peak capacity is always computed if any sustained windows exist
    struct WindowSelectionResult {
        /// Consolidated recovery window (nil if no organized recovery detected)
        let recoveryWindow: RecoveryWindow?
        /// Peak capacity - highest sustained HRV regardless of organization
        let peakCapacity: PeakCapacity?

        /// Whether consolidated recovery was detected
        var hasConsolidatedRecovery: Bool {
            recoveryWindow != nil
        }
    }

    /// Scored candidate block with HRV metrics
    private struct ScoredBlock {
        let startIndex: Int
        let endIndex: Int
        let startMs: Int64
        let endMs: Int64
        let artifactRate: Double
        let ectopicRate: Double
        let meanHR: Double
        let hrCV: Double
        let rmssd: Double
        let sdnn: Double
        let cleanBeatCount: Int
        /// Relative position of window midpoint within sleep episode (0.0 = start, 1.0 = end)
        let relativePosition: Double
        /// Clean RR intervals for this window (needed for DFA/frequency analysis)
        let cleanRRs: [Double]

        // MARK: - Organization Metrics

        /// DFA α1 for this window (nil if insufficient data)
        let dfaAlpha1: Double?
        /// LF/HF ratio (nil if insufficient data for frequency analysis)
        let lfHfRatio: Double?

        /// Consolidated recovery score: RMSSD weighted by stability
        /// Higher RMSSD is good, but unstable windows are penalized
        /// Formula: rmssd * stabilityFactor, where stabilityFactor decreases with higher CV
        func recoveryScore(stabilityWeight: Double) -> Double {
            // Typical HR CV during stable sleep is 0.02-0.05 (2-5%)
            // CV > 0.10 indicates significant instability
            // stabilityFactor ranges from ~1.0 (very stable) to ~0.5 (unstable)
            let stabilityFactor = 1.0 / (1.0 + stabilityWeight * hrCV)
            return rmssd * stabilityFactor
        }

        /// Classify this window as Organized Recovery or High Variability
        /// Organized Recovery: DFA α1 ~0.75-1.0, LF/HF < 1.5, stable HR
        /// High Variability: high RMSSD but disorganized (elevated α1 or LF/HF or unstable)
        var isOrganizedRecovery: Bool {
            // Must have DFA α1 to classify (need sufficient data)
            guard let alpha1 = dfaAlpha1 else {
                // If we can't compute DFA, use HR stability as proxy
                return hrCV < RecoveryWindow.unstableCVThreshold
            }

            // Check DFA α1 is in OPTIMAL range (0.75-1.0)
            // Research shows optimal parasympathetic recovery has α1 in this band
            // Values > 1.0 indicate random/disorganized signal (high variability)
            // Values < 0.75 indicate anti-correlated signal (unusual)
            let alpha1OK = RecoveryWindow.optimalAlpha1Range.contains(alpha1)

            // Check LF/HF is parasympathetic-dominant (if available)
            let lfHfOK: Bool
            if let ratio = lfHfRatio {
                lfHfOK = ratio <= RecoveryWindow.maxOrganizedLfHf
            } else {
                lfHfOK = true  // If we can't compute, don't penalize
            }

            // Check HR stability
            let stableHR = hrCV < RecoveryWindow.unstableCVThreshold

            // Organized if α1 is good AND (LF/HF is good OR HR is stable)
            // We require α1 to be in range, but are flexible on LF/HF vs stability
            return alpha1OK && (lfHfOK || stableHR)
        }

        /// Get window classification for reporting
        /// Three-tier classification based on DFA α1:
        /// - Organized Recovery (0.75-1.0): readiness indicator
        /// - Flexible Unconsolidated (0.6-0.75): capacity, not readiness
        /// - High Variability (outside both): neither
        var classification: RecoveryWindow.WindowClassification {
            if cleanBeatCount < 60 {
                return .insufficient
            }

            guard let alpha1 = dfaAlpha1 else {
                // Without DFA, use HR stability as proxy
                return hrCV < RecoveryWindow.unstableCVThreshold ? .organizedRecovery : .highVariability
            }

            // Three-tier classification based on α1
            if RecoveryWindow.optimalAlpha1Range.contains(alpha1) {
                // α1 in 0.75-1.0: organized, adaptive control
                return .organizedRecovery
            } else if RecoveryWindow.flexibleAlpha1Range.contains(alpha1) {
                // α1 in 0.6-0.75: flexible but unconsolidated (valid capacity, not readiness)
                return .flexibleUnconsolidated
            } else {
                // α1 < 0.6 or > 1.0: high variability (random or constrained)
                return .highVariability
            }
        }
    }

    // MARK: - Configuration

    struct Config {
        /// Number of beats per analysis window (400 beats ≈ 6-7 min at 60bpm)
        var beatsPerWindow: Int = 400
        /// Sliding window step in beats
        var slideStepBeats: Int = 40
        /// Maximum artifact rate for valid block
        var maxArtifactRate: Double = 0.15
        /// Minimum clean beats required for analysis (300 = 75% of 400)
        var minCleanBeats: Int = 300
        /// Ectopic beat detection threshold: 20% deviation from local median
        /// Based on research: 20-25% is standard (Kubios, PMC3268104)
        var ectopicThresholdPercent: Double = 0.20
        /// Number of surrounding beats for local median calculation
        var localMedianWindow: Int = 10

        // MARK: - Temporal Representativeness Constraints

        /// Minimum relative position within sleep episode (0.0 = sleep start, 1.0 = wake)
        /// Windows before this threshold are excluded to avoid early-night NREM spikes
        var minRelativePosition: Double = 0.30
        /// Maximum relative position within sleep episode
        /// Windows after this threshold are excluded to avoid late-night REM/arousal periods
        var maxRelativePosition: Double = 0.70
        /// Whether to enforce temporal position constraints
        /// When true, windows outside the allowed band are excluded even if physiologically valid
        var enforceTemporalConstraints: Bool = true

        // MARK: - Stability Weighting

        /// Weight given to HR stability when scoring windows (0 = ignore stability, higher = more weight)
        /// At 10.0: a window with 10% CV has ~50% penalty vs a perfectly stable window
        /// This ensures we select sustained recovery, not transient peaks
        var stabilityWeight: Double = 10.0

        static let `default` = Config()
    }

    private let config: Config

    init(config: Config = .default) {
        self.config = config
    }

    // MARK: - Main Window Selection

    /// Find the best recovery window - highest valid HRV in 30-70% sleep band
    /// Strategy:
    /// 1. Build all windows within 30-70% of actual sleep (HealthKit-anchored)
    /// 2. Filter only ISOLATED SPIKES (temporal discontinuity: much higher than BOTH neighbors)
    /// 3. Select highest RMSSD among remaining valid windows
    /// NO baseline-relative rejection, NO magnitude caps, NO position bias
    /// - Parameters:
    ///   - series: RR interval series
    ///   - flags: Artifact flags for each point
    ///   - sleepStartMs: Optional sleep start time from HealthKit (ms relative to recording start).
    ///                   If provided, used for 30-70% band calculation instead of recording start.
    ///   - wakeTimeMs: Optional wake time from HealthKit (ms relative to recording start).
    ///                 If provided, used as sleep end for 30-70% band calculation.
    func findBestWindow(
        in series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64? = nil,
        wakeTimeMs: Int64? = nil
    ) -> RecoveryWindow? {
        let points = series.points
        // Use minimum threshold since we now adapt window size
        let minRequiredBeats = 120
        guard points.count >= minRequiredBeats else {
            debugLog("[WindowSelector] Insufficient beats: \(points.count) < \(minRequiredBeats)")
            return nil
        }

        // Determine session boundaries
        guard let firstPoint = points.first, let lastPoint = points.last else {
            debugLog("[WindowSelector] No points in series")
            return nil
        }
        let recordingStartMs = firstPoint.t_ms
        let recordingEndMs = lastPoint.t_ms
        let recordingDurationMs = recordingEndMs - recordingStartMs

        // Use HealthKit sleep boundaries when available for accurate 30-70% band calculation
        // CRITICAL: The 30-70% window band must be computed relative to ACTUAL sleep, not recording
        // This ensures pre-sleep data (recorded before actual sleep onset) is excluded from analysis
        //
        // Timeline: Recording starts -> User falls asleep (sleepStartMs) -> ... -> User wakes (wakeTimeMs)
        // The 30-70% band should be computed relative to actual sleep duration, excluding pre-sleep time

        // Determine actual sleep start (relative to recording start, always >= 0)
        let actualSleepStartMs: Int64
        if let sleepStart = sleepStartMs, sleepStart >= 0 {
            actualSleepStartMs = sleepStart
            debugLog("[WindowSelector] Sleep started \(sleepStart / 60000) min after recording began (pre-sleep excluded)")
        } else {
            actualSleepStartMs = 0
            debugLog("[WindowSelector] No HealthKit sleep start, using recording start")
        }

        // Determine actual sleep end (relative to recording start)
        let actualSleepEndMs: Int64
        if let wake = wakeTimeMs, wake > actualSleepStartMs {
            // Cap at recording end since we can't analyze past that
            actualSleepEndMs = min(wake, recordingDurationMs)
            if wake > recordingDurationMs {
                debugLog("[WindowSelector] Wake time (\(wake / 60000) min) extends past recording, capping at recording end")
            } else {
                debugLog("[WindowSelector] Using HealthKit wake time: \(wake / 60000) min from recording start")
            }
        } else {
            actualSleepEndMs = recordingDurationMs
            debugLog("[WindowSelector] No valid HealthKit wake time, using recording end")
        }

        // Calculate ACTUAL sleep duration (this is physiologically meaningful)
        let actualSleepDurationMs = actualSleepEndMs - actualSleepStartMs

        debugLog("[WindowSelector] ========== WINDOW SELECTION DEBUG ==========")
        debugLog("[WindowSelector] Recording: 0 to \(formatTime(recordingDurationMs)) (\(recordingDurationMs / 60000) min)")
        debugLog("[WindowSelector] Actual sleep: \(actualSleepStartMs / 60000) min to \(actualSleepEndMs / 60000) min (duration: \(actualSleepDurationMs / 60000) min)")

        // Calculate 30% and 70% marks relative to ACTUAL sleep (not recording)
        // These marks are in session-relative coordinates (same as RR timestamps)
        let limitEarlyMs = actualSleepStartMs + Int64(Double(actualSleepDurationMs) * config.minRelativePosition)
        let limitLateMs = actualSleepStartMs + Int64(Double(actualSleepDurationMs) * config.maxRelativePosition)

        // Clamp the limits to recording boundaries (can't analyze data we don't have)
        let effectiveLimitEarlyMs = max(recordingStartMs, limitEarlyMs)
        let effectiveLimitLateMs = min(recordingEndMs, limitLateMs)

        debugLog("[WindowSelector] 30-70% band of sleep: \(limitEarlyMs / 60000) min to \(limitLateMs / 60000) min (session-relative)")
        debugLog("[WindowSelector] Effective search range: \(effectiveLimitEarlyMs / 60000) min to \(effectiveLimitLateMs / 60000) min (clamped to recording)")

        // For relative position calculation in evaluateWindow(), use ACTUAL sleep boundaries
        // This ensures windows are scored by their true position within the sleep episode
        let sleepStartBoundaryMs = actualSleepStartMs
        let sleepEndMs = actualSleepEndMs

        // Find index range for the valid band (using effective limits clamped to recording)
        guard let bandStartIdx = points.firstIndex(where: { $0.t_ms >= effectiveLimitEarlyMs }),
              let bandEndIdx = points.lastIndex(where: { $0.t_ms <= effectiveLimitLateMs }),
              bandEndIdx > bandStartIdx else {
            debugLog("[WindowSelector] Could not find valid indices in temporal band")
            return nil
        }

        // Adaptive window sizing: target is 400 beats (~5 min), scale down only if needed
        let beatsInBand = bandEndIdx - bandStartIdx
        let targetWindowBeats = config.beatsPerWindow  // 400 beats
        let minWindowBeats = 120  // Minimum 120 beats (~2 min at 60 bpm)

        // Only adapt if band is too short - otherwise use full 400-beat window
        let adaptiveWindowSize: Int
        if beatsInBand >= targetWindowBeats {
            // Band is long enough - use full 400-beat window
            adaptiveWindowSize = targetWindowBeats
        } else if beatsInBand >= minWindowBeats * 2 {
            // Band can fit at least 2x minimum window - use half of available beats
            adaptiveWindowSize = beatsInBand / 2
        } else {
            // Band is very short - use 60% of available beats (need room to slide)
            adaptiveWindowSize = max(60, (beatsInBand * 3) / 5)
        }

        let stepSize = max(10, adaptiveWindowSize / 10)
        let stabilityWeight = config.stabilityWeight

        // Calculate band stats for logging
        let bandDurationMs = effectiveLimitLateMs - effectiveLimitEarlyMs
        let bandDurationMinutes = Double(bandDurationMs) / 60000.0
        let averageBPM = Double(beatsInBand) / bandDurationMinutes

        // STEP 1: Build all windows within 30-70% band
        debugLog("[WindowSelector] STEP 1: Building all windows in 30-70% band...")
        debugLog("[WindowSelector] Band indices: \(bandStartIdx) to \(bandEndIdx) (of \(points.count) total points)")
        debugLog("[WindowSelector] Band timestamps: \(points[bandStartIdx].t_ms / 60000) min to \(points[bandEndIdx].t_ms / 60000) min")
        debugLog("[WindowSelector] Band: \(String(format: "%.1f", bandDurationMinutes)) min, \(beatsInBand) beats, avg HR: \(String(format: "%.0f", averageBPM)) bpm")
        debugLog("[WindowSelector] Window size: \(adaptiveWindowSize) beats (~\(String(format: "%.1f", Double(adaptiveWindowSize) / averageBPM)) min)")
        var allWindows: [ScoredBlock] = []

        var scanIdx = bandStartIdx + adaptiveWindowSize
        while scanIdx <= bandEndIdx {
            if let block = evaluateWindow(
                series: series,
                flags: flags,
                startIdx: scanIdx - adaptiveWindowSize,
                endIdx: scanIdx,
                sessionStartMs: sleepStartBoundaryMs,
                sessionEndMs: sleepEndMs
            ) {
                allWindows.append(block)
            }
            scanIdx += stepSize
        }

        guard !allWindows.isEmpty else {
            debugLog("[WindowSelector] No valid windows found in 30-70% band")
            return nil
        }

        debugLog("[WindowSelector] Found \(allWindows.count) windows in band")

        // Log top 10 windows by RMSSD
        let topByRMSSD = allWindows.sorted { $0.rmssd > $1.rmssd }.prefix(10)
        debugLog("[WindowSelector] Top 10 windows by RMSSD:")
        for (i, w) in topByRMSSD.enumerated() {
            let pos = Int(w.relativePosition * 100)
            let score = w.recoveryScore(stabilityWeight: stabilityWeight)
            debugLog("[WindowSelector]   #\(i+1): RMSSD=\(String(format: "%.1f", w.rmssd))ms at \(pos)%, CV=\(String(format: "%.1f", w.hrCV * 100))%, score=\(String(format: "%.1f", score))")
        }

        // STEP 2: Filter out ISOLATED SPIKES only (not sustained plateaus)
        // Per research: "Abrupt" is defined by temporal/structural discontinuity, NOT magnitude.
        // An isolated spike = window significantly higher than BOTH neighbors (temporal discontinuity)
        // A plateau = gradual transitions, fluctuations within a range, sustained elevated values
        // We do NOT reject based on magnitude difference from neighbors (that's baseline-relative rejection)
        debugLog("[WindowSelector] STEP 2: Filtering isolated spikes (temporal discontinuity)...")
        var validWindows: [ScoredBlock] = []
        var rejectedSpikes: [(ScoredBlock, String)] = []

        // Isolated spike threshold: window must be >50% higher than BOTH neighbors to be rejected
        // This catches true temporal discontinuity (42 → 96 → 44) but allows plateaus (80 → 97 → 85)
        let spikeThreshold = 1.50

        for (i, window) in allWindows.enumerated() {
            var isIsolatedSpike = false
            var leftRatio: Double = 1.0
            var rightRatio: Double = 1.0

            // Check if window is much higher than BOTH neighbors (temporal discontinuity)
            let hasLeftNeighbor = i > 0
            let hasRightNeighbor = i < allWindows.count - 1

            if hasLeftNeighbor {
                let leftNeighbor = allWindows[i - 1]
                leftRatio = window.rmssd / leftNeighbor.rmssd
            }

            if hasRightNeighbor {
                let rightNeighbor = allWindows[i + 1]
                rightRatio = window.rmssd / rightNeighbor.rmssd
            }

            // Only reject if it's an isolated spike: much higher than BOTH neighbors
            // This is structural discontinuity, not baseline-relative rejection
            if hasLeftNeighbor && hasRightNeighbor {
                isIsolatedSpike = leftRatio >= spikeThreshold && rightRatio >= spikeThreshold
            }
            // Edge windows (first/last) cannot be isolated spikes by definition

            if isIsolatedSpike {
                let reason = "isolated spike: \(String(format: "%.0f", leftRatio * 100))% > left, \(String(format: "%.0f", rightRatio * 100))% > right"
                rejectedSpikes.append((window, reason))
            } else {
                validWindows.append(window)
            }
        }

        debugLog("[WindowSelector] \(validWindows.count) valid windows (\(rejectedSpikes.count) isolated spikes filtered)")

        // Log rejected spikes
        if !rejectedSpikes.isEmpty {
            debugLog("[WindowSelector] Rejected isolated spikes (temporal discontinuity):")
            for (w, reason) in rejectedSpikes.prefix(5) {
                let pos = Int(w.relativePosition * 100)
                debugLog("[WindowSelector]   RMSSD=\(String(format: "%.1f", w.rmssd))ms at \(pos)% - \(reason)")
            }
        }

        // Use all valid windows (isolated spikes removed)
        let candidateWindows = validWindows.isEmpty ? allWindows : validWindows
        // Track which windows passed the spike filter for consolidated recovery determination
        let sustainedWindows = validWindows

        guard !candidateWindows.isEmpty else {
            debugLog("[WindowSelector] No valid windows found")
            return nil
        }

        // STEP 3: Classify windows as Organized Recovery vs High Variability
        // Organized = DFA α1 ~0.75-1.0, low LF/HF, stable HR
        // High Variability = high RMSSD but disorganized metrics
        debugLog("[WindowSelector] STEP 3: Classifying windows by organization...")

        let organizedWindows = candidateWindows.filter { $0.isOrganizedRecovery }
        let highVariabilityWindows = candidateWindows.filter { !$0.isOrganizedRecovery }

        debugLog("[WindowSelector] Found \(organizedWindows.count) organized windows, \(highVariabilityWindows.count) high-variability windows")

        // Log organization metrics for top windows
        debugLog("[WindowSelector] Top 10 windows with organization metrics:")
        let allSortedByRMSSD = candidateWindows.sorted { $0.rmssd > $1.rmssd }
        for (i, w) in allSortedByRMSSD.prefix(10).enumerated() {
            let pos = Int(w.relativePosition * 100)
            let alpha1Str = w.dfaAlpha1.map { String(format: "%.2f", $0) } ?? "N/A"
            let classStr = w.isOrganizedRecovery ? "ORGANIZED" : "high-var"
            debugLog("[WindowSelector]   #\(i+1): RMSSD=\(String(format: "%.1f", w.rmssd))ms, α1=\(alpha1Str), CV=\(String(format: "%.1f", w.hrCV * 100))% at \(pos)% [\(classStr)]")
        }

        // STEP 4: Select best window - ONLY from organized windows
        // If no organized windows exist, return nil (no consolidated recovery)
        // Peak capacity is captured separately - we do NOT fall back to high-variability for readiness

        guard !organizedWindows.isEmpty else {
            // No organized parasympathetic plateau detected
            // This is the correct physiological answer - don't pretend recovery occurred
            debugLog("[WindowSelector] STEP 4: NO ORGANIZED WINDOWS - No consolidated recovery detected")
            debugLog("[WindowSelector] High-variability windows exist but are NOT load-bearing recovery")
            debugLog("[WindowSelector] Returning nil - peak capacity will be captured separately")
            return nil
        }

        // Select highest RMSSD among organized windows
        let sortedOrganized = organizedWindows.sorted { w1, w2 in
            if w1.rmssd != w2.rmssd {
                return w1.rmssd > w2.rmssd
            }
            return w1.relativePosition > w2.relativePosition
        }
        // Safe access - guard above ensures organizedWindows is non-empty
        guard let finalBlock = sortedOrganized.first else { return nil }
        debugLog("[WindowSelector] STEP 4: Selected from \(organizedWindows.count) ORGANIZED windows")

        let positionPercent = Int(finalBlock.relativePosition * 100)
        let score = finalBlock.recoveryScore(stabilityWeight: stabilityWeight)
        let cvPercent = finalBlock.hrCV * 100
        let isSustained = sustainedWindows.contains { $0.startIndex == finalBlock.startIndex }
        let isStable = finalBlock.hrCV < RecoveryWindow.unstableCVThreshold
        // We only reach here with organized windows, so isConsolidated depends on sustain + stability
        let isConsolidated = isSustained && isStable
        let classification = finalBlock.classification

        // Validate that selected window is actually within the 30-70% band
        let minPos = Int(config.minRelativePosition * 100)
        let maxPos = Int(config.maxRelativePosition * 100)
        if positionPercent < minPos || positionPercent > maxPos {
            debugLog("[WindowSelector] WARNING: Selected window at \(positionPercent)% is outside \(minPos)-\(maxPos)% band!")
            debugLog("[WindowSelector] Window timestamps: \(finalBlock.startMs / 60000) min to \(finalBlock.endMs / 60000) min")
        }

        let alpha1Str = finalBlock.dfaAlpha1.map { String(format: "%.2f", $0) } ?? "N/A"
        let reason = "Organized Recovery (RMSSD \(String(format: "%.1f", finalBlock.rmssd)) ms, α1=\(alpha1Str), CV \(String(format: "%.1f", cvPercent))%) at \(positionPercent)%"

        debugLog("[WindowSelector] ========== CONSOLIDATED RECOVERY DETECTED ==========")
        debugLog("[WindowSelector] Classification: Organized Recovery")
        debugLog("[WindowSelector] Position: \(positionPercent)%")
        debugLog("[WindowSelector] RMSSD: \(String(format: "%.1f", finalBlock.rmssd)) ms")
        debugLog("[WindowSelector] DFA α1: \(alpha1Str)")
        debugLog("[WindowSelector] HR CV: \(String(format: "%.1f", cvPercent))%")
        debugLog("[WindowSelector] Recovery score: \(String(format: "%.1f", score))")
        debugLog("[WindowSelector] Mean HR: \(String(format: "%.1f", finalBlock.meanHR)) bpm")
        debugLog("[WindowSelector] Consolidated: \(isConsolidated)")
        debugLog("[WindowSelector] ====================================================")

        return RecoveryWindow(
            startIndex: finalBlock.startIndex,
            endIndex: finalBlock.endIndex,
            startMs: finalBlock.startMs,
            endMs: finalBlock.endMs,
            beatCount: finalBlock.endIndex - finalBlock.startIndex,
            nnCount: finalBlock.cleanBeatCount,
            qualityScore: finalBlock.rmssd / 100.0,
            artifactRate: finalBlock.artifactRate,
            meanHR: finalBlock.meanHR,
            hrStability: finalBlock.hrCV,
            selectionReason: reason,
            relativePosition: finalBlock.relativePosition,
            recoveryScore: score,
            isConsolidated: isConsolidated,
            dfaAlpha1: finalBlock.dfaAlpha1,
            lfHfRatio: finalBlock.lfHfRatio,
            isOrganizedRecovery: true,  // We only reach here with organized windows
            windowClassification: classification
        )
    }

    /// Find best recovery window AND compute peak capacity (highest sustained HRV)
    /// These are INDEPENDENT assessments:
    /// - Recovery window: only exists if organized parasympathetic plateau occurred (readiness)
    /// - Peak capacity: highest sustained HRV regardless of organization (physiological ceiling)
    ///
    /// If no organized recovery occurred, recoveryWindow will be nil but peakCapacity may exist.
    /// This is the correct physiological answer - don't pretend recovery occurred.
    func findBestWindowWithCapacity(
        in series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64? = nil,
        wakeTimeMs: Int64? = nil
    ) -> WindowSelectionResult? {
        let points = series.points
        guard points.count >= config.beatsPerWindow else {
            return nil
        }

        // Try to get recovery window (may be nil if no organized windows exist)
        // This is NOT a failure - it means no consolidated recovery occurred
        let recoveryWindow = findBestWindow(
            in: series,
            flags: flags,
            sleepStartMs: sleepStartMs,
            wakeTimeMs: wakeTimeMs
        )

        if recoveryWindow != nil {
            debugLog("[WindowSelector] Consolidated recovery window found")
        } else {
            debugLog("[WindowSelector] No consolidated recovery - will still compute peak capacity")
        }

        // Now compute peak capacity - INDEPENDENTLY from recovery window
        // Peak capacity: highest sustained RMSSD (not isolated spike)
        // NO DFA/LF-HF filters - just artifact-clean and sustained
        // Search entire recording for peak capacity
        guard let firstPoint = points.first, let lastPoint = points.last else {
            return WindowSelectionResult(recoveryWindow: recoveryWindow, peakCapacity: nil)
        }
        let recordingStartMs = firstPoint.t_ms
        let recordingEndMs = lastPoint.t_ms

        // Adaptive window sizing for peak capacity: target is 400 beats (~5 min), scale down only if needed
        let totalBeats = points.count
        let targetWindowBeats = config.beatsPerWindow  // 400 beats
        let minWindowBeats = 120  // Minimum 120 beats (~2 min at 60 bpm)

        // Only adapt if recording is too short - otherwise use full 400-beat window
        let adaptiveWindowSize: Int
        if totalBeats >= targetWindowBeats {
            // Recording is long enough - use full 400-beat window
            adaptiveWindowSize = targetWindowBeats
        } else if totalBeats >= minWindowBeats * 3 {
            // Recording can fit at least 3x minimum window - use 1/3 of available beats
            adaptiveWindowSize = totalBeats / 3
        } else {
            // Recording is very short - use 40% of available beats (need room to slide)
            adaptiveWindowSize = max(60, (totalBeats * 2) / 5)
        }

        let stepSize = max(10, adaptiveWindowSize / 10)

        // Calculate recording stats for logging
        let recordingDurationMs = recordingEndMs - recordingStartMs
        let recordingDurationMinutes = Double(recordingDurationMs) / 60000.0
        let averageBPM = Double(totalBeats) / recordingDurationMinutes

        debugLog("[WindowSelector] Peak capacity scan: \(String(format: "%.1f", recordingDurationMinutes)) min recording, \(totalBeats) beats, avg HR: \(String(format: "%.0f", averageBPM)) bpm")
        debugLog("[WindowSelector] Window size: \(adaptiveWindowSize) beats (~\(String(format: "%.1f", Double(adaptiveWindowSize) / averageBPM)) min)")

        var allWindows: [ScoredBlock] = []

        var scanIdx = adaptiveWindowSize
        while scanIdx <= points.count {
            if let block = evaluateWindow(
                series: series,
                flags: flags,
                startIdx: scanIdx - adaptiveWindowSize,
                endIdx: scanIdx,
                sessionStartMs: recordingStartMs,
                sessionEndMs: recordingEndMs
            ) {
                allWindows.append(block)
            }
            scanIdx += stepSize
        }

        guard !allWindows.isEmpty else {
            // No valid windows at all - return whatever we have
            if recoveryWindow != nil {
                return WindowSelectionResult(recoveryWindow: recoveryWindow, peakCapacity: nil)
            }
            return nil  // No data at all
        }

        // Filter isolated spikes only (temporal discontinuity)
        // NO DFA/LF-HF veto, NO baseline veto, NO "too high" veto
        var sustainedWindows: [ScoredBlock] = []
        let spikeThreshold = 1.50

        for (i, window) in allWindows.enumerated() {
            var isIsolatedSpike = false

            let hasLeftNeighbor = i > 0
            let hasRightNeighbor = i < allWindows.count - 1

            if hasLeftNeighbor && hasRightNeighbor {
                let leftRatio = window.rmssd / allWindows[i - 1].rmssd
                let rightRatio = window.rmssd / allWindows[i + 1].rmssd
                isIsolatedSpike = leftRatio >= spikeThreshold && rightRatio >= spikeThreshold
            }

            if !isIsolatedSpike {
                sustainedWindows.append(window)
            }
        }

        // Find highest RMSSD among sustained windows for peak capacity
        guard let peakWindow = sustainedWindows.max(by: { $0.rmssd < $1.rmssd }) else {
            return WindowSelectionResult(recoveryWindow: recoveryWindow, peakCapacity: nil)
        }

        // Calculate window duration in minutes
        let windowDurationMs = peakWindow.endMs - peakWindow.startMs
        let windowDurationMinutes = Double(windowDurationMs) / 60000.0

        let peakCapacity = PeakCapacity(
            peakRMSSD: peakWindow.rmssd,
            peakSDNN: peakWindow.sdnn,
            peakTotalPower: nil,  // Would need frequency domain analysis per window
            windowDurationMinutes: windowDurationMinutes,
            windowRelativePosition: peakWindow.relativePosition,
            windowMeanHR: peakWindow.meanHR
        )

        debugLog("[WindowSelector] Peak Capacity: RMSSD=\(String(format: "%.1f", peakWindow.rmssd))ms, SDNN=\(String(format: "%.1f", peakWindow.sdnn))ms at \(Int(peakWindow.relativePosition * 100))%")

        return WindowSelectionResult(
            recoveryWindow: recoveryWindow,
            peakCapacity: peakCapacity
        )
    }

    // MARK: - Method-Based Window Selection

    /// Select window using a specific method
    /// - Parameters:
    ///   - method: The selection method to use
    ///   - series: RR interval series
    ///   - flags: Artifact flags for each point
    ///   - sleepStartMs: Optional sleep start time from HealthKit
    ///   - wakeTimeMs: Optional wake time from HealthKit
    /// - Returns: Recovery window selected by the specified method, or nil if unavailable
    func selectWindowByMethod(
        _ method: WindowSelectionMethod,
        in series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64? = nil,
        wakeTimeMs: Int64? = nil
    ) -> RecoveryWindow? {
        switch method {
        case .consolidatedRecovery:
            // Use existing algorithm: highest RMSSD among organized windows
            return findBestWindow(in: series, flags: flags, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs)

        case .peakRMSSD:
            // Find window with highest RMSSD (no organization filtering)
            return findPeakMetricWindow(in: series, flags: flags, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs, metric: .rmssd)

        case .peakSDNN:
            // Find window with highest SDNN
            return findPeakMetricWindow(in: series, flags: flags, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs, metric: .sdnn)

        case .peakTotalPower:
            // Find window with highest total spectral power
            return findPeakMetricWindow(in: series, flags: flags, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs, metric: .totalPower)

        case .custom:
            // Custom requires manual positioning - not automatic
            return nil
        }
    }

    /// Metric to optimize for in peak window selection
    private enum OptimizationMetric {
        case rmssd
        case sdnn
        case totalPower
    }

    /// Find window with peak value of a specific metric
    private func findPeakMetricWindow(
        in series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64?,
        wakeTimeMs: Int64?,
        metric: OptimizationMetric
    ) -> RecoveryWindow? {
        let points = series.points
        // Use minimum threshold since we now adapt window size
        let minRequiredBeats = 120
        guard points.count >= minRequiredBeats else {
            debugLog("[WindowSelector] Insufficient beats: \(points.count) < \(minRequiredBeats)")
            return nil
        }

        // Determine session boundaries (same logic as findBestWindow)
        guard let firstPoint = points.first, let lastPoint = points.last else {
            debugLog("[WindowSelector] No points in series")
            return nil
        }
        let recordingStartMs = firstPoint.t_ms
        let recordingEndMs = lastPoint.t_ms
        let recordingDurationMs = recordingEndMs - recordingStartMs

        let actualSleepStartMs: Int64
        if let sleepStart = sleepStartMs, sleepStart >= 0 {
            actualSleepStartMs = sleepStart
        } else {
            actualSleepStartMs = 0
        }

        let actualSleepEndMs: Int64
        if let wake = wakeTimeMs, wake > actualSleepStartMs {
            actualSleepEndMs = min(wake, recordingDurationMs)
        } else {
            actualSleepEndMs = recordingDurationMs
        }

        let actualSleepDurationMs = actualSleepEndMs - actualSleepStartMs

        // Calculate 30-70% band
        let limitEarlyMs = actualSleepStartMs + Int64(Double(actualSleepDurationMs) * config.minRelativePosition)
        let limitLateMs = actualSleepStartMs + Int64(Double(actualSleepDurationMs) * config.maxRelativePosition)
        let effectiveLimitEarlyMs = max(recordingStartMs, limitEarlyMs)
        let effectiveLimitLateMs = min(recordingEndMs, limitLateMs)

        guard let bandStartIdx = points.firstIndex(where: { $0.t_ms >= effectiveLimitEarlyMs }),
              let bandEndIdx = points.lastIndex(where: { $0.t_ms <= effectiveLimitLateMs }),
              bandEndIdx > bandStartIdx else {
            debugLog("[WindowSelector] Could not find valid indices in temporal band")
            return nil
        }

        // Adaptive window sizing: target is 400 beats (~5 min), scale down only if needed
        let beatsInBand = bandEndIdx - bandStartIdx
        let targetWindowBeats = config.beatsPerWindow  // 400 beats
        let minWindowBeats = 120  // Minimum 120 beats (~2 min at 60 bpm)

        // Only adapt if band is too short - otherwise use full 400-beat window
        let adaptiveWindowSize: Int
        if beatsInBand >= targetWindowBeats {
            // Band is long enough - use full 400-beat window
            adaptiveWindowSize = targetWindowBeats
        } else if beatsInBand >= minWindowBeats * 2 {
            // Band can fit at least 2x minimum window - use half of available beats
            adaptiveWindowSize = beatsInBand / 2
        } else {
            // Band is very short - use 60% of available beats (need room to slide)
            adaptiveWindowSize = max(60, (beatsInBand * 3) / 5)
        }

        let stepSize = max(10, adaptiveWindowSize / 10)

        // Calculate band stats for logging
        let bandDurationMs = effectiveLimitLateMs - effectiveLimitEarlyMs
        let bandDurationMinutes = Double(bandDurationMs) / 60000.0
        let averageBPM = Double(beatsInBand) / bandDurationMinutes

        let sleepStartBoundaryMs = actualSleepStartMs
        let sleepEndMs = actualSleepEndMs

        debugLog("[WindowSelector] ========== PEAK \(metric) SELECTION ==========")
        debugLog("[WindowSelector] Band: \(String(format: "%.1f", bandDurationMinutes)) min, \(beatsInBand) beats, avg HR: \(String(format: "%.0f", averageBPM)) bpm")
        debugLog("[WindowSelector] Window size: \(adaptiveWindowSize) beats (~\(String(format: "%.1f", Double(adaptiveWindowSize) / averageBPM)) min)")

        // Build all windows in 30-70% band
        var allWindows: [ScoredBlock] = []
        var scanIdx = bandStartIdx + adaptiveWindowSize
        while scanIdx <= bandEndIdx {
            if let block = evaluateWindow(
                series: series,
                flags: flags,
                startIdx: scanIdx - adaptiveWindowSize,
                endIdx: scanIdx,
                sessionStartMs: sleepStartBoundaryMs,
                sessionEndMs: sleepEndMs
            ) {
                allWindows.append(block)
            }
            scanIdx += stepSize
        }

        guard !allWindows.isEmpty else {
            debugLog("[WindowSelector] No valid windows found in 30-70% band")
            return nil
        }

        // Filter isolated spikes (same logic as findBestWindow)
        var validWindows: [ScoredBlock] = []
        let spikeThreshold = 1.50

        for (i, window) in allWindows.enumerated() {
            var isIsolatedSpike = false
            if i > 0 && i < allWindows.count - 1 {
                let leftRatio = window.rmssd / allWindows[i - 1].rmssd
                let rightRatio = window.rmssd / allWindows[i + 1].rmssd
                isIsolatedSpike = leftRatio >= spikeThreshold && rightRatio >= spikeThreshold
            }
            if !isIsolatedSpike {
                validWindows.append(window)
            }
        }

        let candidateWindows = validWindows.isEmpty ? allWindows : validWindows

        // Select window with peak metric value
        let selectedBlock: ScoredBlock?
        switch metric {
        case .rmssd:
            selectedBlock = candidateWindows.max(by: { $0.rmssd < $1.rmssd })
        case .sdnn:
            selectedBlock = candidateWindows.max(by: { $0.sdnn < $1.sdnn })
        case .totalPower:
            // For total power, we need frequency domain analysis
            // For now, use SDNN as proxy (correlates with total power)
            debugLog("[WindowSelector] Total power requires frequency analysis - using SDNN as proxy")
            selectedBlock = candidateWindows.max(by: { $0.sdnn < $1.sdnn })
        }

        guard let finalBlock = selectedBlock else {
            debugLog("[WindowSelector] No valid windows found")
            return nil
        }

        let positionPercent = Int(finalBlock.relativePosition * 100)
        let cvPercent = finalBlock.hrCV * 100
        let isOrganized = finalBlock.isOrganizedRecovery
        let classification = finalBlock.classification
        let isConsolidated = isOrganized && finalBlock.hrCV < RecoveryWindow.unstableCVThreshold
        let alpha1Str = finalBlock.dfaAlpha1.map { String(format: "%.2f", $0) } ?? "N/A"

        let metricName: String
        let metricValue: String
        switch metric {
        case .rmssd:
            metricName = "RMSSD"
            metricValue = String(format: "%.1f", finalBlock.rmssd)
        case .sdnn:
            metricName = "SDNN"
            metricValue = String(format: "%.1f", finalBlock.sdnn)
        case .totalPower:
            metricName = "SDNN (Total Power proxy)"
            metricValue = String(format: "%.1f", finalBlock.sdnn)
        }

        let reason = "Peak \(metricName) (\(metricValue) ms, α1=\(alpha1Str), CV \(String(format: "%.1f", cvPercent))%) at \(positionPercent)%"

        debugLog("[WindowSelector] Selected window: \(reason)")
        debugLog("[WindowSelector] ====================================================")

        return RecoveryWindow(
            startIndex: finalBlock.startIndex,
            endIndex: finalBlock.endIndex,
            startMs: finalBlock.startMs,
            endMs: finalBlock.endMs,
            beatCount: finalBlock.endIndex - finalBlock.startIndex,
            nnCount: finalBlock.cleanBeatCount,
            qualityScore: finalBlock.rmssd / 100.0,
            artifactRate: finalBlock.artifactRate,
            meanHR: finalBlock.meanHR,
            hrStability: finalBlock.hrCV,
            selectionReason: reason,
            relativePosition: finalBlock.relativePosition,
            recoveryScore: finalBlock.recoveryScore(stabilityWeight: config.stabilityWeight),
            isConsolidated: isConsolidated,
            dfaAlpha1: finalBlock.dfaAlpha1,
            lfHfRatio: finalBlock.lfHfRatio,
            isOrganizedRecovery: isOrganized,
            windowClassification: classification
        )
    }

    // MARK: - Manual Window Selection

    /// Analyze at a specific timestamp (for user-selected windows)
    /// Returns the best window centered on the target time, ignoring temporal constraints
    func analyzeAtPosition(
        in series: RRSeries,
        flags: [ArtifactFlags],
        targetMs: Int64
    ) -> RecoveryWindow? {
        let points = series.points
        guard points.count >= config.beatsPerWindow,
              let firstPoint = points.first,
              let lastPoint = points.last else {
            debugLog("[WindowSelector] Insufficient beats for manual selection")
            return nil
        }

        let sessionStartMs = firstPoint.t_ms
        let sessionEndMs = lastPoint.t_ms

        // Find the index closest to target time
        guard let targetIdx = points.firstIndex(where: { $0.t_ms >= targetMs }) else {
            debugLog("[WindowSelector] Target time outside recording range")
            return nil
        }

        // Center window on target
        let halfWindow = config.beatsPerWindow / 2
        var windowStartIdx = max(0, targetIdx - halfWindow)
        var windowEndIdx = windowStartIdx + config.beatsPerWindow

        // Adjust if we hit the end
        if windowEndIdx > points.count {
            windowEndIdx = points.count
            windowStartIdx = max(0, windowEndIdx - config.beatsPerWindow)
        }

        debugLog("[WindowSelector] Manual selection at \(formatTime(targetMs)) -> indices \(windowStartIdx)-\(windowEndIdx)")

        // Evaluate this specific window
        guard let block = evaluateWindow(
            series: series,
            flags: flags,
            startIdx: windowStartIdx,
            endIdx: windowEndIdx,
            sessionStartMs: sessionStartMs,
            sessionEndMs: sessionEndMs
        ) else {
            debugLog("[WindowSelector] Manual window failed quality checks")
            return nil
        }

        let positionPercent = Int(block.relativePosition * 100)
        let score = block.recoveryScore(stabilityWeight: config.stabilityWeight)
        let cvPercent = block.hrCV * 100
        let isOrganized = block.isOrganizedRecovery
        let classification = block.classification
        // Manual selections use organization status for consolidation
        let isConsolidated = isOrganized && block.hrCV < RecoveryWindow.unstableCVThreshold

        let alpha1Str = block.dfaAlpha1.map { String(format: "%.2f", $0) } ?? "N/A"

        return RecoveryWindow(
            startIndex: block.startIndex,
            endIndex: block.endIndex,
            startMs: block.startMs,
            endMs: block.endMs,
            beatCount: block.endIndex - block.startIndex,
            nnCount: block.cleanBeatCount,
            qualityScore: block.rmssd / 100.0,
            artifactRate: block.artifactRate,
            meanHR: block.meanHR,
            hrStability: block.hrCV,
            selectionReason: "Manual selection at \(positionPercent)% (RMSSD \(String(format: "%.1f", block.rmssd)) ms, α1=\(alpha1Str), CV \(String(format: "%.1f", cvPercent))%)",
            relativePosition: block.relativePosition,
            recoveryScore: score,
            isConsolidated: isConsolidated,
            dfaAlpha1: block.dfaAlpha1,
            lfHfRatio: block.lfHfRatio,
            isOrganizedRecovery: isOrganized,
            windowClassification: classification
        )
    }

    // MARK: - Window Evaluation

    /// Evaluate a single window, filtering ectopic beats individually
    /// Also calculates relative position within sleep episode for temporal representativeness
    private func evaluateWindow(
        series: RRSeries,
        flags: [ArtifactFlags],
        startIdx: Int,
        endIdx: Int,
        sessionStartMs: Int64,
        sessionEndMs: Int64
    ) -> ScoredBlock? {
        let points = series.points
        let windowPoints = Array(points[startIdx..<endIdx])
        let windowFlags = Array(flags[startIdx..<min(endIdx, flags.count)])

        // Get RR values, excluding artifacts
        var rrValues: [(index: Int, rr: Double)] = []
        for (i, point) in windowPoints.enumerated() {
            let flagIdx = i
            let isArtifact = flagIdx < windowFlags.count ? windowFlags[flagIdx].isArtifact : false
            if !isArtifact && point.rr_ms > 300 && point.rr_ms < 2000 {
                rrValues.append((startIdx + i, Double(point.rr_ms)))
            }
        }

        // Check artifact rate from existing flags
        let artifactCount = windowFlags.filter { $0.isArtifact }.count
        let artifactRate = Double(artifactCount) / Double(windowPoints.count)

        if artifactRate > config.maxArtifactRate {
            return nil
        }

        guard rrValues.count >= 50 else {
            return nil
        }

        // Filter ectopic beats using 20% deviation from local median
        let cleanRRs = filterEctopicBeats(rrValues.map { $0.rr })

        guard cleanRRs.count >= config.minCleanBeats else {
            return nil
        }

        let ectopicCount = rrValues.count - cleanRRs.count
        let ectopicRate = Double(ectopicCount) / Double(rrValues.count)

        // Calculate metrics on clean RRs only
        let meanRR = cleanRRs.reduce(0, +) / Double(cleanRRs.count)

        // Calculate mean HR - use stored HR from sensor if available, otherwise from mean RR
        let meanHR: Double
        let hasStoredHR = windowPoints.contains { $0.hr != nil }
        if hasStoredHR {
            // Use stored HR from streaming (accurate)
            let hrValues = windowPoints.compactMap { $0.hr }.map { Double($0) }
            meanHR = hrValues.isEmpty ? (60000.0 / meanRR) : (hrValues.reduce(0, +) / Double(hrValues.count))
        } else {
            // Fallback: calculate from mean RR (close approximation for stable rhythms)
            meanHR = 60000.0 / meanRR
        }

        // HR coefficient of variation and SDNN
        let variance = cleanRRs.map { pow($0 - meanRR, 2) }.reduce(0, +) / Double(cleanRRs.count)
        let hrCV = sqrt(variance) / meanRR
        let sdnn = sqrt(variance)

        // Calculate RMSSD on clean data
        let rmssd = calculateRMSSD(cleanRRs)

        // Calculate relative position within sleep episode
        guard let firstWindowPoint = windowPoints.first,
              let lastWindowPoint = windowPoints.last else {
            return nil
        }
        let windowStartMs = firstWindowPoint.t_ms
        let windowEndMs = lastWindowPoint.t_ms
        let windowMidpointMs = (windowStartMs + windowEndMs) / 2
        let sleepDuration = sessionEndMs - sessionStartMs
        let relativePosition = sleepDuration > 0
            ? Double(windowMidpointMs - sessionStartMs) / Double(sleepDuration)
            : 0.5  // Default to middle if duration is zero

        // Compute DFA α1 for organization classification (requires 64+ beats)
        let dfaAlpha1: Double?
        if cleanRRs.count >= 64 {
            dfaAlpha1 = DFAAnalyzer.compute(cleanRRs)?.alpha1
        } else {
            dfaAlpha1 = nil
        }

        // Note: LF/HF computation is expensive and requires resampling
        // We compute it only for final selected window in the main analysis
        // For window selection, we use DFA α1 + HR stability as primary criteria
        let lfHfRatio: Double? = nil

        return ScoredBlock(
            startIndex: startIdx,
            endIndex: endIdx,
            startMs: windowStartMs,
            endMs: windowEndMs,
            artifactRate: artifactRate,
            ectopicRate: ectopicRate,
            meanHR: meanHR,
            hrCV: hrCV,
            rmssd: rmssd,
            sdnn: sdnn,
            cleanBeatCount: cleanRRs.count,
            relativePosition: relativePosition,
            cleanRRs: cleanRRs,
            dfaAlpha1: dfaAlpha1,
            lfHfRatio: lfHfRatio
        )
    }

    // MARK: - Ectopic Beat Filtering

    /// Filter ectopic beats using 20% deviation from local median
    /// Based on research: PMC3268104, Kubios methodology
    /// Single beats that deviate >20% from surrounding median are filtered
    private func filterEctopicBeats(_ rrValues: [Double]) -> [Double] {
        guard rrValues.count > config.localMedianWindow else {
            return rrValues
        }

        var cleanRRs: [Double] = []
        let halfWindow = config.localMedianWindow / 2

        for i in 0..<rrValues.count {
            let rr = rrValues[i]

            // Calculate local median from surrounding beats
            let windowStart = max(0, i - halfWindow)
            let windowEnd = min(rrValues.count, i + halfWindow + 1)
            var localValues = Array(rrValues[windowStart..<windowEnd])

            // Remove current value from median calculation to avoid self-influence
            if let idx = localValues.firstIndex(of: rr) {
                localValues.remove(at: idx)
            }

            guard !localValues.isEmpty else {
                cleanRRs.append(rr)
                continue
            }

            localValues.sort()
            let localMedian: Double
            if localValues.count % 2 == 0 {
                localMedian = (localValues[localValues.count/2 - 1] + localValues[localValues.count/2]) / 2.0
            } else {
                localMedian = localValues[localValues.count/2]
            }

            // Check if deviation exceeds 20% threshold
            let deviation = abs(rr - localMedian) / localMedian

            if deviation <= config.ectopicThresholdPercent {
                // Normal beat - keep it
                cleanRRs.append(rr)
            }
            // Ectopic beat - filter it out (don't add to cleanRRs)
        }

        return cleanRRs
    }

    /// Calculate RMSSD from RR intervals
    private func calculateRMSSD(_ rrValues: [Double]) -> Double {
        guard rrValues.count >= 2 else { return 0 }

        var sumSquaredDiffs: Double = 0
        var count = 0

        for i in 1..<rrValues.count {
            let diff = rrValues[i] - rrValues[i-1]
            sumSquaredDiffs += diff * diff
            count += 1
        }

        return count > 0 ? sqrt(sumSquaredDiffs / Double(count)) : 0
    }

    // MARK: - Helpers

    private func formatTime(_ ms: Int64) -> String {
        let totalSeconds = Int(ms / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    // MARK: - Legacy API (for compatibility)

    func selectRecoveryWindow(
        series: RRSeries,
        flags: [ArtifactFlags],
        wakeTimeMs: Int64
    ) -> RecoveryWindow? {
        return findBestWindow(in: series, flags: flags, wakeTimeMs: wakeTimeMs)
    }

    func selectRecoveryWindow(
        series: RRSeries,
        flags: [ArtifactFlags],
        sessionStart: Date,
        wakeTime: Date
    ) -> RecoveryWindow? {
        let wakeTimeMs = Int64(wakeTime.timeIntervalSince(sessionStart) * 1000)
        return findBestWindow(in: series, flags: flags, wakeTimeMs: wakeTimeMs)
    }
}
