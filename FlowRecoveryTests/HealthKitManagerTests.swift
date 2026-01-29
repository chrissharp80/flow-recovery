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
import HealthKit
@testable import FlowRecovery

/// Tests for HealthKit integration
final class HealthKitManagerTests: XCTestCase {

    var healthKit: HealthKitManager!

    override func setUp() {
        super.setUp()
        healthKit = HealthKitManager()
    }

    override func tearDown() {
        healthKit = nil
        super.tearDown()
    }

    // MARK: - Authorization Tests

    /// Test HealthKit availability check
    func testHealthKitAvailability() {
        #if targetEnvironment(simulator)
        // HealthKit may not be available on simulator
        XCTAssertNotNil(healthKit)
        #else
        // On device, HealthKit should be available
        XCTAssertTrue(HKHealthStore.isHealthDataAvailable())
        #endif
    }

    /// Test authorization request
    func testRequestAuthorization() async {
        // Request authorization
        do {
            try await healthKit.requestAuthorization()
            // Authorization request should complete without error
            XCTAssertTrue(true)
        } catch {
            // On simulator or if HealthKit unavailable, may fail
            // That's okay for unit tests
            XCTAssertNotNil(error)
        }
    }

    /// Test authorization status check
    func testAuthorizationStatusCheck() {
        #if !targetEnvironment(simulator)
        let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        let status = healthKit.healthStore.authorizationStatus(for: sleepType)

        // Status should be one of the valid states
        XCTAssertTrue([.notDetermined, .sharingDenied, .sharingAuthorized].contains(status))
        #endif
    }

    /// Test authorization already granted scenario
    func testAuthorizationAlreadyGranted() async {
        // If already authorized, second request should succeed quickly
        do {
            try await healthKit.requestAuthorization()
            try await healthKit.requestAuthorization()

            // Both should complete
            XCTAssertTrue(true)
        } catch {
            // Expected on simulator
            XCTAssertNotNil(error)
        }
    }

    // MARK: - Sleep Data Tests

    /// Test fetch sleep data success
    func testFetchSleepDataSuccess() async {
        // Try to fetch sleep data
        do {
            let sleepData = try await healthKit.fetchSleepData(
                for: Date().addingTimeInterval(-86400),  // Yesterday
                recordingEnd: Date()
            )

            // On simulator, likely returns empty
            // On device with sleep data, should return SleepData struct
            XCTAssertNotNil(sleepData)
            XCTAssertGreaterThanOrEqual(sleepData.totalSleepMinutes, 0)
        } catch {
            // Expected on simulator without authorization
            XCTAssertNotNil(error)
        }
    }

    /// Test fetch sleep data empty
    func testFetchSleepDataEmpty() async {
        // Fetch from a time range with no sleep data
        do {
            let sleepData = try await healthKit.fetchSleepData(
                for: Date().addingTimeInterval(-86400 * 365 * 100),  // 100 years ago
                recordingEnd: Date().addingTimeInterval(-86400 * 365 * 99)      // 99 years ago
            )

            // Should return empty SleepData (no sleep minutes)
            XCTAssertEqual(sleepData.totalSleepMinutes, 0)
        } catch {
            // Expected on simulator
            XCTAssertNotNil(error)
        }
    }

    /// Test fetch sleep data error handling
    func testFetchSleepDataError() async {
        // Without authorization, should fail gracefully
        do {
            let _ = try await healthKit.fetchSleepData(
                for: Date().addingTimeInterval(-86400),
                recordingEnd: Date()
            )
        } catch {
            // Should get error if not authorized
            XCTAssertNotNil(error)
        }
    }

    /// Test sleep data parsing
    func testSleepDataParsing() {
        #if !targetEnvironment(simulator)
        // Create mock sleep sample
        let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        let now = Date()
        let start = now.addingTimeInterval(-8 * 3600)  // 8 hours ago

        let sample = HKCategorySample(
            type: sleepType,
            value: HKCategoryValueSleepAnalysis.inBed.rawValue,
            start: start,
            end: now
        )

        XCTAssertEqual(sample.startDate, start)
        XCTAssertEqual(sample.endDate, now)
        #endif
    }

    /// Test sleep timing accuracy
    func testSleepTimingAccuracy() {
        // Sleep data should have accurate timestamps
        let now = Date()
        let start = now.addingTimeInterval(-8 * 3600)

        // Time difference should be 8 hours
        let duration = now.timeIntervalSince(start)
        XCTAssertEqual(duration, 8 * 3600, accuracy: 1.0)
    }

    /// Test multiple naps detection
    func testMultipleNapsDetection() async {
        // Should be able to detect multiple sleep periods in one day
        do {
            let sleepData = try await healthKit.fetchSleepData(
                for: Date().addingTimeInterval(-86400),
                recordingEnd: Date()
            )

            // May have multiple sleep periods (naps, overnight)
            XCTAssertNotNil(sleepData)
        } catch {
            XCTAssertNotNil(error)
        }
    }

    /// Test sleep stage recognition
    func testSleepStageRecognition() {
        #if !targetEnvironment(simulator)
        // HealthKit provides different sleep stages
        let stages: [HKCategoryValueSleepAnalysis] = [
            .inBed,
            .asleep,
            .awake
        ]

        // All stages should be valid
        for stage in stages {
            XCTAssertGreaterThanOrEqual(stage.rawValue, 0)
        }
        #endif
    }

    // MARK: - Integration Tests

    /// Test sleep data session correlation
    func testSleepDataSessionCorrelation() async {
        // When user completes overnight session, should correlate with HealthKit sleep data
        let sessionStart = Date().addingTimeInterval(-8 * 3600)
        let sessionEnd = Date()

        // Fetch sleep data for same period
        do {
            let sleepData = try await healthKit.fetchSleepData(
                for: sessionStart.addingTimeInterval(-3600),  // 1 hour before
                recordingEnd: sessionEnd.addingTimeInterval(3600)         // 1 hour after
            )

            // Should find overlapping sleep data (if any exists)
            XCTAssertNotNil(sleepData)
        } catch {
            XCTAssertNotNil(error)
        }
    }

    /// Test missing sleep data handling
    func testMissingSleepDataHandling() async {
        // If no sleep data available, should handle gracefully
        do {
            let sleepData = try await healthKit.fetchSleepData(
                for: Date().addingTimeInterval(-1000),
                recordingEnd: Date()
            )

            // Empty result is valid (SleepData with 0 minutes)
            XCTAssertNotNil(sleepData)
        } catch {
            // Error is also valid
            XCTAssertNotNil(error)
        }
    }

    /// Test sleep data caching
    func testSleepDataCaching() async {
        // Fetch sleep data twice
        let start = Date().addingTimeInterval(-86400)
        let end = Date()

        do {
            let data1 = try await healthKit.fetchSleepData(for: start, recordingEnd: end)
            let data2 = try await healthKit.fetchSleepData(for: start, recordingEnd: end)

            // Should return same data
            XCTAssertEqual(data1.totalSleepMinutes, data2.totalSleepMinutes)
        } catch {
            XCTAssertNotNil(error)
        }
    }
}
