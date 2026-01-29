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

/// Centralized HRV thresholds and configuration constants.
/// All physiological thresholds and algorithm parameters are defined here
/// with documentation explaining the research basis for each value.
enum HRVThresholds {

    // MARK: - RR Interval Validity

    /// Minimum valid RR interval in milliseconds (300ms = 200 bpm max)
    static let minimumRRIntervalMs = 300

    /// Maximum valid RR interval in milliseconds (2000ms = 30 bpm min)
    static let maximumRRIntervalMs = 2000

    // MARK: - RMSSD Interpretation

    /// Excellent HRV threshold (ms) - strong parasympathetic activity
    static let rmssdExcellent = 50.0

    /// Good HRV threshold (ms) - adequate recovery
    static let rmssdGood = 35.0

    /// Reduced HRV threshold (ms) - recovery may be incomplete
    static let rmssdReduced = 25.0

    /// Low HRV threshold (ms) - significant physiological stress
    static let rmssdLow = 20.0

    // MARK: - Diagnostic Score Thresholds

    /// Score threshold for "Well Recovered" status
    static let scoreWellRecovered = 80.0

    /// Score threshold for "Adequate Recovery" status
    static let scoreAdequateRecovery = 60.0

    /// Score threshold for "Incomplete Recovery" status
    static let scoreIncompleteRecovery = 40.0

    /// Score threshold for "Significant Stress Load" status
    static let scoreSignificantStress = 20.0

    // MARK: - Stress Index (Baevsky's SI)

    /// Low stress threshold - very relaxed state
    static let stressIndexLow = 50.0

    /// Normal stress upper bound
    static let stressIndexNormal = 150.0

    /// Elevated stress threshold
    static let stressIndexElevated = 200.0

    /// High stress threshold - significant physiological load
    static let stressIndexHigh = 300.0

    // MARK: - LF/HF Ratio (Autonomic Balance)

    /// Strong parasympathetic dominance threshold
    static let lfHfParasympatheticDominance = 0.5

    /// Balanced autonomic state lower bound
    static let lfHfBalancedLower = 0.8

    /// Balanced autonomic state upper bound
    static let lfHfBalancedUpper = 1.5

    /// Optimal range upper bound
    static let lfHfOptimalUpper = 2.0

    /// Moderate sympathetic activation threshold
    static let lfHfModerateSympatheticUpper = 3.0

    /// Strong sympathetic dominance threshold - fight-or-flight
    static let lfHfSympatheticDominance = 3.0

    // MARK: - DFA Alpha1 (Fractal Scaling)

    /// Optimal recovery DFA α1 lower bound (organized parasympathetic control)
    static let dfaAlpha1OptimalLower = 0.75

    /// Optimal recovery DFA α1 upper bound
    static let dfaAlpha1OptimalUpper = 1.0

    /// Flexible but unconsolidated range lower bound
    static let dfaAlpha1FlexibleLower = 0.60

    /// Elevated α1 indicating fatigue
    static let dfaAlpha1Fatigue = 1.2

    /// High variability/disorganization threshold
    static let dfaAlpha1HighVariability = 1.15

    // MARK: - Heart Rate

    /// HR elevation threshold above baseline (bpm)
    static let hrElevationThreshold = 5.0

    /// Significant HR elevation threshold (bpm)
    static let hrSignificantElevation = 8.0

    // MARK: - Sleep Duration

    /// Minimum recommended sleep (minutes) - 7 hours
    static let sleepMinimumMinutes = 420

    /// Short sleep threshold (minutes) - 5 hours
    static let sleepShortMinutes = 300

    /// Very short sleep threshold (minutes) - 6 hours
    static let sleepVeryShortMinutes = 360

    // MARK: - Sleep Quality

    /// Good sleep efficiency threshold (%)
    static let sleepEfficiencyGood = 90.0

    /// Acceptable sleep efficiency threshold (%)
    static let sleepEfficiencyAcceptable = 80.0

    /// Low sleep efficiency threshold (%)
    static let sleepEfficiencyLow = 75.0

    /// Fragmented sleep awake threshold (minutes)
    static let sleepFragmentedAwakeMinutes = 30

    /// Good deep sleep percentage threshold (%)
    static let deepSleepGoodPercent = 20.0

    /// Low deep sleep percentage threshold (%)
    static let deepSleepLowPercent = 10.0

    /// Minimum deep sleep minutes for adequacy
    static let deepSleepMinimumMinutes = 45

    // MARK: - Trend Analysis

    /// Significant trend change threshold (%)
    static let trendSignificantChange = 20.0

