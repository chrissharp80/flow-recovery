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

/// Selects the best data source when both streaming and internal recording are available
/// Following Single Responsibility Principle: data source selection is separate from session management
enum DataSourceSelector {

    /// Minimum beats required for a valid data source
    static let minimumValidBeats = 120

    /// Percentage difference threshold for creating a composite
    static let compositeThresholdPercent = 5.0

    /// Result of data source selection
    struct SelectionResult {
        let points: [RRPoint]
        let sourceDescription: String
        let isComposite: Bool
    }

    /// Select the best data source from streaming and internal recording data
    /// - Parameters:
    ///   - streamingPoints: RR points collected via BLE streaming
    ///   - internalPoints: RR points fetched from H10 internal memory
    ///   - sessionId: Session ID for series construction
    ///   - sessionStart: Session start date
    /// - Returns: Selected data source with description, or nil if both sources failed
    static func selectBestSource(
        streamingPoints: [RRPoint],
        internalPoints: [RRPoint]?,
        sessionId: UUID,
        sessionStart: Date
    ) -> SelectionResult? {
        let hasValidStreaming = streamingPoints.count >= minimumValidBeats
        let hasValidInternal = (internalPoints?.count ?? 0) >= minimumValidBeats

        // Both failed - return nil
        guard hasValidStreaming || hasValidInternal else {
            debugLog("[DataSourceSelector] Both data sources failed validation")
            debugLog("[DataSourceSelector] Streaming: \(streamingPoints.count) beats")
            debugLog("[DataSourceSelector] Internal: \(internalPoints?.count ?? 0) beats")
            return nil
        }

        // Choose best source or create composite
        if let internalData = internalPoints, hasValidInternal {
            return selectWithInternalAvailable(
                internalData: internalData,
                streamingPoints: streamingPoints,
                hasValidStreaming: hasValidStreaming,
                sessionId: sessionId,
                sessionStart: sessionStart
            )
        } else if hasValidStreaming {
            // Only streaming succeeded
            debugLog("[DataSourceSelector] Using streaming data (internal failed)")
            return SelectionResult(
                points: streamingPoints,
                sourceDescription: "streaming (internal failed)",
                isComposite: false
            )
        }

        return nil
    }

    // MARK: - Private Methods

    private static func selectWithInternalAvailable(
        internalData: [RRPoint],
        streamingPoints: [RRPoint],
        hasValidStreaming: Bool,
        sessionId: UUID,
        sessionStart: Date
    ) -> SelectionResult {
        guard hasValidStreaming else {
            // Only internal succeeded
            debugLog("[DataSourceSelector] Using internal recording (streaming failed)")
            return SelectionResult(
                points: internalData,
                sourceDescription: "internal",
                isComposite: false
            )
        }

        // Both succeeded - compare and decide
        let comparison = compareDataSources(
            internalCount: internalData.count,
            streamingCount: streamingPoints.count
        )

        debugLog("[DataSourceSelector] Both recordings succeeded")
        debugLog("[DataSourceSelector] Beat count: internal=\(internalData.count) vs streaming=\(streamingPoints.count)")
        debugLog("[DataSourceSelector] Difference: \(comparison.beatDifference) beats (\(String(format: "%.1f", comparison.percentDifference))%)")

        // If internal has significantly fewer beats, create composite
        if comparison.shouldCreateComposite {
            debugLog("[DataSourceSelector] Internal has gaps - attempting composite creation")

            let internalSeries = RRSeries(points: internalData, sessionId: sessionId, startDate: sessionStart)
            let streamingSeries = RRSeries(points: streamingPoints, sessionId: sessionId, startDate: sessionStart)

            if let composite = createComposite(
                internalSeries: internalSeries,
                streamingSeries: streamingSeries
            ) {
                debugLog("[DataSourceSelector] Composite created: \(composite.count) beats")
                return SelectionResult(
                    points: composite,
                    sourceDescription: "composite (internal + streaming gap-fill)",
                    isComposite: true
                )
            } else {
                debugLog("[DataSourceSelector] Composite failed, using internal")
            }
        } else {
            debugLog("[DataSourceSelector] Using internal recording (preferred)")
        }

        return SelectionResult(
            points: internalData,
            sourceDescription: "internal",
            isComposite: false
        )
    }

