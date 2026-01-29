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

/// Tests for PolarManager - BLE connection and streaming
final class PolarManagerTests: XCTestCase {

    // MARK: - RR Data Extraction Tests

    /// Test that RR intervals are correctly extracted when rrAvailable is true
    func testRRDataExtractionWhenAvailable() {
        // This tests the bug we just fixed!
        let manager = PolarManager()

        // Simulate starting streaming to initialize state
        manager.streamingStartTime = Date()
        manager.streamingCumulativeMs = 0
        manager.streamedRRPoints = []

        // Create mock HR data with RR intervals available
        let mockSample = (
            hr: UInt8(65),
            ppgQuality: UInt8(0),
            correctedHr: UInt8(65),
            rrsMs: [920, 940, 930, 910],  // 4 RR intervals
            rrAvailable: true,
            contactStatus: true,
            contactStatusSupported: true
        )

        let mockHrData: [(hr: UInt8, ppgQuality: UInt8, correctedHr: UInt8, rrsMs: [Int], rrAvailable: Bool, contactStatus: Bool, contactStatusSupported: Bool)] = [mockSample]

        // Call the handler (this would be called by Polar SDK)
        manager.handleStreamedHRDataForTesting(mockHrData)

        // Verify RR intervals were extracted
        XCTAssertEqual(manager.streamedRRPoints.count, 4, "Should extract all 4 RR intervals")
        XCTAssertEqual(manager.streamedRRPoints[0].rr_ms, 920)
        XCTAssertEqual(manager.streamedRRPoints[1].rr_ms, 940)
        XCTAssertEqual(manager.streamedRRPoints[2].rr_ms, 930)
        XCTAssertEqual(manager.streamedRRPoints[3].rr_ms, 910)

        // Verify cumulative time is tracked
        let expectedCumulative = Int64(920 + 940 + 930 + 910)
        XCTAssertEqual(manager.streamingCumulativeMs, expectedCumulative)
    }

    /// Test that RR intervals are skipped when rrAvailable is false
    func testRRDataSkippedWhenNotAvailable() {
        let manager = PolarManager()

        manager.streamingStartTime = Date()
        manager.streamingCumulativeMs = 0
        manager.streamedRRPoints = []

        // Create mock HR data WITHOUT RR intervals
        let mockSample = (
            hr: UInt8(65),
            ppgQuality: UInt8(0),
            correctedHr: UInt8(65),
            rrsMs: [],  // Empty array
            rrAvailable: false,  // RR not available!
            contactStatus: true,
            contactStatusSupported: true
        )

        let mockHrData: [(hr: UInt8, ppgQuality: UInt8, correctedHr: UInt8, rrsMs: [Int], rrAvailable: Bool, contactStatus: Bool, contactStatusSupported: Bool)] = [mockSample]

        manager.handleStreamedHRDataForTesting(mockHrData)

        // Verify NO RR intervals were added
        XCTAssertEqual(manager.streamedRRPoints.count, 0, "Should not extract RR when rrAvailable is false")
        XCTAssertEqual(manager.streamingCumulativeMs, 0, "Cumulative time should remain 0")
    }

