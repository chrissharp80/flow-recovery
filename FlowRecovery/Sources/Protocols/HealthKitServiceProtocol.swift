//
//  Copyright © 2024-2026 Chris Sharp. All rights reserved.
//

import Foundation

/// Protocol for HealthKit integration
protocol HealthKitServiceProtocol {

    /// Whether HealthKit is available on this device
    var isHealthKitAvailable: Bool { get }

    /// Request authorization for HealthKit access
    func requestAuthorization() async throws

    // MARK: - Sleep Data

    /// Fetch sleep data for last night
    func fetchLastNightSleep() async throws -> HealthKitManager.SleepData

    /// Fetch sleep data for a recording period
    func fetchSleepData(
        for recordingStart: Date,
        recordingEnd: Date,
        extendForDisplay: Bool
    ) async throws -> HealthKitManager.SleepData

    /// Fetch historical sleep data
    func fetchHistoricalSleep(days: Int) async throws -> [HealthKitManager.SleepData]

    // MARK: - Heart Rate

    /// Fetch daytime resting heart rate
    func fetchDaytimeRestingHR(for sleepDate: Date) async throws -> Double?

    // MARK: - Training Load

    /// Calculate training load metrics
    func calculateTrainingLoad() async -> HealthKitManager.TrainingLoad

    /// Fetch VO2max
    func fetchVO2Max() async -> Double?

    // MARK: - Recovery Vitals

    /// Fetch recovery vitals (respiratory rate, SpO2, temperature)
    func fetchRecoveryVitals() async throws -> HealthKitManager.RecoveryVitals
}
