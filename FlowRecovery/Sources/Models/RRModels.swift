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

/// A single RR interval point
struct RRPoint: Codable, Equatable {
    /// Start timestamp in milliseconds since session start (cumulative from RR intervals)
    let t_ms: Int64
    /// RR interval duration in milliseconds
    let rr_ms: Int
    /// Absolute wall-clock timestamp when this RR was received (for gap detection)
    /// Only populated during streaming mode; nil for H10 internal recording
    let wallClockMs: Int64?
    /// Heart rate calculated by the device (bpm)
    /// Only populated during streaming mode (from Polar H10 sensor); nil for internal recording
    let hr: Int?

    /// Legacy initializer (for backwards compatibility with H10 internal recording)
    init(t_ms: Int64, rr_ms: Int) {
        self.t_ms = t_ms
        self.rr_ms = rr_ms
        self.wallClockMs = nil
        self.hr = nil
    }

    /// Full initializer with wall-clock timestamp (for streaming mode)
    init(t_ms: Int64, rr_ms: Int, wallClockMs: Int64?, hr: Int? = nil) {
        self.t_ms = t_ms
        self.rr_ms = rr_ms
        self.wallClockMs = wallClockMs
        self.hr = hr
    }

    /// End timestamp (start + duration)
    var endMs: Int64 {
        t_ms + Int64(rr_ms)
    }

    /// Midpoint timestamp for interpolation
    var midpointMs: Double {
        Double(t_ms) + Double(rr_ms) / 2.0
    }

    /// Gap between wall-clock time and cumulative RR time (indicates dropped data)
    /// Positive value = wall clock is ahead = data was likely dropped
    /// Only meaningful for streaming data with wallClockMs populated
    var clockDriftMs: Int64? {
        guard let wallClock = wallClockMs else { return nil }
        return wallClock - t_ms
    }
}

/// A series of RR intervals
struct RRSeries: Codable {
    let points: [RRPoint]
    let sessionId: UUID
    let startDate: Date

    /// Total duration from first to last beat end (based on cumulative RR intervals)
    var durationMs: Int64 {
        guard let first = points.first, let last = points.last else { return 0 }
        return last.endMs - first.t_ms
    }

    /// Duration in minutes
    var durationMinutes: Double {
        Double(durationMs) / 60_000.0
    }

    /// Whether this series has wall-clock timestamps (streaming mode)
    var hasWallClockTimestamps: Bool {
        points.first?.wallClockMs != nil
    }

    /// Actual wall-clock duration (for streaming mode with wall-clock timestamps)
    /// Returns nil if wall-clock timestamps aren't available
    var wallClockDurationMs: Int64? {
        guard let firstWall = points.first?.wallClockMs,
              let lastWall = points.last?.wallClockMs else { return nil }
        return lastWall - firstWall
    }

    /// Estimated data loss percentage based on wall-clock vs cumulative RR time drift
    /// Positive value indicates data was likely dropped during streaming
    var estimatedDataLossPercent: Double? {
        guard let wallDuration = wallClockDurationMs, wallDuration > 0 else { return nil }
        let rrDuration = durationMs
        let drift = wallDuration - rrDuration
        guard drift > 0 else { return 0.0 }  // No loss or clock drift backwards (unlikely)
        return (Double(drift) / Double(wallDuration)) * 100.0
    }

    /// Find gaps in the data where wall-clock time advanced more than expected
    /// A gap is detected when wall-clock drift increases significantly between consecutive points
    /// - Parameter thresholdMs: Minimum gap size to report (default 2000ms = 2 seconds)
    /// - Returns: Array of (startIndex, endIndex, gapDurationMs) for each detected gap
    func detectGaps(thresholdMs: Int64 = 2000) -> [(startIndex: Int, endIndex: Int, gapDurationMs: Int64)] {
        guard hasWallClockTimestamps, points.count > 1 else { return [] }

        var gaps: [(startIndex: Int, endIndex: Int, gapDurationMs: Int64)] = []

        for i in 1..<points.count {
            guard let prevWall = points[i-1].wallClockMs,
                  let currWall = points[i].wallClockMs else { continue }

            // Wall-clock time between samples
            let wallElapsed = currWall - prevWall
            // Expected time (just the RR interval)
            let expectedElapsed = Int64(points[i-1].rr_ms)
            // Gap = wall time - expected time
            let gap = wallElapsed - expectedElapsed

            if gap >= thresholdMs {
                gaps.append((startIndex: i-1, endIndex: i, gapDurationMs: gap))
            }
        }

        return gaps
    }