    /// Moderate trend change threshold (%)
    static let trendModerateChange = 10.0

    /// Above baseline threshold (%)
    static let baselineAboveThreshold = 15.0

    // MARK: - pNN50 (Beat-to-Beat Variation)

    /// Very low pNN50 threshold (%) - vagal tone suppressed
    static let pnn50VeryLow = 5.0

    /// Low pNN50 threshold (%)
    static let pnn50Low = 10.0

    /// Strong pNN50 threshold (%) - excellent vagal activity
    static let pnn50Strong = 30.0

    // MARK: - Window Selection

    /// HR coefficient of variation threshold for stability (8%)
    static let windowUnstableCVThreshold = 0.08

    /// Maximum LF/HF for organized recovery
    static let windowMaxOrganizedLfHf = 1.5

    /// Isolated spike detection threshold (150%)
    static let windowIsolatedSpikeThreshold = 1.50

    /// Default window position start (30% of sleep)
    static let windowPositionStart = 0.30

    /// Default window position end (70% of sleep)
    static let windowPositionEnd = 0.70

    /// Target beats per analysis window
    static let windowTargetBeats = 400

    /// Minimum beats per analysis window
    static let windowMinimumBeats = 120

    // MARK: - Artifact Detection

    /// Maximum artifact rate for valid analysis
    static let maxArtifactRate = 0.15

    /// Warning artifact rate
    static let warnArtifactRate = 0.10

    /// Ectopic threshold percent deviation from local median
    static let ectopicThresholdPercent = 0.20

    // MARK: - Illness Detection

    /// Severe HRV crash threshold (% below average)
    static let illnessSevereHRVCrash = -50.0

    /// Major HRV drop threshold (% below average)
    static let illnessMajorHRVDrop = -30.0

    /// Consecutive decline days for illness pattern
    static let illnessConsecutiveDeclineDays = 3

    /// Decline threshold per day (%)
    static let illnessDeclineThreshold = 0.95
}

// MARK: - Diagnostic Scoring Configuration

/// Configuration for diagnostic score calculation
struct DiagnosticScoringConfig {
    /// Base score before adjustments
    let baseScore: Double

    /// RMSSD score adjustments
    let rmssdScores: RMSSDScores

    /// Stress index score adjustments
    let stressScores: StressScores

    /// LF/HF ratio score adjustments
    let lfHfScores: LFHFScores

    /// DFA α1 score adjustments
    let dfaScores: DFAScores

    struct RMSSDScores {
        let excellent: Double  // rmssd >= 60
        let good: Double       // rmssd >= 45
        let moderate: Double   // rmssd >= 30
        let reduced: Double    // rmssd >= 20
        let low: Double        // rmssd < 20
    }

    struct StressScores {
        let veryLow: Double    // stress < 100
        let low: Double        // stress < 150
        let moderate: Double   // stress < 200
        let elevated: Double   // stress < 300
        let high: Double       // stress >= 300
    }

    struct LFHFScores {
        let optimal: Double    // 0.5 <= ratio <= 2.0
        let parasympathetic: Double // ratio < 0.5
        let mildSymapthetic: Double // ratio <= 3.0
        let highSympathetic: Double // ratio > 3.0
    }

    struct DFAScores {
        let optimal: Double    // 0.75 <= alpha1 <= 1.0
        let acceptable: Double // 1.0 < alpha1 <= 1.15
        let elevated: Double   // alpha1 > 1.15
    }

    /// Default configuration based on research
    static let `default` = DiagnosticScoringConfig(
        baseScore: 50.0,
        rmssdScores: RMSSDScores(
            excellent: 40,
            good: 30,
            moderate: 20,
            reduced: 10,
            low: -10
        ),
        stressScores: StressScores(
            veryLow: 20,
            low: 15,
            moderate: 10,
            elevated: 0,
            high: -15
        ),
        lfHfScores: LFHFScores(
            optimal: 20,
            parasympathetic: 15,
            mildSymapthetic: 5,
            highSympathetic: -10
        ),
        dfaScores: DFAScores(
            optimal: 20,
            acceptable: 10,
            elevated: 0
        )
    )
}

// MARK: - Age and Sex Adjusted HRV Interpretation

/// Provides age and sex-adjusted HRV interpretation based on population norms
/// Research basis: Nunan et al. 2010, Voss et al. 2015, Bonnemeier et al. 2003
struct AgeAdjustedHRV {

    /// Biological sex for HRV adjustment
    enum Sex: String, CaseIterable {
        case male, female

        /// Sex adjustment factor for RMSSD (women average ~5-10% lower)
        var rmssdMultiplier: Double {
            switch self {
            case .male: return 1.0
            case .female: return 0.92
            }
        }
    }

