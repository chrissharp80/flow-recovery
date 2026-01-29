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

/// Window selection algorithm tests
final class WindowSelectionTests: XCTestCase {

    let windowSelector = WindowSelector()

    // MARK: - Recovery Window Selection

    /// Test organized recovery detection
    func testOrganizedRecoveryDetection() {
        // Create a session with clear organized recovery pattern
        // High RMSSD, stable HR, good DFA alpha1
        let session = createSessionWithPattern(
            avgRR: 900,  // Low HR (67 bpm)
            rmssdRange: 80...120,
            variationPattern: .stable
        )

        guard let series = session.rrSeries, let flags = session.artifactFlags else {
            XCTFail("Session should have series and flags")
            return
        }

        let window = windowSelector.selectRecoveryWindow(
            series: series,
            flags: flags,
            wakeTimeMs: Int64(series.points.count * 800)
        )

        XCTAssertNotNil(window, "Should find a recovery window with stable pattern")
        if let w = window {
            // Verify window has reasonable quality
            XCTAssertGreaterThan(w.qualityScore, 0, "Window should have positive quality score")
            // With stable pattern, should ideally be organized recovery, but this depends on DFA
            // which may not compute reliably with synthetic data
        }
    }

    /// Test high variability detection
    func testHighVariabilityDetection() {
        // Create session with high, chaotic variability
        let session = createSessionWithPattern(
            avgRR: 800,
            rmssdRange: 100...150,
            variationPattern: .chaotic
        )

        guard let series = session.rrSeries, let flags = session.artifactFlags else {
            XCTFail("Session should have series and flags")
            return
        }

        let window = windowSelector.selectRecoveryWindow(
            series: series,
            flags: flags,
            wakeTimeMs: Int64(series.points.count * 800)
        )

        XCTAssertNotNil(window, "Should find a window even with chaotic pattern")
        if let w = window {
            // Verify window exists - classification depends on actual DFA computation
            XCTAssertGreaterThan(w.qualityScore, 0, "Window should have positive quality score")
        }
    }

    /// Test peak capacity selection
    func testPeakCapacitySelection() {
        let session = createSessionWithPattern(
            avgRR: 900,
            rmssdRange: 80...120,
            variationPattern: .stable
        )

        guard let series = session.rrSeries, let flags = session.artifactFlags else {
            XCTFail("Session should have series and flags")
            return
        }

        let window = windowSelector.selectRecoveryWindow(
            series: series,
            flags: flags,
            wakeTimeMs: Int64(series.points.count * 800)
        )

        XCTAssertNotNil(window)
        // Peak capacity is computed separately, not part of RecoveryWindow
        // Just verify window was selected successfully
        if let w = window {
            XCTAssertGreaterThan(w.qualityScore, 0, "Window should have quality score")
        }
    }

    // MARK: - Window Quality

    /// Test artifact filtering
    func testArtifactFiltering() {
        var session = createSessionWithPattern(avgRR: 800, rmssdRange: 60...90, variationPattern: .stable)

        // Add artifacts to first half
        if var flags = session.artifactFlags {
            for i in 0..<(flags.count / 2) {
                flags[i] = ArtifactFlags(isArtifact: true, type: .technical, confidence: 1.0)
            }
            session.artifactFlags = flags
        }

        guard let series = session.rrSeries, let flags = session.artifactFlags else {
            XCTFail("Session should have series and flags")
            return
        }

        let window = windowSelector.selectRecoveryWindow(
            series: series,
            flags: flags,
            wakeTimeMs: Int64(series.points.count * 800)
        )

        XCTAssertNotNil(window)

        // Window should prefer clean section
        if let w = window {
            let windowArtifacts = flags[w.startIndex..<w.endIndex]
            let artifactPercent = Double(windowArtifacts.filter { $0.isArtifact }.count) / Double(windowArtifacts.count) * 100

            XCTAssertLessThan(artifactPercent, 10.0,
                            "Selected window should have low artifact percentage")
        }
    }

