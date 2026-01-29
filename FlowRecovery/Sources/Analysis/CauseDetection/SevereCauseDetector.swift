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

/// Detects severe anomalies and critical health signals
/// Single Responsibility: only handles critical/severe conditions
final class SevereCauseDetector: CauseDetectionStrategy {

    func detectCauses(in context: CauseDetectionContext) -> [DetectedCause] {
        // Skip severe detection for good readings
        if context.isGoodReading || context.isExcellentReading {
            return []
        }

        var causes: [DetectedCause] = []

        causes.append(contentsOf: detectHRVCrash(in: context))
        causes.append(contentsOf: detectElevatedHRWithLowHRV(in: context))

        return causes
    }

    // MARK: - Private Detection Methods

    private func detectHRVCrash(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        let stats = context.trendStats

        guard stats.hasData && stats.sessionCount >= 3 else {
            return causes
        }

        let deviationPercent = ((context.rmssd - stats.avgRMSSD) / stats.avgRMSSD) * 100

        // Severe HRV crash (>50% below average)
        if deviationPercent < HRVThresholds.illnessSevereHRVCrash {
            causes.append(DetectedCause(
                cause: "Severe HRV Crash",
                confidence: .critical,
                explanation: "Your HRV (\(Int(context.rmssd))ms) is \(String(format: "%.0f", abs(deviationPercent)))% below your average (\(String(format: "%.0f", stats.avgRMSSD))ms). This level of suppression indicates a serious stressor — likely acute illness, severe sleep deprivation, or extreme physical/emotional strain. Consider staying home and monitoring for symptoms.",
                weight: 0.99
            ))
        }
        // Major HRV drop (>30% below average)
        else if deviationPercent < HRVThresholds.illnessMajorHRVDrop {
            causes.append(DetectedCause(
                cause: "Major HRV Drop",
                confidence: .veryHigh,
                explanation: "Your HRV is \(String(format: "%.0f", abs(deviationPercent)))% below your baseline (\(Int(context.rmssd))ms vs \(String(format: "%.0f", stats.avgRMSSD))ms average). This significant deviation suggests your body is under substantial stress. Take it very easy today.",
                weight: 0.92
            ))
        }

        return causes
    }

    private func detectElevatedHRWithLowHRV(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []
        let stats = context.trendStats

        guard stats.hasData, let baselineHR = stats.baselineHR else {
            return causes
        }

        let hrElevation = stats.avgHR - baselineHR
        let hrvSuppressed = context.rmssd < stats.avgRMSSD * 0.8

        if hrElevation > HRVThresholds.hrSignificantElevation && hrvSuppressed {
            causes.append(DetectedCause(
                cause: "Elevated HR + Low HRV",
                confidence: .high,
                explanation: "Your resting HR is \(String(format: "%.0f", hrElevation)) bpm above baseline while HRV is suppressed. This combination is a strong indicator of immune activation, illness onset, or severe fatigue.",
                weight: 0.85
            ))
        }

        return causes
    }
}