    /// Age-based RMSSD norms (50th percentile values in ms)
    /// Based on meta-analysis of healthy adult populations
    static func medianRMSSD(forAge age: Int, sex: Sex? = nil) -> Double {
        let baseValue: Double
        switch age {
        case ..<20: baseValue = 55.0
        case 20..<30: baseValue = 45.0
        case 30..<40: baseValue = 38.0
        case 40..<50: baseValue = 32.0
        case 50..<60: baseValue = 27.0
        case 60..<70: baseValue = 22.0
        default: baseValue = 18.0
        }

        // Apply sex adjustment if known
        let multiplier = sex?.rmssdMultiplier ?? 1.0
        return baseValue * multiplier
    }

    /// Get percentile thresholds for RMSSD by age
    /// Returns (low, fair, good, excellent) thresholds
    static func rmssdThresholds(forAge age: Int, sex: Sex? = nil) -> (low: Double, fair: Double, good: Double, excellent: Double) {
        let median = medianRMSSD(forAge: age, sex: sex)

        // Percentile-based thresholds relative to age-adjusted median
        // Low: <25th percentile (~0.6x median)
        // Fair: 25-50th percentile (~0.6-1.0x median)
        // Good: 50-75th percentile (~1.0-1.4x median)
        // Excellent: >75th percentile (~>1.4x median)
        return (
            low: median * 0.6,
            fair: median * 0.85,
            good: median * 1.15,
            excellent: median * 1.4
        )
    }

    /// Interpret RMSSD value with age context
    static func interpret(rmssd: Double, age: Int?, sex: Sex? = nil) -> RMSSDInterpretation {
        guard let age = age else {
            // Fall back to absolute thresholds if no age
            return interpretAbsolute(rmssd: rmssd)
        }

        let thresholds = rmssdThresholds(forAge: age, sex: sex)
        let median = medianRMSSD(forAge: age, sex: sex)
        let percentile = estimatePercentile(rmssd: rmssd, median: median)

        let category: RMSSDCategory
        let ageContext: String

        if rmssd >= thresholds.excellent {
            category = .excellent
            ageContext = "well above average for your age"
        } else if rmssd >= thresholds.good {
            category = .good
            ageContext = "above average for your age"
        } else if rmssd >= thresholds.fair {
            category = .fair
            ageContext = "typical for your age"
        } else if rmssd >= thresholds.low {
            category = .reduced
            ageContext = "below average for your age"
        } else {
            category = .low
            ageContext = "significantly below average for your age"
        }

        return RMSSDInterpretation(
            category: category,
            ageContext: ageContext,
            percentile: percentile,
            ageAdjustedMedian: median
        )
    }

    /// Fall back to absolute interpretation when age unknown
    private static func interpretAbsolute(rmssd: Double) -> RMSSDInterpretation {
        let category: RMSSDCategory
        if rmssd >= 50 {
            category = .excellent
        } else if rmssd >= 35 {
            category = .good
        } else if rmssd >= 25 {
            category = .fair
        } else if rmssd >= 15 {
            category = .reduced
        } else {
            category = .low
        }

        return RMSSDInterpretation(
            category: category,
            ageContext: nil,
            percentile: nil,
            ageAdjustedMedian: nil
        )
    }

    /// Estimate percentile from RMSSD relative to median
    /// Uses log-normal distribution assumption typical for HRV data
    private static func estimatePercentile(rmssd: Double, median: Double) -> Int {
        // Approximate percentile using ratio to median
        // HRV follows roughly log-normal distribution with CV ~0.4-0.5
        let ratio = rmssd / median

        if ratio >= 1.8 { return 95 }
        if ratio >= 1.5 { return 85 }
        if ratio >= 1.3 { return 75 }
        if ratio >= 1.1 { return 60 }
        if ratio >= 0.95 { return 50 }
        if ratio >= 0.8 { return 35 }
        if ratio >= 0.65 { return 20 }
        if ratio >= 0.5 { return 10 }
        return 5
    }

    // MARK: - VO2max Interpretation

