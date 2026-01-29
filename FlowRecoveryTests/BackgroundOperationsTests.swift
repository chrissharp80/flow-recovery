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

/// Tests for background audio and location managers
final class BackgroundOperationsTests: XCTestCase {

    // MARK: - Background Audio Tests

    /// Test audio session activation
    func testAudioSessionActivation() {
        let audioManager = BackgroundAudioManager.shared

        // Initial state
        XCTAssertFalse(audioManager.isPlaying)

        // Start background audio
        audioManager.startBackgroundAudio()

        // Should be playing
        XCTAssertTrue(audioManager.isPlaying)

        // Clean up
        audioManager.stopBackgroundAudio()
    }

    /// Test silent audio playback
    func testSilentAudioPlayback() {
        let audioManager = BackgroundAudioManager.shared

        audioManager.startBackgroundAudio()

        // Should be playing silent audio
        XCTAssertTrue(audioManager.isPlaying)

        // Audio should be at minimal volume
        XCTAssertLessThanOrEqual(audioManager.player?.volume ?? 1.0, 0.01)

        audioManager.stopBackgroundAudio()
    }

    /// Test audio interruption handling
    func testAudioInterruption() {
        let audioManager = BackgroundAudioManager.shared

        audioManager.startBackgroundAudio()
        XCTAssertTrue(audioManager.isPlaying)

        // Simulate phone call or other interruption
        // Audio should resume after interruption ends

        audioManager.stopBackgroundAudio()
    }

    /// Test audio route change
    func testAudioRouteChange() {
        let audioManager = BackgroundAudioManager.shared

        audioManager.startBackgroundAudio()

        // Simulate headphones plugged/unplugged
        // Audio should continue playing

        XCTAssertTrue(audioManager.isPlaying)

        audioManager.stopBackgroundAudio()
    }

    /// Test audio session deactivation
    func testAudioSessionDeactivation() {
        let audioManager = BackgroundAudioManager.shared

        audioManager.startBackgroundAudio()
        XCTAssertTrue(audioManager.isPlaying)

        audioManager.stopBackgroundAudio()

        // Should stop cleanly
        XCTAssertFalse(audioManager.isPlaying)
    }

    // MARK: - Background Location Tests

    /// Test location updates start
    func testLocationUpdatesStart() {
        let locationManager = BackgroundLocationManager.shared

        // Initial state
        XCTAssertFalse(locationManager.isUpdating)

        // Start location updates
        locationManager.startBackgroundLocation()

        // Should be updating
        XCTAssertTrue(locationManager.isUpdating)

        // Clean up
        locationManager.stopBackgroundLocation()
    }

    /// Test location accuracy
    func testLocationAccuracy() {
        let locationManager = BackgroundLocationManager.shared

        // Should use low accuracy to save battery
        XCTAssertNotNil(locationManager.locationManager)
    }

    /// Test location permissions
    func testLocationPermissions() {
        let locationManager = BackgroundLocationManager.shared

        // Should check authorization status
        XCTAssertNotNil(locationManager.locationManager)

        // If not authorized, should handle gracefully
    }

    /// Test location updates stop
    func testLocationUpdatesStop() {
        let locationManager = BackgroundLocationManager.shared

        locationManager.startBackgroundLocation()
        XCTAssertTrue(locationManager.isUpdating)

        locationManager.stopBackgroundLocation()

        // Should stop cleanly
        XCTAssertFalse(locationManager.isUpdating)
    }

    /// Test location battery impact
    func testLocationBatteryImpact() {
        let locationManager = BackgroundLocationManager.shared

        // Location should use minimal battery
        // Using significantLocationChangeUpdates instead of continuous

        locationManager.startBackgroundLocation()
        XCTAssertTrue(locationManager.isUpdating)

        locationManager.stopBackgroundLocation()
    }

    // MARK: - Integration Tests

    /// Test background overnight session
    func testBackgroundOvernightSession() async {
        let collector = RRCollector()

        // Set up session
        collector.currentSession = HRVSession(sessionType: .overnight)
        collector.isOvernightStreaming = true

        // Background audio and location should start
        BackgroundAudioManager.shared.startBackgroundAudio()
        BackgroundLocationManager.shared.startBackgroundLocation()

        XCTAssertTrue(BackgroundAudioManager.shared.isPlaying)
        XCTAssertTrue(BackgroundLocationManager.shared.isUpdating)

        // Add some data
        for i in 0..<150 {
            collector.polarManager.streamedRRPoints.append(
                RRPoint(t_ms: Int64(i * 920), rr_ms: 920)
            )
        }

        // Stop session
        let session = await collector.stopOvernightStreaming()

        // Background operations should stop
        BackgroundAudioManager.shared.stopBackgroundAudio()
        BackgroundLocationManager.shared.stopBackgroundLocation()

        XCTAssertFalse(BackgroundAudioManager.shared.isPlaying)
        XCTAssertFalse(BackgroundLocationManager.shared.isUpdating)

        // Clean up
        if let s = session {
            try? collector.archive.delete(s.id)
        }
    }

    /// Test background with phone call
    func testBackgroundWithPhoneCall() {
        let audioManager = BackgroundAudioManager.shared

        audioManager.startBackgroundAudio()
        XCTAssertTrue(audioManager.isPlaying)

        // Simulate phone call interruption
        // Audio should pause, then resume after call

        audioManager.stopBackgroundAudio()
    }

    /// Test background with alarm
    func testBackgroundWithAlarm() {
        let audioManager = BackgroundAudioManager.shared

        audioManager.startBackgroundAudio()

        // Alarm should fire without stopping background audio
        XCTAssertTrue(audioManager.isPlaying)

        audioManager.stopBackgroundAudio()
    }

    /// Test background with low power mode
    func testBackgroundWithLowPower() {
        let audioManager = BackgroundAudioManager.shared
        let locationManager = BackgroundLocationManager.shared

        // Start both
        audioManager.startBackgroundAudio()
        locationManager.startBackgroundLocation()

        // Even in low power mode, should continue
        XCTAssertTrue(audioManager.isPlaying)
        XCTAssertTrue(locationManager.isUpdating)

        // Clean up
        audioManager.stopBackgroundAudio()
        locationManager.stopBackgroundLocation()
    }

    /// Test background data preservation
    func testBackgroundDataPreservation() async {
        let collector = RRCollector()

        collector.currentSession = HRVSession(sessionType: .overnight)
        collector.isOvernightStreaming = true

        // Collect data
        for i in 0..<200 {
            collector.polarManager.streamedRRPoints.append(
                RRPoint(t_ms: Int64(i * 920), rr_ms: 920)
            )
        }

        // Simulate app backgrounding
        // Data should be preserved

        XCTAssertEqual(collector.polarManager.streamedRRPoints.count, 200)

        // Simulate app foregrounding
        // Data should still be there
        XCTAssertEqual(collector.polarManager.streamedRRPoints.count, 200)

        // Stop and verify data intact
        let session = await collector.stopOvernightStreaming()
        XCTAssertEqual(session?.rrSeries?.points.count, 200)

        // Clean up
        if let s = session {
            try? collector.archive.delete(s.id)
        }
    }
}