    private static func compareDataSources(internalCount: Int, streamingCount: Int) -> DataSourceComparison {
        let beatDiff = abs(internalCount - streamingCount)
        let percentDiff = (Double(beatDiff) / Double(max(internalCount, streamingCount))) * 100.0

        let shouldComposite = internalCount < streamingCount && percentDiff > compositeThresholdPercent

        return DataSourceComparison(
            beatDifference: beatDiff,
            percentDifference: percentDiff,
            shouldCreateComposite: shouldComposite
        )
    }

    /// Create composite RR points by merging internal recording with streaming data to fill gaps
    private static func createComposite(
        internalSeries: RRSeries,
        streamingSeries: RRSeries
    ) -> [RRPoint]? {
        let internalPoints = internalSeries.points
        let streamingPoints = streamingSeries.points

        guard !internalPoints.isEmpty, !streamingPoints.isEmpty else {
            debugLog("[DataSourceSelector] Cannot create composite: empty series")
            return nil
        }

        // Find gaps in internal recording
        var gaps: [GapInfo] = []

        for i in 1..<internalPoints.count {
            let prevPoint = internalPoints[i-1]
            let currPoint = internalPoints[i]

            let expectedGap = Int64(prevPoint.rr_ms)
            let actualGap = currPoint.t_ms - prevPoint.endMs

            // Significant gap: >2 seconds beyond expected
            if actualGap > expectedGap + 2000 {
                gaps.append(GapInfo(
                    startMs: prevPoint.endMs,
                    endMs: currPoint.t_ms,
                    index: i
                ))
            }
        }

        guard !gaps.isEmpty else {
            debugLog("[DataSourceSelector] No significant gaps found")
            return nil
        }

        debugLog("[DataSourceSelector] Found \(gaps.count) gap(s) to fill")

        // Count how many beats we can fill
        var gapsFilled = 0
        var beatsAdded = 0

        for gap in gaps {
            let fillPoints = streamingPoints.filter { point in
                point.t_ms >= gap.startMs && point.t_ms <= gap.endMs
            }

            if !fillPoints.isEmpty {
                gapsFilled += 1
                beatsAdded += fillPoints.count
                debugLog("[DataSourceSelector] Gap \(gap.startMs/1000)s-\(gap.endMs/1000)s: filling with \(fillPoints.count) beats")
            }
        }

        if gapsFilled == 0 {
            debugLog("[DataSourceSelector] No gaps could be filled from streaming")
            return nil
        }

        // Build composite by merging chronologically
        let mergedPoints = mergePoints(internal: internalPoints, streaming: streamingPoints)

        debugLog("[DataSourceSelector] Composite complete: \(mergedPoints.count) beats")
        debugLog("[DataSourceSelector] Added \(beatsAdded) beats to fill \(gapsFilled) gap(s)")

        return mergedPoints
    }

    private static func mergePoints(internal internalPoints: [RRPoint], streaming streamingPoints: [RRPoint]) -> [RRPoint] {
        var merged: [RRPoint] = []
        var internalIdx = 0
        var streamingIdx = 0

        while internalIdx < internalPoints.count || streamingIdx < streamingPoints.count {
            if internalIdx >= internalPoints.count {
                merged.append(streamingPoints[streamingIdx])
                streamingIdx += 1
            } else if streamingIdx >= streamingPoints.count {
                merged.append(internalPoints[internalIdx])
                internalIdx += 1
            } else {
                let internalTime = internalPoints[internalIdx].t_ms
                let streamingTime = streamingPoints[streamingIdx].t_ms

                if internalTime <= streamingTime {
                    merged.append(internalPoints[internalIdx])
                    internalIdx += 1
                } else {
                    merged.append(streamingPoints[streamingIdx])
                    streamingIdx += 1
                }
            }
        }

        return merged
    }
}

// MARK: - Supporting Types

private struct DataSourceComparison {
    let beatDifference: Int
    let percentDifference: Double
    let shouldCreateComposite: Bool
}

private struct GapInfo {
    let startMs: Int64
    let endMs: Int64
    let index: Int
}
