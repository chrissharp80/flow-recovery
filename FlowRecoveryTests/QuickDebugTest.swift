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

/// Quick debug test to verify basic functionality
final class QuickDebugTest: XCTestCase {

    func testBasicImport() {
        print("✅ Test framework is working")
        XCTAssertTrue(true)
    }

    func testCanCreateRRPoint() {
        let point = RRPoint(t_ms: 0, rr_ms: 800)
        print("✅ Created RRPoint: \(point.rr_ms)ms")
        XCTAssertEqual(point.rr_ms, 800)
    }

    func testCanCreateRRSeries() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 810)
        ]
        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        print("✅ Created RRSeries with \(series.points.count) points")
        XCTAssertEqual(series.points.count, 2)
    }

    func testTimeDomainAnalysisBasic() {
        print("🔍 Testing TimeDomain analysis...")

        // Need at least 10 points for TimeDomain analysis
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 810),
            RRPoint(t_ms: 1610, rr_ms: 820),
            RRPoint(t_ms: 2430, rr_ms: 800),
            RRPoint(t_ms: 3230, rr_ms: 790),
            RRPoint(t_ms: 4020, rr_ms: 805),
            RRPoint(t_ms: 4825, rr_ms: 815),
            RRPoint(t_ms: 5640, rr_ms: 795),
            RRPoint(t_ms: 6435, rr_ms: 800),
            RRPoint(t_ms: 7235, rr_ms: 810)
        ]

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        print("  - Created series with \(points.count) points")
        print("  - Calling TimeDomainAnalyzer.computeTimeDomain...")

        let metrics = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: points.count
        )

        if let m = metrics {
            print("✅ Got metrics: meanRR=\(m.meanRR)ms, meanHR=\(m.meanHR)bpm, RMSSD=\(m.rmssd)")
            XCTAssertGreaterThan(m.meanRR, 0)
            XCTAssertGreaterThan(m.meanHR, 0)
        } else {
            print("❌ Metrics is nil!")
            XCTFail("TimeDomain analysis returned nil")
        }
    }
}
