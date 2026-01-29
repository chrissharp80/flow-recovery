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

/// Protocol for computing diagnostic scores from HRV analysis results
/// Following Single Responsibility Principle: scoring logic is separate from reporting
protocol DiagnosticScoring {
    func computeScore(from metrics: DiagnosticMetrics) -> DiagnosticResult
}

/// Input metrics required for diagnostic scoring
struct DiagnosticMetrics {
    let rmssd: Double
    let stressIndex: Double?
    let lfHfRatio: Double?
    let dfaAlpha1: Double?
    let isConsolidated: Bool

    init(from result: HRVAnalysisResult) {
        self.rmssd = result.timeDomain.rmssd
        self.stressIndex = result.ansMetrics?.stressIndex
        self.lfHfRatio = result.frequencyDomain?.lfHfRatio
        self.dfaAlpha1 = result.nonlinear.dfaAlpha1
        self.isConsolidated = result.isConsolidated ?? false
    }

    init(rmssd: Double, stressIndex: Double? = nil, lfHfRatio: Double? = nil,
         dfaAlpha1: Double? = nil, isConsolidated: Bool = false) {
        self.rmssd = rmssd
        self.stressIndex = stressIndex
        self.lfHfRatio = lfHfRatio
        self.dfaAlpha1 = dfaAlpha1
        self.isConsolidated = isConsolidated
    }
}

/// Output of diagnostic scoring
struct DiagnosticResult {
    let score: Double
    let title: String
    let icon: String
    let status: RecoveryStatus

    enum RecoveryStatus: String {
        case wellRecovered = "Well Recovered"
        case adequateRecovery = "Adequate Recovery"
        case incompleteRecovery = "Incomplete Recovery"
        case significantStress = "Significant Stress Load"
        case recoveryNeeded = "Recovery Needed"
    }
}

/// Default implementation of diagnostic scoring
/// Uses evidence-based thresholds for HRV interpretation
final class DiagnosticScorer: DiagnosticScoring {

    private let config: DiagnosticScoringConfig

    init(config: DiagnosticScoringConfig = .default) {
        self.config = config
    }

    func computeScore(from metrics: DiagnosticMetrics) -> DiagnosticResult {
        let score = calculateScore(from: metrics)
        let status = determineStatus(from: score)
        let title = status.rawValue
        let icon = determineIcon(for: status)

        return DiagnosticResult(
            score: score,
            title: title,
            icon: icon,
            status: status
        )
    }

    // MARK: - Private Methods

    private func calculateScore(from metrics: DiagnosticMetrics) -> Double {
        var score = config.baseScore

        score += rmssdContribution(metrics.rmssd)
        score += stressContribution(metrics.stressIndex)
        score += lfHfContribution(metrics.lfHfRatio)
        score += dfaContribution(metrics.dfaAlpha1)

        return clampScore(score)
    }

    private func rmssdContribution(_ rmssd: Double) -> Double {
        switch rmssd {
        case 60...:
            return config.rmssdScores.excellent
        case 45..<60:
            return config.rmssdScores.good
        case 30..<45:
            return config.rmssdScores.moderate
        case 20..<30:
            return config.rmssdScores.reduced
        default:
            return config.rmssdScores.low
        }
    }

    private func stressContribution(_ stress: Double?) -> Double {
        guard let stress = stress else { return 0 }

        switch stress {
        case ..<100:
            return config.stressScores.veryLow
        case 100..<150:
            return config.stressScores.low
        case 150..<200:
            return config.stressScores.moderate
        case 200..<300:
            return config.stressScores.elevated
        default:
            return config.stressScores.high
        }
    }

    private func lfHfContribution(_ ratio: Double?) -> Double {
        guard let ratio = ratio else { return 0 }

        switch ratio {
        case 0.5...2.0:
            return config.lfHfScores.optimal
        case ..<0.5:
            return config.lfHfScores.parasympathetic
        case 2.0...3.0:
            return config.lfHfScores.mildSymapthetic
        default:
            return config.lfHfScores.highSympathetic
        }
    }

    private func dfaContribution(_ alpha1: Double?) -> Double {
        guard let alpha1 = alpha1 else { return 0 }

        switch alpha1 {
        case 0.75...1.0:
            return config.dfaScores.optimal
        case 1.0...1.15:
            return config.dfaScores.acceptable
        default:
            return config.dfaScores.elevated
        }
    }

    private func clampScore(_ score: Double) -> Double {
        min(100, max(0, score))
    }

    private func determineStatus(from score: Double) -> DiagnosticResult.RecoveryStatus {
        switch score {
        case HRVThresholds.scoreWellRecovered...:
            return .wellRecovered
        case HRVThresholds.scoreAdequateRecovery..<HRVThresholds.scoreWellRecovered:
            return .adequateRecovery
        case HRVThresholds.scoreIncompleteRecovery..<HRVThresholds.scoreAdequateRecovery:
            return .incompleteRecovery
        case HRVThresholds.scoreSignificantStress..<HRVThresholds.scoreIncompleteRecovery:
            return .significantStress
        default:
            return .recoveryNeeded
        }
    }

    private func determineIcon(for status: DiagnosticResult.RecoveryStatus) -> String {
        switch status {
        case .wellRecovered:
            return "checkmark.circle.fill"
        case .adequateRecovery:
            return "hand.thumbsup.fill"
        case .incompleteRecovery, .significantStress:
            return "exclamationmark.triangle.fill"
        case .recoveryNeeded:
            return "bed.double.fill"
        }
    }
}
