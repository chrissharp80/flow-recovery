# Flow Recovery - Comprehensive Technical Documentation

## Overview

Flow Recovery (formerly FlowHRV) is an iOS morning readiness and recovery tracking application built with Swift and SwiftUI. It provides a comprehensive "one-stop shop" for understanding your daily recovery status by integrating:

- **HRV Analysis**: Connects to Polar H10 chest strap heart rate monitors via Bluetooth to collect RR interval data and perform comprehensive HRV analysis
- **Sleep Tracking**: Imports sleep data from Apple Health including sleep stages, efficiency, duration, and sleep latency
- **Recovery Vitals**: Monitors overnight vitals from Apple Watch including respiratory rate, blood oxygen (SpO2), wrist temperature, and resting heart rate
- **Training Load**: Integrates with Apple Health workouts for acute/chronic training load ratio and readiness-adjusted training guidance

The app answers the fundamental morning question: **"How am I today?"**

---

## Table of Contents

1. [Data Models](#data-models)
2. [Data Collection](#data-collection)
3. [HRV Analysis](#hrv-analysis)
4. [Window Selection Algorithm](#window-selection-algorithm)
5. [Storage & Persistence](#storage--persistence)
6. [HealthKit Integration](#healthkit-integration)
7. [Export & Import](#export--import)
8. [User Interface](#user-interface)
9. [Complete API Reference](#complete-api-reference)

---

## Data Models

### RRPoint
**File**: `RRModels.swift`

Single RR interval measurement:
```swift
struct RRPoint: Codable, Equatable {
    let t_ms: Int64       // Cumulative start time in milliseconds
    let rr_ms: UInt16     // Interval duration in milliseconds
    let wallClockMs: Int64?  // Optional wall-clock timestamp (streaming mode only, nil for H10 internal)

    var endMs: Int64      // t_ms + rr_ms
    var midpointMs: Int64 // For interpolation
    var clockDriftMs: Int64? // Wall-clock vs cumulative gap (detects data loss)
}
```

### RRSeries
**File**: `RRModels.swift`

Collection of RR intervals with gap detection:
```swift
struct RRSeries: Codable {
    let points: [RRPoint]
    let sessionId: UUID
    let startDate: Date

    // Computed properties
    var durationMs: Int64
    var durationMinutes: Double
    var hasWallClockTimestamps: Bool
    var wallClockDurationMs: Int64?
    var estimatedDataLossPercent: Double?

    // Methods
    func detectGaps(thresholdMs: Int64) -> [(startIndex: Int, endIndex: Int, gapDurationMs: Int64)]
    func absoluteTime(at index: Int) -> Date
    func absoluteTimeWallClock(at index: Int) -> Date?
    func indexClosestToWallClock(_ date: Date) -> Int  // Binary search
}
```

### ArtifactFlags
**File**: `RRModels.swift`

Artifact classification per RR interval:
```swift
struct ArtifactFlags: Codable, Equatable {
    let isArtifact: Bool
    let type: ArtifactType  // none, ectopic, missed, extra, technical
    let confidence: Double  // 0.0 to 1.0
    let corrected: Bool

    static let clean = ArtifactFlags(isArtifact: false, type: .none, confidence: 1.0, corrected: false)
}
```

### HRVSession
**File**: `HRVSession.swift`

Complete session with analysis:
```swift
struct HRVSession: Codable, Identifiable {
    let id: UUID
    let startDate: Date
    var endDate: Date?
    var state: SessionState  // collecting, analyzing, complete, failed
    var sessionType: SessionType  // overnight, nap, quick

    // Data
    var rrSeries: RRSeries?
    var artifactFlags: [ArtifactFlags]?
    var analysisResult: HRVAnalysisResult?
    var recoveryScore: Double?

    // Metadata
    var tags: [ReadingTag]
    var notes: String?
    var deviceProvenance: DeviceProvenance?
    var importedMetrics: ImportedMetrics?

    // HealthKit sleep boundaries (milliseconds relative to recording start)
    var sleepStartMs: Int64?
    var sleepEndMs: Int64?

    var isValidForAnalysis: Bool { (rrSeries?.points.count ?? 0) >= 120 }
}
```

### DeviceProvenance
**File**: `HRVSession.swift`

Tracks data source:
```swift
struct DeviceProvenance: Codable {
    let deviceId: String
    let deviceModel: String
    let firmwareVersion: String?
    let recordingMode: RecordingMode  // deviceInternal, streaming, imported
    let appVersion: String
    let osVersion: String
    let capturedAt: Date

    var samplingNotes: String  // Human-readable description

    static func current(deviceId:deviceModel:firmwareVersion:recordingMode:) -> DeviceProvenance
    static func imported() -> DeviceProvenance
}
```

### ReadingTag
**File**: `HRVSession.swift`

Session categorization:
```swift
struct ReadingTag: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let colorHex: String
    let isSystem: Bool

    // 14 system tags:
    static let morning, postExercise, recovery, evening, preSleep, stressed, relaxed,
               alcohol, poorSleep, travel, lateMeal, caffeine, illness, menstrual
}
```

### Analysis Result Types
**File**: `RRModels.swift`

```swift
struct TimeDomainMetrics: Codable {
    let meanRR: Double      // Mean RR interval (ms)
    let sdnn: Double        // Standard deviation of NN intervals
    let rmssd: Double       // Root mean square of successive differences
    let pnn50: Double       // Percentage of successive differences > 50ms
    let sdsd: Double        // Standard deviation of successive differences
    let meanHR: Double      // Mean heart rate (bpm)
    let sdHR: Double        // Standard deviation of HR
    let minHR: Double       // Minimum heart rate
    let maxHR: Double       // Maximum heart rate
    let triangularIndex: Double  // HRV triangular index
}

struct FrequencyDomainMetrics: Codable {
    let vlf: Double?        // Very Low Frequency power (nil if window < 10 min)
    let lf: Double          // Low Frequency power (0.04-0.15 Hz)
    let hf: Double          // High Frequency power (0.15-0.4 Hz)
    let lfHfRatio: Double   // LF/HF ratio
    let totalPower: Double  // Total spectral power

    var lfNu: Double { lf / (lf + hf) * 100 }  // Normalized LF
    var hfNu: Double { hf / (lf + hf) * 100 }  // Normalized HF
}

struct NonlinearMetrics: Codable {
    let sd1: Double              // Poincaré SD1 (short-term, perpendicular)
    let sd2: Double              // Poincaré SD2 (long-term, along identity)
    let sd1Sd2Ratio: Double      // SD1/SD2 ratio
    let sampleEntropy: Double?   // Sample entropy
    let approxEntropy: Double?   // Approximate entropy
    let dfaAlpha1: Double?       // DFA short-term scaling (4-16 beats)
    let dfaAlpha2: Double?       // DFA long-term scaling (16-64 beats)
    let dfaAlpha1R2: Double?     // R² fit quality for α1
}

struct ANSMetrics: Codable {
    let stressIndex: Double?       // Baevsky Stress Index
    let pnsIndex: Double?          // Parasympathetic index (-3 to +3)
    let snsIndex: Double?          // Sympathetic index (-3 to +3)
    let readinessScore: Double?    // Recovery readiness (1-10)
    let respirationRate: Double?   // Estimated breaths per minute
    let nocturnalHRDip: Double?    // % HR drop during sleep
    let daytimeRestingHR: Double?  // From HealthKit
    let nocturnalMedianHR: Double? // Median HR during analysis window
}

struct PeakCapacity: Codable {
    let peakRMSSD: Double
    let peakSDNN: Double
    let peakTotalPower: Double?
    let windowDurationMinutes: Double
    let windowRelativePosition: Double?  // 0.0-1.0 position within recording
    let windowMeanHR: Double?
}

struct HRVAnalysisResult: Codable {
    // Window bounds
    var windowStart: Int           // Start index
    var windowEnd: Int             // End index
    var windowStartMs: Int64?      // Start timestamp (ms)
    var windowEndMs: Int64?        // End timestamp (ms)
    var windowMeanHR: Double?
    var windowHRStability: Double? // CV of HR
    var windowSelectionReason: String?
    var windowRelativePosition: Double?  // Position within sleep (0.0-1.0)

    // Core metrics
    let timeDomain: TimeDomainMetrics
    let frequencyDomain: FrequencyDomainMetrics?
    let nonlinear: NonlinearMetrics
    let ansMetrics: ANSMetrics?

    // Quality
    let artifactPercentage: Double
    let cleanBeatCount: Int
    let analysisDate: Date

    // Classification
    var isConsolidated: Bool?         // Sustained + stable HR
    var isOrganizedRecovery: Bool?    // DFA α1 in optimal range
    var windowClassification: String? // "Organized Recovery", "Flexible / Unconsolidated", "High Variability"
    var peakCapacity: PeakCapacity?
}
```

---

## Data Collection

### Hybrid Recording Strategy

**File**: `RRCollector.swift`

FlowHRV uses a **hybrid approach** for overnight recordings:

1. **H10 Internal Recording** = **PRIMARY/PREFERRED** (more stable, survives disconnects)
2. **BLE Streaming** = **BACKUP** (provides real-time display, wall-clock timestamps)
3. **Composite Merging** = Fill gaps in internal recording with streaming data when needed

```swift
// From startOvernightStreaming()
func startOvernightStreaming(sessionType: SessionType = .overnight) throws {
    // Start background audio and location to keep app alive
    BackgroundAudioManager.shared.startBackgroundAudio()
    BackgroundLocationManager.shared.startBackgroundLocation()

    // HYBRID APPROACH: Start both internal recording (backup) and streaming (primary display)
    // Step 1: Start H10 internal recording first (async operation)
    Task {
        try await polarManager.startRecording()  // More stable, survives disconnect
    }

    // Step 2: Start streaming (real-time display, wall-clock timestamps)
    try polarManager.startStreaming()
}
```

### Data Source Selection

When stopping an overnight session:

```swift
// From stopOvernightStreaming()

// Strategy: Prefer internal, create composite if gaps detected, fallback to streaming
let hasValidStreaming = streamingPoints.count >= 120
let hasValidInternal = internalPoints?.count ?? 0 >= 120

if hasValidInternal {
    if hasValidStreaming {
        let beatDiff = abs(internalCount - streamingCount)
        let percentDiff = (Double(beatDiff) / Double(max(internalCount, streamingCount))) * 100.0

        // If internal has significantly fewer beats (>5% difference), create composite
        if internalCount < streamingCount && percentDiff > 5.0 {
            finalPoints = createCompositePoints(internalSeries, streamingSeries)
            dataSource = "composite (internal + streaming gap-fill)"
        } else {
            // Internal is good enough - USE INTERNAL (preferred)
            finalPoints = internalData
            dataSource = "internal"
        }
    } else {
        // Only internal succeeded
        finalPoints = internalData
        dataSource = "internal"
    }
} else if hasValidStreaming {
    // Internal failed, use streaming as fallback
    finalPoints = streamingPoints
    dataSource = "streaming (internal failed)"
}
```

### Composite Merging Algorithm

```swift
// From createCompositePoints()
// Find gaps in internal recording (>2 second jumps) and fill with streaming data

for i in 1..<internalPoints.count {
    let prevPoint = internalPoints[i-1]
    let currPoint = internalPoints[i]
    let expectedGap = Int64(prevPoint.rr_ms)
    let actualGap = currPoint.t_ms - prevPoint.endMs

    // If there's a significant gap (>2 seconds), fill with streaming
    if actualGap > expectedGap + 2000 {
        let gapStart = prevPoint.endMs
        let gapEnd = currPoint.t_ms

        // Find streaming points that fall in this gap
        let gapPoints = streamingPoints.filter { point in
            point.t_ms >= gapStart && point.t_ms <= gapEnd
        }
        // Insert streaming points to fill gap
    }
}

// Build composite by interleaving points chronologically
// Choose earlier timestamp from either source at each step
```

### Recording Modes

#### 1. Overnight Hybrid Mode (Streaming + H10 Internal)
**File**: `RRCollector.swift`

```swift
func startOvernightStreaming(sessionType: SessionType = .overnight) throws
func stopOvernightStreaming() async -> HRVSession?
```

**Hybrid Architecture**: Simultaneous streaming and H10 internal recording for maximum reliability.

**Streaming Path**:
- Real-time BLE streaming to app
- Incremental backup every 5 minutes (time-based)
- Force backup on reconnection events
- Background audio + location keeps app alive
- Keep-alive ping every 30 seconds

**H10 Internal Path**:
- Parallel recording to H10 internal memory
- Survives complete app crashes
- Fetched at end of recording
- Independent failure domain

**Data Merge Logic** (Internal Preferred):
```swift
// At end of overnight recording:
let streamingPoints: [RRPoint]  // From streaming (may have gaps if disconnected)
let internalPoints: [RRPoint]?  // From H10 fetch (complete, but may fail to fetch)

let hasValidStreaming = streamingPoints.count >= 120
let hasValidInternal = internalPoints?.count ?? 0 >= 120

// Decision logic (independent failure domains):
if hasValidInternal && hasValidStreaming {
    // Both succeeded - compare beat counts
    let beatDiff = abs(internalCount - streamingCount)
    let percentDiff = (beatDiff / max(internalCount, streamingCount)) * 100.0

    if internalCount < streamingCount && percentDiff > 5.0 {
        // Internal has gaps (>5% fewer beats) - create composite
        // Fill internal gaps with streaming data
        return createComposite(internal: internalPoints, streaming: streamingPoints)
    } else {
        // Difference is small (<5%) - use internal (PREFERRED)
        return internalPoints
    }
} else if hasValidInternal {
    // Only internal succeeded - use internal
    return internalPoints
} else if hasValidStreaming {
    // Only streaming succeeded - use streaming
    return streamingPoints
} else {
    // Both failed - check RawRRBackup as last resort
    if let backupData = rawBackup.recover(sessionId) {
        return backupData
    } else {
        return nil  // Total failure
    }
}
```

**Preference Order**:
1. **Internal recording** (preferred) - most reliable, no Bluetooth gaps
2. **Composite** (internal + streaming gap-fill) - if internal has >5% fewer beats
3. **Streaming only** - if internal fetch failed
4. **RawRRBackup** - if both internal and streaming failed

**Why Internal is Preferred**:
- H10 records continuously to internal memory, no Bluetooth disconnections
- More reliable for overnight recordings
- Streaming used primarily as backup and gap-fill source

**Failure Independence**:
- H10 fetch failure doesn't cascade to streaming
- Streaming failure doesn't prevent H10 fetch
- Backup continues regardless of both
- Each path can succeed or fail independently

### Composite Creation Algorithm

**File**: `RRCollector.swift` - `createCompositePoints()`

When internal recording has >5% fewer beats than streaming (indicating gaps), the composite algorithm fills internal gaps with streaming data:

```swift
private func createCompositePoints(
    internalSeries: RRSeries,
    streamingSeries: RRSeries
) -> [RRPoint]?
```

**Algorithm**:

1. **Detect Gaps in Internal Recording**:
   ```swift
   for i in 1..<internalPoints.count {
       let prevPoint = internalPoints[i-1]
       let currPoint = internalPoints[i]

       let expectedGap = Int64(prevPoint.rr_ms)  // Just the RR interval
       let actualGap = currPoint.t_ms - prevPoint.endMs

       // Gap detected: >2 seconds beyond expected RR interval
       if actualGap > expectedGap + 2000 {
           // Find gap boundaries
           let gapStart = prevPoint.endMs
           let gapEnd = currPoint.t_ms
       }
   }
   ```

2. **Fill Gaps with Streaming Data**:
   ```swift
   // Find streaming points that fall within the gap time range
   let gapPoints = streamingPoints.filter { point in
       point.t_ms >= gapStart && point.endMs <= gapEnd
   }

   // Validate gap-fill data (require >2 beats, reasonable duration)
   guard gapPoints.count >= 2 else { continue }

   // Insert gap-fill points into composite
   composite.append(contentsOf: gapPoints)
   ```

3. **Merge and Sort**:
   - Combine internal points (base) + streaming gap-fill points
   - Sort by cumulative time (t_ms)
   - Return merged array

**Gap Detection Threshold**:
- Actual time jump > expected RR interval + 2 seconds
- Example: If RR=800ms, gap detected if jump >2800ms
- Filters normal beat-to-beat variation, only catches true data loss

**Why 2-Second Threshold**:
- Normal RR intervals: 600-1200ms (50-100 bpm)
- Worst case sinus arrhythmia: ~±200ms variation
- 2-second buffer ensures we only detect actual recording gaps, not normal variation

**Composite Quality**:
- Preserves internal recording as ground truth
- Only adds streaming data where internal has proven gaps
- Maintains temporal ordering and RR interval accuracy

Session types: `.overnight`, `.nap`

#### 2. Quick Streaming Mode
```swift
func startStreamingSession(durationSeconds: Int = 180) throws
func stopStreamingSession() async -> HRVSession?
```

- Streaming only (2, 3, or 5 minutes)
- Real-time HRV preview during collection
- Full series analysis (no window selection)
- Auto-archive on completion

#### 3. Device-Only Recording
```swift
func startSession(sessionType: SessionType = .overnight) async throws
func stopSession() async throws -> HRVSession?
```

- H10 internal memory only
- Survives complete app termination
- Multi-attempt fetch with retry

### PolarManager
**File**: `PolarManager.swift`

```swift
class PolarManager: ObservableObject {
    // Connection
    @Published var connectionState: ConnectionState  // disconnected, scanning, connecting, connected
    @Published var connectedDeviceId: String?
    @Published var batteryLevel: Int?

    // Recording
    @Published var recordingState: RecordingState  // idle, starting, recording, stopping, fetching
    @Published var isRecordingOnDevice: Bool
    @Published var isStreaming: Bool
    @Published var streamedRRPoints: [RRPoint]
    @Published var streamingElapsedSeconds: Int

    // Streaming reconnection
    @Published var isReconnectingStream: Bool
    @Published var streamingReconnectCount: Int  // Total successful reconnects

    // Fetch progress
    @Published var fetchProgress: FetchProgress?  // stages: stopping, finalizing, listingExercises, fetchingData, reconnecting, retrying
    @Published var hasStoredExercise: Bool  // H10 has unrecovered data

    // Methods
    func startScanning()
    func connect(deviceId: String)
    func startRecording() async throws
    func stopAndFetchRecording() async throws -> [RRPoint]
    func startStreaming() throws
    func stopStreaming() -> [RRPoint]
    func sendKeepAlivePing()
    func recoverExerciseData() async throws -> RecoveredExercise
}
```

#### Streaming Reconnection Logic
When H10 disconnects during streaming:
1. `deviceDisconnected()` callback fires → **preserves `connectedDeviceId`** if streaming (critical fix)
2. Streaming `onError` triggers `attemptStreamingReconnect()`
3. Waits 2 seconds (exponential backoff after 10 attempts)
4. Reconnects to same device using preserved `connectedDeviceId`
5. Resumes streaming, preserving all previously collected points

**Bug fixed (Jan 2026)**: Previously cleared `connectedDeviceId = nil` immediately on disconnection, causing reconnection to fail with "Cannot reconnect - no API or device ID". Now preserves device ID during streaming, enabling automatic reconnection within 2 seconds instead of waiting 20-30 minutes for iOS auto-reconnect.

### Background Execution
**Files**: `BackgroundAudioManager.swift`, `BackgroundLocationManager.swift`

- Silent audio playback keeps app alive during overnight streaming
- Location manager provides additional background runtime
- Handles audio interruptions gracefully

---

## HRV Analysis

### Artifact Detection
**File**: `ArtifactDetection.swift`

```swift
class ArtifactDetector {
    struct Config {
        var windowSize: Int = 50           // Rolling median window (centered)
        var ectopicThreshold: Double = 0.20  // 20% deviation from median
        var missedThreshold: Double = 0.50   // 50% longer than expected
        var extraThreshold: Double = 0.30    // 30% shorter than expected
        var minRR: Int = 300                 // Minimum valid RR (ms)
        var maxRR: Int = 2000                // Maximum valid RR (ms)
    }

    func detectArtifacts(in series: RRSeries) -> [ArtifactFlags]
    func artifactPercentage(_ flags: [ArtifactFlags], start: Int, end: Int) -> Double
}
```

**Detection Algorithm**:
1. **Compute Rolling Median**: O(n log w) using centered 50-beat window
2. **Classify Each Beat**:
   - **Technical artifacts**: RR < 300ms or > 2000ms → confidence 1.0
   - **Extra beat**: RR < median × 0.5 (very short) → type=extra
   - **Ectopic**: RR < median × (1 - 0.30) → type=ectopic if ratio > 0.20
   - **Missed beat**: RR > median × (1 + 0.50) → type=missed
   - **Clean**: All others

**Confidence Calculation**:
```swift
let ratio = abs(rr - median) / median
let confidence = min(1.0, ratio / threshold)
```

**Artifact Correction Methods** (ArtifactCorrector):

```swift
enum ArtifactCorrectionMethod: String {
    case none                  // Keep artifacts (excluded from analysis)
    case deletion              // Remove artifact intervals entirely
    case linearInterpolation   // Replace with linear interpolation
    case cubicSpline           // Replace with cubic spline (smoother)
    case median                // Replace with local median (11-beat window)
}

static func correct(
    rrValues: [Int],
    flags: [ArtifactFlags],
    method: ArtifactCorrectionMethod
) -> (corrected: [Int], flags: [ArtifactFlags])
```

**Linear Interpolation**:
- Find clean beats before and after artifact segment
- Linearly interpolate RR values across the gap
- Mark corrected beats with `corrected: true` flag

**Cubic Spline Interpolation**:
- Requires ≥4 clean points for natural cubic spline
- Computes tridiagonal system for second derivatives (Thomas algorithm)
- Evaluates spline at artifact positions
- Clamps corrected values to 300-2000ms range
- Falls back to linear if insufficient clean points

**Median Replacement**:
- For each artifact, collects clean beats in 11-beat window
- Replaces artifact with median of clean values
- Robust for isolated artifacts, preserves local behavior

### Time Domain Analysis
**File**: `TimeDomainAnalysis.swift`

```swift
static func compute(_ series: RRSeries, flags: [ArtifactFlags], windowStart: Int, windowEnd: Int) -> TimeDomainMetrics?
```

**Metrics** (requires ≥10 clean RR intervals):
- **meanRR**: Mean RR interval
- **SDNN**: Standard deviation of NN intervals
- **RMSSD**: Root mean square of successive differences
- **pNN50**: Percentage of successive differences > 50ms
- **SDSD**: Standard deviation of successive differences
- **meanHR, sdHR, minHR, maxHR**: Heart rate statistics
- **Triangular Index**: N / max(histogram bin count), 7.8125ms bins

### Frequency Domain Analysis
**File**: `FrequencyDomainAnalysis.swift`

**Configuration**:
- Resampling: 4 Hz (uniform grid for FFT, Nyquist = 2Hz > HF max 0.4Hz)
- Welch method: 256-sample segments (64s @ 4Hz = 0.016Hz resolution), 50% overlap
- Hann window (-31dB side lobe attenuation)

**Band Boundaries**:
- **VLF**: 0.003-0.04 Hz (requires ≥10 min window, nil otherwise)
- **LF**: 0.04-0.15 Hz (mixed sympathetic/parasympathetic)
- **HF**: 0.15-0.4 Hz (parasympathetic, respiratory)

**Algorithm**:
1. Extract clean data only (non-artifact points, mid-point timing)
2. Linear resampling to uniform 4Hz grid
3. Welch PSD: overlapping Hann-windowed segments, averaged periodograms
4. Integrate PSD over frequency bands

### Nonlinear Analysis
**File**: `NonlinearAnalysis.swift`

```swift
static func computeNonlinear(
    _ series: RRSeries,
    flags: [ArtifactFlags],
    windowStart: Int,
    windowEnd: Int
) -> NonlinearMetrics?
```

**Poincaré Plot Analysis**:

Plots each RR interval against the next (RR_n vs RR_n+1):

```swift
// SD1: Short-term variability (perpendicular to identity line)
// SD1 = SDSD / √2
let meanDiff = Σ(RR[i+1] - RR[i]) / n
let varDiff = Σ((RR[i+1] - RR[i])²) / n - meanDiff²
let sd1 = sqrt(varDiff / 2.0)

// SD2: Long-term variability (along identity line)
// SD2² = 2×SDNN² - SD1²
let sd2 = sqrt(2 * sdnn² - sd1²)

// SD1/SD2 Ratio: Balance between short and long-term variability
let ratio = sd1 / sd2
```

**Interpretation**:
- **SD1**: Reflects rapid changes (parasympathetic activity, beat-to-beat)
- **SD2**: Reflects slow trends (sympathetic + parasympathetic)
- **SD1/SD2 ratio**: <1 = sympathetic dominance, >1 = parasympathetic dominance

**Entropy Measures**:

```swift
// Sample Entropy (m=2, r=0.2×SD)
// Measures pattern regularity - lower = more regular
let sampleEntropy = -ln(countM1 / countM)

// Approximate Entropy (m=2, r=0.2×SD)
// Similar to sample entropy but includes self-matches
let approxEntropy = PhiM - PhiM+1
```

### DFA Analysis
**File**: `DFAAnalysis.swift`

**Detrended Fluctuation Analysis** - Quantifies fractal-like correlation in RR time series:

```swift
struct DFAResult {
    let alpha1: Double      // Short-term scaling (4-16 beats)
    let alpha2: Double?     // Long-term scaling (16-64 beats, requires ≥256 beats)
    let alpha1R2: Double    // R² fit quality for alpha1
    let alpha2R2: Double?   // R² fit quality for alpha2
}

static func compute(_ cleanRRs: [Double]) -> DFAResult?  // Requires ≥64 beats
```

**Algorithm** (Full Detail):

1. **Integrate RR Series**:
   ```swift
   let mean = RRs.reduce(0, +) / Double(RRs.count)
   var integrated = [Double]()
   var cumSum: Double = 0
   for rr in RRs {
       cumSum += (rr - mean)
       integrated.append(cumSum)
   }
   ```

2. **Partition into Boxes** (for each box size n = 4, 5, 6, ..., 64):
   ```swift
   let boxSizes = [4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 16, 20, 24, 28, 32, 40, 48, 56, 64]
   ```

3. **Detrend Each Box**:
   ```swift
   for boxSize in boxSizes {
       let numBoxes = integrated.count / boxSize

       for box in 0..<numBoxes {
           // Extract box segment
           let segment = integrated[box*boxSize..<(box+1)*boxSize]

           // Fit linear trend using least squares
           let trend = linearFit(segment)

           // Calculate RMS fluctuation (residuals from trend)
           let residuals = segment - trend
           let rms = sqrt(Σ(residuals²) / boxSize)
           fluctuations[boxSize].append(rms)
       }

       // Average fluctuation for this box size
       F[boxSize] = mean(fluctuations[boxSize])
   }
   ```

4. **Log-Log Regression**:
   ```swift
   // Plot log(F) vs log(n) → slope = α
   let logN = boxSizes.map { log($0) }
   let logF = boxSizes.map { log(F[$0]) }

   // Alpha1: short-term (box sizes 4-16)
   let alpha1 = slope(logN[0...5], logF[0...5])
   let alpha1R2 = rSquared(logN[0...5], logF[0...5], alpha1)

   // Alpha2: long-term (box sizes 16-64), requires ≥256 beats
   if cleanRRs.count >= 256 {
       let alpha2 = slope(logN[5...], logF[5...])
       let alpha2R2 = rSquared(logN[5...], logF[5...], alpha2)
   }
   ```

**Interpretation**:
- **α1 ≈ 0.75-1.0**: **Organized recovery** - optimal fractal correlation, consolidated parasympathetic control
- **α1 ≈ 0.6-0.75**: **Flexible/unconsolidated** - good capacity but not load-bearing readiness
- **α1 ≈ 0.5**: **White noise** - random, uncorrelated (Brownian motion boundary)
- **α1 > 1.0**: **High variability** - constrained or overly organized (may indicate stress)
- **α1 < 0.6**: **Anti-correlated** - unusual, may indicate pathology

**Window Selection Usage**:
- **Consolidated Recovery method** requires α1 ∈ [0.75, 1.0]
- **Flexible Unconsolidated** allows α1 ∈ [0.60, 0.75]
- α1 filters out windows with disorganized variability (capacity vs. readiness)

### Stress Analysis
**File**: `StressAnalysis.swift`

**Baevsky Stress Index**:
```
SI = AMo / (2 × Mo × MxDMn)
```
- AMo: Amplitude of mode (% intervals in modal 50ms histogram bin)
- Mo: Mode (most frequent RR interval)
- MxDMn: Max-Min RR span

**PNS Index** (-3 to +3):
```swift
// Z-scores averaged equally:
meanRR_z = (meanRR - 926) / stdRef
rmssd_z = (rmssd - 42) / stdRef
sd1_z = (sd1 - 29) / stdRef
pnsIndex = (meanRR_z + rmssd_z + sd1_z) / 3
```

**SNS Index** (-3 to +3):
```swift
// Z-scores (SD2 inverted):
meanHR_z = (meanHR - 66) / stdRef
stressIndex_z = (stressIndex - 10) / stdRef
sd2_z = (65 - sd2) / stdRef  // Inverted: lower SD2 = more sympathetic
snsIndex = (meanHR_z + stressIndex_z + sd2_z) / 3
```

**Readiness Score** (1-10):

```swift
static func computeReadinessScore(
    rmssd: Double,
    baselineRMSSD: Double?,
    alpha1: Double?
) -> Double {
    var score = 5.0  // Neutral baseline

    // RMSSD Component (relative to personal baseline)
    if let baseline = baselineRMSSD, baseline > 0 {
        let rmssdRatio = rmssd / baseline

        if rmssdRatio >= 0.85 && rmssdRatio <= 1.15 {
            // Within 15% of baseline - optimal
            score += 2.0
        } else if rmssdRatio >= 0.70 && rmssdRatio <= 1.30 {
            // Within 30% of baseline - good
            score += 1.0
        } else if rmssdRatio < 0.60 || rmssdRatio > 1.50 {
            // >40% deviation - concerning
            score -= 2.0
        }
        // Else: 15-30% deviation, no change (neutral)
    } else {
        // No baseline - use absolute RMSSD thresholds
        if rmssd > 50 { score += 1.5 }
        else if rmssd > 30 { score += 0.5 }
        else if rmssd < 20 { score -= 1.5 }
    }

    // DFA α1 Component (fractal organization)
    if let a1 = alpha1 {
        if a1 >= 0.75 && a1 <= 1.0 {
            // Organized recovery - optimal
            score += 2.0
        } else if a1 >= 0.5 && a1 <= 1.25 {
            // Moderate organization - good
            score += 0.5
        } else {
            // Disorganized or overly constrained
            score -= 1.0
        }
    }

    // Clamp to 1-10 range
    return max(1.0, min(10.0, score))
}
```

**Interpretation**:
- **1-3**: Significantly compromised recovery
- **4-6**: Below baseline or uncertain recovery
- **7-8**: Good recovery, within normal range
- **9-10**: Excellent recovery, above baseline

### Respiration Analysis
**File**: `RespirationAnalysis.swift`

**Methods**:
1. **Spectral**: Resample RR to 4Hz, FFT, find peak in HF band (0.15-0.4Hz), convert to breaths/min
2. **Zero-crossing**: Bandpass filter RR (0.1-0.5Hz), count zero crossings

**Sanity Check**: 6-40 breaths/min (normal range 8-30)

### Baseline Tracking
**File**: `BaselineTracker.swift`

**Purpose**: Track personal HRV baseline over rolling 7-day window to detect deviations and trends.

```swift
class BaselineTracker {
    struct Baseline: Codable {
        let date: Date
        let rmssd: Double
        let sdnn: Double
        let meanHR: Double
        let hf: Double?
        let lf: Double?
        let lfHfRatio: Double?
        let dfaAlpha1: Double?
        let stressIndex: Double?
        let readinessScore: Double?
        let sampleCount: Int

        static let minimumSamples = 3  // Require 3+ readings for valid baseline
    }

    struct BaselineDeviation: Codable {
        let rmssdDeviation: Double?       // Percentage deviation
        let sdnnDeviation: Double?
        let meanHRDeviation: Double?
        // ... other metrics

        var rmssdInterpretation: DeviationInterpretation
        var overallStatus: OverallStatus
    }
}
```

**Configuration**:
- **Rolling Window**: 7 days (last week of data)
- **Minimum Samples**: 3 readings required for valid baseline
- **Maximum History**: 90 data points stored (limits storage growth)
- **Storage**: App Group container or Documents directory
- **Persistence**: JSON file with automatic save/load

**Daily Reading Selection** (Morning Replacement Logic):

When multiple sessions recorded on same day, only ONE contributes to baseline:

```swift
// Morning reading (before 10am) is preferred
let hour = calendar.component(.hour, from: dataPoint.date)
let isMorningReading = hour < 10

if existingDataForToday {
    let shouldReplace: Bool

    if newIsMorning && existingIsMorning {
        // Both morning - keep higher readiness score
        shouldReplace = newReadiness > existingReadiness
    } else if newIsMorning && !existingIsMorning {
        // New is morning - always replace non-morning with morning
        shouldReplace = true
    } else if !newIsMorning && existingIsMorning {
        // Existing is morning - keep morning reading
        shouldReplace = false
    } else {
        // Both non-morning - keep higher readiness score
        shouldReplace = newReadiness > existingReadiness
    }
}
```

**Why Morning Priority**:
- Morning overnight recordings more consistent (standardized conditions)
- Afternoon/evening naps have different physiological state
- Morning HRV better reflects overnight recovery

**Baseline Calculation**:

```swift
func recalculateBaseline() {
    // Filter to last 7 days
    let cutoffDate = Date().addingTimeInterval(-7 * 24 * 3600)
    let recentData = historicalData.filter { $0.date >= cutoffDate }

    guard recentData.count >= Baseline.minimumSamples else {
        currentBaseline = nil
        return
    }

    // Calculate mean of all metrics
    let baseline = Baseline(
        date: Date(),
        rmssd: mean(recentData.map { $0.rmssd }),
        sdnn: mean(recentData.map { $0.sdnn }),
        meanHR: mean(recentData.map { $0.meanHR }),
        hf: mean(recentData.compactMap { $0.hf }),
        lf: mean(recentData.compactMap { $0.lf }),
        // ... other metrics
        sampleCount: recentData.count
    )

    currentBaseline = baseline
}
```

**Deviation Calculation**:

```swift
func deviation(for session: HRVSession) -> BaselineDeviation? {
    guard let baseline = currentBaseline,
          baseline.sampleCount >= Baseline.minimumSamples else {
        return nil
    }

    return BaselineDeviation(
        rmssdDeviation: percentDeviation(
            current: session.rmssd,
            baseline: baseline.rmssd
        ),
        // ... other metrics
    )
}

private func percentDeviation(current: Double, baseline: Double) -> Double? {
    guard baseline > 0 else { return nil }
    return ((current - baseline) / baseline) * 100.0
}
```

**Deviation Interpretation**:

```swift
enum DeviationInterpretation {
    case significantlyBelow  // < -20%
    case belowBaseline       // -20% to -10%
    case withinNormal        // -10% to +10%
    case aboveBaseline       // +10% to +20%
    case significantlyAbove  // > +20%
}

enum OverallStatus {
    case belowBaseline      // "Recovery may be compromised"
    case normal             // "Within your normal range"
    case aboveBaseline      // "Elevated recovery capacity"
    case noBaseline         // "Building baseline..."
}
```

**Integration with Readiness Score**:
- Baseline RMSSD feeds into readiness score calculation
- Deviation from baseline adjusts score (±15% optimal, >40% penalized)
- Syncs to UserSettings for display in Settings view

**Use Cases**:
1. **Morning Results View**: Show today's deviation from baseline
2. **Trend Analysis**: Track week-over-week changes
3. **AI Explanations**: "Your RMSSD is 15% below your 7-day baseline..."
4. **Training Load**: Detect when to push vs. recover

---

## Window Selection Algorithm

**File**: `WindowSelection.swift`

### Multiple Selection Methods

Users can choose from 5 window selection methods:

```swift
enum WindowSelectionMethod: String, Codable, CaseIterable {
    case consolidatedRecovery  // Default: Research-backed organized recovery
    case peakRMSSD            // Highest RMSSD in 30-70% band
    case peakSDNN             // Highest SDNN in 30-70% band
    case peakTotalPower       // Highest spectral power in 30-70% band
    case custom               // Manual window positioning (UI not implemented)
}

func selectWindowByMethod(
    _ method: WindowSelectionMethod,
    in series: RRSeries,
    flags: [ArtifactFlags],
    sleepStartMs: Int64? = nil,
    wakeTimeMs: Int64? = nil
) -> RecoveryWindow?
```

**Consolidated Recovery** (default): Highest RMSSD among organized windows (DFA α1 ~0.75-1.0, stable HR)
**Peak RMSSD**: Highest RMSSD value, no organization filtering
**Peak SDNN**: Highest total variability (parasympathetic + sympathetic)
**Peak Total Power**: Highest frequency domain power (currently uses SDNN proxy)
**Custom**: User-positioned window (returns nil, manual UI required)

All methods except Custom search within 30-70% sleep band and filter isolated spikes.

### Core Principle: 30-70% of ACTUAL Sleep

The window selection operates on the **30% to 70% band of actual sleep duration**, NOT the recording duration. Sleep boundaries come from HealthKit when available.

```swift
// Calculate 30-70% band relative to ACTUAL sleep (not recording)
let actualSleepStartMs: Int64  // From HealthKit or 0
let actualSleepEndMs: Int64    // From HealthKit or recording end
let actualSleepDurationMs = actualSleepEndMs - actualSleepStartMs

let limitEarlyMs = actualSleepStartMs + Int64(Double(actualSleepDurationMs) * 0.30)
let limitLateMs = actualSleepStartMs + Int64(Double(actualSleepDurationMs) * 0.70)
```

### Window Classification

```swift
enum WindowClassification: String, Codable {
    case organizedRecovery = "Organized Recovery"
    case flexibleUnconsolidated = "Flexible / Unconsolidated"
    case highVariability = "High Variability"
    case insufficient = "Insufficient Data"
}
```

**Classification Criteria**:
- **Organized Recovery**: DFA α1 ∈ [0.75, 1.0], LF/HF < 1.5, HR CV < 8%
- **Flexible Unconsolidated**: DFA α1 ∈ [0.60, 0.75] (valid capacity, not load-bearing)
- **High Variability**: DFA α1 < 0.6 or > 1.0 (random or constrained)

### Algorithm Steps

```swift
struct Config {
    var beatsPerWindow: Int = 400          // ~6-7 min at 60bpm
    var slideStepBeats: Int = 40           // Sliding window step
    var maxArtifactRate: Double = 0.15     // Maximum 15% artifacts
    var minCleanBeats: Int = 300           // Minimum 300 clean beats per window
    var minRelativePosition: Double = 0.30 // Start of search band
    var maxRelativePosition: Double = 0.70 // End of search band
    var stabilityWeight: Double = 10.0     // HR stability penalty factor
}
```

**Step 1**: Build all windows within 30-70% band using **adaptive window sizing**

### Adaptive Window Sizing

Window size adapts based on available beats in the 30-70% sleep band:

```swift
let targetWindowBeats = 400  // Target: ~6-7 min at 60bpm
let minWindowBeats = 200     // Minimum for valid analysis

let beatsInBand = // Count of beats in 30-70% sleep band

let adaptiveWindowSize: Int
if beatsInBand >= targetWindowBeats {
    // Sufficient data - use full 400-beat windows
    adaptiveWindowSize = targetWindowBeats
} else if beatsInBand >= minWindowBeats * 2 {
    // Limited data - use 50% of available beats
    adaptiveWindowSize = beatsInBand / 2
} else {
    // Very limited data - use 60% of available beats (minimum 60 beats)
    adaptiveWindowSize = max(60, (beatsInBand * 3) / 5)
}
```

**Why Adaptive**:
- **Short recordings** (e.g., 30-min nap): 30-70% band may only have 200 beats → 100-beat windows
- **Full overnight** (8 hours): Band has 3000+ beats → full 400-beat windows
- **Ensures analysis works** for recordings of any length while maximizing window size when possible

**Step 2**: Filter isolated spikes only (temporal discontinuity)
- Spike threshold: window must be >50% higher than BOTH neighbors to be rejected
- NO baseline-relative rejection, NO magnitude caps

**Step 3**: Classify each window
- Compute DFA α1 (requires ≥64 beats)
- Check LF/HF ratio (if available)
- Check HR stability (CV)

**Step 4**: Select best window
- **Only from Organized windows** (α1 in 0.75-1.0)
- Select highest RMSSD among organized windows
- If no organized windows exist, return nil (peak capacity captured separately)

### Consolidation Score

```swift
// RMSSD weighted by HR stability
// Higher RMSSD is good, unstable windows are penalized
func recoveryScore(stabilityWeight: Double) -> Double {
    let stabilityFactor = 1.0 / (1.0 + stabilityWeight * hrCV)
    return rmssd * stabilityFactor
}
```

A window is **consolidated** if:
1. It passed the spike filter (sustained, not isolated)
2. HR CV < 8% (stable)
3. DFA α1 in optimal range (organized)

### Peak Capacity

Computed independently from recovery window:
- Highest sustained RMSSD regardless of organization
- Represents physiological ceiling (capacity)
- May exist even when no consolidated recovery window exists

```swift
struct WindowSelectionResult {
    let recoveryWindow: RecoveryWindow?  // Nil if no organized recovery
    let peakCapacity: PeakCapacity?      // Highest sustained HRV

    var hasConsolidatedRecovery: Bool { recoveryWindow != nil }
}
```

---

## Storage & Persistence

### Session Archive
**File**: `Archive.swift`

```swift
class SessionArchive {
    // Storage: App Group "group.com.chrissharp.flowrecovery"

    func archive(_ session: HRVSession) throws
    func retrieve(_ id: UUID) throws -> HRVSession?
    func delete(_ id: UUID) throws

    // Index for quick lookups
    var entries: [SessionArchiveEntry]

    // Integrity checking with SHA256 hash
    // Throws: fileNotFound, hashMismatch (corruption detected)
}

struct SessionArchiveEntry: Codable {
    let sessionId: UUID
    let date: Date
    let fileHash: String
    let filePath: String
    let recoveryScore: Double?
    let meanRMSSD: Double?
    let tags: [ReadingTag]
    let notes: String?
    let sessionType: SessionType
}
```

### Raw RR Backup
**File**: `RawRRBackup.swift`

**Purpose**: Continuous backup during overnight streaming to prevent data loss from app crashes or Bluetooth disconnections.

**Backup Strategy**:
- **Initial backup**: First 60 beats immediately upon starting recording
- **Time-based incremental backup**: Every 5 minutes during streaming (not count-based)
- **Force backup on reconnection**: Immediate backup when streaming reconnects after disconnection
- **Survives app crashes**: Stored in App Group container
- **Independent from H10 fetch**: Backup continues even if H10 internal recording fails

```swift
struct BackupIndex: Codable {
    let id: UUID
    let captureDate: Date
    let fileName: String
    let beatCount: Int
    let hash: String
    var archived: Bool
    var lastBackupTime: Date?  // For time-based incremental backups
}

func incrementalBackup(
    points: [RRPoint],
    sessionId: UUID,
    deviceId: String? = nil,
    force: Bool = false  // Force immediate backup (reconnection events)
) -> Bool
```

**Time-Based Logic** (Jan 2026 fix):
- **Old**: Count-based (`points.count >= previousCount + 300`) - failed on reconnection when buffer reset
- **New**: Time-based (backup every 5 minutes) - works even when buffer resets
- **Force parameter**: Triggers immediate backup on reconnection, ensuring no data loss

**Integration with RRCollector**:
```swift
// RRCollector tracks reconnection count and forces backup
private var lastSeenReconnectCount: Int = 0

// In overnight timer (every 1 second):
let currentReconnectCount = polarManager.streamingReconnectCount
if currentReconnectCount > lastSeenReconnectCount {
    // Reconnection detected - force immediate backup
    rawBackup.incrementalBackup(points: collectedPoints, sessionId: session.id, force: true)
    lastSeenReconnectCount = currentReconnectCount
}
```

### Persisted Recording State
**File**: `RRCollector.swift`

```swift
// Survives app crashes (stored in UserDefaults)
private static let activeRecordingStartTimeKey = "RRCollector.activeRecordingStartTime"
private static let activeRecordingSessionIdKey = "RRCollector.activeRecordingSessionId"
private static let activeRecordingTypeKey = "RRCollector.activeRecordingSessionType"

func getPersistedRecordingState() -> (sessionId: UUID, startTime: Date, sessionType: SessionType)?
var hasPersistedRecordingState: Bool
```

### Baseline Tracker
**File**: `BaselineTracker.swift`

```swift
class BaselineTracker {
    // Rolling 7-day window, max 90 historical points

    struct Baseline: Codable {
        let rmssd, sdnn, meanHR, hf, lf, lfHfRatio, dfaAlpha1, stressIndex, readinessScore: Double?
        let sampleCount: Int  // Requires ≥3 for validity
    }

    struct BaselineDeviation {
        let rmssdDeviation: Double  // Percentage
        let rmssdInterpretation: Interpretation
        // significantly_below (<-20%), below (<-10%), within_normal (<10%), above (>10%), significantly_above (>20%)
    }

    func update(with session: HRVSession)
    func deviation(for session: HRVSession) -> BaselineDeviation?
}
```

---

## HealthKit Integration

**File**: `HealthKitManager.swift`

### Sleep Data

```swift
struct SleepData {
    let date: Date
    let inBedStart: Date?        // When user got into bed (for latency calculation)
    let sleepStart: Date?        // When sleep actually started
    let sleepEnd: Date?          // When sleep ended
    let totalSleepMinutes: Int
    let inBedMinutes: Int
    let deepSleepMinutes: Int?   // Apple Watch only
    let remSleepMinutes: Int?    // Apple Watch only
    let awakeMinutes: Int
    let sleepEfficiency: Double  // Percentage of in-bed time actually asleep
    let boundarySource: SleepBoundarySource  // healthKit, hrEstimated, recordingBounds

    /// Sleep latency in minutes (time from getting in bed to falling asleep)
    var sleepLatencyMinutes: Int? {
        guard let inBed = inBedStart, let sleep = sleepStart else { return nil }
        let latency = Int(sleep.timeIntervalSince(inBed) / 60)
        return latency > 0 ? latency : nil
    }
}

enum SleepBoundarySource {
    case healthKit       // From Apple Health sleep data
    case hrEstimated     // Estimated from HR patterns
    case recordingBounds // Using recording start/end
}

func fetchSleepData(
    for recordingStart: Date,
    recordingEnd: Date,
    extendForDisplay: Bool = false  // Extend query for accurate total sleep display
) async throws -> SleepData
```

**Sleep Query Modes** (Jan 2026 enhancement):

**`extendForDisplay: false` (default)** - For HRV Analysis:
- Queries sleep data matching actual RR data boundaries
- Used by window selection to find 30-70% sleep band
- Ensures analysis window matches available data

**`extendForDisplay: true`** - For Display/Reporting:
- Extends query to 2pm next day to capture post-wakeup sleep
- Used by HistoryView and MorningResultsView
- Displays accurate total sleep even if user woke up, checked app, then slept more

**Example scenario**:
```swift
// User stops recording at 4am, sleeps again 5am-6am

// Window selection (extendForDisplay: false)
// Queries 11pm-4am → finds deep sleep at 11:30pm-12:30am for HRV analysis

// Display (extendForDisplay: true)
// Queries 11pm-2pm next day → captures 11pm-4am + 5am-6am = 6 hours total sleep
// Report shows "6 hours sleep" not "5 hours sleep"
```

**Morning Replacement Logic**:
If two sessions recorded same day before 10am:
- Higher readiness score replaces lower score as daily reading
- Both sessions remain in archive independently
- Only better session used for baseline tracking

### Sleep Trend Analysis

```swift
struct SleepTrendStats {
    let averageSleepMinutes: Double
    let averageDeepSleepMinutes: Double?
    let averageEfficiency: Double
    let trend: SleepTrend  // improving, declining, stable, insufficient
    let nightsAnalyzed: Int
}
```

### Recovery Vitals
**File**: `HealthKitManager.swift`

Overnight vitals from Apple Watch for recovery assessment:

```swift
struct RecoveryVitals {
    let respiratoryRate: Double?        // breaths per minute
    let respiratoryRateBaseline: Double? // 7-day average
    let oxygenSaturation: Double?       // percentage (0-100)
    let oxygenSaturationMin: Double?    // lowest during sleep
    let wristTemperature: Double?       // deviation from baseline in °C
    let restingHeartRate: Double?       // lowest during sleep

    // Computed properties
    var respiratoryDeviation: Double?   // Rate - baseline (positive = elevated)
    var isRespiratoryElevated: Bool     // >2 breaths/min above baseline
    var isSpO2Concerning: Bool          // <95%
    var isTemperatureElevated: Bool     // >0.5°C above baseline
    var status: VitalsStatus            // normal, elevated, warning

    enum VitalsStatus {
        case normal     // All vitals within range
        case elevated   // One or more vitals elevated
        case warning    // Respiratory AND temperature elevated (likely illness)
    }
}
```

**Fetch Function**:
```swift
func fetchRecoveryVitals() async -> RecoveryVitals
```

**Vitals Sources**:
- **Respiratory Rate**: `HKQuantityType.respiratoryRate` (Apple Watch during sleep)
- **Blood Oxygen**: `HKQuantityType.oxygenSaturation` (Apple Watch during sleep)
- **Wrist Temperature**: `HKQuantityType.appleSleepingWristTemperature` (Watch Series 8+)
- **Resting Heart Rate**: `HKQuantityType.restingHeartRate` (lowest during sleep)

**Clinical Thresholds**:
- Respiratory rate elevated: >2 breaths/min above 7-day baseline
- SpO2 concerning: <95%
- Temperature elevated: >0.5°C above personal baseline
- Warning state: Both respiratory AND temperature elevated (suggests illness)

### Usage in Window Selection

Sleep boundaries are converted to milliseconds relative to recording start:

```swift
if let hkSleepStart = sleepData?.sleepStart {
    sleepStartMs = Int64(hkSleepStart.timeIntervalSince(session.startDate) * 1000)
}
if let hkSleepEnd = sleepData?.sleepEnd {
    wakeTimeMs = Int64(hkSleepEnd.timeIntervalSince(session.startDate) * 1000)
}
```

---

## Export & Import

### PDF Report Generator
**File**: `PDFReportGenerator.swift`

**Page Setup**:
- Size: Letter (612×792pt)
- Margins: 40pt all sides
- Fonts: Title 22pt bold, heading 14pt semibold, body 10pt, mono 9pt

**Report Contents**:
1. Analysis summary (via AnalysisSummaryGenerator)
2. Sleep data from HealthKit
3. 7-day sleep trends
4. Poincaré plot visualization
5. PSD/frequency graph
6. Tachogram (RR time-series)

### Data Import
**File**: `RRDataImporter.swift`

**Supported Formats**:
- CSV: RR intervals comma-separated
- JSON: Array of RR values
- TXT: One RR per line
- Kubios: Kubios HRV export format
- EliteHRV: Elite HRV summary (batch import with pre-computed metrics)

**Validation**:
- Minimum 120 RR intervals
- RR values in 300-2500ms range

---

## User Interface

### Main Views

- **RecordView**: Polar H10 connection, overnight/nap/quick recording controls
- **RecoveryDashboardView**: Pro-style morning readiness dashboard with all recovery metrics at a glance
- **MorningResultsView**: Full analysis display with charts and AI summary
- **DashboardView**: Recent sessions overview, trends, peak capacity
- **HistoryView**: Session list with filtering by tags and dates
- **TrendView**: Multi-day HRV trends and baseline comparison
- **SettingsView**: User preferences, custom tags, HealthKit permissions

### Recovery Dashboard
**File**: `RecoveryDashboardView.swift`

The Recovery Dashboard is the primary "How am I today?" view, consolidating all recovery metrics:

```swift
struct RecoveryDashboardView: View {
    // Inputs
    let sessions: [HRVSession]
    let onStartRecording: () -> Void
    let onViewReport: (HRVSession) -> Void

    // State
    @State private var recoveryVitals: HealthKitManager.RecoveryVitals?
    @State private var trainingMetrics: HealthKitManager.TrainingMetrics?
    @State private var sleepData: HealthKitManager.SleepData?
}
```

**Dashboard Components**:
1. **Recovery Score Hero**: 0-100 composite score with color-coded ring
2. **HRV Card**: Today's RMSSD with baseline comparison (tappable → HRVDetailView)
3. **Sleep Card**: Duration and efficiency (tappable → SleepDetailView)
4. **Training Load Card**: ATL/CTL/TSB and ACR gauge (tappable → TrainingDetailView)
5. **Vitals Grid**: RHR, respiratory rate, SpO2, temperature (tappable → VitalsDetailView)
6. **Insights Section**: Auto-generated recovery insights
7. **Action Button**: "View Recovery Report" or "Take Morning Reading"

**Recovery Score Calculation**:
Composite score from:
- HRV readiness score (from ANS metrics)
- RMSSD relative to baseline
- Sleep duration and efficiency
- Training load (TSB)
- Vitals status

### Sleep Detail View
**File**: `SleepDetailView.swift`

Comprehensive sleep analysis with:

```swift
struct SleepDetailView: View {
    let sleepData: HealthKitManager.SleepData?
    let typicalSleepHours: Double
}
```

**Features**:
- **Sleep Score**: 0-100 composite (duration 40pts, efficiency 30pts, deep 15pts, REM 15pts)
- **Duration Card**: Hours slept with goal progress bar
- **Sleep Timing Card**: Bedtime → wake time with duration
- **Sleep Stages Card**: Visual bar + breakdown (Deep, Light, REM, Awake with ideal ranges)
- **Key Metrics Grid**:
  - Efficiency (% of in-bed time asleep, target ≥85%)
  - WASO (Wake After Sleep Onset, target <20 min)
  - Sleep Time (actual sleep)
  - Time in Bed
  - Sleep Latency (time to fall asleep)
- **Quality Check**: Pass/fail indicators for each metric
- **Sleep Insights**: Auto-generated recommendations

**Sleep Latency Thresholds**:
```swift
private func sleepLatencyStatus(_ latency: Int) -> MetricStatus {
    if latency < 5 { return .poor }       // Sleep deprivation - falling asleep too fast
    if latency < 10 { return .fair }      // Slightly fast, may indicate tiredness
    if latency <= 20 { return .good }     // Ideal range (10-20 min)
    if latency <= 30 { return .fair }     // Slightly slow
    return .poor                           // Difficulty falling asleep (>30 min)
}
```

**Note**: Falling asleep in <5 minutes indicates sleep deprivation, not good sleep. The ideal is 10-20 minutes.

### Vitals Detail View
**File**: `VitalsDetailView.swift`

Detailed overnight vitals with expandable educational cards:

```swift
struct VitalsDetailView: View {
    let vitals: HealthKitManager.RecoveryVitals?
    let temperatureUnit: TemperatureUnit
}
```

**Features**:
- **Status Banner**: Overall vitals status (Normal/Elevated/Warning)
- **Vitals Score**: 0-100 based on deviations from normal
- **Expandable Vital Cards** (tap to expand with educational info):
  - **Resting Heart Rate**: Lowest HR during sleep (normal: varies, athletes often 40-60 bpm)
  - **Respiratory Rate**: Breaths/min with 7-day baseline comparison (normal: 12-20)
  - **Blood Oxygen (SpO2)**: Average and minimum during sleep (normal: 95-100%)
  - **Wrist Temperature**: Deviation from baseline in °C/°F (normal: ±0.5°C)
- **About Section**: How vitals affect recovery

**Vitals Score Calculation**:
```swift
func calculateVitalsScore() -> Int {
    var score = 100
    if isRespiratoryElevated { score -= 15 }
    if isSpO2Concerning { score -= 25 }
    if isTemperatureElevated { score -= 15 }
    if spo2 < 93 { score -= 15 }  // Extra penalty for very low SpO2
    return max(0, score)
}
```

### HRV Detail View
**File**: `HRVDetailView.swift`

In-depth HRV analysis with trends and nervous system balance:

```swift
struct HRVDetailView: View {
    let sessions: [HRVSession]
    let currentHRV: Double?
    let baselineRMSSD: Double?
    var onViewReport: ((HRVSession) -> Void)? = nil
}
```

**Features**:
- **Today's HRV Card**: Current RMSSD with label (Excellent/Good/Fair/Low) and baseline deviation
- **View Full Report Button**: Navigate to complete HRV report
- **Nervous System Card**:
  - Readiness score ring (0-100)
  - ANS Balance Bar: Sympathetic vs Parasympathetic percentage
  - Balance interpretation text
- **30-Day Trend Chart**: Line chart with baseline reference and CV badge
- **Statistics Card**: 30-day average, range, variability (CV), baseline
- **Recent Readings**: Last 7 sessions with tap-to-view-report
- **Understanding HRV**: Educational tips

**ANS Balance Calculation**:
```swift
private var nervousSystemBalance: (sympathetic: Double, parasympathetic: Double)? {
    guard let sns = ans.snsIndex, let pns = ans.pnsIndex else { return nil }
    // Convert from -3 to +3 scale to 0-1 scale for display
    let snsNormalized = max(0, min(1, (sns + 3) / 6))
    let pnsNormalized = max(0, min(1, (pns + 3) / 6))
    let total = snsNormalized + pnsNormalized
    return (snsNormalized / total, pnsNormalized / total)
}
```

### Visualization Components

- **OvernightChartsView**: HR/RR over time with sleep stage overlay and recovery window
- **LiveWaveformView**: Real-time RR streaming display
- **PoincarePlotView**: Interactive nonlinear dynamics visualization
- **BreathingMandalaView**: Coherence breathing guide (6 breaths/min)
- **DraggableAnalysisWindow**: Manual window selection on charts
- **PeakCapacityCard**: Peak capacity display
- **ACRGaugeView**: Acute/Chronic Ratio gauge with zones (under/optimal/peak/over/risk)
- **ANSBalanceBar**: Sympathetic vs Parasympathetic horizontal bar

### Analysis Summary Generator
**File**: `AnalysisSummaryGenerator.swift`

Generates comprehensive analysis including:

```swift
struct AnalysisSummary {
    let diagnosticTitle: String        // "Well Recovered", "Adequate Recovery", etc.
    let diagnosticIcon: String
    let diagnosticScore: Double        // 0-100
    let diagnosticExplanation: String
    let probableCauses: [ProbableCause]
    let keyFindings: [String]
    let actionableSteps: [String]
    let trendInsight: String
}
```

**Diagnostic Score Calculation** (0-100):
- RMSSD (40 pts): ≥60→+40, ≥45→+30, ≥30→+20, ≥20→+10, else -10
- Stress Index (20 pts): <150→+20, <200→+15, <300→+10, ≥300→-15
- LF/HF (20 pts): 0.5-2.0→+20, <0.5→+15, ≤3.0→+5, >3.0→-10
- DFA α1 (20 pts): 0.75-1.0→+20, 1.0-1.15→+10

**Diagnostic Titles**:
- ≥80: "Well Recovered"
- ≥60: "Adequate Recovery"
- ≥40: "Incomplete Recovery"
- ≥20: "Significant Stress"
- <20: "Recovery Needed"

**Probable Causes** (60+ factors):
- Tag-based: Alcohol, Poor Sleep, Late Meal, Caffeine, Travel, Illness, Menstrual, Stressed, Post-Exercise
- Sleep-based: Insufficient (<6h), Fragmented (<80% efficiency), Low Deep Sleep (<10%)
- Pattern detection: Consecutive declines (illness pattern), Day-of-week patterns
- Severe anomalies: >50% drop = "Severe HRV Crash", elevated HR + low HRV = immune activation

**Actionable Steps**:
- Consolidated recovery (RMSSD high + sustained + stable HR + DFA 0.75-1.0) → "Great day for high-intensity training"
- High HRV but unconsolidated → recommend moderate activity instead
- Score-based recommendations for rest, light activity, or full training

---

## Complete API Reference

### RRCollector (Main Orchestrator)

```swift
@MainActor
final class RRCollector: ObservableObject {
    // Published State
    @Published var isCollecting: Bool
    @Published var currentSession: HRVSession?
    @Published var collectedPoints: [RRPoint]
    @Published var lastError: Error?
    @Published var verificationResult: Verification.Result?
    @Published var recoveryWindow: WindowSelector.RecoveryWindow?
    @Published var needsAcceptance: Bool
    @Published var baselineDeviation: BaselineTracker.BaselineDeviation?
    @Published var isStreamingMode: Bool
    @Published var streamingTargetSeconds: Int  // Default 180
    @Published var streamingElapsedSeconds: Int
    @Published var isOvernightStreaming: Bool
    @Published var fetchProgress: PolarManager.FetchProgress?
    @Published var archiveVersion: Int  // Trigger UI updates

    // Dependencies
    let polarManager: PolarManager
    let archive: SessionArchive
    let rawBackup: RawRRBackup
    let baselineTracker: BaselineTracker

    // Computed
    var archivedSessions: [HRVSession]
    var hasUnrecoveredData: Bool
    var hasPersistedRecordingState: Bool

    // Hybrid Overnight Recording
    func startOvernightStreaming(sessionType: SessionType) throws
    func stopOvernightStreaming() async -> HRVSession?

    // Quick Streaming
    func startStreamingSession(durationSeconds: Int) throws
    func stopStreamingSession() async -> HRVSession?

    // Device-Only Recording
    func startSession(sessionType: SessionType) async throws
    func stopSession() async throws -> HRVSession?
    func retryFetchRecording() async throws -> HRVSession?
    func recoverFromDevice() async throws -> HRVSession?

    // Session Management
    func acceptSession() async throws
    func rejectSession() async
    func resetSession()
    func reanalyzeSession(_ session: HRVSession, method: WindowSelectionMethod) async -> HRVSession?

    // Import
    func saveImportedSession(_ session: HRVSession) async throws
    func saveImportedSessionsBatch(_ sessions: [HRVSession]) async throws -> Int

    // Backup Recovery
    func checkForLostSessions() -> [(id: UUID, date: Date, beatCount: Int)]
    func recoverFromBackup(_ sessionId: UUID) async -> HRVSession?
    func findCorruptedSessions(toleranceDays: Int) -> [CorruptedSessionInfo]
    func restoreCorruptedSession(_ sessionId: UUID) async -> HRVSession?
}
```

### WindowSelector

```swift
final class WindowSelector {
    func findBestWindow(
        in series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64?,
        wakeTimeMs: Int64?
    ) -> RecoveryWindow?

    func findBestWindowWithCapacity(
        in series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64?,
        wakeTimeMs: Int64?
    ) -> WindowSelectionResult?

    func selectWindowByMethod(
        _ method: WindowSelectionMethod,
        in series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64?,
        wakeTimeMs: Int64?
    ) -> RecoveryWindow?

    func analyzeAtPosition(
        in series: RRSeries,
        flags: [ArtifactFlags],
        targetMs: Int64
    ) -> RecoveryWindow?
}
```

### Analysis Functions

```swift
// Artifact Detection
ArtifactDetector.detectArtifacts(in: RRSeries) -> [ArtifactFlags]

// Time Domain
TimeDomainAnalyzer.compute(_:flags:windowStart:windowEnd:) -> TimeDomainMetrics?

// Frequency Domain (Welch's method)
FrequencyDomainAnalyzer.compute(_:flags:windowStart:windowEnd:) -> FrequencyDomainMetrics?

// Nonlinear (Poincaré, Entropy)
NonlinearAnalyzer.compute(_:flags:windowStart:windowEnd:) -> NonlinearMetrics?

// DFA
DFAAnalyzer.compute(_: [Double]) -> DFAResult?

// Stress
StressAnalyzer.computeStressIndex(_: [Double]) -> Double?
StressAnalyzer.computePNSIndex(meanRR:rmssd:sd1:) -> Double?
StressAnalyzer.computeSNSIndex(meanHR:stressIndex:sd2:) -> Double?
StressAnalyzer.computeReadinessScore(rmssd:baselineRMSSD:alpha1:) -> Double?

// Respiration
RespirationAnalyzer.estimateRespirationRate(_: [Double]) -> Double?

// Summary
AnalysisSummaryGenerator(result:session:recentSessions:selectedTags:sleep:sleepTrend:).generate() -> AnalysisSummary
```

---

## Summary of Capabilities

### Data Collection
- ✅ Hybrid recording: Internal (preferred) + Streaming (backup)
- ✅ Composite merging: Fill internal gaps with streaming data
- ✅ Polar H10 Bluetooth connectivity
- ✅ Real-time RR streaming with wall-clock timestamps
- ✅ Device internal recording (survives disconnects)
- ✅ Background execution via silent audio + location
- ✅ Automatic reconnection handling
- ✅ Multi-attempt fetch with retry
- ✅ Incremental backup (time-based, force on reconnect)
- ✅ Persisted recording state (survives app restart)
- ✅ Device provenance tracking

### HRV Analysis
- ✅ Time domain (RMSSD, SDNN, pNN50, SDSD, triangular index, HR stats)
- ✅ Frequency domain (VLF, LF, HF, LF/HF, Welch's method with Hann window)
- ✅ Nonlinear (Poincaré SD1/SD2, Sample Entropy, Approximate Entropy)
- ✅ DFA (α1 short-term, α2 long-term)
- ✅ Stress Index (Baevsky)
- ✅ PNS/SNS indices
- ✅ Readiness score
- ✅ Respiration rate estimation
- ✅ Artifact detection and correction (linear, cubic spline, median)

### Window Selection
- ✅ **30-70% of actual sleep** (HealthKit-anchored)
- ✅ Organization classification (DFA α1 based)
- ✅ Consolidated recovery detection (sustained + stable + organized)
- ✅ Peak capacity tracking (independent from recovery)
- ✅ Multiple selection methods (consolidated, peak RMSSD/SDNN/TotalPower, custom)
- ✅ Manual window positioning

### Data Management
- ✅ Persistent session archive with SHA256 integrity
- ✅ Raw RR backup system
- ✅ 7-day rolling baseline tracking
- ✅ Tag-based organization (14 system + custom tags)
- ✅ CSV/JSON/Kubios/EliteHRV import
- ✅ PDF report generation with visualizations

### HealthKit Integration
- ✅ Sleep data import (stages, duration, efficiency, latency)
- ✅ Sleep boundary detection for window selection
- ✅ Daytime resting HR for nocturnal dip
- ✅ Sleep trend analysis (7-day averages)
- ✅ Recovery vitals (respiratory rate, SpO2, wrist temperature, resting HR)
- ✅ Respiratory rate baseline tracking (7-day average)
- ✅ Vitals status assessment (normal/elevated/warning)

### Recovery Dashboard
- ✅ Composite recovery score (HRV + Sleep + Training + Vitals)
- ✅ One-stop morning readiness view
- ✅ Interactive cards with drill-down detail views
- ✅ Auto-generated recovery insights
- ✅ Training load integration with ACR gauge

### Sleep Analysis
- ✅ Sleep score (0-100 composite)
- ✅ Sleep stages breakdown with ideal ranges
- ✅ Sleep latency tracking with proper thresholds (<5 min = deprivation, 10-20 min = ideal)
- ✅ Sleep efficiency calculation (handles iOS 16+ stage-only data)
- ✅ WASO (Wake After Sleep Onset)
- ✅ Quality check indicators
- ✅ Educational sleep insights

### Vitals Monitoring
- ✅ Expandable vital cards with educational content
- ✅ Vitals score calculation
- ✅ Respiratory rate with baseline deviation
- ✅ Blood oxygen with minimum overnight value
- ✅ Wrist temperature with deviation from baseline
- ✅ Resting heart rate from overnight data

### User Interface
- ✅ Real-time heart rate display
- ✅ Live waveform visualization
- ✅ Interactive Poincaré plot
- ✅ Overnight charts with sleep overlay and recovery window
- ✅ Breathing mandala for coherence
- ✅ Comprehensive results view with AI explanations
- ✅ Session tagging and notes
- ✅ Manual window reanalysis
- ✅ Recovery Dashboard with drill-down views
- ✅ Sleep Detail View with stages, metrics, and insights
- ✅ Vitals Detail View with expandable educational cards
- ✅ HRV Detail View with trends and ANS balance
- ✅ Training Detail View with load metrics

---

## Known Limitations & TODOs

### Multi-Device Support
- ❌ **Multiple Device Management**: Currently hardcoded to single Polar H10. Need to support:
  - Device selection UI for choosing from multiple paired devices
  - Per-device settings and history
  - Device-specific baseline tracking (different devices may have different baselines)
  - Device switching during session (if primary fails, switch to backup)
  - Device library/roster management

- ❌ **Per-Device Sliding Window Configuration**: Each device type may need different window parameters:
  - H10 internal: 400-beat windows optimal
  - Streaming-only devices: May need smaller windows due to gaps
  - Different chest straps: May have different artifact patterns
  - Need per-device window sizing config stored in device profiles

### Window Selection UI Issues

- ❌ **Manual Window Selection Not Implemented**:
  - `WindowSelectionMethod.custom` exists in code but UI not built
  - Draggable/movable window not implemented in OvernightChartsView
  - Users cannot manually position the recovery window
  - Need: Interactive slider or draggable overlay on overnight chart
  - Should show real-time RMSSD/DFA α1 as user moves window

- ⚠️ **Method Selection vs Display Mismatch**:
  - "Consolidated Recovery" displayed by default in results view
  - But may not be the **selected** method in UserSettings
  - If user changes selection method, results view doesn't update
  - Need: Sync between `UserSettings.windowSelectionMethod` and displayed results
  - Need: Clear indication of which method is currently active

- ❌ **Window Re-selection After Method Change**:
  - When user switches from "Consolidated Recovery" to "Peak RMSSD", window doesn't recalculate
  - Requires manual "Reanalyze" button press
  - Should: Auto-recalculate and update results when method changes
  - Current workaround: User must manually tap "Reanalyze Session"

### Device-Specific Features

- ❌ **Polar H10 Internal Recording Assumptions**:
  - Code assumes all devices support internal recording
  - Many devices (Verity Sense, OH1, other brands) are streaming-only
  - Need: Device capability detection and adaptive recording mode
  - Need: Graceful degradation when internal recording unavailable

- ❌ **Device Battery & Memory Monitoring**:
  - No indication of H10 internal memory usage (max ~65 hours)
  - No battery level display
  - User doesn't know when to clear H10 memory or charge
  - Need: Device info panel with battery, memory, firmware version

### Baseline & Trend Analysis

- ⚠️ **Baseline Not Synced Across Devices**:
  - 7-day baseline assumes same device
  - If user switches devices, baseline becomes invalid
  - Need: Per-device baseline OR cross-device normalization
  - Device ID should be stored with each baseline data point

- ❌ **Long-Term Trend Analysis**:
  - Baseline only tracks 7 days
  - No 30-day, 90-day, or yearly trends
  - No seasonal adjustment (HRV naturally varies with seasons)
  - No training load periodization tracking

### Sleep Data Integration

- ⚠️ **Sleep Stage Alignment Edge Cases**:
  - If user wakes up during night, sleep data may have gaps
  - Multiple sleep sessions in one recording not handled
  - Need: Better multi-segment sleep detection
  - Need: Handle interrupted sleep (wake periods)

### Export & Sharing

- ❌ **Cloud Sync**:
  - No iCloud sync between devices
  - User loses data if device is lost
  - No backup/restore mechanism beyond local files

- ❌ **Share Recovery Window**:
  - Can export full session but not specific recovery window
  - Cannot share annotated overnight chart with window highlighted
  - Coaches/practitioners would benefit from visual window exports

---

*Documentation generated from Flow Recovery codebase analysis. All information is derived from actual source code.*