    /// VO2max fitness categories by age and sex
    /// Based on ACSM guidelines
    static func interpretVO2Max(_ vo2max: Double, age: Int?, sex: Sex? = nil) -> VO2MaxInterpretation {
        guard let age = age else {
            return VO2MaxInterpretation(category: .unknown, percentileRange: nil, ageContext: nil)
        }

        let thresholds = vo2maxThresholds(forAge: age, sex: sex ?? .male)

        let category: FitnessCategory
        let percentileRange: String

        if vo2max >= thresholds.superior {
            category = .superior
            percentileRange = "top 5%"
        } else if vo2max >= thresholds.excellent {
            category = .excellent
            percentileRange = "top 20%"
        } else if vo2max >= thresholds.good {
            category = .good
            percentileRange = "top 40%"
        } else if vo2max >= thresholds.fair {
            category = .fair
            percentileRange = "average"
        } else if vo2max >= thresholds.poor {
            category = .belowAverage
            percentileRange = "below average"
        } else {
            category = .poor
            percentileRange = "bottom 20%"
        }

        return VO2MaxInterpretation(
            category: category,
            percentileRange: percentileRange,
            ageContext: "for age \(age)"
        )
    }

    /// VO2max thresholds by age and sex (ml/kg/min)
    private static func vo2maxThresholds(forAge age: Int, sex: Sex) -> (poor: Double, fair: Double, good: Double, excellent: Double, superior: Double) {
        // ACSM fitness categories
        switch sex {
        case .male:
            switch age {
            case ..<30: return (poor: 33, fair: 37, good: 42, excellent: 48, superior: 54)
            case 30..<40: return (poor: 31, fair: 35, good: 40, excellent: 45, superior: 51)
            case 40..<50: return (poor: 28, fair: 32, good: 37, excellent: 42, superior: 48)
            case 50..<60: return (poor: 25, fair: 29, good: 34, excellent: 39, superior: 45)
            case 60..<70: return (poor: 22, fair: 26, good: 31, excellent: 36, superior: 42)
            default: return (poor: 19, fair: 23, good: 28, excellent: 33, superior: 39)
            }
        case .female:
            switch age {
            case ..<30: return (poor: 28, fair: 32, good: 37, excellent: 43, superior: 49)
            case 30..<40: return (poor: 26, fair: 30, good: 35, excellent: 40, superior: 46)
            case 40..<50: return (poor: 24, fair: 28, good: 32, excellent: 37, superior: 43)
            case 50..<60: return (poor: 21, fair: 25, good: 29, excellent: 34, superior: 40)
            case 60..<70: return (poor: 18, fair: 22, good: 26, excellent: 31, superior: 37)
            default: return (poor: 16, fair: 20, good: 24, excellent: 29, superior: 35)
            }
        }
    }

    // MARK: - Resting Heart Rate Interpretation

    /// Interpret resting heart rate with age/fitness context
    static func interpretRestingHR(_ hr: Double, age: Int?, vo2max: Double? = nil) -> String {
        // Athletes typically have lower resting HR
        let isLikelyFit = vo2max.map { $0 > 45 } ?? false

        if hr < 50 {
            return isLikelyFit ? "Athletic (normal for your fitness)" : "Very low – consider checking with doctor if not athletic"
        } else if hr < 60 {
            return "Excellent"
        } else if hr < 70 {
            return "Good"
        } else if hr < 80 {
            return "Average"
        } else if hr < 90 {
            return "Elevated"
        } else {
            return "High – may indicate stress or health concern"
        }
    }
}

// MARK: - Interpretation Result Types

enum RMSSDCategory: String {
    case excellent = "Excellent"
    case good = "Good"
    case fair = "Fair"
    case reduced = "Reduced"
    case low = "Low"

    var color: String {
        switch self {
        case .excellent: return "green"
        case .good: return "teal"
        case .fair: return "yellow"
        case .reduced: return "orange"
        case .low: return "red"
        }
    }
}

struct RMSSDInterpretation {
    let category: RMSSDCategory
    let ageContext: String?
    let percentile: Int?
    let ageAdjustedMedian: Double?

    /// Full description with age context
    var fullDescription: String {
        if let context = ageContext {
            return "\(category.rawValue) – \(context)"
        }
        return category.rawValue
    }

    /// Short label for UI
    var label: String {
        category.rawValue
    }

    /// Percentile description if available
    var percentileDescription: String? {
        guard let p = percentile else { return nil }
        return "\(p)th percentile for your age"
    }
}

enum FitnessCategory: String {
    case superior = "Superior"
    case excellent = "Excellent"
    case good = "Good"
    case fair = "Fair"
    case belowAverage = "Below Average"
    case poor = "Poor"
    case unknown = "Unknown"
}

struct VO2MaxInterpretation {
    let category: FitnessCategory
    let percentileRange: String?
    let ageContext: String?

    var fullDescription: String {
        var parts = [category.rawValue]
        if let range = percentileRange {
            parts.append("(\(range))")
        }
        if let context = ageContext {
            parts.append(context)
        }
        return parts.joined(separator: " ")
    }
}
