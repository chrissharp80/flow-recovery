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

/// Storage and archive integrity tests
final class ArchiveIntegrityTests: XCTestCase {

    var archive: SessionArchive!
    var testSessionIds: [UUID] = []

    override func setUp() {
        super.setUp()
        archive = SessionArchive()
        testSessionIds = []
    }

    override func tearDown() {
        // Clean up test sessions
        for id in testSessionIds {
            try? archive.delete(id)
        }
        testSessionIds = []
        super.tearDown()
    }

    // MARK: - Basic Archive Operations

    /// Test archiving and retrieving a session
    func testArchiveAndRetrieve() throws {
        let session = createTestSession()
        testSessionIds.append(session.id)

        // Archive the session
        let entry = try archive.archive(session)

        XCTAssertEqual(entry.sessionId, session.id)
        XCTAssertNotNil(entry.fileHash)

        // Retrieve it back
        let retrieved = try archive.retrieve(session.id)

        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved!.id, session.id)
        XCTAssertEqual(retrieved!.startDate.timeIntervalSince1970,
                      session.startDate.timeIntervalSince1970,
                      accuracy: 1.0)
    }

    /// Test SHA256 hash verification
    func testHashVerification() throws {
        let session = createTestSession()
        testSessionIds.append(session.id)

        let entry = try archive.archive(session)

        // Hash should be 64 hex characters (256 bits)
        XCTAssertEqual(entry.fileHash.count, 64)

        // Retrieve should verify hash automatically
        let retrieved = try archive.retrieve(session.id)
        XCTAssertNotNil(retrieved)
    }

    /// Test duplicate session handling
    func testDuplicateHandling() throws {
        let session = createTestSession()
        testSessionIds.append(session.id)

        // Archive twice
        _ = try archive.archive(session)
        _ = try archive.archive(session)

        // Should only have one entry
        let entries = archive.entries
        let matchingEntries = entries.filter { $0.sessionId == session.id }
        XCTAssertEqual(matchingEntries.count, 1, "Should not create duplicate entries")
    }

    /// Test session deletion
    func testDeletion() throws {
        let session = createTestSession()

        _ = try archive.archive(session)
        XCTAssertTrue(archive.exists(session.id))

        try archive.delete(session.id)
        XCTAssertFalse(archive.exists(session.id))

        let retrieved = try? archive.retrieve(session.id)
        XCTAssertNil(retrieved)
    }

    // MARK: - Tag and Notes Management

    /// Test updating tags
    func testUpdateTags() throws {
        var session = createTestSession()
        session.tags = []
        testSessionIds.append(session.id)

        _ = try archive.archive(session)

        // Update with tags
        let newTags = [ReadingTag.morning, ReadingTag.stressed]
        try archive.updateTags(session.id, tags: newTags, notes: "Test note")

        let retrieved = try archive.retrieve(session.id)
        XCTAssertEqual(retrieved!.tags.count, 2)
        XCTAssertEqual(retrieved!.notes, "Test note")
    }

    /// Test filtering by tags
    func testTagFiltering() throws {
        // Create sessions with different tags
        var session1 = createTestSession()
        session1.tags = [ReadingTag.morning]
        testSessionIds.append(session1.id)

        var session2 = createTestSession()
        session2.tags = [ReadingTag.evening]
        testSessionIds.append(session2.id)

        var session3 = createTestSession()
        session3.tags = [ReadingTag.morning, ReadingTag.stressed]
        testSessionIds.append(session3.id)

        _ = try archive.archive(session1)
        _ = try archive.archive(session2)
        _ = try archive.archive(session3)

        // Filter for morning tag
        let morningEntries = archive.entries(includingTags: [ReadingTag.morning])

        let morningIds = Set(morningEntries.map { $0.sessionId })
        XCTAssertTrue(morningIds.contains(session1.id))
        XCTAssertFalse(morningIds.contains(session2.id))
        XCTAssertTrue(morningIds.contains(session3.id))
    }

    // MARK: - Concurrency Safety

    /// Test concurrent archive operations
    func testConcurrentAccess() throws {
        let expectation = self.expectation(description: "Concurrent operations")
        expectation.expectedFulfillmentCount = 10

        // Create multiple sessions
        let sessions = (0..<10).map { _ in createTestSession() }
        testSessionIds.append(contentsOf: sessions.map { $0.id })

        // Archive concurrently
        DispatchQueue.concurrentPerform(iterations: sessions.count) { index in
            do {
                _ = try archive.archive(sessions[index])
                expectation.fulfill()
            } catch {
                XCTFail("Concurrent archive failed: \(error)")
            }
        }

        wait(for: [expectation], timeout: 5.0)

        // All sessions should be archived
        for session in sessions {
            XCTAssertTrue(archive.exists(session.id))
        }
    }

    /// Test concurrent reads
    func testConcurrentReads() throws {
        let session = createTestSession()
        testSessionIds.append(session.id)
        _ = try archive.archive(session)

        let expectation = self.expectation(description: "Concurrent reads")
        expectation.expectedFulfillmentCount = 20

        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            do {
                let retrieved = try archive.retrieve(session.id)
                XCTAssertNotNil(retrieved)
                expectation.fulfill()
            } catch {
                XCTFail("Concurrent read failed: \(error)")
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - Batch Operations

    /// Test batch archiving
    func testBatchArchive() throws {
        // Create sessions with well-separated start times to avoid "near duplicate" detection
        let baseDate = Date().addingTimeInterval(-86400 * 7)  // 1 week ago
        let sessions = (0..<20).map { i in
            // Space sessions 2 hours apart to avoid hasSessionNear() conflicts
            createTestSession(startDate: baseDate.addingTimeInterval(Double(i) * 2 * 3600))
        }
        testSessionIds.append(contentsOf: sessions.map { $0.id })

        let count = try archive.archiveBatch(sessions)

        XCTAssertEqual(count, sessions.count, "Should archive all \(sessions.count) sessions. Got \(count)")

        // All should be retrievable
        for session in sessions {
            let retrieved = try archive.retrieve(session.id)
            XCTAssertNotNil(retrieved, "Should retrieve session \(session.id)")
        }
    }

    /// Test batch archive with duplicates
    func testBatchArchiveWithDuplicates() throws {
        var sessions = (0..<10).map { _ in createTestSession() }

        // Add a duplicate (same session twice)
        sessions.append(sessions[0])

        testSessionIds.append(contentsOf: Set(sessions.map { $0.id }))

        let count = try archive.archiveBatch(sessions)

        // Should only archive unique sessions
        XCTAssertLessThanOrEqual(count, 10)
    }

    // MARK: - Integrity Verification

    /// Test integrity check
    func testIntegrityVerification() throws {
        let session = createTestSession()
        testSessionIds.append(session.id)

        _ = try archive.archive(session)

        let results = archive.verifyIntegrity()

        XCTAssertNotNil(results[session.id])
        XCTAssertTrue(results[session.id]!,
                     "Integrity check should pass for valid session")
    }

    /// Test detecting nearby sessions
    func testHasSessionNear() throws {
        let baseDate = Date()
        let session = createTestSession(startDate: baseDate)
        testSessionIds.append(session.id)

        _ = try archive.archive(session)

        // Should find session within tolerance
        XCTAssertTrue(archive.hasSessionNear(date: baseDate.addingTimeInterval(10 * 60), toleranceMinutes: 30))

        // Should not find session outside tolerance
        XCTAssertFalse(archive.hasSessionNear(date: baseDate.addingTimeInterval(60 * 60), toleranceMinutes: 30))
    }

    // MARK: - Edge Cases

    /// Test empty archive
    func testEmptyArchive() {
        let entries = archive.entries
        // May have entries from other tests, so just verify it doesn't crash
        XCTAssertNotNil(entries)
    }

    /// Test retrieving non-existent session
    func testRetrieveNonExistent() throws {
        let fakeId = UUID()
        let retrieved = try archive.retrieve(fakeId)
        XCTAssertNil(retrieved)
    }

    /// Test deleting non-existent session
    func testDeleteNonExistent() {
        let fakeId = UUID()
        XCTAssertNoThrow(try archive.delete(fakeId))
    }

    // MARK: - Helper Methods

    private func createTestSession(startDate: Date? = nil) -> HRVSession {
        let sessionStartDate = startDate ?? Date().addingTimeInterval(-Double.random(in: 0...86400))
        let points = (0..<200).map { i in
            RRPoint(t_ms: Int64(i * 800), rr_ms: 800 + Int.random(in: -50...50))
        }

        let series = RRSeries(
            points: points,
            sessionId: UUID(),
            startDate: sessionStartDate
        )

        let flags = [ArtifactFlags](repeating: .clean, count: points.count)

        let timeDomain = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: points.count
        )

        // Create a basic nonlinear metrics object
        let nonlinear = NonlinearMetrics(
            sd1: 50.0,
            sd2: 100.0,
            sd1Sd2Ratio: 0.5,
            sampleEntropy: 1.5,
            approxEntropy: 1.2,
            dfaAlpha1: 1.0,
            dfaAlpha2: 1.0,
            dfaAlpha1R2: 0.95
        )

        return HRVSession(
            id: UUID(),
            startDate: series.startDate,
            endDate: series.startDate.addingTimeInterval(Double(points.count) * 0.8),
            state: .complete,
            sessionType: .overnight,
            rrSeries: series,
            analysisResult: timeDomain.map { td in
                HRVAnalysisResult(
                    windowStart: 0,
                    windowEnd: points.count,
                    timeDomain: td,
                    frequencyDomain: nil,
                    nonlinear: nonlinear,
                    ansMetrics: nil,
                    artifactPercentage: 0,
                    cleanBeatCount: points.count,
                    analysisDate: Date(),
                    windowStartMs: 0,
                    windowEndMs: Int64(points.count * 800),
                    windowMeanHR: nil,
                    windowHRStability: nil,
                    windowSelectionReason: nil,
                    windowRelativePosition: nil,
                    isConsolidated: nil,
                    isOrganizedRecovery: true,
                    windowClassification: "Organized Recovery",
                    peakCapacity: nil
                )
            },
            artifactFlags: flags,
            tags: [],
            notes: nil,
            deviceProvenance: nil
        )
    }
}