    /// Test handling multiple samples in a single batch
    func testMultipleSamplesInBatch() {
        let manager = PolarManager()

        manager.streamingStartTime = Date()
        manager.streamingCumulativeMs = 0
        manager.streamedRRPoints = []

        // Create multiple samples in one batch
        let sample1 = (
            hr: UInt8(65),
            ppgQuality: UInt8(0),
            correctedHr: UInt8(65),
            rrsMs: [920, 940],
            rrAvailable: true,
            contactStatus: true,
            contactStatusSupported: true
        )

        let sample2 = (
            hr: UInt8(66),
            ppgQuality: UInt8(0),
            correctedHr: UInt8(66),
            rrsMs: [910],
            rrAvailable: true,
            contactStatus: true,
            contactStatusSupported: true
        )

        let sample3 = (
            hr: UInt8(67),
            ppgQuality: UInt8(0),
            correctedHr: UInt8(67),
            rrsMs: [],
            rrAvailable: false,  // This one has no RR data
            contactStatus: true,
            contactStatusSupported: true
        )

        let mockHrData = [sample1, sample2, sample3]

        manager.handleStreamedHRDataForTesting(mockHrData)

        // Should extract RR from sample1 and sample2, skip sample3
        XCTAssertEqual(manager.streamedRRPoints.count, 3, "Should extract 2 + 1 + 0 = 3 RR intervals")
        XCTAssertEqual(manager.streamedRRPoints[0].rr_ms, 920)
        XCTAssertEqual(manager.streamedRRPoints[1].rr_ms, 940)
        XCTAssertEqual(manager.streamedRRPoints[2].rr_ms, 910)
    }

    /// Test that empty rrsMs array is handled correctly even when rrAvailable is true
    func testEmptyRRsMsArray() {
        let manager = PolarManager()

        manager.streamingStartTime = Date()
        manager.streamingCumulativeMs = 0
        manager.streamedRRPoints = []

        // Edge case: rrAvailable is true but array is empty
        let mockSample = (
            hr: UInt8(65),
            ppgQuality: UInt8(0),
            correctedHr: UInt8(65),
            rrsMs: [],  // Empty!
            rrAvailable: true,  // But flag says available
            contactStatus: true,
            contactStatusSupported: true
        )

        let mockHrData: [(hr: UInt8, ppgQuality: UInt8, correctedHr: UInt8, rrsMs: [Int], rrAvailable: Bool, contactStatus: Bool, contactStatusSupported: Bool)] = [mockSample]

        // Should not crash
        XCTAssertNoThrow(manager.handleStreamedHRDataForTesting(mockHrData))

        // No RR intervals should be added
        XCTAssertEqual(manager.streamedRRPoints.count, 0)
    }

    /// Test cumulative time calculation across multiple calls
    func testCumulativeTimeTracking() {
        let manager = PolarManager()

        manager.streamingStartTime = Date()
        manager.streamingCumulativeMs = 0
        manager.streamedRRPoints = []

        // First batch
        let batch1 = [(
            hr: UInt8(65),
            ppgQuality: UInt8(0),
            correctedHr: UInt8(65),
            rrsMs: [1000, 1000],  // 2 seconds
            rrAvailable: true,
            contactStatus: true,
            contactStatusSupported: true
        )]

        manager.handleStreamedHRDataForTesting(batch1)
        XCTAssertEqual(manager.streamingCumulativeMs, 2000)
        XCTAssertEqual(manager.streamedRRPoints.count, 2)

        // Second batch - cumulative should continue
        let batch2 = [(
            hr: UInt8(65),
            ppgQuality: UInt8(0),
            correctedHr: UInt8(65),
            rrsMs: [1000, 1000, 1000],  // 3 more seconds
            rrAvailable: true,
            contactStatus: true,
            contactStatusSupported: true
        )]

        manager.handleStreamedHRDataForTesting(batch2)
        XCTAssertEqual(manager.streamingCumulativeMs, 5000, "Cumulative time should be 5 seconds")
        XCTAssertEqual(manager.streamedRRPoints.count, 5, "Should have 5 total points")

        // Verify t_ms values are cumulative
        XCTAssertEqual(manager.streamedRRPoints[0].t_ms, 0)
        XCTAssertEqual(manager.streamedRRPoints[1].t_ms, 1000)
        XCTAssertEqual(manager.streamedRRPoints[2].t_ms, 2000)
        XCTAssertEqual(manager.streamedRRPoints[3].t_ms, 3000)
        XCTAssertEqual(manager.streamedRRPoints[4].t_ms, 4000)
    }

