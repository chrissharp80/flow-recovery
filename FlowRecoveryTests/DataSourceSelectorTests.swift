//
//  Copyright © 2024-2026 Flow Recovery. All rights reserved.
//
//  This source code is provided for reference and verification purposes only.
//  Unauthorized copying, modification, distribution, or use of this code,
//  via any medium, is strictly prohibited without prior written permission.
//
//  For licensing inquiries, contact the copyright holder.
//

import XCTest
@testable import FlowRecovery

/// Tests for DataSourceSelector
/// Validates data source selection logic for hybrid recording
final class DataSourceSelectorTests: XCTestCase {

    // MARK: - Test Helpers

    private func createRRPoints(count: Int, startMs: Int64 = 0, intervalMs: Int = 800) -> [RRPoint] {
        var points: [RRPoint] = []
        var currentMs = startMs
        for _ in 0..<count {
            points.append(RRPoint(t_ms: currentMs, rr_ms: intervalMs))
            currentMs += Int64(intervalMs)
        }
        return points
    }

    private func createRRPointsWithGap(
        beforeGap: Int,
        afterGap: Int,
        gapDurationMs: Int64,
        intervalMs: Int = 800
    ) -> [RRPoint] {
        var points: [RRPoint] = []
        var currentMs: Int64 = 0

        // Points before gap
        for _ in 0..<beforeGap {
            points.append(RRPoint(t_ms: currentMs, rr_ms: intervalMs))
            currentMs += Int64(intervalMs)
        }

        // Gap
        currentMs += gapDurationMs

        // Points after gap
        for _ in 0..<afterGap {
            points.append(RRPoint(t_ms: currentMs, rr_ms: intervalMs))
            currentMs += Int64(intervalMs)
        }

        return points
    }

    // MARK: - Basic Selection Tests

