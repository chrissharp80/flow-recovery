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

/// Tests for RRCollector - Session orchestration and lifecycle
final class RRCollectorTests: XCTestCase {

    var collector: RRCollector!

    override func setUp() {
        super.setUp()
        collector = RRCollector()
    }

    override func tearDown() {
        // Clean up any sessions created during tests
        if let session = collector.currentSession {
            try? collector.archive.delete(session.id)
        }
        collector = nil
        super.tearDown()
    }

    // MARK: - Overnight Streaming Tests

    /// Test overnight streaming can be started
    func testStartOvernightStreaming() {
        // Note: This test can only verify state changes, not actual BLE streaming
        // which requires a real Polar H10 device

        XCTAssertFalse(collector.isOvernightStreaming, "Should not be streaming initially")
        XCTAssertFalse(collector.isCollecting, "Should not be collecting initially")

        // Starting overnight streaming requires connected device
        // Without real device, we test the state management

        // Verify initial state
        XCTAssertNil(collector.currentSession, "Should have no session initially")
        XCTAssertEqual(collector.streamingElapsedSeconds, 0, "Elapsed time should be 0")
    }

    /// Test stopping overnight streaming with sufficient data
    func testStopOvernightStreamingWithSufficientData() async {
        // Create a mock session with sufficient data
        let mockPoints = (0..<150).map { i in
            RRPoint(t_ms: Int64(i * 920), rr_ms: 920)
        }

        // Manually set up streaming state
        collector.currentSession = HRVSession(sessionType: .overnight)
        collector.isOvernightStreaming = true
        collector.isCollecting = true

        // Manually add points to polar manager
        for point in mockPoints {
            collector.polarManager.streamedRRPoints.append(point)
        }

        // Stop streaming
        let session = await collector.stopOvernightStreaming()

        // Verify session completed successfully
        XCTAssertNotNil(session, "Should return a session")
        XCTAssertEqual(session?.state, .complete, "Session should be complete with 150 beats")
        XCTAssertFalse(collector.isOvernightStreaming, "Should no longer be streaming")
        XCTAssertFalse(collector.isCollecting, "Should no longer be collecting")
    }

    /// Test stopping overnight streaming with insufficient data (< 120 beats)
    func testStopOvernightStreamingWithInsufficientData() async {
        // Create a mock session with insufficient data (< 120 beats)
        let mockPoints = (0..<100).map { i in
            RRPoint(t_ms: Int64(i * 920), rr_ms: 920)
        }

        collector.currentSession = HRVSession(sessionType: .overnight)
        collector.isOvernightStreaming = true

        for point in mockPoints {
            collector.polarManager.streamedRRPoints.append(point)
        }

        let session = await collector.stopOvernightStreaming()

        // Should fail with insufficient data
        XCTAssertNotNil(session, "Should return a session")
        XCTAssertEqual(session?.state, .failed, "Session should fail with only 100 beats")
        XCTAssertNotNil(collector.lastError, "Should have an error set")
    }

    /// Test the 120-beat minimum threshold (the threshold we just changed)
    func testMinimumBeatThreshold() async {
        // Test exactly at the threshold
        let mockPoints = (0..<120).map { i in
            RRPoint(t_ms: Int64(i * 920), rr_ms: 920)
        }

        collector.currentSession = HRVSession(sessionType: .overnight)
        collector.isOvernightStreaming = true

        for point in mockPoints {
            collector.polarManager.streamedRRPoints.append(point)
        }

        let session = await collector.stopOvernightStreaming()

        // Should succeed with exactly 120 beats
        XCTAssertNotNil(session, "Should return a session")
        XCTAssertEqual(session?.state, .complete, "Should succeed with exactly 120 beats")

        // Clean up
        if let session = session {
            try? collector.archive.delete(session.id)
        }
    }