    /// Total time lost to gaps (useful for adjusting sleep calculations)
    var totalGapDurationMs: Int64 {
        detectGaps().reduce(0) { $0 + $1.gapDurationMs }
    }

    /// Get the absolute timestamp for a point at a given index
    /// Uses cumulative RR time (t_ms) - accurate for H10 internal recording
    /// For streaming mode with gaps, use absoluteTimeWallClock() instead
    /// - Parameter index: Index of the RR point
    /// - Returns: Absolute Date for when this beat occurred
    func absoluteTime(at index: Int) -> Date? {
        guard index >= 0 && index < points.count else { return nil }
        let point = points[index]
        return startDate.addingTimeInterval(TimeInterval(point.t_ms) / 1000.0)
    }

    /// Get the absolute timestamp using wall-clock time (streaming mode)
    /// This is more accurate than cumulative RR time when data gaps occurred
    /// Falls back to cumulative RR time if wall-clock not available
    /// - Parameter index: Index of the RR point
    /// - Returns: Absolute Date for when this beat was received
    func absoluteTimeWallClock(at index: Int) -> Date? {
        guard index >= 0 && index < points.count else { return nil }
        let point = points[index]
        if let wallClock = point.wallClockMs {
            return startDate.addingTimeInterval(TimeInterval(wallClock) / 1000.0)
        }
        return startDate.addingTimeInterval(TimeInterval(point.t_ms) / 1000.0)
    }

    /// Get the absolute timestamp for a point's midpoint (useful for interpolation)
    /// - Parameter index: Index of the RR point
    /// - Returns: Absolute Date for the midpoint of this RR interval
    func absoluteMidpoint(at index: Int) -> Date? {
        guard index >= 0 && index < points.count else { return nil }
        let point = points[index]
        return startDate.addingTimeInterval(point.midpointMs / 1000.0)
    }

    /// Get absolute timestamp for a relative millisecond offset
    /// - Parameter relativeMs: Milliseconds from session start
    /// - Returns: Absolute Date
    func absoluteTime(fromRelativeMs relativeMs: Int64) -> Date {
        startDate.addingTimeInterval(TimeInterval(relativeMs) / 1000.0)
    }

    /// Get relative milliseconds from an absolute Date
    /// - Parameter date: Absolute Date
    /// - Returns: Milliseconds since session start
    func relativeMs(from date: Date) -> Int64 {
        Int64(date.timeIntervalSince(startDate) * 1000.0)
    }

    /// Find the RR point index closest to a given absolute time using wall-clock timestamps
    /// This is useful for aligning streaming data with Apple Sleep boundaries
    /// Falls back to cumulative RR time if wall-clock not available
    /// - Parameter date: The target absolute Date
    /// - Returns: Index of the closest RR point, or nil if series is empty
    func indexClosestToWallClock(_ date: Date) -> Int? {
        guard !points.isEmpty else { return nil }

        let targetMs = Int64(date.timeIntervalSince(startDate) * 1000.0)

        // Binary search for closest point
        var low = 0
        var high = points.count - 1

        while low < high {
            let mid = (low + high) / 2
            let midMs = points[mid].wallClockMs ?? points[mid].t_ms

            if midMs < targetMs {
                low = mid + 1
            } else {
                high = mid
            }
        }

        // Check if the point before is closer
        if low > 0 {
            let lowMs = points[low].wallClockMs ?? points[low].t_ms
            let prevMs = points[low - 1].wallClockMs ?? points[low - 1].t_ms
            if abs(prevMs - targetMs) < abs(lowMs - targetMs) {
                return low - 1
            }
        }

        return low
    }

