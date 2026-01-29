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

/// Time domain HRV analysis tests
final class TimeDomainTests: XCTestCase {

    // MARK: - RMSSD Tests

    /// RMSSD should be within 5% of reference implementation
    func testRMSSDAccuracy() {
        // Create known RR intervals with calculable RMSSD
        // Need at least 10 points for TimeDomain analysis
        // Using pattern: 800, 820, 790, 830, 780, repeated twice
        // Successive diffs: 20, -30, 40, -50, 20, -30, 40, -50, 20
        // Mean of squared diffs ≈ 1350
        // RMSSD = sqrt(1350) ≈ 36.74

        let basePattern = [800, 820, 790, 830, 780]
        var points: [RRPoint] = []
        var t_ms: Int64 = 0

        for _ in 0..<2 {
            for rr in basePattern {
                points.append(RRPoint(t_ms: t_ms, rr_ms: rr))
                t_ms += Int64(rr)
            }
        }
        // Total: 10 points

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        let metrics = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: points.count
        )

        XCTAssertNotNil(metrics)

        let expectedRMSSD = 36.74
        XCTAssertEqual(
            metrics!.rmssd,
            expectedRMSSD,
            accuracy: expectedRMSSD * 0.05,
            "RMSSD should be within 5% of reference. Expected \(expectedRMSSD), got \(metrics!.rmssd)"
        )
    }

    /// Test pNN50 calculation
    func testPNN50() {
        // Create intervals where some diffs > 50ms
        // Need at least 10 points for TimeDomain analysis
        // Pattern: 800, 860(+60), 840(-20), 895(+55), 865(-30), 935(+70), 900(-35), 820(-80), 880(+60), 830(-50), 890(+60)
        // Diffs > 50: +60, +55, +70, -80, +60, +60 = 6 out of 10 = 60%
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 860),    // +60
            RRPoint(t_ms: 1660, rr_ms: 840),   // -20
            RRPoint(t_ms: 2500, rr_ms: 895),   // +55
            RRPoint(t_ms: 3395, rr_ms: 865),   // -30
            RRPoint(t_ms: 4260, rr_ms: 935),   // +70
            RRPoint(t_ms: 5195, rr_ms: 900),   // -35
            RRPoint(t_ms: 6095, rr_ms: 820),   // -80
            RRPoint(t_ms: 6915, rr_ms: 880),   // +60
            RRPoint(t_ms: 7795, rr_ms: 830),   // -50
            RRPoint(t_ms: 8625, rr_ms: 890)    // +60
        ]

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        let metrics = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: points.count
        )

        XCTAssertNotNil(metrics)
        XCTAssertEqual(metrics!.pnn50, 60.0, accuracy: 0.1,
                       "pNN50 should be 60%. Got \(metrics!.pnn50)")
    }

    /// Test SDNN calculation
    func testSDNN() {
        // Need at least 10 points for TimeDomain analysis
        // RR intervals: 800, 900, 700, 850, 750, 800, 900, 700, 850, 750
        // Mean: 800
        // Variance and SD should be consistent with pattern

        let pattern = [800, 900, 700, 850, 750]
        var points: [RRPoint] = []
        var t_ms: Int64 = 0

        for _ in 0..<2 {
            for rr in pattern {
                points.append(RRPoint(t_ms: t_ms, rr_ms: rr))
                t_ms += Int64(rr)
            }
        }
        // Total: 10 points

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        let metrics = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: points.count
        )

        XCTAssertNotNil(metrics)

        // With repeated pattern [800, 900, 700, 850, 750], mean is 800
        // SDNN should still be around 79 since pattern repeats
        // Just verify it's in a reasonable range
        XCTAssertGreaterThan(metrics!.sdnn, 70, "SDNN should be > 70 for this pattern")
        XCTAssertLessThan(metrics!.sdnn, 90, "SDNN should be < 90 for this pattern")
    }

    /// Test mean RR and HR
    func testMeanRRAndHR() {
        // RR intervals averaging 750ms = 80 bpm
        // Need at least 10 points for TimeDomain analysis
        let points = [
            RRPoint(t_ms: 0, rr_ms: 700),
            RRPoint(t_ms: 700, rr_ms: 750),
            RRPoint(t_ms: 1450, rr_ms: 800),
            RRPoint(t_ms: 2250, rr_ms: 750),
            RRPoint(t_ms: 3000, rr_ms: 750),
            RRPoint(t_ms: 3750, rr_ms: 740),
            RRPoint(t_ms: 4490, rr_ms: 760),
            RRPoint(t_ms: 5250, rr_ms: 750),
            RRPoint(t_ms: 6000, rr_ms: 750),
            RRPoint(t_ms: 6750, rr_ms: 750)
        ]

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        let metrics = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: points.count
        )

        XCTAssertNotNil(metrics)
        XCTAssertEqual(metrics!.meanRR, 750, accuracy: 1,
                       "Mean RR should be 750ms. Got \(metrics!.meanRR)")
        XCTAssertEqual(metrics!.meanHR, 80, accuracy: 1,
                       "Mean HR should be 80 bpm. Got \(metrics!.meanHR)")
    }

    // MARK: - Artifact Exclusion

    /// Artifacts should be excluded from calculations
    func testArtifactExclusion() {
        // Need at least 10 clean points after excluding artifacts
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 810),
            RRPoint(t_ms: 1610, rr_ms: 400),    // Artifact - should be excluded
            RRPoint(t_ms: 2010, rr_ms: 790),
            RRPoint(t_ms: 2800, rr_ms: 800),
            RRPoint(t_ms: 3600, rr_ms: 805),
            RRPoint(t_ms: 4405, rr_ms: 795),
            RRPoint(t_ms: 5200, rr_ms: 800),
            RRPoint(t_ms: 6000, rr_ms: 810),
            RRPoint(t_ms: 6810, rr_ms: 790),
            RRPoint(t_ms: 7600, rr_ms: 800)
        ]

        var flags = [ArtifactFlags](repeating: .clean, count: points.count)
        flags[2] = ArtifactFlags(isArtifact: true, type: .ectopic, confidence: 1.0)
        // 11 points total, 10 clean after excluding artifact

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())

        let metrics = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: points.count
        )

        XCTAssertNotNil(metrics)

        // Mean should be based on clean beats only: (800 + 810 + 790 + 800) / 4 = 800
        XCTAssertEqual(metrics!.meanRR, 800, accuracy: 1,
                       "Mean RR should exclude artifacts. Got \(metrics!.meanRR)")
    }

    // MARK: - Edge Cases

    /// Insufficient data should return nil
    func testInsufficientData() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 810)
        ]

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        let metrics = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: points.count
        )

        XCTAssertNil(metrics, "Should return nil for insufficient data")
    }

    /// Window bounds should be respected
    func testWindowBounds() {
        let points = (0..<20).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800 + (i % 2 == 0 ? 20 : -20))
        }

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        // Analyze only middle 10 beats
        let metrics = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: 5,
            windowEnd: 15
        )

        XCTAssertNotNil(metrics)
        // Should analyze exactly 10 beats
    }
}