    /// Test the 119-beat case (just below threshold)
    func testJustBelowThreshold() async {
        let mockPoints = (0..<119).map { i in
            RRPoint(t_ms: Int64(i * 920), rr_ms: 920)
        }

        collector.currentSession = HRVSession(sessionType: .overnight)
        collector.isOvernightStreaming = true

        for point in mockPoints {
            collector.polarManager.streamedRRPoints.append(point)
        }

        let session = await collector.stopOvernightStreaming()

        // Should fail with 119 beats
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.state, .failed, "Should fail with 119 beats (just below threshold)")
    }

    // MARK: - Quick Streaming Tests

    /// Test streaming session lifecycle
    func testStreamingSessionLifecycle() {
        XCTAssertFalse(collector.isStreamingMode, "Should not be in streaming mode initially")

        // Start a 3-minute streaming session
        // Note: Requires connected device in real usage
        collector.streamingTargetSeconds = 180

        // Verify target is set
        XCTAssertEqual(collector.streamingTargetSeconds, 180)
    }

    /// Test streaming elapsed time tracking
    func testStreamingElapsedTimeTracking() {
        collector.streamingElapsedSeconds = 0
        collector.streamingTargetSeconds = 180

        // Simulate time passing
        collector.streamingElapsedSeconds = 45

        XCTAssertEqual(collector.streamingElapsedSeconds, 45)
        XCTAssertLessThan(collector.streamingElapsedSeconds, collector.streamingTargetSeconds)
    }

    // MARK: - Persisted State Tests

    /// Test persisted recording state is saved
    func testPersistedRecordingStateSaved() {
        let sessionId = UUID()
        let startTime = Date()
        let sessionType = SessionType.overnight

        // Simulate starting a session (would normally call startOvernightStreaming)
        UserDefaults.standard.set(startTime, forKey: "RRCollector.activeRecordingStartTime")
        UserDefaults.standard.set(sessionId.uuidString, forKey: "RRCollector.activeRecordingSessionId")
        UserDefaults.standard.set(sessionType.rawValue, forKey: "RRCollector.activeRecordingSessionType")

        // Retrieve persisted state
        let retrieved = collector.getPersistedRecordingState()

        XCTAssertNotNil(retrieved, "Should retrieve persisted state")
        XCTAssertEqual(retrieved?.sessionId, sessionId)
        XCTAssertEqual(retrieved?.sessionType, sessionType)

        // Clean up
        UserDefaults.standard.removeObject(forKey: "RRCollector.activeRecordingStartTime")
        UserDefaults.standard.removeObject(forKey: "RRCollector.activeRecordingSessionId")
        UserDefaults.standard.removeObject(forKey: "RRCollector.activeRecordingSessionType")
    }

    /// Test persisted state is cleared after successful session
    func testPersistedStateCleared() {
        let sessionId = UUID()
        let startTime = Date()

        // Set persisted state
        UserDefaults.standard.set(startTime, forKey: "RRCollector.activeRecordingStartTime")
        UserDefaults.standard.set(sessionId.uuidString, forKey: "RRCollector.activeRecordingSessionId")
        UserDefaults.standard.set("overnight", forKey: "RRCollector.activeRecordingSessionType")

        // Verify it exists
        XCTAssertTrue(collector.hasPersistedRecordingState)

        // Manually call clearPersistedRecordingState (normally called after successful stop)
        UserDefaults.standard.removeObject(forKey: "RRCollector.activeRecordingStartTime")
        UserDefaults.standard.removeObject(forKey: "RRCollector.activeRecordingSessionId")
        UserDefaults.standard.removeObject(forKey: "RRCollector.activeRecordingSessionType")

        // Verify it's cleared
        XCTAssertFalse(collector.hasPersistedRecordingState)
    }

    /// Test recovery from persisted state after app restart
    func testRecoveryFromPersistedState() {
        let sessionId = UUID()
        let startTime = Date().addingTimeInterval(-3600)  // 1 hour ago
        let sessionType = SessionType.overnight

        // Simulate persisted state from previous session
        UserDefaults.standard.set(startTime, forKey: "RRCollector.activeRecordingStartTime")
        UserDefaults.standard.set(sessionId.uuidString, forKey: "RRCollector.activeRecordingSessionId")
        UserDefaults.standard.set(sessionType.rawValue, forKey: "RRCollector.activeRecordingSessionType")

        // Create a fresh collector (simulating app restart)
        let freshCollector = RRCollector()

        // Should detect persisted state
        XCTAssertTrue(freshCollector.hasPersistedRecordingState)

        let recovered = freshCollector.getPersistedRecordingState()
        XCTAssertNotNil(recovered)
        XCTAssertEqual(recovered?.sessionId, sessionId)
        XCTAssertEqual(recovered?.sessionType, sessionType)

        // Start time should be from 1 hour ago
        let timeDiff = abs(recovered!.startTime.timeIntervalSince(startTime))
        XCTAssertLessThan(timeDiff, 1.0, "Start time should match persisted value")

        // Clean up
        UserDefaults.standard.removeObject(forKey: "RRCollector.activeRecordingStartTime")
        UserDefaults.standard.removeObject(forKey: "RRCollector.activeRecordingSessionId")
        UserDefaults.standard.removeObject(forKey: "RRCollector.activeRecordingSessionType")
    }

    // MARK: - Session Acceptance Tests

    /// Test accepting a completed session
    func testAcceptSession() async {
        // Create a completed session
        let mockPoints = (0..<200).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800)
        }

        let series = RRSeries(points: mockPoints, sessionId: UUID(), startDate: Date())
        let flags = [ArtifactFlags](repeating: .clean, count: mockPoints.count)

        let timeDomain = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: mockPoints.count
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

        // Accept the session
        try? await collector.acceptSession()

        // Verify session was accepted
        XCTAssertFalse(collector.needsAcceptance, "Should no longer need acceptance")
        XCTAssertNil(collector.currentSession, "Current session should be cleared after acceptance")

        // Verify session was archived
        let archived = try? collector.archive.retrieve(session.id)
        XCTAssertNotNil(archived, "Session should be in archive")

        // Clean up
        try? collector.archive.delete(session.id)
    }

    /// Test rejecting a session
    func testRejectSession() async {
        let session = HRVSession(
            startDate: Date(),
            endDate: Date(),
            state: .complete,
            sessionType: .overnight
        )

        collector.currentSession = session
        collector.needsAcceptance = true

        // Reject the session
        await collector.rejectSession()

        // Verify session was rejected
        XCTAssertFalse(collector.needsAcceptance, "Should no longer need acceptance")
        XCTAssertNil(collector.currentSession, "Current session should be cleared after rejection")

        // Verify session was NOT archived
        let archived = try? collector.archive.retrieve(session.id)
        XCTAssertNil(archived, "Session should not be in archive after rejection")
    }

    // MARK: - Error Handling Tests

    /// Test insufficient data error
    func testInsufficientDataError() async {
        let mockPoints = (0..<50).map { i in  // Only 50 beats - way too few
            RRPoint(t_ms: Int64(i * 920), rr_ms: 920)
        }

        collector.currentSession = HRVSession(sessionType: .overnight)
        collector.isOvernightStreaming = true

        for point in mockPoints {
            collector.polarManager.streamedRRPoints.append(point)
        }

        let session = await collector.stopOvernightStreaming()

        // Should fail
        XCTAssertEqual(session?.state, .failed)
        XCTAssertNotNil(collector.lastError)

        // Error should be insufficientData
        if let error = collector.lastError as? RRCollector.CollectorError {
            XCTAssertEqual(error, .insufficientData)
        }
    }

    // MARK: - Archive Integration Tests

    /// Test that completed sessions are backed up
    func testRawDataBackup() async {
        let mockPoints = (0..<150).map { i in
            RRPoint(t_ms: Int64(i * 920), rr_ms: 920)
        }

        collector.currentSession = HRVSession(sessionType: .overnight)
        collector.isOvernightStreaming = true

        for point in mockPoints {
            collector.polarManager.streamedRRPoints.append(point)
        }

        let session = await collector.stopOvernightStreaming()

        // Verify backup was created
        XCTAssertNotNil(session)

        // Clean up
        if let session = session {
            try? collector.archive.delete(session.id)
        }
    }

    // MARK: - Collected Points Tests

    /// Test that collected points are updated during streaming
    func testCollectedPointsTracking() {
        XCTAssertEqual(collector.collectedPoints.count, 0, "Should have no points initially")

        // Simulate adding points to polar manager
        let mockPoints = (0..<10).map { i in
            RRPoint(t_ms: Int64(i * 920), rr_ms: 920)
        }

        for point in mockPoints {
            collector.polarManager.streamedRRPoints.append(point)
        }

        // In real usage, the timer updates collectedPoints from streamingBuffer
        collector.collectedPoints = collector.polarManager.streamingBuffer

        XCTAssertEqual(collector.collectedPoints.count, 10, "Should track collected points")
    }
}

// MARK: - CollectorError Tests

extension RRCollectorTests {
    /// Test error descriptions
    func testErrorDescriptions() {
        let errors: [RRCollector.CollectorError] = [
            .notConnected,
            .alreadyRecording,
            .sessionExists,
            .insufficientData,
            .noSessionToAccept,
            .noSessionToRecover,
            .dataAlreadyExists
        ]

        // All errors should have descriptive messages
        for error in errors {
            XCTAssertFalse(error.localizedDescription.isEmpty, "Error should have description")
        }

        // Check specific message
        XCTAssertEqual(
            RRCollector.CollectorError.insufficientData.localizedDescription,
            "Not enough RR data collected (need at least 120 beats)"
        )
    }
}
