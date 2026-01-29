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

/// A detected probable cause with confidence level and explanation
struct DetectedCause {
    let cause: String
    let confidence: CauseConfidence
    let explanation: String
    let weight: Double

    enum CauseConfidence: String {
        case critical = "Critical"
        case veryHigh = "Very High"
        case high = "High"
        case moderateHigh = "Moderate-High"
        case moderate = "Moderate"
        case lowModerate = "Low-Moderate"
        case low = "Low"
        case pattern = "Pattern"
        case contributingFactor = "Contributing Factor"
        case goodSign = "Good Sign"
        case excellent = "Excellent"
    }
}

/// Context containing all data needed for cause detection
struct CauseDetectionContext {
    let rmssd: Double
    let stressIndex: Double
    let lfHfRatio: Double
    let dfaAlpha1: Double
    let pnn50: Double
    let isGoodReading: Bool
    let isExcellentReading: Bool
    let selectedTags: Set<ReadingTag>
    let trendStats: AnalysisSummaryGenerator.TrendStats
    let sleepInput: AnalysisSummaryGenerator.SleepInput
    let sleepTrend: AnalysisSummaryGenerator.SleepTrendInput?
    let session: HRVSession
    let recentSessions: [HRVSession]

    var isShortSleep: Bool { sleepInput.isShortSleep }
    var isGoodSleep: Bool { sleepInput.isGoodSleep }
    var isFragmented: Bool { sleepInput.isFragmented }
}

/// Protocol for cause detection strategies
/// Following Open/Closed Principle: open for extension, closed for modification
protocol CauseDetectionStrategy {
    /// Detect causes related to this strategy's domain
    func detectCauses(in context: CauseDetectionContext) -> [DetectedCause]
}

/// Aggregates all cause detection strategies and returns combined results
final class CauseDetector {

    private let strategies: [CauseDetectionStrategy]

    /// Initialize with default strategies
    init() {
        self.strategies = [
            PositiveCauseDetector(),
            SevereCauseDetector(),
            TagBasedCauseDetector(),
            SleepCauseDetector(),
            MetricBasedCauseDetector(),
            PatternCauseDetector()
        ]
    }

    /// Initialize with custom strategies (useful for testing)
    init(strategies: [CauseDetectionStrategy]) {
        self.strategies = strategies
    }

    /// Detect all probable causes and return top results
    func detectCauses(in context: CauseDetectionContext, limit: Int = 3) -> [DetectedCause] {
        var allCauses: [DetectedCause] = []

        for strategy in strategies {
            let causes = strategy.detectCauses(in: context)
            allCauses.append(contentsOf: causes)
        }

        // Sort by weight (highest first) and return top results
        return Array(allCauses.sorted { $0.weight > $1.weight }.prefix(limit))
    }
}

// MARK: - Helper Extensions

extension DetectedCause {
    /// Convert to the format expected by AnalysisSummaryGenerator
    func toProbableCause() -> AnalysisSummaryGenerator.ProbableCause {
        AnalysisSummaryGenerator.ProbableCause(
            cause: cause,
            confidence: confidence.rawValue,
            explanation: explanation
        )
    }
}
