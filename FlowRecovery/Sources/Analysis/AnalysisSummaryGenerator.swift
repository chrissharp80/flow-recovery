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

/// Shared analysis summary generator used by both MorningResultsView and PDFReportGenerator
/// This ensures the PDF contains 100% of the same analysis content as the app
final class AnalysisSummaryGenerator {

    // MARK: - Output Models

    struct AnalysisSummary {
        let diagnosticTitle: String
        let diagnosticIcon: String
        let diagnosticScore: Double
        let diagnosticExplanation: String
        let probableCauses: [ProbableCause]
        let keyFindings: [String]
        let actionableSteps: [String]
        let trendInsight: String
    }

    struct ProbableCause {
        let cause: String
        let confidence: String
        let explanation: String
    }

    struct TrendStats {
        let hasData: Bool
        let avgRMSSD: Double
        let baselineRMSSD: Double?
        let avgHR: Double
        let baselineHR: Double?
        let avgStress: Double?
        let baselineStress: Double?
        let avgReadiness: Double?
        let sessionCount: Int
        let daySpan: Int
        let trend7Day: Double?
        let trend30Day: Double?

        static let empty = TrendStats(
            hasData: false, avgRMSSD: 0, baselineRMSSD: nil, avgHR: 0,
            baselineHR: nil, avgStress: nil, baselineStress: nil,
            avgReadiness: nil, sessionCount: 0, daySpan: 0,
            trend7Day: nil, trend30Day: nil
        )
    }

    struct SleepInput {
        let totalSleepMinutes: Int
        let inBedMinutes: Int
        let deepSleepMinutes: Int?
        let remSleepMinutes: Int?
        let awakeMinutes: Int
        let sleepEfficiency: Double

        var totalSleepFormatted: String {
            let hours = totalSleepMinutes / 60
            let mins = totalSleepMinutes % 60
            return hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
        }

        var isShortSleep: Bool { totalSleepMinutes > 0 && totalSleepMinutes < 300 }
        var isGoodSleep: Bool { totalSleepMinutes >= 420 }
        var isFragmented: Bool { awakeMinutes > 30 }

        static let empty = SleepInput(
            totalSleepMinutes: 0, inBedMinutes: 0,
            deepSleepMinutes: nil, remSleepMinutes: nil,
            awakeMinutes: 0, sleepEfficiency: 0
        )

        init(totalSleepMinutes: Int, inBedMinutes: Int, deepSleepMinutes: Int?, remSleepMinutes: Int?, awakeMinutes: Int, sleepEfficiency: Double) {
            self.totalSleepMinutes = totalSleepMinutes
            self.inBedMinutes = inBedMinutes
            self.deepSleepMinutes = deepSleepMinutes
            self.remSleepMinutes = remSleepMinutes
            self.awakeMinutes = awakeMinutes
            self.sleepEfficiency = sleepEfficiency
        }

        init(from healthKit: HealthKitManager.SleepData?) {
            guard let hk = healthKit else {
                self = .empty
                return
            }
            self.totalSleepMinutes = hk.totalSleepMinutes
            self.inBedMinutes = hk.inBedMinutes
            self.deepSleepMinutes = hk.deepSleepMinutes
            self.remSleepMinutes = hk.remSleepMinutes
            self.awakeMinutes = hk.awakeMinutes
            self.sleepEfficiency = hk.sleepEfficiency
        }
    }

    struct SleepTrendInput {
        let averageSleepMinutes: Double
        let averageDeepSleepMinutes: Double?
        let averageEfficiency: Double
        let trend: SleepTrend
        let nightsAnalyzed: Int

        enum SleepTrend: String {
            case improving, declining, stable, insufficient
        }

        var averageSleepFormatted: String {
            let hours = Int(averageSleepMinutes) / 60
            let mins = Int(averageSleepMinutes) % 60
            return hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
        }

        static let empty = SleepTrendInput(
            averageSleepMinutes: 0, averageDeepSleepMinutes: nil,
            averageEfficiency: 0, trend: .insufficient, nightsAnalyzed: 0
        )

        init(averageSleepMinutes: Double, averageDeepSleepMinutes: Double?, averageEfficiency: Double, trend: SleepTrend, nightsAnalyzed: Int) {
            self.averageSleepMinutes = averageSleepMinutes
            self.averageDeepSleepMinutes = averageDeepSleepMinutes
            self.averageEfficiency = averageEfficiency
            self.trend = trend
            self.nightsAnalyzed = nightsAnalyzed
        }

        init(from healthKit: HealthKitManager.SleepTrendStats?) {
            guard let hk = healthKit else {
                self = .empty
                return
            }
            self.averageSleepMinutes = hk.averageSleepMinutes
            self.averageDeepSleepMinutes = hk.averageDeepSleepMinutes
            self.averageEfficiency = hk.averageEfficiency
            self.nightsAnalyzed = hk.nightsAnalyzed
            switch hk.trend {
            case .improving: self.trend = .improving
            case .declining: self.trend = .declining
            case .stable: self.trend = .stable
            case .insufficient: self.trend = .insufficient
            }
        }
    }

    // MARK: - Input

    private let result: HRVAnalysisResult
    private let session: HRVSession
    private let recentSessions: [HRVSession]
    private let selectedTags: Set<ReadingTag>
    private let sleep: SleepInput
    private let sleepTrend: SleepTrendInput?

    // Computed once
    private lazy var stats: TrendStats = computeTrendStats()

    // MARK: - Init

    init(result: HRVAnalysisResult,
         session: HRVSession,
         recentSessions: [HRVSession] = [],
         selectedTags: Set<ReadingTag> = [],
         sleep: SleepInput = .empty,
         sleepTrend: SleepTrendInput? = nil) {
        self.result = result
        self.session = session
        self.recentSessions = recentSessions
        self.selectedTags = selectedTags
        self.sleep = sleep
        self.sleepTrend = sleepTrend
    }

    // MARK: - Public API

    func generate() -> AnalysisSummary {
        return AnalysisSummary(
            diagnosticTitle: diagnosticTitle,
            diagnosticIcon: diagnosticIcon,
            diagnosticScore: computeDiagnosticScore(),
            diagnosticExplanation: diagnosticExplanation,
            probableCauses: probableCauses,
            keyFindings: keyFindings,
            actionableSteps: actionableSteps,
            trendInsight: trendInsight
        )
    }

    // MARK: - Trend Stats Computation