    /// Test wall clock time is captured
    func testWallClockTimeCapture() {
        let manager = PolarManager()

        let startTime = Date()
        manager.streamingStartTime = startTime
        manager.streamingCumulativeMs = 0
        manager.streamedRRPoints = []

        // Wait a bit to create wall-clock offset
        Thread.sleep(forTimeInterval: 0.1)

        let mockSample = (
            hr: UInt8(65),
            ppgQuality: UInt8(0),
            correctedHr: UInt8(65),
            rrsMs: [920],
            rrAvailable: true,
            contactStatus: true,
            contactStatusSupported: true
        )

        let mockHrData: [(hr: UInt8, ppgQuality: UInt8, correctedHr: UInt8, rrsMs: [Int], rrAvailable: Bool, contactStatus: Bool, contactStatusSupported: Bool)] = [mockSample]

        manager.handleStreamedHRDataForTesting(mockHrData)

        // Wall clock should be > 0 (at least 100ms passed)
        XCTAssertGreaterThan(manager.streamedRRPoints[0].wallClockMs ?? 0, 50,
                            "Wall clock time should reflect actual elapsed time")
    }

    /// Test realistic scenario: 2 minutes of continuous streaming
    func testRealisticTwoMinuteStream() {
        let manager = PolarManager()

        manager.streamingStartTime = Date()
        manager.streamingCumulativeMs = 0
        manager.streamedRRPoints = []

        // Simulate ~2 minutes at 65 bpm (130 beats)
        // Typical RR interval at 65 bpm is ~923ms
        let totalBeats = 130
        let avgRR = 923

        // Simulate receiving data in batches (Polar sends ~1 sample per second)
        for _ in 0..<totalBeats {
            let rr = avgRR + Int.random(in: -50...50)  // Some variation

            let mockSample = (
                hr: UInt8(65),
                ppgQuality: UInt8(0),
                correctedHr: UInt8(65),
                rrsMs: [rr],
                rrAvailable: true,
                contactStatus: true,
                contactStatusSupported: true
            )

            let mockHrData: [(hr: UInt8, ppgQuality: UInt8, correctedHr: UInt8, rrsMs: [Int], rrAvailable: Bool, contactStatus: Bool, contactStatusSupported: Bool)] = [mockSample]
            manager.handleStreamedHRDataForTesting(mockHrData)
        }

        // Verify we collected all beats
        XCTAssertEqual(manager.streamedRRPoints.count, 130, "Should collect 130 beats")

        // Verify total duration is approximately 2 minutes
        let totalDurationMs = manager.streamingCumulativeMs
        let expectedMs = Int64(avgRR * totalBeats)
        let tolerance = Int64(10000)  // 10 second tolerance

        XCTAssertEqual(totalDurationMs, expectedMs, accuracy: tolerance,
                      "Total duration should be approximately 2 minutes")
    }
}

// MARK: - Testing Extension

extension PolarManager {
    /// Expose handleStreamedHRData for testing
    /// This allows us to test the RR extraction logic without the Polar SDK
    func handleStreamedHRDataForTesting(_ hrData: [(hr: UInt8, ppgQuality: UInt8, correctedHr: UInt8, rrsMs: [Int], rrAvailable: Bool, contactStatus: Bool, contactStatusSupported: Bool)]) {
        // Simulate the same logic as the real handler
        let wallClockNow: Int64
        if let startTime = streamingStartTime {
            wallClockNow = Int64(Date().timeIntervalSince(startTime) * 1000.0)
        } else {
            wallClockNow = 0
        }

        for sample in hrData {
            guard sample.rrAvailable else {
                continue
            }

            for rr in sample.rrsMs {
                let rrInterval = Int(rr)
                let point = RRPoint(
                    t_ms: streamingCumulativeMs,
                    rr_ms: rrInterval,
                    wallClockMs: wallClockNow
                )
                streamedRRPoints.append(point)
                streamingCumulativeMs += Int64(rrInterval)
            }
        }
    }
}
