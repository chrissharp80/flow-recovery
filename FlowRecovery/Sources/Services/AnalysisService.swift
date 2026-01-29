//
//  Copyright © 2024-2026 Chris Sharp. All rights reserved.
//

import Foundation

/// Centralized HRV analysis service
/// Coordinates artifact detection, window selection, and metric computation
final class AnalysisService: AnalysisServiceProtocol {

    // MARK: - Dependencies

    private let artifactDetector: ArtifactDetector
    private let windowSelector: WindowSelector
    private let verification: Verification
    private let diagnosticScorer: DiagnosticScorer

    // MARK: - Initialization

    init(
        artifactDetector: ArtifactDetector = ArtifactDetector(),
        windowSelector: WindowSelector = WindowSelector(),
        verification: Verification = Verification(),
        diagnosticScorer: DiagnosticScorer = DiagnosticScorer()
    ) {
        self.artifactDetector = artifactDetector
        self.windowSelector = windowSelector
        self.verification = verification
        self.diagnosticScorer = diagnosticScorer
    }

    /// Create with relaxed config for streaming mode
    static func forStreaming() -> AnalysisService {
        AnalysisService(
            verification: Verification(config: Verification.Config(
                minPoints: HRVConstants.MinimumBeats.forStreaming,
                minDurationHours: 0.025,
                maxArtifactPercent: HRVConstants.Artifacts.maxPercentForAnalysis,
                warnArtifactPercent: HRVConstants.Artifacts.warnPercentThreshold
            ))
        )
    }

    // MARK: - AnalysisServiceProtocol

    func detectArtifacts(in series: RRSeries) -> [ArtifactFlags] {
        artifactDetector.detectArtifacts(in: series)
    }

    func findRecoveryWindow(
        in series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64?,
        wakeTimeMs: Int64?
    ) -> WindowSelector.RecoveryWindow? {
        windowSelector.findBestWindow(
            in: series,
            flags: flags,
            sleepStartMs: sleepStartMs,
            wakeTimeMs: wakeTimeMs
        )
    }

    func findRecoveryWindowWithCapacity(
        in series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64?,
        wakeTimeMs: Int64?
    ) -> WindowSelector.WindowSelectionResult? {
        windowSelector.findBestWindowWithCapacity(
            in: series,
            flags: flags,
            sleepStartMs: sleepStartMs,
            wakeTimeMs: wakeTimeMs
        )
    }

    func analyzeWindow(
        in series: RRSeries,
        flags: [ArtifactFlags],
        window: WindowSelector.RecoveryWindow
    ) -> HRVAnalysisResult? {
        analyzeFullSeries(
            series,
            flags: flags,
            windowStart: window.startIndex,
            windowEnd: window.endIndex
        )
    }

    func analyzeFullSeries(
        _ series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int = 0,
        windowEnd: Int
    ) -> HRVAnalysisResult? {
        let effectiveEnd = windowEnd > 0 ? windowEnd : series.points.count

        guard let timeDomain = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: windowStart,
            windowEnd: effectiveEnd
        ) else {
            return nil
        }

        let frequencyDomain = FrequencyDomainAnalyzer.computeFrequencyDomain(
            series,
            flags: flags,
            windowStart: windowStart,
            windowEnd: effectiveEnd
        )

        let nonlinear = NonlinearAnalyzer.computeNonlinear(
            series,
            flags: flags,
            windowStart: windowStart,
            windowEnd: effectiveEnd
        )

        guard let nonlinearMetrics = nonlinear else {
            return nil
        }

        // Extract clean RR intervals for ANS metrics
        var cleanRRs: [Double] = []
        for i in windowStart..<effectiveEnd {
            if !flags[i].isArtifact {
                cleanRRs.append(Double(series.points[i].rr_ms))
            }
        }

        // Compute ANS metrics using clean RRs
        let stressIndex = StressAnalyzer.computeStressIndex(cleanRRs)
        let respirationRate = RespirationAnalyzer.estimateRespirationRate(cleanRRs)

        // Count clean beats
        let cleanCount = flags[windowStart..<effectiveEnd].filter { !$0.isArtifact }.count
        let artifactPercent = Double(effectiveEnd - windowStart - cleanCount) / Double(effectiveEnd - windowStart) * 100

        return HRVAnalysisResult(
            windowStart: windowStart,
            windowEnd: effectiveEnd,
            timeDomain: timeDomain,
            frequencyDomain: frequencyDomain,
            nonlinear: nonlinearMetrics,
            ansMetrics: ANSMetrics(
                stressIndex: stressIndex,
                pnsIndex: nil,
                snsIndex: nil,
                readinessScore: nil,
                respirationRate: respirationRate,
                nocturnalHRDip: nil,
                daytimeRestingHR: nil,
                nocturnalMedianHR: nil
            ),
            artifactPercentage: artifactPercent,
            cleanBeatCount: cleanCount,
            analysisDate: Date()
        )
    }

    func verify(_ series: RRSeries, flags: [ArtifactFlags]) -> Verification.Result {
        verification.verify(series, flags: flags)
    }

    // MARK: - Full Analysis Pipeline

    /// Run complete analysis pipeline on a session
    func analyze(
        session: inout HRVSession,
        sleepStartMs: Int64? = nil,
        wakeTimeMs: Int64? = nil
    ) -> HRVAnalysisResult? {
        guard let series = session.rrSeries else { return nil }

        // Detect artifacts
        let flags = detectArtifacts(in: series)
        session.artifactFlags = flags

        // Verify data quality
        let verificationResult = verify(series, flags: flags)
        guard verificationResult.passed else {
            debugLog("[AnalysisService] Data verification failed: \(verificationResult.summary)")
            return nil
        }

        // Find recovery window with capacity
        guard let windowResult = findRecoveryWindowWithCapacity(
            in: series,
            flags: flags,
            sleepStartMs: sleepStartMs,
            wakeTimeMs: wakeTimeMs
        ) else {
            debugLog("[AnalysisService] Could not find recovery window")
            return nil
        }

        guard let window = windowResult.recoveryWindow else {
            debugLog("[AnalysisService] No valid recovery window found")
            return nil
        }

        // Analyze the window
        guard var result = analyzeWindow(in: series, flags: flags, window: window) else {
            debugLog("[AnalysisService] Window analysis failed")
            return nil
        }

        // Add window metadata
        result.windowStartMs = series.points[window.startIndex].t_ms
        result.windowEndMs = series.points[window.endIndex - 1].endMs
        result.windowMeanHR = window.meanHR
        result.windowHRStability = window.hrStability
        result.windowSelectionReason = window.selectionReason
        result.windowRelativePosition = window.relativePosition
        result.windowClassification = window.windowClassification.rawValue
        result.isOrganizedRecovery = window.windowClassification == .organizedRecovery
        result.peakCapacity = windowResult.peakCapacity

        session.analysisResult = result
        session.recoveryScore = window.recoveryScore

        return result
    }

    // MARK: - Diagnostic Scoring

    func computeDiagnosticScore(from result: HRVAnalysisResult) -> DiagnosticResult {
        let metrics = DiagnosticMetrics(from: result)
        return diagnosticScorer.computeScore(from: metrics)
    }
}