    private func computeTrendStats() -> TrendStats {
        let validSessions = recentSessions.filter { $0.state == .complete && $0.analysisResult != nil }
        guard validSessions.count >= 2 else {
            return TrendStats.empty
        }

        let rmssdValues = validSessions.compactMap { $0.analysisResult?.timeDomain.rmssd }
        let hrValues = validSessions.compactMap { $0.analysisResult?.timeDomain.meanHR }
        let stressValues = validSessions.compactMap { $0.analysisResult?.ansMetrics?.stressIndex }
        let readinessValues = validSessions.compactMap { $0.analysisResult?.ansMetrics?.readinessScore }

        let avgRMSSD = rmssdValues.isEmpty ? 0 : rmssdValues.reduce(0, +) / Double(rmssdValues.count)
        let avgHR = hrValues.isEmpty ? 0 : hrValues.reduce(0, +) / Double(hrValues.count)
        let avgStress = stressValues.isEmpty ? nil : stressValues.reduce(0, +) / Double(stressValues.count)
        let avgReadiness = readinessValues.isEmpty ? nil : readinessValues.reduce(0, +) / Double(readinessValues.count)

        let morningReadings = validSessions.filter { $0.tags.contains { $0.name == "Morning" } }
        let baselineSessions = morningReadings.isEmpty ? validSessions : morningReadings
        let baselineRMSSD = baselineSessions.count >= 3 ? baselineSessions.suffix(5).compactMap { $0.analysisResult?.timeDomain.rmssd }.reduce(0, +) / Double(min(5, baselineSessions.count)) : nil
        let baselineHR = baselineSessions.count >= 3 ? baselineSessions.suffix(5).compactMap { $0.analysisResult?.timeDomain.meanHR }.reduce(0, +) / Double(min(5, baselineSessions.count)) : nil
        let baselineStress = baselineSessions.count >= 3 ? baselineSessions.suffix(5).compactMap { $0.analysisResult?.ansMetrics?.stressIndex }.reduce(0, +) / Double(min(5, baselineSessions.count)) : nil

        let dates = validSessions.map { $0.startDate }
        let daySpan = Calendar.current.dateComponents([.day], from: dates.min() ?? Date(), to: dates.max() ?? Date()).day ?? 0

        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let recentWeek = validSessions.filter { $0.startDate >= sevenDaysAgo }
        let olderWeek = validSessions.filter { $0.startDate < sevenDaysAgo }
        var trend7Day: Double?
        if recentWeek.count >= 2 && olderWeek.count >= 2 {
            let recentAvg = recentWeek.compactMap { $0.analysisResult?.timeDomain.rmssd }.reduce(0, +) / Double(recentWeek.count)
            let olderAvg = olderWeek.compactMap { $0.analysisResult?.timeDomain.rmssd }.reduce(0, +) / Double(olderWeek.count)
            if olderAvg > 0 {
                trend7Day = ((recentAvg - olderAvg) / olderAvg) * 100
            }
        }

        return TrendStats(
            hasData: true,
            avgRMSSD: avgRMSSD,
            baselineRMSSD: baselineRMSSD,
            avgHR: avgHR,
            baselineHR: baselineHR,
            avgStress: avgStress,
            baselineStress: baselineStress,
            avgReadiness: avgReadiness,
            sessionCount: validSessions.count,
            daySpan: daySpan,
            trend7Day: trend7Day,
            trend30Day: nil
        )
    }

    // MARK: - Age-Adjusted Interpretation

    /// Get age-adjusted HRV interpretation using user settings
    private var ageAdjustedInterpretation: RMSSDInterpretation {
        let settings = SettingsManager.shared.settings
        let sex: AgeAdjustedHRV.Sex? = {
            switch settings.biologicalSex {
            case .male: return .male
            case .female: return .female
            case .other, .none: return nil
            }
        }()
        return AgeAdjustedHRV.interpret(rmssd: result.timeDomain.rmssd, age: settings.age, sex: sex)
    }

    // MARK: - Diagnostic Score

    private func computeDiagnosticScore() -> Double {
        var score = 50.0

        // Use age-adjusted interpretation for RMSSD scoring
        switch ageAdjustedInterpretation.category {
        case .excellent: score += 40
        case .good: score += 30
        case .fair: score += 20
        case .reduced: score += 10
        case .low: score -= 10
        }

        if let stress = result.ansMetrics?.stressIndex {
            if stress < 100 { score += 20 }
            else if stress < 150 { score += 15 }
            else if stress < 200 { score += 10 }
            else if stress < 300 { score += 0 }
            else { score -= 15 }
        }

        if let ratio = result.frequencyDomain?.lfHfRatio {
            if ratio >= 0.5 && ratio <= 2.0 { score += 20 }
            else if ratio < 0.5 { score += 15 }
            else if ratio <= 3.0 { score += 5 }
            else { score -= 10 }
        }

        if let dfa = result.nonlinear.dfaAlpha1 {
            if dfa >= 0.75 && dfa <= 1.0 { score += 20 }
            else if dfa > 1.0 && dfa <= 1.15 { score += 10 }
            else { score += 0 }
        }

        // ANS Balance contribution - penalize sympathetic dominance
        if let sns = result.ansMetrics?.snsIndex, let pns = result.ansMetrics?.pnsIndex {
            let balance = pns - sns  // Positive = parasympathetic dominant
            if balance >= 1.0 { score += 15 }
            else if balance >= 0 { score += 10 }
            else if balance >= -1.0 { score -= 5 }
            else { score -= 15 }
        }

        return min(100, max(0, score))
    }

    // MARK: - Diagnostic Title, Icon, Color

    private var diagnosticTitle: String {
        let score = computeDiagnosticScore()
        if score >= 80 { return "Well Recovered" }
        if score >= 60 { return "Adequate Recovery" }
        if score >= 40 { return "Incomplete Recovery" }
        if score >= 20 { return "Significant Stress Load" }
        return "Recovery Needed"
    }

    private var diagnosticIcon: String {
        let score = computeDiagnosticScore()
        if score >= 80 { return "checkmark.circle.fill" }
        if score >= 60 { return "hand.thumbsup.fill" }
        if score >= 40 { return "exclamationmark.triangle.fill" }
        return "bed.double.fill"
    }

    // MARK: - Diagnostic Explanation

