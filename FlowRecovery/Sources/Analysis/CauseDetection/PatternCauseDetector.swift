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

/// Detects causes based on historical patterns (day-of-week, etc.)
/// Single Responsibility: only handles pattern-based cause detection
final class PatternCauseDetector: CauseDetectionStrategy {

    func detectCauses(in context: CauseDetectionContext) -> [DetectedCause] {
        // Skip for good readings
        if context.isGoodReading || context.isExcellentReading {
            return []
        }

        var causes: [DetectedCause] = []

        causes.append(contentsOf: detectDayOfWeekPattern(in: context))

        return causes
    }

    // MARK: - Day of Week Pattern

    private func detectDayOfWeekPattern(in context: CauseDetectionContext) -> [DetectedCause] {
        var causes: [DetectedCause] = []

        guard let dayImpact = calculateDayOfWeekImpact(in: context) else {
            return causes
        }

        let significantImpact = dayImpact.impact > 0.15

        if significantImpact && dayImpact.isLowDay && context.rmssd < HRVThresholds.rmssdGood {
            let context = dayImpact.dayName == "Monday" ? "weekend" : "mid-week"

            causes.append(DetectedCause(
                cause: "\(dayImpact.dayName) Pattern",
                confidence: .low,
                explanation: "Historically, your HRV tends to be \(Int(dayImpact.impact * 100))% lower on \(dayImpact.dayName)s. Consider your typical \(context) activities.",
                weight: 0.3
            ))
        }

        return causes
    }

    private func calculateDayOfWeekImpact(in context: CauseDetectionContext) -> DayOfWeekImpact? {
        let recentSessions = context.recentSessions

        guard recentSessions.count >= 14 else {
            return nil
        }

        let calendar = Calendar.current
        var dayAverages: [Int: [Double]] = [:]

        for session in recentSessions {
            guard let rmssd = session.analysisResult?.timeDomain.rmssd else { continue }
            let day = calendar.component(.weekday, from: session.startDate)
            dayAverages[day, default: []].append(rmssd)
        }

        let validDays = dayAverages.filter { $0.value.count >= 2 }
        guard validDays.count >= 3 else {
            return nil
        }

        let allValues = validDays.values.flatMap { $0 }
        let overallAvg = allValues.reduce(0, +) / Double(allValues.count)

        let today = calendar.component(.weekday, from: context.session.startDate)
        guard let todayReadings = dayAverages[today], todayReadings.count >= 2 else {
            return nil
        }

        let todayAvg = todayReadings.reduce(0, +) / Double(todayReadings.count)
        let impact = (overallAvg - todayAvg) / overallAvg

        let dayNames = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return DayOfWeekImpact(
            dayName: dayNames[today],
            impact: abs(impact),
            isLowDay: impact > 0
        )
    }
}

// MARK: - Supporting Types

private struct DayOfWeekImpact {
    let dayName: String
    let impact: Double
    let isLowDay: Bool
}
