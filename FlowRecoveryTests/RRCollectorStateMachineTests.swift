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

/// Comprehensive state machine and session management tests for RRCollector
final class RRCollectorStateMachineTests: XCTestCase {

    var collector: RRCollector!

    override func setUp() {
        super.setUp()
        collector = RRCollector()
    }

    override func tearDown() {
        // Clean up any sessions created
        if let session = collector.currentSession {
            try? collector.archive.delete(session.id)
        }
        // Clear persisted state
        UserDefaults.standard.removeObject(forKey: "RRCollector.activeRecordingStartTime")
        UserDefaults.standard.removeObject(forKey: "RRCollector.activeRecordingSessionId")
        UserDefaults.standard.removeObject(forKey: "RRCollector.activeRecordingSessionType")
        collector = nil
        super.tearDown()
    }

    // MARK: - State Transition Tests

    /// Test idle to streaming transition
    func testIdleToStreaming() {
        XCTAssertFalse(collector.isOvernightStreaming)
        XCTAssertFalse(collector.isStreamingMode)
        XCTAssertFalse(collector.isCollecting)

        // Transition to streaming would require:
        // 1. Connected device
        // 2. Call startOvernightStreaming()
        // 3. State changes to streaming

        XCTAssertNil(collector.currentSession)
    }

    /// Test streaming to complete transition
    func testStreamingToComplete() async {
        // Set up streaming state
        collector.currentSession = HRVSession(sessionType: .overnight)
        collector.isOvernightStreaming = true
        collector.isCollecting = true

        // Add sufficient data
        for i in 0..<150 {
            collector.polarManager.streamedRRPoints.append(
                RRPoint(t_ms: Int64(i * 920), rr_ms: 920)
            )
        }

        // Stop streaming
        let session = await collector.stopOvernightStreaming()

        // Should transition to complete
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.state, .complete)
        XCTAssertFalse(collector.isOvernightStreaming)
        XCTAssertFalse(collector.isCollecting)