    private var diagnosticExplanation: String {
        let rmssd = result.timeDomain.rmssd
        let stress = result.ansMetrics?.stressIndex ?? 150
        let lfhf = result.frequencyDomain?.lfHfRatio ?? 1.0
        let dfa = result.nonlinear.dfaAlpha1 ?? 1.0

        var explanation = ""
        let interpretation = ageAdjustedInterpretation
        let ageNote = interpretation.ageContext.map { " (\($0))" } ?? ""

        let isShortSleep = sleep.isShortSleep
        let isGoodSleep = sleep.isGoodSleep
        let isFragmented = sleep.isFragmented
        let sleepFormatted = sleep.totalSleepFormatted

        var sleepContext = ""
        if sleep.totalSleepMinutes > 0 {
            if isShortSleep {
                sleepContext = " Your short sleep (\(sleepFormatted)) is likely a major contributor."
            } else if isFragmented {
                sleepContext = " Fragmented sleep (\(sleep.awakeMinutes) min awake) may be reducing recovery quality."
            } else if sleep.sleepEfficiency < 75 {
                sleepContext = " Low sleep efficiency (\(Int(sleep.sleepEfficiency))%) limits restorative recovery."
            }
        }

        switch interpretation.category {
        case .low:
            explanation = "Your HRV is low at \(Int(rmssd))ms\(ageNote). "
            if isShortSleep {
                explanation += "With only \(sleepFormatted) of sleep, your body hasn't had adequate time to recover. This is the most likely explanation for your low HRV."
            } else if stress > 300 {
                explanation += "Combined with high stress markers, this pattern is often seen with: acute illness coming on, severe sleep deprivation, or intense accumulated physical/mental strain.\(sleepContext)"
            } else if lfhf > 3 {
                explanation += "Your nervous system is in fight-or-flight mode. This can indicate mental/emotional stress, poor sleep quality, or your body fighting off infection.\(sleepContext)"
            } else {
                explanation += "This suggests your parasympathetic (rest-and-digest) system is suppressed. Common causes include overtraining, chronic stress, or early illness.\(sleepContext)"
            }

        case .reduced:
            explanation = "Your HRV is reduced at \(Int(rmssd))ms\(ageNote). "
            if isShortSleep {
                explanation += "Your short sleep duration (\(sleepFormatted)) is likely contributing to incomplete recovery."
            } else if isFragmented {
                explanation += "Fragmented sleep (\(sleep.awakeMinutes) min awake) may be preventing deep recovery even with adequate duration."
            } else if dfa > 1.2 {
                explanation += "The reduced complexity in your heart rhythm suggests fatigue or incomplete recovery from recent demands.\(sleepContext)"
            } else if stress > 200 {
                explanation += "Elevated stress markers suggest your body is working harder than usual to maintain balance.\(sleepContext)"
            } else {
                explanation += "This may indicate accumulated fatigue, mild dehydration, or the early stages of fighting off illness.\(sleepContext)"
            }

        case .excellent:
            let isConsolidated = result.isConsolidated ?? false
            explanation = "Your HRV of \(Int(rmssd))ms indicates strong vagal tone and excellent recovery capacity\(ageNote). "
            if isGoodSleep && !isFragmented && isConsolidated {
                explanation += "Quality sleep (\(sleepFormatted)) combined with stable, sustained recovery patterns means you're fully ready for demands."
            } else if isShortSleep {
                explanation += "However, with only \(sleepFormatted) of sleep, this represents capacity rather than full load-bearing readiness."
            } else if !isConsolidated {
                explanation += "The pattern shows capacity but wasn't sustained long enough to confirm full readiness. Listen to your body."
            } else if stress < 100 {
                explanation += "Low stress markers confirm your nervous system is well-balanced and recovery is consolidated."
            } else {
                explanation += "Your parasympathetic system is active and healthy."
            }

        case .good:
            explanation = "Your HRV of \(Int(rmssd))ms is good\(ageNote). "
            if isGoodSleep && !isFragmented {
                explanation += "Combined with quality sleep, you're well-positioned for activity today."
            } else if isShortSleep {
                explanation += "With better sleep, you could see even stronger recovery."
            } else {
                explanation += "Your autonomic nervous system is well-balanced."
            }

        case .fair:
            explanation = "Your HRV of \(Int(rmssd))ms is in a moderate range\(ageNote). "
            if isShortSleep {
                explanation += "With only \(sleepFormatted) of sleep, your HRV may improve with better rest."
            } else if lfhf > 2 {
                explanation += "There's some sympathetic activation present, which could be residual from yesterday's activities or mild ongoing stress.\(sleepContext)"
            } else {
                explanation += "Your autonomic nervous system is reasonably balanced."
            }
        }

        return explanation
    }

    // MARK: - Probable Causes