    /// Get the actual end time of the series using wall-clock time if available
    /// More accurate than durationMs for streaming mode with data gaps
    var actualEndDate: Date {
        if let lastWall = points.last?.wallClockMs {
            return startDate.addingTimeInterval(TimeInterval(lastWall) / 1000.0)
        }
        return startDate.addingTimeInterval(TimeInterval(durationMs) / 1000.0)
    }
}

/// Artifact classification flags for each RR interval
struct ArtifactFlags: Codable, Equatable {
    /// True if this interval is considered an artifact
    let isArtifact: Bool
    /// Classification of artifact type
    let type: ArtifactType?
    /// Confidence score (0-1)
    let confidence: Double
    /// True if this artifact was corrected/interpolated
    let corrected: Bool

    enum ArtifactType: String, Codable {
        case none
        case ectopic       // Premature beat
        case missed        // Missed beat detection
        case extra         // Extra detection (noise)
        case technical     // Sensor artifact
    }

    static let clean = ArtifactFlags(isArtifact: false, type: ArtifactType.none, confidence: 1.0, corrected: false)

    /// Legacy initializer for backwards compatibility
    init(isArtifact: Bool, type: ArtifactType?, confidence: Double) {
        self.isArtifact = isArtifact
        self.type = type
        self.confidence = confidence
        self.corrected = false
    }

    /// Full initializer with corrected flag
    init(isArtifact: Bool, type: ArtifactType?, confidence: Double, corrected: Bool) {
        self.isArtifact = isArtifact
        self.type = type
        self.confidence = confidence
        self.corrected = corrected
    }
}

/// Time-domain HRV metrics
struct TimeDomainMetrics: Codable {
    /// Mean RR interval (ms)
    let meanRR: Double
    /// Standard deviation of RR intervals (ms)
    let sdnn: Double
    /// Root mean square of successive differences (ms)
    let rmssd: Double
    /// Percentage of successive RR differences > 50ms
    let pnn50: Double
    /// Standard deviation of successive differences (ms)
    let sdsd: Double
    /// Mean heart rate (bpm)
    let meanHR: Double
    /// Standard deviation of heart rate (bpm)
    let sdHR: Double
    /// Minimum heart rate (bpm)
    let minHR: Double
    /// Maximum heart rate (bpm)
    let maxHR: Double
    /// HRV Triangular Index (N / max histogram bin)
    let triangularIndex: Double?

    /// Backwards compatible initializer (for existing archived data)
    init(meanRR: Double, sdnn: Double, rmssd: Double, pnn50: Double, sdsd: Double,
         meanHR: Double, sdHR: Double, triangularIndex: Double?) {
        self.meanRR = meanRR
        self.sdnn = sdnn
        self.rmssd = rmssd
        self.pnn50 = pnn50
        self.sdsd = sdsd
        self.meanHR = meanHR
        self.sdHR = sdHR
        self.minHR = meanHR - sdHR  // Approximate from SD
        self.maxHR = meanHR + sdHR
        self.triangularIndex = triangularIndex
    }

    /// Full initializer with min/max HR
    init(meanRR: Double, sdnn: Double, rmssd: Double, pnn50: Double, sdsd: Double,
         meanHR: Double, sdHR: Double, minHR: Double, maxHR: Double, triangularIndex: Double?) {
        self.meanRR = meanRR
        self.sdnn = sdnn
        self.rmssd = rmssd
        self.pnn50 = pnn50
        self.sdsd = sdsd
        self.meanHR = meanHR
        self.sdHR = sdHR
        self.minHR = minHR
        self.maxHR = maxHR
        self.triangularIndex = triangularIndex
    }

