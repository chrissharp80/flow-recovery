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

/// Integration tests covering acceptance criteria
final class IntegrationTests: XCTestCase {

    // MARK: - Critical: Reconciliation

    /// Reconciliation should block session start if session exists
    func testReconciliationBlocksDuplicateSession() throws {
        let archive = SessionArchive()
        let reconciliation = ReconciliationManager(archive: archive)

        // Create and complete a session
        var session = HRVSession()
        session.endDate = Date()
        session.state = .complete
        session.rrSeries = createTestSeries(beatCount: 150, sessionId: session.id)

        // Archive it
        try archive.archive(session)

        // Reconciliation should now block this session ID
        XCTAssertTrue(reconciliation.sessionExists(session.id),
                     "Reconciliation should report session exists after archiving")

        // Trying to queue again should throw
        XCTAssertThrowsError(try reconciliation.queueForSync(session)) { error in
            XCTAssertTrue(error is ReconciliationManager.ReconciliationError)
        }
    }

    // MARK: - Archive Integrity

    /// Archive hash should match file bytes
    func testArchiveHashMatchesFileBytes() throws {
        let archive = SessionArchive()

        var session = HRVSession()
        session.endDate = Date()
        session.state = .complete
        session.rrSeries = createTestSeries(beatCount: 200, sessionId: session.id)

        let entry = try archive.archive(session)

        // Verify integrity
        let results = archive.verifyIntegrity()
        XCTAssertTrue(results[session.id] == true,
                     "Archive integrity check should pass")

        // Retrieve and verify hash
        let retrieved = try archive.retrieve(session.id)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, session.id)
    }

    // MARK: - Duration Calculation

    /// Duration should use last.endMs
    func testDurationCalculation() {
        let points = [
            RRPoint(t_ms: 0, rr_ms: 800),
            RRPoint(t_ms: 800, rr_ms: 850),
            RRPoint(t_ms: 1650, rr_ms: 750)
        ]

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())

        // Duration should be from first t_ms to last endMs
        // last.endMs = 1650 + 750 = 2400
        // first.t_ms = 0
        // duration = 2400 - 0 = 2400ms
        XCTAssertEqual(series.durationMs, 2400,
                      "Duration should be last.endMs - first.t_ms")
    }

    // MARK: - Window Selection

    /// Recovery window should be found within temporal constraints
    func testRecoveryWindowSelectionWithTemporalConstraints() {
        let windowSelector = WindowSelector()

        // Create long series (simulating overnight - 8 hours at ~60bpm)
        // Use more realistic variation to produce valid DFA patterns
        let beatCount = 28800  // ~8 hours
        var points: [RRPoint] = []
        var t_ms: Int64 = 0

        for i in 0..<beatCount {
            // More physiological variation pattern
            let baseRR = 1000
            let slowWave = Int(20.0 * sin(Double(i) / 100.0))  // Slow respiratory variation
            let fastWave = Int(10.0 * sin(Double(i) / 10.0))   // Faster variation
            let noise = Int.random(in: -15...15)  // Random noise
            let rr = baseRR + slowWave + fastWave + noise

            points.append(RRPoint(t_ms: t_ms, rr_ms: rr))
            t_ms += Int64(rr)
        }

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let detector = ArtifactDetector()
        let flags = detector.detectArtifacts(in: series)

        // Wake time at the end of the recording
        let wakeTimeMs = t_ms

        let window = windowSelector.findBestWindow(in: series, flags: flags, wakeTimeMs: wakeTimeMs)

        // Should find a window (may be organized or high-variability depending on DFA)
        XCTAssertNotNil(window, "Should find a window for 8-hour recording")

        // Window should be within the temporal representativeness band (30-70%)
        if let window = window, let relativePosition = window.relativePosition {
            XCTAssertGreaterThanOrEqual(relativePosition, 0.30,
                                       "Window should be at least 30% into sleep episode")
            XCTAssertLessThanOrEqual(relativePosition, 0.70,
                                    "Window should be at most 70% into sleep episode")
        }
    }

    /// Test that short sleep returns no representative window
    func testNoRepresentativeWindowForShortSleep() {
        let windowSelector = WindowSelector()

        // Create short series (2 hours at ~60bpm)
        // With 3-hour pre-wake search window, all windows will be outside 30-70% band
        let beatCount = 7200  // ~2 hours
        let points = (0..<beatCount).map { i in
            RRPoint(t_ms: Int64(i * 1000), rr_ms: 1000 + (i % 50))
        }

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())
        let detector = ArtifactDetector()
        let flags = detector.detectArtifacts(in: series)

        // Wake time at the end
        let wakeTimeMs = Int64(beatCount * 1000)

        let window = windowSelector.findBestWindow(in: series, flags: flags, wakeTimeMs: wakeTimeMs)

        // With a 2-hour recording and 3-hour search window, all windows are in the last portion
        // which falls outside the 30-70% band, so no representative window should be found
        // This is the expected behavior for short/fragmented sleep
        XCTAssertNil(window, "Short sleep should return nil (no representative window)")
    }

    // MARK: - Full Analysis Pipeline

    /// Test complete analysis pipeline
    func testFullAnalysisPipeline() {
        // Generate realistic RR data with some variability
        let beatCount = 300  // 5 minutes at ~60bpm
        var points = [RRPoint]()
        var t: Int64 = 0

        for _ in 0..<beatCount {
            let rr = 1000 + Int.random(in: -100...100)  // ~60 bpm with variability
            points.append(RRPoint(t_ms: t, rr_ms: rr))
            t += Int64(rr)
        }

        let series = RRSeries(points: points, sessionId: UUID(), startDate: Date())

        // Detect artifacts
        let detector = ArtifactDetector()
        let flags = detector.detectArtifacts(in: series)

        // Should have mostly clean data
        let artifactPct = detector.artifactPercentage(flags, start: 0, end: beatCount)
        XCTAssertLessThan(artifactPct, 20,
                         "Realistic data should have <20% artifacts")

        // Time domain analysis
        let timeDomain = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: beatCount
        )
        XCTAssertNotNil(timeDomain)
        XCTAssertGreaterThan(timeDomain!.rmssd, 0)
        XCTAssertGreaterThan(timeDomain!.sdnn, 0)

        // Frequency domain analysis
        let frequencyDomain = FrequencyDomainAnalyzer.computeFrequencyDomain(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: beatCount
        )
        XCTAssertNotNil(frequencyDomain)
        XCTAssertGreaterThan(frequencyDomain!.totalPower, 0)

        // Nonlinear analysis
        let nonlinear = NonlinearAnalyzer.computeNonlinear(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: beatCount
        )
        XCTAssertNotNil(nonlinear)
        XCTAssertGreaterThan(nonlinear!.sd1, 0)
        XCTAssertGreaterThan(nonlinear!.sd2, 0)
    }

    // MARK: - Helpers

    private func createTestSeries(beatCount: Int, sessionId: UUID) -> RRSeries {
        let points = (0..<beatCount).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800)
        }
        return RRSeries(points: points, sessionId: sessionId, startDate: Date())
    }
}