    private var probableCauses: [ProbableCause] {
        var causes: [(cause: ProbableCause, weight: Double)] = []

        let rmssd = result.timeDomain.rmssd
        let stress = result.ansMetrics?.stressIndex ?? 150
        let lfhf = result.frequencyDomain?.lfHfRatio ?? 1.0
        let dfa = result.nonlinear.dfaAlpha1 ?? 1.0
        let pnn50 = result.timeDomain.pnn50

        let isGoodReading = rmssd >= 40 && stress < 200 && lfhf < 2.5 && dfa < 1.2
        let isExcellentReading = stats.hasData && rmssd > stats.avgRMSSD * 1.15

        let tagImpact = calculateTagImpact()

        // === POSITIVE INSIGHTS ===
        if isGoodReading || isExcellentReading {
            // HealthKit sleep - positive factors
            if sleep.totalSleepMinutes >= 420 {
                let hours = Double(sleep.totalSleepMinutes) / 60.0
                causes.append((ProbableCause(
                    cause: "Solid Sleep",
                    confidence: "Contributing Factor",
                    explanation: "HealthKit shows \(String(format: "%.1f", hours)) hours of sleep. Getting 7+ hours is strongly associated with elevated HRV and better recovery."
                ), 0.8))
            }

            if sleep.sleepEfficiency >= 90 {
                causes.append((ProbableCause(
                    cause: "Excellent Sleep Quality",
                    confidence: "Contributing Factor",
                    explanation: "HealthKit shows \(Int(sleep.sleepEfficiency))% sleep efficiency — minimal awakenings. Uninterrupted sleep allows full parasympathetic restoration."
                ), 0.75))
            }

            if let deepMins = sleep.deepSleepMinutes, sleep.totalSleepMinutes > 0 {
                let deepPercent = Double(deepMins) / Double(sleep.totalSleepMinutes) * 100
                if deepPercent >= 20 {
                    causes.append((ProbableCause(
                        cause: "Strong Deep Sleep",
                        confidence: "Contributing Factor",
                        explanation: "\(deepMins) minutes of deep sleep (\(Int(deepPercent))%). Deep sleep is when HRV peaks and the nervous system fully recovers."
                    ), 0.7))
                }
            }

            if selectedTags.contains(where: { $0.name == "Good Sleep" }) {
                causes.append((ProbableCause(
                    cause: "Restful Night",
                    confidence: "High",
                    explanation: "You reported good sleep. Quality sleep is the #1 factor in HRV recovery."
                ), 0.85))
            }

            if selectedTags.contains(where: { $0.name == "Rest Day" }) {
                causes.append((ProbableCause(
                    cause: "Recovery Day",
                    confidence: "Moderate-High",
                    explanation: "Rest days allow accumulated training stress to dissipate, often resulting in HRV rebound."
                ), 0.7))
            }

            if stats.hasData && stats.sessionCount >= 5 {
                if let trend = stats.trend7Day, trend > 10 {
                    causes.append((ProbableCause(
                        cause: "Upward Trend",
                        confidence: "Pattern",
                        explanation: "Your HRV has been climbing over the past week (+\(String(format: "%.0f", trend))%). Whatever you're doing is working — keep it up."
                    ), 0.65))
                }

                if rmssd > stats.avgRMSSD * 1.2 {
                    causes.append((ProbableCause(
                        cause: "Above Your Baseline",
                        confidence: "Excellent",
                        explanation: "Today's HRV (\(Int(rmssd))ms) is \(String(format: "%.0f", ((rmssd - stats.avgRMSSD) / stats.avgRMSSD) * 100))% above your average of \(String(format: "%.0f", stats.avgRMSSD))ms. Your body is well-recovered and ready for challenges."
                    ), 0.8))
                }
            }

            if stats.hasData, let baselineHR = stats.baselineHR {
                let hrDrop = baselineHR - result.timeDomain.meanHR
                if hrDrop > 5 {
                    causes.append((ProbableCause(
                        cause: "Low Resting HR",
                        confidence: "Good Sign",
                        explanation: "Resting HR is \(String(format: "%.0f", hrDrop)) bpm below your baseline — indicates strong parasympathetic activity and cardiovascular efficiency."
                    ), 0.6))
                }
            }

            if !causes.isEmpty {
                causes.sort { $0.weight > $1.weight }
                return Array(causes.prefix(3).map { $0.cause })
            }

            return []
        }

        // === SEVERE ANOMALY DETECTION ===
        if stats.hasData && stats.sessionCount >= 3 {
            let deviationPercent = ((rmssd - stats.avgRMSSD) / stats.avgRMSSD) * 100

            if deviationPercent < -50 {
                causes.append((ProbableCause(
                    cause: "Severe HRV Crash",
                    confidence: "Critical",
                    explanation: "Your HRV (\(Int(rmssd))ms) is \(String(format: "%.0f", abs(deviationPercent)))% below your average (\(String(format: "%.0f", stats.avgRMSSD))ms). This level of suppression indicates a serious stressor — likely acute illness, severe sleep deprivation, or extreme physical/emotional strain. Consider staying home and monitoring for symptoms."
                ), 0.99))
            } else if deviationPercent < -30 {
                causes.append((ProbableCause(
                    cause: "Major HRV Drop",
                    confidence: "Very High",
                    explanation: "Your HRV is \(String(format: "%.0f", abs(deviationPercent)))% below your baseline (\(Int(rmssd))ms vs \(String(format: "%.0f", stats.avgRMSSD))ms average). This significant deviation suggests your body is under substantial stress. Take it very easy today."
                ), 0.92))
            }

            if let baselineHR = stats.baselineHR {
                let hrElevation = result.timeDomain.meanHR - baselineHR
                if hrElevation > 8 && rmssd < stats.avgRMSSD * 0.8 {
                    causes.append((ProbableCause(
                        cause: "Elevated HR + Low HRV",
                        confidence: "High",
                        explanation: "Your resting HR is \(String(format: "%.0f", hrElevation)) bpm above baseline while HRV is suppressed. This combination is a strong indicator of immune activation, illness onset, or severe fatigue."
                    ), 0.85))
                }
            }
        }

        // === TAG-BASED CAUSES ===
        if selectedTags.contains(where: { $0.name == "Alcohol" }) {
            let conf = rmssd < 30 ? "Very High" : "High"
            let boost = rmssd < 30 ? 0.95 : 0.85
            causes.append((ProbableCause(
                cause: "Alcohol Consumption",
                confidence: conf,
                explanation: "You tagged alcohol. Even moderate drinking suppresses HRV for 24-48 hours by disrupting sleep architecture and increasing sympathetic tone."
            ), boost))
        } else if let alcoholImpact = tagImpact["Alcohol"], alcoholImpact > 0.3 {
            let dayOfWeek = Calendar.current.component(.weekday, from: session.startDate)
            if dayOfWeek == 1 || dayOfWeek == 7 {
                causes.append((ProbableCause(
                    cause: "Possible Alcohol Effect",
                    confidence: "Moderate",
                    explanation: "Your past readings with the alcohol tag averaged \(Int(alcoholImpact * 100))% lower HRV. Weekend timing + low reading suggests this might be a factor."
                ), 0.55))
            }
        }

        if selectedTags.contains(where: { $0.name == "Poor Sleep" }) {
            let conf = dfa > 1.15 ? "Very High" : "High"
            let boost = dfa > 1.15 ? 0.92 : 0.82
            causes.append((ProbableCause(
                cause: "Poor Sleep Quality",
                confidence: conf,
                explanation: "You tagged poor sleep. Sleep debt is one of the strongest suppressors of HRV. Your DFA α1 pattern confirms reduced recovery."
            ), boost))
        }

        if selectedTags.contains(where: { $0.name == "Late Meal" }) {
            causes.append((ProbableCause(
                cause: "Late Night Eating",
                confidence: "Moderate-High",
                explanation: "You tagged a late meal. Digestion during sleep elevates metabolism and heart rate, reducing vagal tone and HRV."
            ), 0.7))
        }

        if selectedTags.contains(where: { $0.name == "Caffeine" }) {
            causes.append((ProbableCause(
                cause: "Caffeine Effect",
                confidence: "Moderate",
                explanation: "You tagged caffeine. Caffeine's half-life is 5-6 hours—late consumption can disrupt deep sleep even if you fall asleep fine."
            ), 0.6))
        }

        if selectedTags.contains(where: { $0.name == "Travel" }) {
            causes.append((ProbableCause(
                cause: "Travel Stress / Jet Lag",
                confidence: "Moderate-High",
                explanation: "You tagged travel. Travel disrupts circadian rhythm, sleep, and hydration—all of which lower HRV."
            ), 0.75))
        }

        if selectedTags.contains(where: { $0.name == "Illness" }) {
            causes.append((ProbableCause(
                cause: "Active Illness",
                confidence: "Very High",
                explanation: "You tagged illness. Your immune system is active, which dramatically increases sympathetic tone and suppresses HRV."
            ), 0.98))
        }

        if selectedTags.contains(where: { $0.name == "Menstrual" }) {
            causes.append((ProbableCause(
                cause: "Menstrual Cycle Phase",
                confidence: "Moderate",
                explanation: "You tagged menstrual. HRV naturally varies across the cycle, often dipping during menstruation due to hormonal shifts."
            ), 0.6))
        }

        if selectedTags.contains(where: { $0.name == "Stressed" }) {
            let conf = lfhf > 2.5 ? "Very High" : "High"
            let boost = lfhf > 2.5 ? 0.9 : 0.8
            causes.append((ProbableCause(
                cause: "Psychological Stress",
                confidence: conf,
                explanation: "You tagged feeling stressed. Your LF/HF ratio confirms elevated sympathetic activity consistent with mental/emotional load."
            ), boost))
        }

        if selectedTags.contains(where: { $0.name == "Post-Exercise" }) {
            let conf = rmssd < 30 ? "High" : "Moderate"
            causes.append((ProbableCause(
                cause: "Exercise Recovery",
                confidence: conf,
                explanation: "You tagged post-exercise. HRV is suppressed for 24-72 hours after intense training while your body repairs and adapts."
            ), rmssd < 30 ? 0.85 : 0.65))
        }

        // === HEALTHKIT SLEEP DATA ===
        if sleep.totalSleepMinutes > 0 {
            if sleep.totalSleepMinutes < 360 {
                let conf = sleep.totalSleepMinutes < 300 ? "Very High" : "High"
                let weight = sleep.totalSleepMinutes < 300 ? 0.92 : 0.82
                let hours = Double(sleep.totalSleepMinutes) / 60.0
                causes.append((ProbableCause(
                    cause: "Insufficient Sleep",
                    confidence: conf,
                    explanation: "HealthKit shows only \(String(format: "%.1f", hours)) hours of sleep. Research shows HRV drops significantly with less than 7 hours. This is likely the primary factor."
                ), weight))
            }

            if sleep.sleepEfficiency < 80 && sleep.inBedMinutes > 300 {
                let conf = sleep.sleepEfficiency < 70 ? "High" : "Moderate-High"
                let weight = sleep.sleepEfficiency < 70 ? 0.78 : 0.65
                causes.append((ProbableCause(
                    cause: "Fragmented Sleep",
                    confidence: conf,
                    explanation: "HealthKit shows \(Int(sleep.sleepEfficiency))% sleep efficiency with \(sleep.awakeMinutes) minutes awake. Fragmented sleep reduces HRV even when total time is adequate."
                ), weight))
            }

            if let deepMins = sleep.deepSleepMinutes, deepMins < 45 && sleep.totalSleepMinutes > 300 {
                let deepPercent = Double(deepMins) / Double(sleep.totalSleepMinutes) * 100
                if deepPercent < 10 {
                    causes.append((ProbableCause(
                        cause: "Low Deep Sleep",
                        confidence: "Moderate-High",
                        explanation: "Only \(deepMins) minutes of deep sleep (\(Int(deepPercent))%). Deep sleep is when HRV-restoring parasympathetic activity peaks. Alcohol, late meals, and stress reduce deep sleep."
                    ), 0.7))
                }
            }

            if sleep.awakeMinutes > 30 && rmssd < 40 {
                causes.append((ProbableCause(
                    cause: "Frequent Awakenings",
                    confidence: "Moderate",
                    explanation: "HealthKit recorded \(sleep.awakeMinutes) minutes awake during sleep. Each awakening interrupts recovery cycles."
                ), 0.55))
            }

            // Sleep trend insights
            if let trends = sleepTrend, trends.nightsAnalyzed >= 3 {
                let avgHours = trends.averageSleepMinutes / 60.0
                let tonightHours = Double(sleep.totalSleepMinutes) / 60.0

                let sleepDiffPercent = trends.averageSleepMinutes > 0 ?
                    ((Double(sleep.totalSleepMinutes) - trends.averageSleepMinutes) / trends.averageSleepMinutes) * 100 : 0

                if sleepDiffPercent < -20 && rmssd < 45 {
                    causes.append((ProbableCause(
                        cause: "Below Your Sleep Average",
                        confidence: "High",
                        explanation: "Tonight's \(String(format: "%.1f", tonightHours))h is \(Int(abs(sleepDiffPercent)))% below your 7-day average of \(String(format: "%.1f", avgHours))h. Consistently getting less sleep than usual impacts HRV."
                    ), 0.75))
                }

                if trends.trend == .declining && rmssd < 40 {
                    causes.append((ProbableCause(
                        cause: "Declining Sleep Pattern",
                        confidence: "Moderate-High",
                        explanation: "Your sleep duration has been trending downward over the past week (avg \(trends.averageSleepFormatted)). Cumulative sleep debt suppresses HRV even before you feel tired."
                    ), 0.72))
                }

                if sleepDiffPercent > 20 && isGoodReading {
                    causes.append((ProbableCause(
                        cause: "Above Your Sleep Average",
                        confidence: "High",
                        explanation: "Tonight's \(String(format: "%.1f", tonightHours))h is \(Int(sleepDiffPercent))% above your recent average. Extra sleep pays immediate dividends in HRV recovery."
                    ), 0.78))
                }

                if trends.trend == .improving && isGoodReading {
                    causes.append((ProbableCause(
                        cause: "Improving Sleep Pattern",
                        confidence: "Moderate-High",
                        explanation: "Your sleep has been improving over the past week. Consistent sleep improvements compound - expect HRV to continue rising if you maintain this pattern."
                    ), 0.7))
                }
            }
        }

        // === METRIC-BASED CAUSES ===
        if !selectedTags.contains(where: { $0.name == "Illness" }) {
            let illnessSignals = detectIllnessPattern()

            if illnessSignals.consecutiveDeclines >= 3 && rmssd < 35 && stress > 200 {
                causes.append((ProbableCause(
                    cause: "Likely Getting Sick",
                    confidence: "High",
                    explanation: "Your HRV has declined for \(illnessSignals.consecutiveDeclines) consecutive days (\(String(format: "%.0f", illnessSignals.totalDeclinePercent))% total drop). This pattern strongly suggests your immune system is fighting something. Monitor closely for symptoms."
                ), 0.88))
            } else if illnessSignals.consecutiveDeclines >= 2 && (rmssd < 30 || illnessSignals.hrElevated) {
                var explanation = "Your HRV has dropped for \(illnessSignals.consecutiveDeclines) days in a row"
                if illnessSignals.hrElevated {
                    explanation += " and your resting HR is elevated (+\(String(format: "%.0f", illnessSignals.hrIncrease)) bpm)"
                }
                explanation += ". This often precedes illness symptoms by 1-2 days."
                causes.append((ProbableCause(
                    cause: "Possible Illness Coming On",
                    confidence: "Moderate-High",
                    explanation: explanation
                ), 0.72))
            } else if rmssd < 25 && stress > 250 {
                causes.append((ProbableCause(
                    cause: "Possible Immune Response",
                    confidence: "High",
                    explanation: "Very low HRV + high stress often precedes illness by 1-2 days. Monitor for symptoms."
                ), 0.75))
            } else if illnessSignals.hrElevated && stress > 200 && rmssd < 40 {
                causes.append((ProbableCause(
                    cause: "Elevated Resting HR",
                    confidence: "Moderate",
                    explanation: "Your resting HR is \(String(format: "%.0f", illnessSignals.hrIncrease)) bpm above your average. Combined with elevated stress, this can indicate your body is fighting something or under significant strain."
                ), 0.55))
            } else if rmssd < 30 && stress > 220 {
                causes.append((ProbableCause(
                    cause: "Possible Illness Coming On",
                    confidence: "Moderate",
                    explanation: "This pattern sometimes appears before cold/flu symptoms manifest."
                ), 0.45))
            }
        }

        if !selectedTags.contains(where: { $0.name == "Stressed" }) {
            if lfhf > 3.0 && stress > 200 {
                causes.append((ProbableCause(
                    cause: "Unidentified Stress",
                    confidence: "Moderate-High",
                    explanation: "High sympathetic activation without tagged cause. Consider what might be weighing on you mentally."
                ), 0.65))
            }
        }

        if !selectedTags.contains(where: { $0.name == "Poor Sleep" }) {
            if rmssd < 30 && dfa > 1.15 {
                causes.append((ProbableCause(
                    cause: "Possible Sleep Debt",
                    confidence: "Moderate",
                    explanation: "Reduced HRV with elevated DFA α1 is characteristic of insufficient sleep."
                ), 0.55))
            }
        }

        if !selectedTags.contains(where: { $0.name == "Post-Exercise" }) {
            if rmssd < 35 && pnn50 < 10 && dfa > 1.1 {
                causes.append((ProbableCause(
                    cause: "Accumulated Training Load",
                    confidence: "Low-Moderate",
                    explanation: "If you've been training hard recently, your body may need extra recovery time."
                ), 0.4))
            }
        }

        if rmssd < 35 && stress > 180 && lfhf < 2 {
            causes.append((ProbableCause(
                cause: "Dehydration or Fasting",
                confidence: "Low-Moderate",
                explanation: "Low HRV without strong sympathetic shift can indicate dehydration or low blood sugar."
            ), 0.35))
        }

        // Day of week patterns
        if let dayImpact = calculateDayOfWeekImpact(), dayImpact.impact > 0.15 {
            if dayImpact.isLowDay && rmssd < 40 {
                causes.append((ProbableCause(
                    cause: "\(dayImpact.dayName) Pattern",
                    confidence: "Low",
                    explanation: "Historically, your HRV tends to be \(Int(dayImpact.impact * 100))% lower on \(dayImpact.dayName)s. Consider your typical \(dayImpact.dayName == "Monday" ? "weekend" : "mid-week") activities."
                ), 0.3))
            }
        }

        causes.sort { $0.weight > $1.weight }
        return Array(causes.prefix(3).map { $0.cause })
    }