    /// Codable with defaults for missing fields
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meanRR = try container.decode(Double.self, forKey: .meanRR)
        sdnn = try container.decode(Double.self, forKey: .sdnn)
        rmssd = try container.decode(Double.self, forKey: .rmssd)
        pnn50 = try container.decode(Double.self, forKey: .pnn50)
        sdsd = try container.decode(Double.self, forKey: .sdsd)
        meanHR = try container.decode(Double.self, forKey: .meanHR)
        sdHR = try container.decode(Double.self, forKey: .sdHR)
        triangularIndex = try container.decodeIfPresent(Double.self, forKey: .triangularIndex)
        // Default min/max from SD if not present (backwards compatibility)
        minHR = try container.decodeIfPresent(Double.self, forKey: .minHR) ?? (meanHR - sdHR)
        maxHR = try container.decodeIfPresent(Double.self, forKey: .maxHR) ?? (meanHR + sdHR)
    }
}

/// Frequency-domain HRV metrics
struct FrequencyDomainMetrics: Codable {
    /// Very low frequency power (ms²) - nil if window < 10 min
    let vlf: Double?
    /// Low frequency power (ms²) - 0.04-0.15 Hz
    let lf: Double
    /// High frequency power (ms²) - 0.15-0.4 Hz
    let hf: Double
    /// LF/HF ratio - nil if HF is 0
    let lfHfRatio: Double?
    /// Total power (VLF + LF + HF)
    let totalPower: Double

    /// LF in normalized units (LF / (LF + HF) * 100)
    var lfNu: Double? {
        let sum = lf + hf
        guard sum > 0 else { return nil }
        return lf / sum * 100
    }

    /// HF in normalized units (HF / (LF + HF) * 100)
    var hfNu: Double? {
        let sum = lf + hf
        guard sum > 0 else { return nil }
        return hf / sum * 100
    }
}

/// Nonlinear HRV metrics (Poincaré plot, entropy, DFA)
struct NonlinearMetrics: Codable {
    /// Short-term variability (perpendicular to line of identity)
    let sd1: Double
    /// Long-term variability (along line of identity)
    let sd2: Double
    /// SD1/SD2 ratio
    let sd1Sd2Ratio: Double
    /// Sample entropy (complexity measure)
    let sampleEntropy: Double?
    /// Approximate entropy
    let approxEntropy: Double?
    /// DFA α1 (short-term fractal scaling, 4-16 beats)
    let dfaAlpha1: Double?
    /// DFA α2 (long-term fractal scaling, 16-64 beats)
    let dfaAlpha2: Double?
    /// R² fit quality for α1
    let dfaAlpha1R2: Double?
}

/// ANS Indexes (Autonomic Nervous System)
struct ANSMetrics: Codable {
    /// Baevsky's Stress Index (SI)
    let stressIndex: Double?
    /// Parasympathetic Nervous System Index (-3 to +3 typical)
    let pnsIndex: Double?
    /// Sympathetic Nervous System Index (-3 to +3 typical)
    let snsIndex: Double?
    /// Recovery/Readiness Score (1-10)
    let readinessScore: Double?
    /// Estimated respiration rate (breaths/min)
    let respirationRate: Double?
    /// Nocturnal HR dip percentage: (daytimeHR - sleepHR) / daytimeHR * 100
    /// Normal range: 10-20%. <10% = blunted (cardiovascular risk), >20% = exaggerated
    let nocturnalHRDip: Double?
    /// Daytime resting HR used for dip calculation (bpm)
    let daytimeRestingHR: Double?
    /// Nocturnal median HR used for dip calculation (bpm)
    let nocturnalMedianHR: Double?
}

/// Peak autonomic capacity metrics - highest sustained HRV values observed
/// These represent physiological capacity, NOT readiness for training
/// "Sustained" = ≥4 min contiguous, artifact-clean, not an isolated spike
struct PeakCapacity: Codable {
    /// Highest sustained RMSSD observed (ms)
    let peakRMSSD: Double
    /// SDNN at the peak RMSSD window (ms)
    let peakSDNN: Double
    /// Total spectral power at the peak window (ms²), if available
    let peakTotalPower: Double?
    /// Duration of the peak window in minutes
    let windowDurationMinutes: Double
    /// Relative position of peak window within sleep (0.0-1.0)
    let windowRelativePosition: Double?
    /// Mean HR during the peak window (bpm)
    let windowMeanHR: Double?
}

