//
//  Copyright © 2024-2026 Chris Sharp. All rights reserved.
//

import Foundation

// MARK: - Time Conversions

enum TimeConstants {
    static let msPerSecond: Double = 1000.0
    static let msPerMinute: Double = 60_000.0
    static let msPerHour: Double = 3_600_000.0
    static let secondsPerMinute: Int = 60
    static let minutesPerHour: Int = 60
    static let hoursPerDay: Int = 24
}

// MARK: - HRV Analysis

enum HRVConstants {

    /// Minimum/maximum physiologically valid RR intervals (ms)
    enum RRInterval {
        static let minimum: Int = 200    // ~300 bpm
        static let maximum: Int = 2000   // ~30 bpm

        static let range: ClosedRange<Int> = minimum...maximum

        /// Check if an RR interval is physiologically valid
        static func isValid(_ ms: Int) -> Bool {
            range.contains(ms)
        }
    }

    /// Beat count thresholds for analysis
    enum MinimumBeats {
        static let forAnalysis: Int = 300      // Minimum for reliable HRV metrics
        static let forStreaming: Int = 120     // Relaxed for short recordings
        static let forTimeDomain: Int = 10     // Minimum for basic statistics
        static let forTriangularIndex: Int = 20
        static let forDFA: Int = 256           // Minimum for fractal analysis
        static let forFrequencyDomain: Int = 256
    }

    /// Frequency domain band boundaries (Hz)
    enum FrequencyBands {
        static let vlfLow: Double = 0.003
        static let vlfHigh: Double = 0.04
        static let lfLow: Double = 0.04
        static let lfHigh: Double = 0.15
        static let hfLow: Double = 0.15
        static let hfHigh: Double = 0.4

        /// Minimum window duration for VLF analysis (minutes)
        static let minimumVLFWindowMinutes: Double = 5.0
    }

    /// DFA (Detrended Fluctuation Analysis) parameters
    enum DFA {
        static let alpha1ScaleMin: Int = 4
        static let alpha1ScaleMax: Int = 16
        static let alpha2ScaleMin: Int = 16
        static let alpha2ScaleMax: Int = 64

        /// Optimal α1 range for organized parasympathetic recovery
        static let organizedRecoveryAlpha1Range: ClosedRange<Double> = 0.75...1.0
    }

    /// Artifact detection thresholds
    enum Artifacts {
        static let maxPercentForAnalysis: Double = 15.0
        static let warnPercentThreshold: Double = 5.0
        static let windowSize: Int = 50
    }
}

// MARK: - Heart Rate

enum HeartRateConstants {
    static let minimumPhysiological: Int = 30
    static let maximumPhysiological: Int = 220
    static let defaultMax: Int = 190
    static let defaultAverage: Int = 120

    /// Convert RR interval (ms) to heart rate (bpm)
    static func bpmFromRR(_ rrMs: Double) -> Double {
        guard rrMs > 0 else { return 0 }
        return TimeConstants.msPerMinute / rrMs
    }

    /// Convert heart rate (bpm) to RR interval (ms)
    static func rrFromBPM(_ bpm: Double) -> Double {
        guard bpm > 0 else { return 0 }
        return TimeConstants.msPerMinute / bpm
    }
}

// MARK: - Sleep Analysis

enum SleepConstants {
    /// Sleep duration thresholds (minutes)
    static let goodSleepMinutes: Int = 420       // 7 hours
    static let minimumSleepMinutes: Int = 240    // 4 hours
    static let optimalSleepMinutes: Int = 480    // 8 hours

    /// Sleep efficiency thresholds (percentage)
    static let goodEfficiency: Double = 85.0
    static let poorEfficiency: Double = 75.0

    /// Window positioning within sleep (0.0-1.0)
    enum WindowPosition {
        static let earlyRecoveryStart: Double = 0.30
        static let earlyRecoveryEnd: Double = 0.70
    }
}

// MARK: - Training Load

enum TrainingConstants {
    /// Acute:Chronic Workload Ratio thresholds
    enum ACR {
        static let detraining: Double = 0.8
        static let optimalLow: Double = 0.8
        static let optimalHigh: Double = 1.1
        static let building: Double = 1.3
        static let overreaching: Double = 1.5
    }

    /// Training Stress Balance interpretation
    enum TSB {
        static let veryFresh: Double = 25
        static let fresh: Double = 10
        static let neutral: Double = -10
        static let tired: Double = -25
    }

    /// TRIMP calculation constants (Bannister method)
    enum TRIMP {
        static let maleWeighting: Double = 1.92
        static let femaleWeighting: Double = 1.67
    }

    /// EWMA decay constants
    enum EWMA {
        static let acuteDays: Int = 7     // ATL window
        static let chronicDays: Int = 42  // CTL window
    }
}

// MARK: - Recording

enum RecordingConstants {
    /// Gap detection threshold (ms)
    static let gapThresholdMs: Int64 = 2000

    /// Session matching tolerance (minutes)
    static let sessionMatchToleranceMinutes: Int = 30

    /// Streaming mode defaults
    static let defaultStreamingDurationSeconds: Int = 180

    /// Background keep-alive interval (seconds)
    static let backgroundKeepAliveInterval: TimeInterval = 30
}

// MARK: - Analysis Windows

enum WindowConstants {
    /// Minimum window duration (minutes)
    static let minimumDurationMinutes: Double = 4.0

    /// Window step size (minutes)
    static let stepSizeMinutes: Double = 1.0

    /// HR stability threshold (CV)
    static let hrStabilityThreshold: Double = 0.08

    /// Histogram bin width for triangular index (ms)
    static let triangularIndexBinWidth: Double = 7.8125  // 1/128 second
}

// MARK: - Readiness Scoring

enum ReadinessConstants {
    /// Score boundaries (1-10 scale)
    static let minimumScore: Double = 1.0
    static let maximumScore: Double = 10.0

    /// Thresholds for color coding
    static let excellentThreshold: Double = 8.0
    static let goodThreshold: Double = 6.0
    static let fairThreshold: Double = 4.0
}