    // MARK: - Key Findings

    private var keyFindings: [String] {
        var findings: [String] = []

        let rmssd = result.timeDomain.rmssd
        let stress = result.ansMetrics?.stressIndex
        let lfhf = result.frequencyDomain?.lfHfRatio
        let dfa = result.nonlinear.dfaAlpha1
        let pnn50 = result.timeDomain.pnn50

        // TREND & BASELINE COMPARISONS FIRST
        if stats.hasData {
            let rmssdPct = ((rmssd - stats.avgRMSSD) / stats.avgRMSSD) * 100

            if rmssdPct > 20 {
                findings.append("HRV is significantly higher than your average of \(String(format: "%.0f", stats.avgRMSSD))ms (+\(String(format: "%.0f", rmssdPct))%) — excellent recovery today")
            } else if rmssdPct > 10 {
                findings.append("HRV is above your recent average of \(String(format: "%.0f", stats.avgRMSSD))ms (+\(String(format: "%.0f", rmssdPct))%) — good recovery")
            } else if rmssdPct < -20 {
                findings.append("HRV is significantly below your average of \(String(format: "%.0f", stats.avgRMSSD))ms (\(String(format: "%.0f", rmssdPct))%) — recovery may be compromised")
            } else if rmssdPct < -10 {
                findings.append("HRV is below your average of \(String(format: "%.0f", stats.avgRMSSD))ms (\(String(format: "%.0f", rmssdPct))%) — not fully recovered")
            }

            if let baseline = stats.baselineRMSSD {
                let baselineDiff = ((rmssd - baseline) / baseline) * 100
                if baselineDiff > 15 {
                    findings.append("You're \(String(format: "%.0f", baselineDiff))% above your personal baseline — you're in great shape")
                } else if baselineDiff < -15 {
                    findings.append("You're \(String(format: "%.0f", abs(baselineDiff)))% below your personal baseline")
                }
            }

            if let trend = stats.trend7Day {
                if trend > 10 {
                    findings.append("Your 7-day HRV trend is improving (+\(String(format: "%.0f", trend))%) — keep doing what you're doing!")
                } else if trend < -10 {
                    findings.append("Your 7-day HRV trend shows a decline (\(String(format: "%.0f", trend))%)")
                }
            }

            let hrDiff = result.timeDomain.meanHR - stats.avgHR
            if hrDiff > 5 {
                findings.append("Resting HR is elevated (+\(String(format: "%.0f", hrDiff)) bpm vs average) — possible stress or incomplete recovery")
            } else if hrDiff < -5 {
                findings.append("Resting HR is lower than average (\(String(format: "%.0f", abs(hrDiff))) bpm) — good cardiovascular state")
            }
        }

        // AGE-ADJUSTED HRV ASSESSMENT
        if findings.isEmpty {
            let interpretation = ageAdjustedInterpretation
            let ageContext = interpretation.ageContext.map { " — \($0)" } ?? ""
            switch interpretation.category {
            case .excellent:
                findings.append("HRV is excellent at \(Int(rmssd))ms\(ageContext)")
            case .good:
                findings.append("HRV is good at \(Int(rmssd))ms\(ageContext)")
            case .fair:
                findings.append("HRV is fair at \(Int(rmssd))ms\(ageContext)")
            case .reduced:
                findings.append("HRV is reduced at \(Int(rmssd))ms\(ageContext)")
            case .low:
                findings.append("HRV is low at \(Int(rmssd))ms\(ageContext)")
            }
        } else if let ageContext = ageAdjustedInterpretation.ageContext {
            // Add age context as supplementary finding if we have other trend-based findings
            findings.append("This reading is \(ageContext)")
        }

        // Stress finding
        // Scale: <50 low/relaxed, 50-150 normal, 150-300 elevated, >300 high
        if let s = stress {
            if s > 300 {
                findings.append("Stress index is high (\(Int(s))) - significant physiological load")
            } else if s > 150 {
                findings.append("Stress index is elevated (\(Int(s))) - moderate strain present")
            } else if s > 50 {
                findings.append("Stress index is normal (\(Int(s))) - within typical resting range")
            } else {
                findings.append("Stress index is low (\(Int(s))) - very relaxed state")
            }
        }

        // ANS balance
        if let ratio = lfhf {
            if ratio > 3 {
                findings.append("Strong sympathetic dominance (LF/HF \(String(format: "%.1f", ratio))) - fight-or-flight active")
            } else if ratio < 0.5 {
                findings.append("Parasympathetic dominance (LF/HF \(String(format: "%.1f", ratio))) - deep recovery state")
            } else if ratio >= 0.8 && ratio <= 1.5 {
                findings.append("Balanced autonomic state (LF/HF \(String(format: "%.1f", ratio)))")
            }
        }

        // DFA finding
        if let alpha = dfa {
            if alpha > 1.2 {
                findings.append("DFA α1 is elevated (\(String(format: "%.2f", alpha))) - suggests fatigue")
            } else if alpha >= 0.75 && alpha <= 1.0 {
                findings.append("DFA α1 is optimal (\(String(format: "%.2f", alpha))) - healthy heart rhythm complexity")
            }
        }

        // pNN50 finding
        if pnn50 < 5 {
            findings.append("Very low beat-to-beat variation (pNN50 \(Int(pnn50))%) - vagal tone suppressed")
        } else if pnn50 > 30 {
            findings.append("Strong beat-to-beat variation (pNN50 \(Int(pnn50))%) - excellent vagal activity")
        }

        // HealthKit sleep insights
        if sleep.totalSleepMinutes > 0 {
            let hours = Double(sleep.totalSleepMinutes) / 60.0
            let isGoodHRV = rmssd >= 40 || (stats.hasData && rmssd >= stats.avgRMSSD * 0.95)
            let isExcellentHRV = stats.hasData && rmssd > stats.avgRMSSD * 1.1

            if sleep.totalSleepMinutes < 300 {
                if isExcellentHRV {
                    findings.append("Remarkable: Excellent HRV despite only \(String(format: "%.1f", hours))h sleep — your recovery capacity is impressive")
                } else if isGoodHRV {
                    findings.append("Solid HRV despite \(String(format: "%.1f", hours))h sleep — you're handling the short night well")
                } else {
                    findings.append("Short sleep (\(String(format: "%.1f", hours))h) per HealthKit — likely a major factor in reduced HRV")
                }
            } else if sleep.totalSleepMinutes >= 420 && isExcellentHRV {
                findings.append("Great combo: \(String(format: "%.1f", hours))h sleep + elevated HRV — fully recovered")
            }

            if sleep.sleepEfficiency >= 92 {
                findings.append("Sleep efficiency \(Int(sleep.sleepEfficiency))% — nearly uninterrupted rest")
            } else if sleep.sleepEfficiency < 75 && sleep.inBedMinutes > 360 {
                findings.append("Low sleep efficiency (\(Int(sleep.sleepEfficiency))%) — \(sleep.awakeMinutes) min awake during the night")
            }

            // Sleep trend insights
            if let trends = sleepTrend, trends.nightsAnalyzed >= 3 {
                let avgHours = trends.averageSleepMinutes / 60.0
                let tonightHours = Double(sleep.totalSleepMinutes) / 60.0
                let sleepDiffPercent = trends.averageSleepMinutes > 0 ?
                    ((Double(sleep.totalSleepMinutes) - trends.averageSleepMinutes) / trends.averageSleepMinutes) * 100 : 0

                switch trends.trend {
                case .declining:
                    findings.append("Sleep trending down over past \(trends.nightsAnalyzed) nights (avg \(String(format: "%.1f", avgHours))h) — watch for cumulative fatigue")
                case .improving:
                    if isGoodHRV {
                        findings.append("Sleep improving over past week — your body is responding positively")
                    }
                case .stable:
                    if avgHours >= 7 && isGoodHRV {
                        findings.append("Consistent \(String(format: "%.1f", avgHours))h average sleep supporting steady HRV")
                    }
                case .insufficient:
                    break
                }

                if abs(sleepDiffPercent) > 25 {
                    if sleepDiffPercent > 25 {
                        findings.append("Tonight's \(String(format: "%.1f", tonightHours))h is \(Int(sleepDiffPercent))% above your recent average")
                    } else {
                        findings.append("Tonight's \(String(format: "%.1f", tonightHours))h is \(Int(abs(sleepDiffPercent)))% below your \(String(format: "%.1f", avgHours))h average")
                    }
                }
            }
        }

        return findings
    }