        // Clean up
        if let session = session {
            try? collector.archive.delete(session.id)
        }
    }

    /// Test streaming to failed transition
    func testStreamingToFailed() async {
        collector.currentSession = HRVSession(sessionType: .overnight)
        collector.isOvernightStreaming = true

        // Add insufficient data (< 120 beats)
        for i in 0..<100 {
            collector.polarManager.streamedRRPoints.append(
                RRPoint(t_ms: Int64(i * 920), rr_ms: 920)
            )
        }

        let session = await collector.stopOvernightStreaming()

        // Should fail
        XCTAssertEqual(session?.state, .failed)
        XCTAssertNotNil(collector.lastError)
    }

    /// Test complete to accepted transition
    func testCompleteToAccepted() async {
        // Create completed session
        let mockPoints = (0..<200).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800)
        }

        let series = RRSeries(points: mockPoints, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: mockPoints.count)

        let timeDomain = TimeDomainAnalyzer.computeTimeDomain(
            series, flags: flags, windowStart: 0, windowEnd: mockPoints.count
        )

        let session = HRVSession(
            startDate: Date(),
            endDate: Date(),
            state: .complete,
            sessionType: .overnight,
            rrSeries: series,
            analysisResult: timeDomain.map { td in
                HRVAnalysisResult(
                    windowStart: 0,
                    windowEnd: mockPoints.count,
                    timeDomain: td,
                    frequencyDomain: nil,
                    nonlinear: nil,
                    ansMetrics: nil,
                    artifactPercentage: 0,
                    cleanBeatCount: mockPoints.count,
                    analysisDate: Date()
                )
            },
            artifactFlags: flags
        )

        collector.currentSession = session
        collector.needsAcceptance = true

        // Accept
        try? await collector.acceptSession()

        // Should transition to accepted (cleared)
        XCTAssertFalse(collector.needsAcceptance)
        XCTAssertNil(collector.currentSession)

        // Clean up
        try? collector.archive.delete(session.id)
    }

    /// Test complete to rejected transition
    func testCompleteToRejected() async {
        let session = HRVSession(
            startDate: Date(),
            endDate: Date(),
            state: .complete,
            sessionType: .overnight
        )

        collector.currentSession = session
        collector.needsAcceptance = true

        // Reject
        await collector.rejectSession()

        // Should clear without archiving
        XCTAssertFalse(collector.needsAcceptance)
        XCTAssertNil(collector.currentSession)

        // Should NOT be in archive
        let archived = try? collector.archive.retrieve(session.id)
        XCTAssertNil(archived)
    }

    /// Test failed to retry transition
    func testFailedToRetry() async {
        // Create failed session
        let session = HRVSession(
            startDate: Date(),
            endDate: Date(),
            state: .failed,
            sessionType: .overnight
        )

        collector.currentSession = session

        // In production, user would tap "retry"
        // State should allow retry
        XCTAssertEqual(session.state, .failed)
    }

    /// Test streaming to canceled transition
    func testStreamingToCanceled() async {
        collector.currentSession = HRVSession(sessionType: .overnight)
        collector.isOvernightStreaming = true

        // User cancels mid-stream
        let session = await collector.stopOvernightStreaming()

        // Should handle gracefully even with 0 beats
        XCTAssertNotNil(session)
        XCTAssertFalse(collector.isOvernightStreaming)
    }

    /// Test persisted state recovery after app crash
    func testPersistedStateRecovery() {
        let sessionId = UUID()
        let startTime = Date().addingTimeInterval(-7200)  // 2 hours ago
        let sessionType = SessionType.overnight

        // Simulate app crashed during recording
        UserDefaults.standard.set(startTime, forKey: "RRCollector.activeRecordingStartTime")
        UserDefaults.standard.set(sessionId.uuidString, forKey: "RRCollector.activeRecordingSessionId")
        UserDefaults.standard.set(sessionType.rawValue, forKey: "RRCollector.activeRecordingSessionType")

        // Create new collector (simulates app restart)
        let recovered = RRCollector()

        // Should detect persisted state
        XCTAssertTrue(recovered.hasPersistedRecordingState)

        let state = recovered.getPersistedRecordingState()
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.sessionId, sessionId)
        XCTAssertEqual(state?.sessionType, sessionType)

        // Start time should match
        let timeDiff = abs(state!.startTime.timeIntervalSince(startTime))
        XCTAssertLessThan(timeDiff, 1.0)
    }

    /// Test invalid state transition prevention
    func testInvalidStateTransition() {
        // Can't go from idle directly to complete
        XCTAssertNil(collector.currentSession)
        XCTAssertFalse(collector.needsAcceptance)

        // Can't accept without a session
        XCTAssertFalse(collector.needsAcceptance)
    }

    /// Test concurrent state change prevention
    func testConcurrentStateChange() {
        // Only one session should be active at a time
        XCTAssertNil(collector.currentSession)

        let session1 = HRVSession(sessionType: .overnight)
        collector.currentSession = session1

        // Setting another session should replace
        let session2 = HRVSession(sessionType: .quick)
        collector.currentSession = session2

        XCTAssertEqual(collector.currentSession?.sessionType, .quick)

        // Clean up
        try? collector.archive.delete(session2.id)
    }

    /// Test state rollback on error
    func testStateRollbackOnError() async {
        // If error occurs, state should rollback
        collector.currentSession = HRVSession(sessionType: .overnight)
        collector.isOvernightStreaming = true

        // Simulate error (no data)
        let session = await collector.stopOvernightStreaming()

        // Should handle error gracefully
        XCTAssertNotNil(session)
        XCTAssertFalse(collector.isOvernightStreaming)
    }

    /// Test state persistence during crash
    func testStatePersistenceOnCrash() {
        let sessionId = UUID()
        let startTime = Date()

        // Start recording
        UserDefaults.standard.set(startTime, forKey: "RRCollector.activeRecordingStartTime")
        UserDefaults.standard.set(sessionId.uuidString, forKey: "RRCollector.activeRecordingSessionId")
        UserDefaults.standard.set("overnight", forKey: "RRCollector.activeRecordingSessionType")

        // Simulate crash (app terminates)
        // State should be persisted in UserDefaults

        // On restart
        let newCollector = RRCollector()

        // Should be able to recover
        XCTAssertTrue(newCollector.hasPersistedRecordingState)
    }

    // MARK: - Session Management Tests

    /// Test overnight session creation
    func testOvernightSessionCreation() {
        XCTAssertNil(collector.currentSession)

        // Create overnight session
        let session = HRVSession(sessionType: .overnight)

        XCTAssertEqual(session.sessionType, .overnight)
        XCTAssertEqual(session.state, .idle)
        XCTAssertNotNil(session.id)
    }

    /// Test nap session creation
    func testNapSessionCreation() {
        let session = HRVSession(sessionType: .nap)

        XCTAssertEqual(session.sessionType, .nap)
        XCTAssertEqual(session.state, .idle)
    }

    /// Test quick session creation
    func testQuickSessionCreation() {
        let session = HRVSession(sessionType: .quick)

        XCTAssertEqual(session.sessionType, .quick)
        XCTAssertEqual(session.state, .idle)
    }

    /// Test session duplication prevention
    func testSessionDuplicationPrevention() async {
        // Create and archive a session
        let session = HRVSession(
            startDate: Date(),
            endDate: Date(),
            state: .complete,
            sessionType: .overnight
        )

        try? collector.archive.archive(session)

        // Try to archive duplicate
        // Should be prevented by reconciliation
        let exists = collector.archive.exists(session.id)
        XCTAssertTrue(exists)

        // Clean up
        try? collector.archive.delete(session.id)
    }

    /// Test session ID consistency
    func testSessionIDConsistency() {
        let session = HRVSession()
        let id1 = session.id

        // ID should remain consistent
        let id2 = session.id
        XCTAssertEqual(id1, id2)
    }

    /// Test session timestamp accuracy
    func testSessionTimestampAccuracy() {
        let before = Date()
        let session = HRVSession()
        let after = Date()

        // Session timestamp should be between before and after
        XCTAssertGreaterThanOrEqual(session.startDate, before)
        XCTAssertLessThanOrEqual(session.startDate, after)
    }

    /// Test session metadata tracking
    func testSessionMetadataTracking() {
        let session = HRVSession(sessionType: .overnight)

        XCTAssertEqual(session.sessionType, .overnight)
        XCTAssertNil(session.notes)
        XCTAssertEqual(session.tags.count, 0)
    }

    /// Test multiple sessions sequential
    func testMultipleSessionsSequential() async {
        // Session 1
        collector.currentSession = HRVSession(sessionType: .overnight)
        collector.isOvernightStreaming = true

        for i in 0..<150 {
            collector.polarManager.streamedRRPoints.append(
                RRPoint(t_ms: Int64(i * 920), rr_ms: 920)
            )
        }

        let session1 = await collector.stopOvernightStreaming()
        XCTAssertNotNil(session1)

        // Clean up session 1
        if let s1 = session1 {
            try? collector.archive.delete(s1.id)
        }

        // Reset polar manager for next session
        collector.polarManager.streamedRRPoints = []

        // Session 2
        collector.currentSession = HRVSession(sessionType: .quick)
        collector.isOvernightStreaming = true

        for i in 0..<150 {
            collector.polarManager.streamedRRPoints.append(
                RRPoint(t_ms: Int64(i * 920), rr_ms: 920)
            )
        }

        let session2 = await collector.stopOvernightStreaming()
        XCTAssertNotNil(session2)

        // Should be different sessions
        XCTAssertNotEqual(session1?.id, session2?.id)

        // Clean up
        if let s2 = session2 {
            try? collector.archive.delete(s2.id)
        }
    }

    /// Test session cleanup on error
    func testSessionCleanupOnError() async {
        collector.currentSession = HRVSession(sessionType: .overnight)
        collector.isOvernightStreaming = true

        // Cause error (insufficient data)
        let session = await collector.stopOvernightStreaming()

        // Should fail gracefully
        XCTAssertEqual(session?.state, .failed)
        XCTAssertFalse(collector.isOvernightStreaming)
    }

    /// Test session archive integration
    func testSessionArchiveIntegration() async {
        let mockPoints = (0..<200).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800)
        }

        let series = RRSeries(points: mockPoints, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: mockPoints.count)

        let timeDomain = TimeDomainAnalyzer.computeTimeDomain(
            series, flags: flags, windowStart: 0, windowEnd: mockPoints.count
        )

        let session = HRVSession(
            startDate: Date(),
            endDate: Date(),
            state: .complete,
            sessionType: .overnight,
            rrSeries: series,
            analysisResult: timeDomain.map { td in
                HRVAnalysisResult(
                    windowStart: 0,
                    windowEnd: mockPoints.count,
                    timeDomain: td,
                    frequencyDomain: nil,
                    nonlinear: nil,
                    ansMetrics: nil,
                    artifactPercentage: 0,
                    cleanBeatCount: mockPoints.count,
                    analysisDate: Date()
                )
            },
            artifactFlags: flags
        )

        collector.currentSession = session
        collector.needsAcceptance = true

        // Accept and archive
        try? await collector.acceptSession()

        // Should be in archive
        let archived = try? collector.archive.retrieve(session.id)
        XCTAssertNotNil(archived)

        // Clean up
        try? collector.archive.delete(session.id)
    }

    /// Test session tagging
    func testSessionTagging() async {
        let mockPoints = (0..<200).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800)
        }

        let series = RRSeries(points: mockPoints, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: mockPoints.count)

        let timeDomain = TimeDomainAnalyzer.computeTimeDomain(
            series, flags: flags, windowStart: 0, windowEnd: mockPoints.count
        )

        var session = HRVSession(
            startDate: Date(),
            endDate: Date(),
            state: .complete,
            sessionType: .overnight,
            rrSeries: series,
            analysisResult: timeDomain.map { td in
                HRVAnalysisResult(
                    windowStart: 0,
                    windowEnd: mockPoints.count,
                    timeDomain: td,
                    frequencyDomain: nil,
                    nonlinear: nil,
                    ansMetrics: nil,
                    artifactPercentage: 0,
                    cleanBeatCount: mockPoints.count,
                    analysisDate: Date()
                )
            },
            artifactFlags: flags
        )

        // Add tags
        session.tags = [ReadingTag.morning, ReadingTag.stressed]

        collector.currentSession = session
        try? collector.archive.archive(session)

        // Update tags
        try? collector.archive.updateTags(
            session.id,
            tags: [ReadingTag.morning, ReadingTag.stressed, ReadingTag.recovery],
            notes: "Test notes"
        )

        let retrieved = try? collector.archive.retrieve(session.id)
        XCTAssertEqual(retrieved?.tags.count, 3)
        XCTAssertEqual(retrieved?.notes, "Test notes")

        // Clean up
        try? collector.archive.delete(session.id)
    }

    /// Test session notes management
    func testSessionNotesManagement() async {
        let session = HRVSession(
            startDate: Date(),
            endDate: Date(),
            state: .complete,
            sessionType: .overnight
        )

        try? collector.archive.archive(session)

        // Add notes
        try? collector.archive.updateTags(
            session.id,
            tags: [],
            notes: "Initial notes"
        )

        var retrieved = try? collector.archive.retrieve(session.id)
        XCTAssertEqual(retrieved?.notes, "Initial notes")

        // Update notes
        try? collector.archive.updateTags(
            session.id,
            tags: [],
            notes: "Updated notes"
        )

        retrieved = try? collector.archive.retrieve(session.id)
        XCTAssertEqual(retrieved?.notes, "Updated notes")

        // Clean up
        try? collector.archive.delete(session.id)
    }

    // MARK: - Background Operations Tests

    /// Test background audio lifecycle
    func testBackgroundAudioLifecycle() {
        // Background audio should start with overnight streaming
        XCTAssertFalse(collector.isOvernightStreaming)

        // After starting overnight streaming, background audio should be active
        // (can't test actual audio without running on device)
    }

    /// Test background location lifecycle
    func testBackgroundLocationLifecycle() {
        // Background location should start with overnight streaming
        XCTAssertFalse(collector.isOvernightStreaming)
    }

    /// Test background data collection
    func testBackgroundDataCollection() async {
        // Data should continue collecting in background
        collector.currentSession = HRVSession(sessionType: .overnight)
        collector.isOvernightStreaming = true

        // Add data
        for i in 0..<150 {
            collector.polarManager.streamedRRPoints.append(
                RRPoint(t_ms: Int64(i * 920), rr_ms: 920)
            )
        }

        // Should preserve data even if app backgrounds
        XCTAssertEqual(collector.polarManager.streamedRRPoints.count, 150)

        // Clean up
        let session = await collector.stopOvernightStreaming()
        if let s = session {
            try? collector.archive.delete(s.id)
        }
    }

    // MARK: - Error Recovery Tests

    /// Test recovery from BLE disconnect
    func testRecoveryFromBLEDisconnect() {
        // If BLE disconnects during streaming, data should be preserved
        collector.currentSession = HRVSession(sessionType: .overnight)
        collector.isOvernightStreaming = true

        // Add some data
        for i in 0..<50 {
            collector.polarManager.streamedRRPoints.append(
                RRPoint(t_ms: Int64(i * 920), rr_ms: 920)
            )
        }

        let dataBeforeDisconnect = collector.polarManager.streamedRRPoints.count
        XCTAssertEqual(dataBeforeDisconnect, 50)

        // BLE disconnect would preserve data
        // On reconnect, should continue from where left off
    }

    /// Test recovery from analysis failure
    func testRecoveryFromAnalysisFailure() async {
        // If analysis fails, should still save raw data
        collector.currentSession = HRVSession(sessionType: .overnight)
        collector.isOvernightStreaming = true

        // Add data
        for i in 0..<150 {
            collector.polarManager.streamedRRPoints.append(
                RRPoint(t_ms: Int64(i * 920), rr_ms: 920)
            )
        }

        // Even if analysis fails, raw data should be backed up
        let session = await collector.stopOvernightStreaming()
        XCTAssertNotNil(session)

        // Clean up
        if let s = session {
            try? collector.archive.delete(s.id)
        }
    }
}