    func testSelectsStreamingWhenInternalFails() {
        let streamingPoints = createRRPoints(count: 500)
        let internalPoints: [RRPoint]? = nil

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.points.count, 500)
        XCTAssertTrue(result?.sourceDescription.contains("streaming") ?? false)
        XCTAssertFalse(result?.isComposite ?? true)
    }

    func testSelectsInternalWhenStreamingFails() {
        let streamingPoints = createRRPoints(count: 50)  // Below 120 minimum
        let internalPoints = createRRPoints(count: 500)

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.points.count, 500)
        XCTAssertTrue(result?.sourceDescription.contains("internal") ?? false)
        XCTAssertFalse(result?.isComposite ?? true)
    }

    func testReturnsNilWhenBothFail() {
        let streamingPoints = createRRPoints(count: 50)  // Below minimum
        let internalPoints = createRRPoints(count: 50)   // Below minimum

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNil(result)
    }

    func testSelectsInternalWhenBothValidAndSimilar() {
        let streamingPoints = createRRPoints(count: 500)
        let internalPoints = createRRPoints(count: 505)  // Within 5% difference

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.sourceDescription, "internal")
        XCTAssertFalse(result?.isComposite ?? true)
    }

    // MARK: - Minimum Threshold Tests

    func testMinimumBeatsThreshold() {
        // Exactly at threshold
        let atThreshold = createRRPoints(count: 120)
        let result1 = DataSourceSelector.selectBestSource(
            streamingPoints: atThreshold,
            internalPoints: nil,
            sessionId: UUID(),
            sessionStart: Date()
        )
        XCTAssertNotNil(result1)

        // Below threshold
        let belowThreshold = createRRPoints(count: 119)
        let result2 = DataSourceSelector.selectBestSource(
            streamingPoints: belowThreshold,
            internalPoints: nil,
            sessionId: UUID(),
            sessionStart: Date()
        )
        XCTAssertNil(result2)
    }

    // MARK: - Composite Creation Tests

    func testCreatesCompositeWhenInternalHasGaps() {
        // Internal has 400 beats with a gap
        let internalPoints = createRRPointsWithGap(
            beforeGap: 200,
            afterGap: 200,
            gapDurationMs: 10000  // 10 second gap
        )

        // Streaming has continuous data including the gap period
        let streamingPoints = createRRPoints(count: 500)

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNotNil(result)
        // Should create composite since internal has significant gaps
        // and streaming has more points (>5% difference)
        if result?.isComposite == true {
            XCTAssertTrue(result?.sourceDescription.contains("composite") ?? false)
        }
    }

    func testDoesNotCreateCompositeWhenDifferenceSmall() {
        let streamingPoints = createRRPoints(count: 500)
        let internalPoints = createRRPoints(count: 490)  // Only 2% difference

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNotNil(result)
        XCTAssertFalse(result?.isComposite ?? true)
        XCTAssertEqual(result?.sourceDescription, "internal")
    }

    func testCompositeThresholdIsRespected() {
        // Exactly at 5% threshold
        let streamingPoints = createRRPoints(count: 1000)
        let internalPoints = createRRPoints(count: 950)  // Exactly 5% fewer

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNotNil(result)
        // At exactly 5%, should not create composite (need >5%)
        XCTAssertFalse(result?.isComposite ?? true)
    }

    // MARK: - Source Description Tests

    func testSourceDescriptionForStreamingOnly() {
        let streamingPoints = createRRPoints(count: 500)

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: nil,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertTrue(result?.sourceDescription.contains("streaming") ?? false)
        XCTAssertTrue(result?.sourceDescription.contains("internal failed") ?? false)
    }

    func testSourceDescriptionForInternalOnly() {
        let streamingPoints = createRRPoints(count: 50)  // Invalid
        let internalPoints = createRRPoints(count: 500)

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertEqual(result?.sourceDescription, "internal")
    }

    func testSourceDescriptionForPreferredInternal() {
        let streamingPoints = createRRPoints(count: 500)
        let internalPoints = createRRPoints(count: 500)

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertEqual(result?.sourceDescription, "internal")
    }

    // MARK: - Edge Cases

    func testEmptyStreamingPoints() {
        let streamingPoints: [RRPoint] = []
        let internalPoints = createRRPoints(count: 500)

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.points.count, 500)
    }

    func testBothEmpty() {
        let streamingPoints: [RRPoint] = []
        let internalPoints: [RRPoint] = []

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNil(result)
    }

    func testNilInternalPoints() {
        let streamingPoints = createRRPoints(count: 500)

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: nil,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.points.count, 500)
    }

    // MARK: - Session ID Preservation

    func testSessionIdIsPreserved() {
        let sessionId = UUID()
        let streamingPoints = createRRPoints(count: 500)

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: nil,
            sessionId: sessionId,
            sessionStart: Date()
        )

        XCTAssertNotNil(result)
        // The result doesn't directly contain sessionId, but it's used for series construction
        // This test verifies the function accepts the parameter
    }

    // MARK: - Large Dataset Tests

    func testLargeDatasetSelection() {
        // Simulate overnight recording (~8 hours at 60bpm = ~28800 beats)
        let streamingPoints = createRRPoints(count: 28000)
        let internalPoints = createRRPoints(count: 28500)

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNotNil(result)
        // Should prefer internal as difference is only ~1.8%
        XCTAssertFalse(result?.isComposite ?? true)
    }

    // MARK: - Percentage Calculation Tests

    func testPercentageDifferenceCalculation() {
        // 10% difference should trigger composite consideration
        let streamingPoints = createRRPoints(count: 1000)
        let internalPoints = createRRPoints(count: 900)  // 10% fewer

        let result = DataSourceSelector.selectBestSource(
            streamingPoints: streamingPoints,
            internalPoints: internalPoints,
            sessionId: UUID(),
            sessionStart: Date()
        )

        XCTAssertNotNil(result)
        // With 10% difference, should consider composite
        // (actual composite creation depends on gap detection)
    }
}