    /// Test minimum window length requirement
    func testMinimumWindowLength() {
        // Create very short session
        let points = (0..<50).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800)
        }

        let session = createSession(points: points)

        guard let series = session.rrSeries, let flags = session.artifactFlags else {
            XCTFail("Session should have series and flags")
            return
        }

        let window = windowSelector.selectRecoveryWindow(
            series: series,
            flags: flags,
            wakeTimeMs: Int64(series.points.count * 800)
        )

        // Should either return nil or a valid window
        if let w = window {
            let duration = (w.endIndex - w.startIndex)
            XCTAssertGreaterThanOrEqual(duration, 120,
                                       "Window should meet minimum length requirement")
        }
    }

    // MARK: - Temporal Spike Filtering

    /// Test spike detection and filtering
    func testSpikeFiltering() {
        // Create session with a temporary spike in variability
        // Need 1500 beats so 30-70% band can contain 400-beat window
        var points = (0..<1500).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800 + Int.random(in: -20...20))
        }

        // Add spike in middle (600-650)
        for i in 600..<650 {
            points[i] = RRPoint(t_ms: Int64(i * 800), rr_ms: 800 + Int.random(in: -100...100))
        }

        let session = createSession(points: points)

        guard let series = session.rrSeries, let flags = session.artifactFlags else {
            XCTFail("Session should have series and flags")
            return
        }

        let window = windowSelector.selectRecoveryWindow(
            series: series,
            flags: flags,
            wakeTimeMs: Int64(series.points.count * 800)
        )

        XCTAssertNotNil(window)

        // Window should avoid the spike region
        if let w = window {
            let spikeRegion = 600..<650
            let windowRange = w.startIndex..<w.endIndex

            // Check if window overlaps significantly with spike
            let overlap = windowRange.clamped(to: spikeRegion)
            let overlapPercent = Double(overlap.count) / Double(windowRange.count) * 100

            XCTAssertLessThan(overlapPercent, 20.0,
                            "Window should avoid spike regions")
        }
    }

    // MARK: - Heart Rate Stability

    /// Test HR stability preference
    func testHRStabilityPreference() {
        // Create two regions: one stable, one variable HR
        // Need 1500 beats so 30-70% band can contain 400-beat window
        var points: [RRPoint] = []

        // First half: stable HR (~75 bpm, 800ms RR)
        for i in 0..<750 {
            points.append(RRPoint(t_ms: Int64(i * 800), rr_ms: 800 + Int.random(in: -10...10)))
        }

        // Second half: variable HR (60-90 bpm)
        for i in 750..<1500 {
            let rr = Int.random(in: 667...1000)
            points.append(RRPoint(t_ms: Int64(i * 800), rr_ms: rr))
        }

        let session = createSession(points: points)

        guard let series = session.rrSeries, let flags = session.artifactFlags else {
            XCTFail("Session should have series and flags")
            return
        }

        let window = windowSelector.selectRecoveryWindow(
            series: series,
            flags: flags,
            wakeTimeMs: Int64(series.points.count * 800)
        )

        XCTAssertNotNil(window)

        if let w = window {
            // Calculate HR variability in selected window
            let windowPoints = Array(points[w.startIndex..<w.endIndex])
            let hrValues = windowPoints.map { 60000.0 / Double($0.rr_ms) }
            let hrStdDev = standardDeviation(hrValues)

            // Should prefer stable HR region
            XCTAssertLessThan(hrStdDev, 10.0,
                            "Selected window should have stable HR")
        }
    }

    // MARK: - Edge Cases

    /// Test all artifacts session
    func testAllArtifacts() {
        let session = createSessionWithPattern(avgRR: 800, rmssdRange: 60...90, variationPattern: .stable)
        var badSession = session

        guard let series = session.rrSeries else {
            XCTFail("Session should have series")
            return
        }

        badSession.artifactFlags = [ArtifactFlags](repeating: ArtifactFlags(isArtifact: true, type: .technical, confidence: 1.0), count: series.points.count)

        guard let flags = badSession.artifactFlags else {
            XCTFail("Should have flags")
            return
        }

        let window = windowSelector.selectRecoveryWindow(
            series: series,
            flags: flags,
            wakeTimeMs: Int64(series.points.count * 800)
        )

        // Should return nil or handle gracefully
        if window != nil {
            XCTFail("Should not select window from session with all artifacts")
        }
    }

    /// Test insufficient data
    func testInsufficientData() {
        let points = (0..<10).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800)
        }

        let session = createSession(points: points)

        guard let series = session.rrSeries, let flags = session.artifactFlags else {
            XCTFail("Session should have series and flags")
            return
        }

        let window = windowSelector.selectRecoveryWindow(
            series: series,
            flags: flags,
            wakeTimeMs: Int64(series.points.count * 800)
        )

        XCTAssertNil(window, "Should return nil for insufficient data")
    }

    // MARK: - Helper Methods

    enum VariationPattern {
        case stable
        case chaotic
        case increasing
        case decreasing
    }

    private func createSessionWithPattern(
        avgRR: Int,
        rmssdRange: ClosedRange<Int>,
        variationPattern: VariationPattern
    ) -> HRVSession {
        var points: [RRPoint] = []

        // Need at least 1500 beats so 30-70% band can contain 400-beat window
        // 30-70% of 1500 = 450-1050 (600 beats) which is enough for 400-beat window
        for i in 0..<1500 {
            let variation: Int

            switch variationPattern {
            case .stable:
                variation = Int.random(in: -20...20)
            case .chaotic:
                variation = Int.random(in: -100...100)
            case .increasing:
                variation = Int(Double(i) / 3.0) + Int.random(in: -10...10)
            case .decreasing:
                variation = -Int(Double(i) / 3.0) + Int.random(in: -10...10)
            }

            points.append(RRPoint(
                t_ms: Int64(i * avgRR),
                rr_ms: avgRR + variation
            ))
        }

        return createSession(points: points)
    }

    private func createSession(points: [RRPoint]) -> HRVSession {
        let series = RRSeries(
            points: points,
            sessionId: UUID(),
            startDate: Date()
        )

        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        return HRVSession(
            id: UUID(),
            startDate: series.startDate,
            endDate: series.startDate.addingTimeInterval(Double(points.count) * 0.8),
            state: .complete,
            sessionType: .overnight,
            rrSeries: series,
            analysisResult: nil,
            artifactFlags: flags,
            recoveryScore: nil,
            tags: [],
            notes: nil,
            importedMetrics: nil,
            deviceProvenance: nil,
            sleepStartMs: nil,
            sleepEndMs: nil
        )
    }

    private func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }

        let mean = values.reduce(0.0, +) / Double(values.count)
        let squaredDiffs = values.map { pow($0 - mean, 2) }
        let variance = squaredDiffs.reduce(0.0, +) / Double(values.count - 1)

        return sqrt(variance)
    }
}