    // MARK: - Actionable Steps

    private var actionableSteps: [String] {
        var steps: [String] = []

        let score = computeDiagnosticScore()
        let rmssd = result.timeDomain.rmssd
        let stress = result.ansMetrics?.stressIndex ?? 150
        let lfhf = result.frequencyDomain?.lfHfRatio ?? 1.0
        let dfa = result.nonlinear.dfaAlpha1 ?? 1.0
        let windowCV = result.windowHRStability ?? 0.0

        let isShortSleep = sleep.isShortSleep
        let isGoodSleep = sleep.isGoodSleep
        let isFragmented = sleep.isFragmented
        let sleepFormatted = sleep.totalSleepFormatted

        // CRITICAL: Distinguish between capacity (high HRV) and consolidated readiness (sustained + stable)
        // Only "push" recommendations should be given when recovery is CONSOLIDATED
        // High HRV alone represents MAX CAPACITY, not necessarily load-bearing readiness
        //
        // A window is consolidated if: (1) it passed persistence/plateau check, AND (2) CV < 8%
        // This is computed in WindowSelector and propagated via isConsolidated
        let isConsolidated = result.isConsolidated ?? false

        // Additional gates for "push" recommendations:
        // - windowCV > 0.08 (8%) indicates unstable HR during analysis window
        // - dfaAlpha1 > 1.2 indicates fatigue/reduced complexity
        // - lfhf > 3.0 indicates strong sympathetic activation
        let hasUnstableWindow = windowCV > 0.08
        let hasFatigueSignal = dfa > 1.2
        let hasSympatheticDominance = lfhf > 3.0

        // shouldNotPush: any of these signals indicates the HRV represents capacity, not load-bearing readiness
        let shouldNotPush = isShortSleep || hasUnstableWindow || hasFatigueSignal || hasSympatheticDominance || !isConsolidated

        // Trend-aware recommendations
        if stats.hasData {
            let rmssdPct = ((rmssd - stats.avgRMSSD) / stats.avgRMSSD) * 100

            if let trend = stats.trend7Day, trend > 10 {
                steps.append("Your improving trend suggests your current routine is working well")
            }

            if rmssdPct > 15 && score >= 70 && !shouldNotPush {
                // Consolidated recovery: sustained plateau + stable HR = load-bearing readiness
                steps.append("This is a great day to push yourself — your recovery is consolidated and load-bearing")
            } else if rmssdPct > 15 && score >= 70 && shouldNotPush {
                // High HRV but not consolidated = capacity, not readiness
                // Explain why this represents max capacity rather than true readiness
                if !isConsolidated && !hasUnstableWindow && !hasFatigueSignal && !hasSympatheticDominance && !isShortSleep {
                    steps.append("Good HRV shows recovery capacity, but the pattern wasn't sustained — moderate load is safer")
                } else if isShortSleep {
                    steps.append("High HRV shows good capacity, but short sleep limits how much load you can handle")
                } else if hasUnstableWindow {
                    steps.append("Good HRV, but variable HR during sleep indicates incomplete consolidation — moderate intensity")
                } else if hasFatigueSignal {
                    steps.append("Good HRV numbers, but DFA pattern suggests underlying fatigue — don't overdo it")
                } else if hasSympatheticDominance {
                    steps.append("HRV looks good but nervous system is still activated — ease into the day")
                }
            }

            if let trend = stats.trend7Day, trend < -10 {
                steps.append("Consider what changed in the past week — sleep, stress, training load?")
            }
        }

        if score >= 80 {
            if shouldNotPush {
                // High score but not consolidated - explain this represents capacity, not readiness
                if !isConsolidated && !hasUnstableWindow && !hasFatigueSignal && !hasSympatheticDominance && !isShortSleep {
                    steps.append("Excellent recovery capacity detected, but pattern wasn't held long enough for full readiness")
                } else if isShortSleep {
                    steps.append("Strong metrics show good capacity, but short sleep (\(sleepFormatted)) limits load-bearing readiness")
                } else if hasUnstableWindow {
                    steps.append("Good overall score, but variable HR during sleep suggests recovery wasn't consolidated")
                } else if hasFatigueSignal {
                    steps.append("Strong HRV capacity but DFA α1 (\(String(format: "%.2f", dfa))) suggests accumulated fatigue")
                } else if hasSympatheticDominance {
                    steps.append("Good recovery capacity but elevated LF/HF ratio — your nervous system is still activated")
                }
                steps.append("Consider moderate activity rather than high intensity")
            } else {
                // Consolidated recovery = safe to push
                steps.append("Great day for high-intensity training or challenging activities")
                steps.append("Your recovery is consolidated — your body can handle physical and mental demands")
                if isGoodSleep {
                    steps.append("Good sleep is supporting your recovery — maintain this pattern")
                }
            }
        } else if score >= 60 {
            steps.append("Moderate activity is fine — listen to your body")
            if isShortSleep {
                steps.append("Prioritize getting more sleep tonight (\(sleepFormatted) is insufficient)")
            } else {
                steps.append("Stay hydrated and maintain good sleep habits")
            }
        } else if score >= 40 {
            steps.append("Prioritize rest and recovery today")
            steps.append("Light movement like walking is better than intense exercise")
            if isShortSleep {
                steps.append("Aim for 7-9 hours of sleep tonight (you got \(sleepFormatted))")
            }
            if isFragmented {
                steps.append("Address sleep quality — avoid screens before bed, keep room cool and dark")
            }
            if lfhf > 2.5 {
                steps.append("Try 5-10 minutes of slow breathing (4s in, 6s out) to activate parasympathetic")
            }
            if stress > 200 {
                steps.append("Consider what stressors you can reduce or delegate today")
            }
        } else {
            steps.append("Take it easy — your body is signaling it needs recovery")
            if isShortSleep {
                steps.append("Your short sleep (\(sleepFormatted)) needs to be addressed — make sleep the priority")
            } else {
                steps.append("Monitor for illness symptoms over the next 24-48 hours")
            }
            if rmssd < 25 {
                steps.append("If you feel unwell, consider staying home and resting")
            }
            steps.append("Ensure adequate hydration and nutrition")
            if isFragmented {
                steps.append("Focus on uninterrupted sleep — avoid alcohol, caffeine after noon")
            } else {
                steps.append("Aim for extra sleep tonight (8-9+ hours)")
            }
        }

        return steps
    }

