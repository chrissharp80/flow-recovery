//
//  Copyright © 2024-2026 Chris Sharp. All rights reserved.
//
//  This source code is provided for reference and verification purposes only.
//  Unauthorized copying, modification, distribution, or use of this code,
//  via any medium, is strictly prohibited without prior written permission.
//
//  For licensing inquiries, contact the copyright holder.
//

import CoreLocation
import UIKit

/// Manages background location updates to keep the app alive during overnight streaming
/// Uses minimal accuracy to reduce battery impact while maintaining continuous background execution
final class BackgroundLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = BackgroundLocationManager()

    private var locationManager: CLLocationManager?
    @Published private(set) var isRunning = false
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private override init() {
        super.init()
    }

    /// Check if location services can be used for background keep-alive
    /// Note: This property is intentionally synchronous despite the warning.
    /// It's called during initialization before UI is shown, and the
    /// locationManagerDidChangeAuthorization callback handles runtime changes.
    var canUseLocationServices: Bool {
        CLLocationManager.locationServicesEnabled() &&
        (authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse)
    }

    /// Check if we have "Always" authorization (required for true background operation)
    var hasAlwaysAuthorization: Bool {
        authorizationStatus == .authorizedAlways
    }

    /// Request location authorization - call this before starting
    func requestAuthorization() {
        if locationManager == nil {
            setupLocationManager()
        }

        guard let manager = locationManager else { return }

        // Request "When In Use" first, then can upgrade to "Always"
        // This is Apple's recommended two-step approach
        if authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else if authorizationStatus == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }
    }

    /// Start background location updates to keep app alive
    /// Will request authorization if needed
    func startBackgroundLocation() {
        guard !isRunning else {
            debugLog("BackgroundLocationManager: Already running")
            return
        }

        if locationManager == nil {
            setupLocationManager()
        }

        guard let manager = locationManager else {
            debugLog("BackgroundLocationManager: Failed to create location manager")
            return
        }

        // Request authorization if needed - will start in delegate callback when granted
        if authorizationStatus == .notDetermined {
            debugLog("BackgroundLocationManager: Requesting authorization")
            pendingStart = true
            manager.requestWhenInUseAuthorization()
            return
        }

        // Check authorization
        guard canUseLocationServices else {
            debugLog("BackgroundLocationManager: Location services not authorized (status: \(authorizationStatus.rawValue))")
            return
        }

        startLocationUpdates(manager: manager)
    }

    private var pendingStart = false

    private func startLocationUpdates(manager: CLLocationManager) {
        // Configure for minimal battery impact
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers  // Lowest accuracy = lowest battery
        manager.distanceFilter = CLLocationDistanceMax  // Only update on significant changes
        manager.pausesLocationUpdatesAutomatically = false  // Never pause - we need continuous background
        manager.allowsBackgroundLocationUpdates = true  // Enable background updates
        manager.showsBackgroundLocationIndicator = true  // Show blue bar (required for transparency)

        // Start updates
        manager.startUpdatingLocation()

        isRunning = true
        pendingStart = false
        // No logging - start/stop already logged in RRCollector
    }

    /// Stop background location updates
    func stopBackgroundLocation() {
        guard isRunning else { return }

        locationManager?.stopUpdatingLocation()
        isRunning = false
        // No logging - start/stop already logged in RRCollector
    }

    // MARK: - Private

    private func setupLocationManager() {
        let manager = CLLocationManager()
        manager.delegate = self
        locationManager = manager
        authorizationStatus = manager.authorizationStatus
        debugLog("BackgroundLocationManager: Initialized with status \(authorizationStatus.rawValue)")
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let newStatus = manager.authorizationStatus
        debugLog("BackgroundLocationManager: Authorization changed from \(authorizationStatus.rawValue) to \(newStatus.rawValue)")

        authorizationStatus = newStatus

        // If we were waiting for authorization and got it, start location updates
        if pendingStart && canUseLocationServices {
            debugLog("BackgroundLocationManager: Authorization granted, starting location updates")
            startLocationUpdates(manager: manager)
        }

        // If we lost authorization while running, stop
        if isRunning && !canUseLocationServices {
            debugLog("BackgroundLocationManager: Lost authorization while running")
            isRunning = false
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // We don't actually need the location data - this is just to keep the app alive
        // No logging - these updates happen constantly during overnight and are too noisy
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Location errors are not critical for our use case
        // We just need the app to stay alive, not accurate location
        debugLog("BackgroundLocationManager: Location error (non-critical): \(error.localizedDescription)")
    }
}
