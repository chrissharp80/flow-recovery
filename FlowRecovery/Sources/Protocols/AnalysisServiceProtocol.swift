//
//  Copyright © 2024-2026 Chris Sharp. All rights reserved.
//

import Foundation

/// Protocol for HRV analysis operations
protocol AnalysisServiceProtocol {

    /// Detect artifacts in an RR series
    func detectArtifacts(in series: RRSeries) -> [ArtifactFlags]

    /// Find the best recovery window in a series
    func findRecoveryWindow(
        in series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64?,
        wakeTimeMs: Int64?
    ) -> WindowSelector.RecoveryWindow?

    /// Find recovery window with peak capacity information
    func findRecoveryWindowWithCapacity(
        in series: RRSeries,
        flags: [ArtifactFlags],
        sleepStartMs: Int64?,
        wakeTimeMs: Int64?
    ) -> WindowSelector.WindowSelectionResult?

    /// Analyze a recovery window
    func analyzeWindow(
        in series: RRSeries,
        flags: [ArtifactFlags],
        window: WindowSelector.RecoveryWindow
    ) -> HRVAnalysisResult?

    /// Analyze full series (for streaming mode)
    func analyzeFullSeries(
        _ series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int,
        windowEnd: Int
    ) -> HRVAnalysisResult?

    /// Verify data quality
    func verify(_ series: RRSeries, flags: [ArtifactFlags]) -> Verification.Result
}

/// Protocol for analysis configuration
protocol AnalysisConfigurable {
    var minPoints: Int { get }
    var minDurationHours: Double { get }
    var maxArtifactPercent: Double { get }
}