    // MARK: - Trend Insight

    private var trendInsight: String {
        guard stats.hasData else { return "Record more sessions to see trends." }

        var insights: [String] = []
        let currentRMSSD = result.timeDomain.rmssd
        let currentHR = result.timeDomain.meanHR
        let currentStress = result.ansMetrics?.stressIndex

        let rmssdDiff = currentRMSSD - stats.avgRMSSD
        let rmssdPct = (rmssdDiff / stats.avgRMSSD) * 100

        if abs(rmssdPct) < 10 {
            insights.append("Your HRV is consistent with your recent average (\(String(format: "%.0f", stats.avgRMSSD))ms).")
        } else if rmssdPct > 20 {
            insights.append("Your HRV is significantly higher than your average of \(String(format: "%.0f", stats.avgRMSSD))ms (+\(String(format: "%.0f", rmssdPct))%), suggesting excellent recovery today.")
        } else if rmssdPct > 10 {
            insights.append("Your HRV is above your average of \(String(format: "%.0f", stats.avgRMSSD))ms (+\(String(format: "%.0f", rmssdPct))%), indicating good recovery.")
        } else if rmssdPct < -20 {
            insights.append("Your HRV is significantly below your average of \(String(format: "%.0f", stats.avgRMSSD))ms (\(String(format: "%.0f", rmssdPct))%). Consider taking it easy today.")
        } else if rmssdPct < -10 {
            insights.append("Your HRV is below your average of \(String(format: "%.0f", stats.avgRMSSD))ms (\(String(format: "%.0f", rmssdPct))%). You may not be fully recovered.")
        }

        if let baseline = stats.baselineRMSSD {
            let baselineDiff = ((currentRMSSD - baseline) / baseline) * 100
            if baselineDiff < -15 {
                insights.append("This is \(String(format: "%.0f", abs(baselineDiff)))% below your personal baseline.")
            } else if baselineDiff > 15 {
                insights.append("This is \(String(format: "%.0f", baselineDiff))% above your baseline—you're in great shape.")
            }
        }

        let hrDiff = currentHR - stats.avgHR
        if hrDiff > 5 {
            insights.append("Resting heart rate is elevated (+\(String(format: "%.0f", hrDiff)) bpm), which may indicate stress, dehydration, or incomplete recovery.")
        } else if hrDiff < -5 {
            insights.append("Resting heart rate is lower than average, suggesting good cardiovascular fitness or deep rest.")
        }

        if let stress = currentStress, let avgStress = stats.avgStress {
            if stress > avgStress * 1.3 && stress > 200 {
                insights.append("Stress markers are elevated compared to your norm. Consider stress management today.")
            }
        }

        if let trend = stats.trend7Day {
            if trend > 10 {
                insights.append("Your 7-day HRV trend is improving (+\(String(format: "%.0f", trend))%)—keep doing what you're doing!")
            } else if trend < -10 {
                insights.append("Your 7-day HRV trend shows a decline (\(String(format: "%.0f", trend))%). Consider prioritizing recovery.")
            }
        }

        if stats.sessionCount < 7 {
            insights.append("With \(stats.sessionCount) sessions recorded, trends will become more accurate over time.")
        }

        return insights.joined(separator: " ")
    }