/// Training context snapshot - captured at time of HRV recording
/// Stores ATL/CTL/TSB so historical reports show training state from that day
struct TrainingContext: Codable {
    /// Acute Training Load (7-day EWMA of TRIMP) - "fatigue"
    let atl: Double
    /// Chronic Training Load (42-day EWMA of TRIMP) - "fitness"
    let ctl: Double
    /// Training Stress Balance (CTL - ATL) - "form/freshness"
    let tsb: Double
    /// Yesterday's TRIMP (training load day before this reading)
    let yesterdayTrimp: Double
    /// VO2max at time of recording (user override or HealthKit)
    let vo2Max: Double?
    /// Days since last hard workout
    let daysSinceHardWorkout: Int?
    /// Recent workout summary (last 3 days for context)
    let recentWorkouts: [WorkoutSnapshot]?

    /// Acute:Chronic Ratio (injury risk indicator)
    var acuteChronicRatio: Double? {
        guard ctl > 0 else { return nil }
        return atl / ctl
    }

    /// Form interpretation
    var formDescription: String {
        if tsb > 25 { return "Very Fresh" }
        if tsb > 10 { return "Fresh" }
        if tsb > -10 { return "Neutral" }
        if tsb > -25 { return "Tired" }
        return "Very Tired"
    }

    /// Risk level based on ACR
    var riskLevel: String {
        guard ctl > 0 else { return "Building Base" }
        guard let acr = acuteChronicRatio else { return "Unknown" }
        if acr > 1.5 { return "High Risk" }
        if acr > 1.3 { return "Caution" }
        if acr < 0.8 { return "Detraining" }
        return "Optimal"
    }

    static let empty = TrainingContext(
        atl: 0, ctl: 0, tsb: 0, yesterdayTrimp: 0,
        vo2Max: nil, daysSinceHardWorkout: nil, recentWorkouts: nil
    )
}

/// Lightweight workout snapshot for storing with session
struct WorkoutSnapshot: Codable {
    let date: Date
    let type: String
    let durationMinutes: Double
    let trimp: Double
}

/// Complete HRV analysis result for a window
struct HRVAnalysisResult: Codable {
    let windowStart: Int
    let windowEnd: Int
    let timeDomain: TimeDomainMetrics
    let frequencyDomain: FrequencyDomainMetrics?
    let nonlinear: NonlinearMetrics
    let ansMetrics: ANSMetrics?
    let artifactPercentage: Double
    let cleanBeatCount: Int
    let analysisDate: Date

    // Window selection info (for display)
    var windowStartMs: Int64?
    var windowEndMs: Int64?
    var windowMeanHR: Double?
    var windowHRStability: Double?
    var windowSelectionReason: String?
    /// Relative position of analysis window within sleep episode (0.0-1.0)
    var windowRelativePosition: Double?
    /// Whether the window represents consolidated recovery (sustained plateau AND stable HR)
    /// This distinguishes true readiness from mere high HRV capacity
    var isConsolidated: Bool?
    /// Whether the window shows organized parasympathetic control (DFA α1 ~0.75-1.0, low LF/HF)
    /// vs high variability without organization (capacity, not recovery)
    var isOrganizedRecovery: Bool?
    /// Classification label for the selected window (Organized Recovery vs High Variability)
    var windowClassification: String?
    /// Peak autonomic capacity - highest sustained HRV values observed during the night
    /// This represents physiological capacity, separate from readiness assessment
    var peakCapacity: PeakCapacity?
    /// Training context snapshot - ATL/CTL/TSB frozen at time of this reading
    var trainingContext: TrainingContext?
}