    // MARK: - Helper Methods

    private func calculateTagImpact() -> [String: Double] {
        var tagImpact: [String: Double] = [:]
        guard recentSessions.count >= 5 else { return tagImpact }

        let allRMSSDs = recentSessions.compactMap { $0.analysisResult?.timeDomain.rmssd }
        guard !allRMSSDs.isEmpty else { return tagImpact }
        let baselineRMSSD = allRMSSDs.reduce(0, +) / Double(allRMSSDs.count)

        for tag in ReadingTag.systemTags {
            let sessionsWithTag = recentSessions.filter { $0.tags.contains(where: { $0.name == tag.name }) }
            guard sessionsWithTag.count >= 2 else { continue }

            let taggedRMSSDs = sessionsWithTag.compactMap { $0.analysisResult?.timeDomain.rmssd }
            guard !taggedRMSSDs.isEmpty else { continue }

            let avgWithTag = taggedRMSSDs.reduce(0, +) / Double(taggedRMSSDs.count)
            let impact = (baselineRMSSD - avgWithTag) / baselineRMSSD

            if impact > 0.1 {
                tagImpact[tag.name] = impact
            }
        }

        return tagImpact
    }

    private func calculateDayOfWeekImpact() -> (dayName: String, impact: Double, isLowDay: Bool)? {
        guard recentSessions.count >= 14 else { return nil }

        let calendar = Calendar.current
        var dayAverages: [Int: [Double]] = [:]

        for session in recentSessions {
            guard let rmssd = session.analysisResult?.timeDomain.rmssd else { continue }
            let day = calendar.component(.weekday, from: session.startDate)
            dayAverages[day, default: []].append(rmssd)
        }

        let validDays = dayAverages.filter { $0.value.count >= 2 }
        guard validDays.count >= 3 else { return nil }

        let allValues = validDays.values.flatMap { $0 }
        let overallAvg = allValues.reduce(0, +) / Double(allValues.count)

        let today = calendar.component(.weekday, from: session.startDate)
        guard let todayReadings = dayAverages[today], todayReadings.count >= 2 else { return nil }

        let todayAvg = todayReadings.reduce(0, +) / Double(todayReadings.count)
        let impact = (overallAvg - todayAvg) / overallAvg

        let dayNames = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return (dayNames[today], abs(impact), impact > 0)
    }

    private func detectIllnessPattern() -> (consecutiveDeclines: Int, totalDeclinePercent: Double, hrElevated: Bool, hrIncrease: Double) {
        guard recentSessions.count >= 3 else {
            return (0, 0, false, 0)
        }

        let sortedSessions = recentSessions
            .filter { $0.state == .complete && $0.analysisResult != nil }
            .sorted { $0.startDate > $1.startDate }

        guard sortedSessions.count >= 3 else {
            return (0, 0, false, 0)
        }

        var consecutiveDeclines = 0
        var totalDeclinePercent = 0.0
        var previousRMSSD: Double?

        for session in sortedSessions.prefix(7) {
            guard let rmssd = session.analysisResult?.timeDomain.rmssd else { continue }

            if let prev = previousRMSSD {
                if rmssd < prev * 0.95 {
                    consecutiveDeclines += 1
                    totalDeclinePercent += ((prev - rmssd) / prev) * 100
                } else {
                    break
                }
            }
            previousRMSSD = rmssd
        }

        // Check HR elevation
        let hrValues = sortedSessions.prefix(14).compactMap { $0.analysisResult?.timeDomain.meanHR }
        let avgHR = hrValues.isEmpty ? 0 : hrValues.reduce(0, +) / Double(hrValues.count)
        let currentHR = result.timeDomain.meanHR
        let hrIncrease = currentHR - avgHR
        let hrElevated = hrIncrease > 5

        return (consecutiveDeclines, totalDeclinePercent, hrElevated, hrIncrease)
    }
}
