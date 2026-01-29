//
//  Copyright © 2024-2026 Chris Sharp. All rights reserved.
//
//  This source code is provided for reference and verification purposes only.
//  Unauthorized copying, modification, distribution, or use of this code,
//  via any medium, is strictly prohibited without prior written permission.
//
//  For licensing inquiries, contact the copyright holder.
//

import Foundation
import HealthKit

/// HealthKit integration for sleep data and HRV export
final class HealthKitManager: ObservableObject {

    // MARK: - Properties

    private let healthStore = HKHealthStore()
    /// IMPORTANT: This flag only indicates authorization was REQUESTED, not that it was granted.
    /// HealthKit deliberately doesn't reveal if read access was denied to protect user privacy.
    ///
    /// Callers MUST:
    /// - Handle empty results gracefully (user may have denied access)
    /// - Never assume data will be available just because this flag is true
    /// - Provide appropriate fallback UI when sleep/HR data is unavailable
    @Published var authorizationRequested = false
    @Published var lastSleepData: SleepData?

    // MARK: - Types

    enum SleepBoundarySource: String {
        case healthKit = "HealthKit"           // From Apple Watch/HealthKit
        case hrEstimated = "HR Estimated"      // Estimated from HR drop patterns
        case recordingBounds = "Recording"     // Using recording start/end as fallback
    }

    struct SleepData {
        let date: Date
        let inBedStart: Date?       // When user got into bed (for latency calculation)
        let sleepStart: Date?       // When sleep actually started
        let sleepEnd: Date?         // When sleep actually ended
        let totalSleepMinutes: Int
        let inBedMinutes: Int
        let deepSleepMinutes: Int?  // Only available from Apple Watch
        let remSleepMinutes: Int?   // Only available from Apple Watch
        let awakeMinutes: Int
        let sleepEfficiency: Double  // % of in-bed time actually asleep
        let boundarySource: SleepBoundarySource  // Where sleep boundaries came from

        /// Sleep latency in minutes (time from getting in bed to falling asleep)
        var sleepLatencyMinutes: Int? {
            guard let inBed = inBedStart, let sleep = sleepStart else { return nil }
            let latency = Int(sleep.timeIntervalSince(inBed) / 60)
            return latency > 0 ? latency : nil
        }

        var totalSleepFormatted: String {
            let hours = totalSleepMinutes / 60
            let mins = totalSleepMinutes % 60
            return hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
        }

        static let empty = SleepData(
            date: Date(),
            inBedStart: nil,
            sleepStart: nil,
            sleepEnd: nil,
            totalSleepMinutes: 0,
            inBedMinutes: 0,
            deepSleepMinutes: nil,
            remSleepMinutes: nil,
            awakeMinutes: 0,
            sleepEfficiency: 0,
            boundarySource: .recordingBounds
        )
    }

    // MARK: - Authorization

    /// Check if HealthKit is available on this device
    var isHealthKitAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    /// Request authorization to read sleep data
    func requestAuthorization() async throws {
        guard isHealthKitAvailable else {
            throw HealthKitError.notAvailable
        }

        // Types we want to read
        var readTypes: Set<HKObjectType> = [
            HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!,
            HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!,
            HKObjectType.quantityType(forIdentifier: .heartRate)!,
            HKObjectType.quantityType(forIdentifier: .vo2Max)!,
            HKObjectType.workoutType(),
            HKObjectType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKObjectType.quantityType(forIdentifier: .respiratoryRate)!,
            HKObjectType.quantityType(forIdentifier: .oxygenSaturation)!
        ]

        // Wrist temperature requires iOS 16+
        if #available(iOS 16.0, *) {
            readTypes.insert(HKObjectType.quantityType(forIdentifier: .appleSleepingWristTemperature)!)
        }

        // Types we want to write (future: export HRV data)
        let writeTypes: Set<HKSampleType> = [
            HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN)!
        ]

        try await healthStore.requestAuthorization(toShare: writeTypes, read: readTypes)
        debugLog("[HealthKitManager] Authorization request completed (note: HealthKit doesn't reveal if read access was denied)")

        await MainActor.run {
            self.authorizationRequested = true
        }
    }

    // MARK: - Sleep Data

    /// Fetch sleep data for last night (or most recent sleep session)
    func fetchLastNightSleep() async throws -> SleepData {
        guard isHealthKitAvailable else {
            throw HealthKitError.notAvailable
        }

        let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!

        // Look for sleep in the overnight window (6pm yesterday to 12pm today)
        // This avoids counting daytime naps as main sleep
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)

        // Overnight window: 6pm yesterday to 12pm today
        let windowStart = calendar.date(byAdding: .hour, value: -6, to: todayStart)!  // 6pm yesterday
        let windowEnd = calendar.date(byAdding: .hour, value: 12, to: todayStart)!     // 12pm today

        let predicate = HKQuery.predicateForSamples(
            withStart: windowStart,
            end: min(windowEnd, now),
            options: .strictStartDate
        )

        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        let allSamples: [HKCategorySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, results, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: results as? [HKCategorySample] ?? [])
            }
            healthStore.execute(query)
        }

        // Deduplicate: use only ONE source to avoid double-counting
        // iPhone and Apple Watch both write sleep data for the same night
        // Priority: Apple Watch (detailed stages) > iPhone > third-party apps

        // Group samples by source
        var samplesBySource: [String: [HKCategorySample]] = [:]
        for sample in allSamples {
            let bundleId = sample.sourceRevision.source.bundleIdentifier
            samplesBySource[bundleId, default: []].append(sample)
        }

        // Find the best source: prefer Watch, then iPhone, then any
        let watchSource = samplesBySource.keys.first { $0.lowercased().contains("watch") }
        let appleSource = samplesBySource.keys.first { $0.hasPrefix("com.apple.health") && !$0.contains("watch") }

        let selectedSource: String?
        if let watch = watchSource {
            selectedSource = watch
        } else if let apple = appleSource {
            selectedSource = apple
        } else {
            // Use source with most samples
            selectedSource = samplesBySource.max(by: { $0.value.count < $1.value.count })?.key
        }

        let samples = selectedSource.flatMap { samplesBySource[$0] } ?? allSamples

        debugLog("[HealthKitManager] Sleep: \(allSamples.count) total samples from \(samplesBySource.count) sources, using \(selectedSource ?? "all") (\(samples.count) samples)")

        // Process sleep samples
        var inBedMinutes = 0
        var asleepMinutes = 0
        var deepMinutes = 0
        var remMinutes = 0
        var awakeMinutes = 0

        // Track actual sleep start and end times (from asleep stages only)
        var earliestSleepStart: Date?
        var latestSleepEnd: Date?

        // Track inBed boundaries separately as fallback
        var earliestInBedStart: Date?
        var latestInBedEnd: Date?

        for sample in samples {
            let duration = Int(sample.endDate.timeIntervalSince(sample.startDate) / 60)

            switch sample.value {
            case HKCategoryValueSleepAnalysis.inBed.rawValue:
                inBedMinutes += duration
                earliestInBedStart.updateMin(sample.startDate)
                latestInBedEnd.updateMax(sample.endDate)

            case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                asleepMinutes += duration
                earliestSleepStart.updateMin(sample.startDate)
                latestSleepEnd.updateMax(sample.endDate)

            case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                asleepMinutes += duration
                earliestSleepStart.updateMin(sample.startDate)
                latestSleepEnd.updateMax(sample.endDate)

            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                deepMinutes += duration
                asleepMinutes += duration
                earliestSleepStart.updateMin(sample.startDate)
                latestSleepEnd.updateMax(sample.endDate)

            case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                remMinutes += duration
                asleepMinutes += duration
                earliestSleepStart.updateMin(sample.startDate)
                latestSleepEnd.updateMax(sample.endDate)

            case HKCategoryValueSleepAnalysis.awake.rawValue:
                awakeMinutes += duration
            default:
                break
            }
        }

        // If no detailed sleep stages, total asleep is the full duration
        let totalSleep = max(asleepMinutes, inBedMinutes - awakeMinutes)

        // Calculate inBedMinutes from boundaries to avoid double-counting overlapping samples
        // Multiple sources (iPhone Sleep schedule + Apple Watch) can report overlapping .inBed periods
        var effectiveInBedMinutes: Int
        if let inBedStart = earliestInBedStart, let inBedEnd = latestInBedEnd {
            // Use boundary times - most accurate when multiple sources exist
            effectiveInBedMinutes = Int(inBedEnd.timeIntervalSince(inBedStart) / 60)
        } else if let sleepStart = earliestSleepStart, let sleepEnd = latestSleepEnd {
            // iOS 16+ Apple Watch no longer writes .inBed samples, only sleep stages
            // Estimate in-bed time from sleep stage boundaries
            effectiveInBedMinutes = Int(sleepEnd.timeIntervalSince(sleepStart) / 60)
        } else {
            // Fallback to summed duration (shouldn't happen with valid data)
            effectiveInBedMinutes = inBedMinutes
        }

        // Cap efficiency at 100% - can exceed if sleep stages don't match in-bed detection
        let efficiency = min(100, effectiveInBedMinutes > 0 ? Double(totalSleep) / Double(effectiveInBedMinutes) * 100 : 0)

        // Use actual sleep boundaries when available, fall back to inBed only when no sleep stages
        let finalSleepStart = earliestSleepStart ?? earliestInBedStart
        let finalSleepEnd = latestSleepEnd ?? latestInBedEnd

        // inBedStart is from explicit .inBed samples or fall back to sleep start
        let inBedStart = earliestInBedStart ?? earliestSleepStart

        let sleepData = SleepData(
            date: samples.first?.endDate ?? now,
            inBedStart: inBedStart,
            sleepStart: finalSleepStart,
            sleepEnd: finalSleepEnd,
            totalSleepMinutes: totalSleep,
            inBedMinutes: effectiveInBedMinutes,
            deepSleepMinutes: deepMinutes > 0 ? deepMinutes : nil,
            remSleepMinutes: remMinutes > 0 ? remMinutes : nil,
            awakeMinutes: awakeMinutes,
            sleepEfficiency: efficiency,
            boundarySource: .healthKit
        )

        await MainActor.run {
            self.lastSleepData = sleepData
        }

        return sleepData
    }

    /// Fetch sleep data for a specific recording session
    /// Uses Apple's sleep data as the authoritative source - no truncation
    /// The recording times are used only to identify which sleep session is relevant
    func fetchSleepData(for recordingStart: Date, recordingEnd: Date, extendForDisplay: Bool = false) async throws -> SleepData {
        _ = extendForDisplay  // Kept for API compatibility

        guard isHealthKitAvailable else {
            throw HealthKitError.notAvailable
        }

        let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        let calendar = Calendar.current

        // Search broadly: 6 PM the day before to noon the day after
        // This captures any sleep session that could be relevant to the recording
        let dayStart = calendar.startOfDay(for: recordingStart)
        let searchStart = calendar.date(byAdding: .hour, value: -6, to: dayStart)!  // 6 PM previous day
        let searchEnd = calendar.date(byAdding: .hour, value: 36, to: dayStart)!    // Noon next day

        debugLog("[HealthKitManager] Recording: \(recordingStart) to \(recordingEnd)")
        debugLog("[HealthKitManager] Search window: \(searchStart) to \(searchEnd)")

        let predicate = HKQuery.predicateForSamples(
            withStart: searchStart,
            end: searchEnd,
            options: []
        )

        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, results, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: results as? [HKCategorySample] ?? [])
            }
            healthStore.execute(query)
        }

        // Deduplicate by source FIRST (before any filtering)
        // Prefer Apple Watch > iPhone > third-party
        var samplesBySource: [String: [HKCategorySample]] = [:]
        for sample in samples {
            let bundleId = sample.sourceRevision.source.bundleIdentifier
            samplesBySource[bundleId, default: []].append(sample)
        }

        let watchSource = samplesBySource.keys.first { $0.lowercased().contains("watch") }
        let appleSource = samplesBySource.keys.first { $0.hasPrefix("com.apple.health") && !$0.contains("watch") }

        let selectedSource: String?
        if let watch = watchSource {
            selectedSource = watch
        } else if let apple = appleSource {
            selectedSource = apple
        } else {
            selectedSource = samplesBySource.max(by: { $0.value.count < $1.value.count })?.key
        }

        let deduplicatedSamples = selectedSource.flatMap { samplesBySource[$0] } ?? samples

        debugLog("[HealthKitManager] Found \(samples.count) samples from \(samplesBySource.count) sources, using \(selectedSource ?? "all") (\(deduplicatedSamples.count) samples)")

        // Group samples into sleep sessions (contiguous samples within 2 hours = same session)
        let sortedSamples = deduplicatedSamples.sorted { $0.startDate < $1.startDate }
        var sessions: [[HKCategorySample]] = []
        var currentSession: [HKCategorySample] = []

        for sample in sortedSamples {
            if let lastSample = currentSession.last {
                let gap = sample.startDate.timeIntervalSince(lastSample.endDate)
                if gap <= 2 * 60 * 60 {  // 2 hour gap = same session
                    currentSession.append(sample)
                } else {
                    if !currentSession.isEmpty { sessions.append(currentSession) }
                    currentSession = [sample]
                }
            } else {
                currentSession.append(sample)
            }
        }
        if !currentSession.isEmpty { sessions.append(currentSession) }

        // Find the session that overlaps with the recording
        // If no overlap, find the closest session
        let relevantSession = sessions.max { s1, s2 in
            let overlap1 = Self.sessionOverlap(s1, recordingStart: recordingStart, recordingEnd: recordingEnd)
            let overlap2 = Self.sessionOverlap(s2, recordingStart: recordingStart, recordingEnd: recordingEnd)
            return overlap1 < overlap2
        } ?? []

        debugLog("[HealthKitManager] Found \(sessions.count) sleep sessions, selected one with \(relevantSession.count) samples")

        // Process the selected session - use Apple's FULL data, no truncation
        var hasDetailedStages = false
        var detailedSleepMinutes = 0
        var unspecifiedSleepMinutes = 0
        var inBedMinutes = 0
        var deepMinutes = 0
        var remMinutes = 0
        var coreMinutes = 0
        var awakeMinutes = 0

        var earliestSleepStart: Date?
        var latestSleepEnd: Date?
        var earliestInBedStart: Date?
        var latestInBedEnd: Date?

        for sample in relevantSession {
            // Use the FULL sleep duration from HealthKit - no truncation
            let duration = Int(sample.endDate.timeIntervalSince(sample.startDate) / 60)

            guard duration > 0 else { continue }

            var isSleepSample = false

            switch sample.value {
            case HKCategoryValueSleepAnalysis.inBed.rawValue:
                inBedMinutes += duration
                earliestInBedStart.updateMin(sample.startDate)
                latestInBedEnd.updateMax(sample.endDate)

            case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                isSleepSample = true
                unspecifiedSleepMinutes += duration

            case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                isSleepSample = true
                hasDetailedStages = true
                coreMinutes += duration
                detailedSleepMinutes += duration

            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                isSleepSample = true
                hasDetailedStages = true
                deepMinutes += duration
                detailedSleepMinutes += duration

            case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                isSleepSample = true
                hasDetailedStages = true
                remMinutes += duration
                detailedSleepMinutes += duration

            case HKCategoryValueSleepAnalysis.awake.rawValue:
                awakeMinutes += duration

            default:
                break
            }

            if isSleepSample {
                earliestSleepStart.updateMin(sample.startDate)
                latestSleepEnd.updateMax(sample.endDate)
            }
        }

        // Use detailed stages if available (Apple Watch), otherwise use unspecified
        let asleepMinutes: Int
        if hasDetailedStages && detailedSleepMinutes > 0 {
            asleepMinutes = detailedSleepMinutes
        } else {
            asleepMinutes = unspecifiedSleepMinutes
        }

        // Total sleep is the asleep time (already excludes awake periods in detailed data)
        let totalSleep = asleepMinutes

        // Calculate inBedMinutes from boundaries to avoid double-counting overlapping samples
        // Multiple sources (iPhone Sleep schedule + Apple Watch) can report overlapping .inBed periods
        var effectiveInBedMinutes: Int
        if let inBedStart = earliestInBedStart, let inBedEnd = latestInBedEnd {
            // Use boundary times - most accurate when multiple sources exist
            effectiveInBedMinutes = Int(inBedEnd.timeIntervalSince(inBedStart) / 60)
        } else if let sleepStart = earliestSleepStart, let sleepEnd = latestSleepEnd {
            // iOS 16+ Apple Watch no longer writes .inBed samples, only sleep stages
            // Estimate in-bed time from sleep stage boundaries
            effectiveInBedMinutes = Int(sleepEnd.timeIntervalSince(sleepStart) / 60)
        } else {
            // Fallback to summed duration (shouldn't happen with valid data)
            effectiveInBedMinutes = inBedMinutes
        }

        let efficiency = effectiveInBedMinutes > 0 ? Double(totalSleep) / Double(effectiveInBedMinutes) * 100 : 0

        // Fall back to inBed boundaries when no actual sleep stages available
        let finalSleepStart: Date?
        let finalSleepEnd: Date?
        if earliestSleepStart != nil || latestSleepEnd != nil {
            finalSleepStart = earliestSleepStart
            finalSleepEnd = latestSleepEnd
        } else if earliestInBedStart != nil || latestInBedEnd != nil {
            finalSleepStart = earliestInBedStart
            finalSleepEnd = latestInBedEnd
        } else {
            finalSleepStart = nil
            finalSleepEnd = nil
        }

        // inBedStart is from explicit .inBed samples or fall back to sleep start
        let inBedStart = earliestInBedStart ?? earliestSleepStart

        // Determine boundary source
        let boundarySource: SleepBoundarySource
        if finalSleepStart != nil || finalSleepEnd != nil {
            boundarySource = .healthKit
        } else {
            boundarySource = .recordingBounds  // Will be overridden if HR estimation is used
        }

        return SleepData(
            date: relevantSession.first?.startDate ?? recordingStart,
            inBedStart: inBedStart,
            sleepStart: finalSleepStart,
            sleepEnd: finalSleepEnd,
            totalSleepMinutes: totalSleep,
            inBedMinutes: effectiveInBedMinutes,
            deepSleepMinutes: deepMinutes > 0 ? deepMinutes : nil,
            remSleepMinutes: remMinutes > 0 ? remMinutes : nil,
            awakeMinutes: awakeMinutes,
            sleepEfficiency: efficiency,
            boundarySource: boundarySource
        )
    }

    // MARK: - Sleep Session Helpers

    /// Calculate how much a sleep session overlaps with a recording window
    private static func sessionOverlap(_ session: [HKCategorySample], recordingStart: Date, recordingEnd: Date) -> TimeInterval {
        guard let sessionStart = session.first?.startDate,
              let sessionEnd = session.last?.endDate else {
            return 0
        }

        let overlapStart = max(sessionStart, recordingStart)
        let overlapEnd = min(sessionEnd, recordingEnd)

        return max(0, overlapEnd.timeIntervalSince(overlapStart))
    }

    // MARK: - HR-Based Sleep Estimation

    /// Estimate sleep onset and wake time from RR interval data when HealthKit sleep data is unavailable
    /// Uses HR drop patterns: sleep onset is detected when HR drops significantly and stabilizes
    /// Wake is detected when HR rises back toward awake levels
    ///
    /// - Parameters:
    ///   - rrPoints: Array of RR data points with timestamps
    ///   - recordingStart: When the recording started
    /// - Returns: SleepData with estimated boundaries, or nil if estimation fails
    static func estimateSleepFromHR(rrPoints: [RRPoint], recordingStart: Date) -> SleepData? {
        guard rrPoints.count >= 100 else { return nil }

        // Convert RR intervals to HR and smooth with 5-minute windows
        let windowSizeMs: Int64 = 5 * 60 * 1000  // 5 minutes in ms

        // Calculate HR in windows
        var windowedHR: [(timeMs: Int64, hr: Double)] = []
        var windowStart: Int64 = 0

        while windowStart < (rrPoints.last?.t_ms ?? 0) {
            let windowEnd = windowStart + windowSizeMs
            let windowPoints = rrPoints.filter { $0.t_ms >= windowStart && $0.t_ms < windowEnd }

            if windowPoints.count >= 10 {
                let avgRR = windowPoints.map { Double($0.rr_ms) }.reduce(0, +) / Double(windowPoints.count)
                let hr = 60000.0 / avgRR  // Convert ms to BPM
                windowedHR.append((timeMs: windowStart + windowSizeMs / 2, hr: hr))
            }

            windowStart += windowSizeMs
        }

        guard windowedHR.count >= 3 else { return nil }

        // Find initial HR (first 15 minutes average) as baseline
        let initialWindows = windowedHR.prefix(3)
        let initialHR = initialWindows.map { $0.hr }.reduce(0, +) / Double(initialWindows.count)

        // Find minimum HR (likely deep sleep)
        let minHR = windowedHR.map { $0.hr }.min() ?? initialHR
        let hrDropThreshold = initialHR - (initialHR - minHR) * 0.5  // 50% of the way to minimum

        // Find sleep onset: first window where HR drops below threshold and stays low
        var sleepOnsetMs: Int64?
        for i in 0..<(windowedHR.count - 2) {
            if windowedHR[i].hr < hrDropThreshold &&
               windowedHR[i + 1].hr < hrDropThreshold &&
               windowedHR[i + 2].hr < hrDropThreshold {
                sleepOnsetMs = windowedHR[i].timeMs
                break
            }
        }

        // Find wake time: last window where HR rises back above threshold
        var wakeMs: Int64?
        for i in stride(from: windowedHR.count - 1, through: 2, by: -1) {
            if windowedHR[i].hr > hrDropThreshold &&
               windowedHR[i - 1].hr < hrDropThreshold {
                wakeMs = windowedHR[i].timeMs
                break
            }
        }

        // Convert to dates
        let sleepStart = sleepOnsetMs.map { recordingStart.addingTimeInterval(Double($0) / 1000.0) }
        let sleepEnd = wakeMs.map { recordingStart.addingTimeInterval(Double($0) / 1000.0) }

        // Calculate approximate sleep duration
        let sleepDurationMinutes: Int
        if let onset = sleepOnsetMs, let wake = wakeMs, wake > onset {
            sleepDurationMinutes = Int((wake - onset) / 60000)
        } else if let lastPoint = rrPoints.last, let onset = sleepOnsetMs {
            sleepDurationMinutes = Int((lastPoint.t_ms - onset) / 60000)
        } else {
            sleepDurationMinutes = Int((rrPoints.last?.t_ms ?? 0) / 60000)
        }

        let inBedMinutes = Int((rrPoints.last?.t_ms ?? 0) / 60000)
        let efficiency = inBedMinutes > 0 ? Double(sleepDurationMinutes) / Double(inBedMinutes) * 100 : 0

        return SleepData(
            date: recordingStart,
            inBedStart: recordingStart,  // Recording start is when user got in bed
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            totalSleepMinutes: sleepDurationMinutes,
            inBedMinutes: inBedMinutes,
            deepSleepMinutes: nil,
            remSleepMinutes: nil,
            awakeMinutes: 0,
            sleepEfficiency: efficiency,
            boundarySource: .hrEstimated
        )
    }

    // MARK: - Daytime Heart Rate

    /// Fetch daytime resting heart rate for HR dip calculation
    /// Uses median HR from afternoon/evening of the day before the sleep recording
    /// This provides a stable "awake resting" baseline for nocturnal dip calculation
    /// - Parameter sleepDate: The date of the sleep recording (morning wake time)
    /// - Returns: Median daytime resting HR in bpm, or nil if insufficient data
    func fetchDaytimeRestingHR(for sleepDate: Date) async throws -> Double? {
        guard isHealthKitAvailable else {
            throw HealthKitError.notAvailable
        }

        let hrType = HKObjectType.quantityType(forIdentifier: .heartRate)!
        let calendar = Calendar.current

        // Get the day before the sleep recording
        // For a morning reading on Jan 15, we want afternoon HR from Jan 14
        let previousDay = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: sleepDate))!

        // Query HR from 12 PM to 9 PM on the previous day
        // This window captures typical "awake resting" periods while avoiding:
        // - Morning (still waking up, coffee, etc.)
        // - Late night (approaching sleep, HR already dropping)
        let queryStart = calendar.date(byAdding: .hour, value: 12, to: previousDay)!  // 12 PM
        let queryEnd = calendar.date(byAdding: .hour, value: 21, to: previousDay)!    // 9 PM

        debugLog("[HealthKitManager] Fetching daytime HR from \(queryStart) to \(queryEnd)")

        let predicate = HKQuery.predicateForSamples(
            withStart: queryStart,
            end: queryEnd,
            options: .strictStartDate
        )

        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: hrType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: results as? [HKQuantitySample] ?? [])
            }
            healthStore.execute(query)
        }

        guard samples.count >= 10 else {
            debugLog("[HealthKitManager] Insufficient HR samples for daytime resting HR: \(samples.count)")
            return nil
        }

        // Extract HR values in bpm
        let hrValues = samples.map { sample in
            sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        }

        // Use median for robustness against spikes (activity, stress, etc.)
        let sorted = hrValues.sorted()
        let median: Double
        if sorted.count % 2 == 0 {
            median = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2.0
        } else {
            median = sorted[sorted.count / 2]
        }

        debugLog("[HealthKitManager] Daytime resting HR: \(String(format: "%.1f", median)) bpm from \(samples.count) samples")
        return median
    }

    /// Fetch heart rate samples during a recording period with detailed metadata
    /// Returns array of (timestamp, HR, source app, interval) tuples
    /// Useful for understanding HR sampling patterns and data sources
    func fetchHeartRateSamplesDetailed(from start: Date, to end: Date) async throws -> [(date: Date, hr: Double, source: String, interval: TimeInterval?)] {
        guard isHealthKitAvailable else {
            throw HealthKitError.notAvailable
        }

        let hrType = HKObjectType.quantityType(forIdentifier: .heartRate)!

        debugLog("[HealthKitManager] Fetching detailed HR samples from \(start) to \(end)")

        let predicate = HKQuery.predicateForSamples(
            withStart: start,
            end: end,
            options: .strictStartDate
        )

        let samples: [HKQuantitySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: hrType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: results as? [HKQuantitySample] ?? [])
            }
            healthStore.execute(query)
        }

        // Build detailed sample data with source and interval information
        var detailedSamples: [(date: Date, hr: Double, source: String, interval: TimeInterval?)] = []
        var previousDate: Date?

        for sample in samples {
            let hr = sample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            let date = sample.startDate
            let sourceName = sample.sourceRevision.source.name
            let bundleId = sample.sourceRevision.source.bundleIdentifier

            // Calculate interval since previous sample
            let interval: TimeInterval?
            if let prev = previousDate {
                interval = date.timeIntervalSince(prev)
            } else {
                interval = nil
            }

            // Use bundle ID if available, otherwise use source name
            let source = bundleId.isEmpty ? sourceName : bundleId

            detailedSamples.append((date: date, hr: hr, source: source, interval: interval))
            previousDate = date
        }

        debugLog("[HealthKitManager] Found \(detailedSamples.count) HR samples from \(Set(detailedSamples.map { $0.source }).count) sources")

        // Analyze sources
        let sourceCounts = Dictionary(grouping: detailedSamples, by: { $0.source })
            .mapValues { $0.count }
            .sorted { $0.value > $1.value }

        debugLog("[HealthKitManager] HR sample sources:")
        for (source, count) in sourceCounts {
            debugLog("[HealthKitManager]   \(source): \(count) samples")
        }

        // Analyze intervals
        let intervals = detailedSamples.compactMap { $0.interval }
        if !intervals.isEmpty {
            let avgInterval = intervals.reduce(0, +) / Double(intervals.count)
            let minInterval = intervals.min() ?? 0
            let maxInterval = intervals.max() ?? 0
            debugLog("[HealthKitManager] Interval stats: min=\(String(format: "%.0f", minInterval))s, avg=\(String(format: "%.0f", avgInterval))s, max=\(String(format: "%.0f", maxInterval))s")
        }

        return detailedSamples
    }

    /// Fetch heart rate samples during a recording period
    /// Returns array of (timestamp, HR) tuples for all HR samples in the time range
    /// Useful for calculating nadir HR and HR statistics from Apple Watch data
    func fetchHeartRateSamples(from start: Date, to end: Date) async throws -> [(date: Date, hr: Double)] {
        let detailed = try await fetchHeartRateSamplesDetailed(from: start, to: end)
        return detailed.map { (date: $0.date, hr: $0.hr) }
    }

    /// Calculate HR statistics from HealthKit samples during a recording
    /// Returns (mean, min, max, nadir time) or nil if insufficient data
    func calculateHRStats(from start: Date, to end: Date) async throws -> (mean: Double, min: Double, max: Double, nadirTime: Date)? {
        let samples = try await fetchHeartRateSamples(from: start, to: end)

        guard samples.count >= 10 else {
            debugLog("[HealthKitManager] Insufficient HR samples for stats: \(samples.count)")
            return nil
        }

        let hrValues = samples.map { $0.hr }
        let mean = hrValues.reduce(0, +) / Double(hrValues.count)
        let min = hrValues.min() ?? 0
        let max = hrValues.max() ?? 0

        // Find nadir (lowest HR) timestamp
        guard let nadirSample = samples.min(by: { $0.hr < $1.hr }) else {
            return nil
        }
        let nadirTime = nadirSample.date

        debugLog("[HealthKitManager] HR stats: mean=\(String(format: "%.1f", mean)), min=\(String(format: "%.1f", min)), max=\(String(format: "%.1f", max))")
        debugLog("[HealthKitManager] Nadir at \(nadirTime): \(String(format: "%.1f", min)) bpm")

        return (mean: mean, min: min, max: max, nadirTime: nadirTime)
    }

    // MARK: - Sleep Trends

    /// Fetch sleep data for the past N days
    /// - Parameter days: Number of days to look back (default 7)
    /// - Returns: Array of SleepData for each night, sorted newest first
    func fetchSleepTrend(days: Int = 7) async throws -> [SleepData] {
        guard isHealthKitAvailable else {
            throw HealthKitError.notAvailable
        }

        let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        let calendar = Calendar.current

        // Look back N days
        let now = Date()
        let startDate = calendar.date(byAdding: .day, value: -days, to: now)!

        let predicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: now,
            options: .strictStartDate
        )

        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, results, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: results as? [HKCategorySample] ?? [])
            }
            healthStore.execute(query)
        }

        // Deduplicate: use only ONE source to avoid double-counting
        var samplesBySource: [String: [HKCategorySample]] = [:]
        for sample in samples {
            let bundleId = sample.sourceRevision.source.bundleIdentifier
            samplesBySource[bundleId, default: []].append(sample)
        }

        let watchSource = samplesBySource.keys.first { $0.lowercased().contains("watch") }
        let appleSource = samplesBySource.keys.first { $0.hasPrefix("com.apple.health") && !$0.contains("watch") }

        let selectedSource: String?
        if let watch = watchSource {
            selectedSource = watch
        } else if let apple = appleSource {
            selectedSource = apple
        } else {
            selectedSource = samplesBySource.max(by: { $0.value.count < $1.value.count })?.key
        }

        let deduplicatedSamples = selectedSource.flatMap { samplesBySource[$0] } ?? samples

        // Group samples by night (using end date as the reference)
        // A "night" is defined as sleep that ends on a given calendar day
        var nightData: [Date: (asleep: Int, deep: Int, rem: Int, awake: Int, sleepStart: Date?, sleepEnd: Date?, inBedStart: Date?, inBedEnd: Date?)] = [:]

        for sample in deduplicatedSamples {
            let nightDate = calendar.startOfDay(for: sample.endDate)
            let duration = Int(sample.endDate.timeIntervalSince(sample.startDate) / 60)

            var current = nightData[nightDate] ?? (0, 0, 0, 0, nil, nil, nil, nil)

            // Track sleep boundaries
            var isSleepSample = false

            switch sample.value {
            case HKCategoryValueSleepAnalysis.inBed.rawValue:
                // Track inBed boundaries instead of summing to avoid double-counting overlapping samples
                current.inBedStart.updateMin(sample.startDate)
                current.inBedEnd.updateMax(sample.endDate)
            case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                current.asleep += duration
                isSleepSample = true
            case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                current.asleep += duration
                isSleepSample = true
            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                current.deep += duration
                current.asleep += duration
                isSleepSample = true
            case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                current.rem += duration
                current.asleep += duration
                isSleepSample = true
            case HKCategoryValueSleepAnalysis.awake.rawValue:
                current.awake += duration
            default:
                break
            }

            if isSleepSample {
                current.sleepStart.updateMin(sample.startDate)
                current.sleepEnd.updateMax(sample.endDate)
            }

            nightData[nightDate] = current
        }

        // Convert to SleepData array
        var result: [SleepData] = []
        for (date, data) in nightData {
            // Calculate inBed from boundaries to avoid double-counting overlapping samples
            let inBedMinutes: Int
            if let inBedStart = data.inBedStart, let inBedEnd = data.inBedEnd {
                inBedMinutes = Int(inBedEnd.timeIntervalSince(inBedStart) / 60)
            } else if let sleepStart = data.sleepStart, let sleepEnd = data.sleepEnd {
                // iOS 16+ Apple Watch no longer writes .inBed, estimate from sleep stages
                inBedMinutes = Int(sleepEnd.timeIntervalSince(sleepStart) / 60)
            } else {
                inBedMinutes = data.asleep // Fallback to asleep time
            }

            let totalSleep = max(data.asleep, inBedMinutes - data.awake)
            let efficiency = inBedMinutes > 0 ? Double(totalSleep) / Double(inBedMinutes) * 100 : 0

            let sleepData = SleepData(
                date: date,
                inBedStart: data.inBedStart ?? data.sleepStart,
                sleepStart: data.sleepStart,
                sleepEnd: data.sleepEnd,
                totalSleepMinutes: totalSleep,
                inBedMinutes: inBedMinutes,
                deepSleepMinutes: data.deep > 0 ? data.deep : nil,
                remSleepMinutes: data.rem > 0 ? data.rem : nil,
                awakeMinutes: data.awake,
                sleepEfficiency: efficiency,
                boundarySource: .healthKit
            )
            result.append(sleepData)
        }

        // Sort by date, newest first
        return result.sorted { $0.date > $1.date }
    }

    /// Calculate sleep trend statistics
    struct SleepTrendStats {
        let averageSleepMinutes: Double
        let averageDeepSleepMinutes: Double?
        let averageEfficiency: Double
        let trend: SleepTrend  // improving, declining, stable
        let nightsAnalyzed: Int

        enum SleepTrend: String {
            case improving = "improving"
            case declining = "declining"
            case stable = "stable"
            case insufficient = "insufficient data"
        }

        var averageSleepFormatted: String {
            let hours = Int(averageSleepMinutes) / 60
            let mins = Int(averageSleepMinutes) % 60
            return hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
        }
    }

    /// Analyze sleep trends from recent data
    func analyzeSleepTrend(from sleepData: [SleepData]) -> SleepTrendStats {
        guard sleepData.count >= 2 else {
            return SleepTrendStats(
                averageSleepMinutes: sleepData.first.map { Double($0.totalSleepMinutes) } ?? 0,
                averageDeepSleepMinutes: sleepData.first?.deepSleepMinutes.map { Double($0) },
                averageEfficiency: sleepData.first?.sleepEfficiency ?? 0,
                trend: .insufficient,
                nightsAnalyzed: sleepData.count
            )
        }

        let avgSleep = sleepData.map { Double($0.totalSleepMinutes) }.reduce(0, +) / Double(sleepData.count)
        let deepValues = sleepData.compactMap { $0.deepSleepMinutes }
        let avgDeep = deepValues.isEmpty ? nil : Double(deepValues.reduce(0, +)) / Double(deepValues.count)
        let avgEfficiency = sleepData.map { $0.sleepEfficiency }.reduce(0, +) / Double(sleepData.count)

        // Determine trend by comparing first half vs second half (newer vs older)
        let midpoint = sleepData.count / 2
        let newerHalf = Array(sleepData.prefix(midpoint))
        let olderHalf = Array(sleepData.suffix(from: midpoint))

        let newerAvg = newerHalf.map { Double($0.totalSleepMinutes) }.reduce(0, +) / Double(max(1, newerHalf.count))
        let olderAvg = olderHalf.map { Double($0.totalSleepMinutes) }.reduce(0, +) / Double(max(1, olderHalf.count))

        let trend: SleepTrendStats.SleepTrend
        let changePct = olderAvg > 0 ? ((newerAvg - olderAvg) / olderAvg) * 100 : 0

        if changePct > 10 {
            trend = .improving
        } else if changePct < -10 {
            trend = .declining
        } else {
            trend = .stable
        }

        return SleepTrendStats(
            averageSleepMinutes: avgSleep,
            averageDeepSleepMinutes: avgDeep,
            averageEfficiency: avgEfficiency,
            trend: trend,
            nightsAnalyzed: sleepData.count
        )
    }

    // MARK: - Training Load & Fitness Data

    /// TrainingPeaks-style training metrics (TRIMP, ATL, CTL, TSB)
    struct TrainingMetrics {
        let atl: Double              // Acute Training Load (7-day EWMA of TRIMP) - "fatigue"
        let ctl: Double              // Chronic Training Load (42-day EWMA of TRIMP) - "fitness"
        let tsb: Double              // Training Stress Balance (CTL - ATL) - "form/freshness"
        let dailyTrimp: [Date: Double]  // Daily TRIMP values for charting
        let todayTrimp: Double       // Today's accumulated TRIMP

        /// Form interpretation for display
        var formDescription: String {
            if tsb > 25 { return "Very Fresh" }
            if tsb > 10 { return "Fresh" }
            if tsb > -10 { return "Neutral" }
            if tsb > -25 { return "Tired" }
            return "Very Tired"
        }

        /// Risk level based on ACR (ATL/CTL ratio)
        var riskLevel: String {
            guard ctl > 0 else { return "Building Base" }
            let acr = atl / ctl
            if acr > 1.5 { return "High Risk" }
            if acr > 1.3 { return "Caution" }
            if acr < 0.8 { return "Detraining" }
            return "Optimal"
        }

        /// Acute:Chronic Ratio
        var acuteChronicRatio: Double? {
            guard ctl > 0 else { return nil }
            return atl / ctl
        }

        static let empty = TrainingMetrics(
            atl: 0,
            ctl: 0,
            tsb: 0,
            dailyTrimp: [:],
            todayTrimp: 0
        )
    }

    /// Training load data for readiness context
    struct TrainingLoad {
        let vo2Max: Double?                    // ml/kg/min (from HealthKit or nil)
        let recentWorkouts: [WorkoutSummary]   // Last 7 days of workouts
        let weeklyLoadScore: Double            // 0-100 based on workout intensity/duration
        let daysSinceHardWorkout: Int?         // Days since last intense session
        let acuteChronicRatio: Double?         // Training load ratio (injury risk indicator)
        let metrics: TrainingMetrics?          // Full TRIMP/ATL/CTL/TSB metrics

        /// Adjustment factor for readiness based on training load (-2 to +1)
        /// Negative = recent hard training, expect lower HRV
        /// Positive = well rested, expect normal/higher HRV
        var readinessAdjustment: Double {
            guard let days = daysSinceHardWorkout else { return 0 }

            // Day after hard workout: expect suppressed HRV, don't penalize readiness
            if days == 0 { return -2.0 }
            if days == 1 { return -1.0 }
            if days == 2 { return -0.5 }

            // Well rested: normal expectations
            return 0
        }

        /// Whether current training load suggests overtraining risk
        var overtrainingRisk: Bool {
            if let acr = acuteChronicRatio, acr > 1.5 { return true }
            if weeklyLoadScore > 80 { return true }
            return false
        }

        static let empty = TrainingLoad(
            vo2Max: nil,
            recentWorkouts: [],
            weeklyLoadScore: 0,
            daysSinceHardWorkout: nil,
            acuteChronicRatio: nil,
            metrics: nil
        )
    }

    struct WorkoutSummary: Codable {
        let date: Date
        let workoutType: String  // Store as string for Codable
        let durationMinutes: Double
        let caloriesBurned: Double?
        let averageHR: Double?
        let maxHR: Double?

        init(date: Date, type: HKWorkoutActivityType, durationMinutes: Double, caloriesBurned: Double?, averageHR: Double?, maxHR: Double?) {
            self.date = date
            self.workoutType = WorkoutSummary.typeToString(type)
            self.durationMinutes = durationMinutes
            self.caloriesBurned = caloriesBurned
            self.averageHR = averageHR
            self.maxHR = maxHR
        }

        private static func typeToString(_ type: HKWorkoutActivityType) -> String {
            switch type {
            case .running: return "Running"
            case .cycling: return "Cycling"
            case .swimming: return "Swimming"
            case .functionalStrengthTraining, .traditionalStrengthTraining: return "Strength"
            case .highIntensityIntervalTraining: return "HIIT"
            case .yoga: return "Yoga"
            case .walking: return "Walking"
            case .hiking: return "Hiking"
            case .rowing: return "Rowing"
            case .crossTraining: return "Cross Training"
            case .elliptical: return "Elliptical"
            case .stairClimbing: return "Stairs"
            default: return "Workout"
            }
        }

        var typeDescription: String { workoutType }

        /// Calculate TRIMP (Training Impulse) using Bannister's method
        /// TRIMP = Duration (min) × HRreserve fraction × intensity weighting
        /// Uses exponential weighting: higher HR zones contribute disproportionately more
        func calculateTrimp(restingHR: Double = 60, maxHR: Double? = nil) -> Double {
            let effectiveMaxHR = maxHR ?? self.maxHR ?? 190
            let effectiveAvgHR = averageHR ?? 120  // Fallback if no HR data

            // HR Reserve fraction: (avgHR - restingHR) / (maxHR - restingHR)
            let hrReserve = max(0, min(1, (effectiveAvgHR - restingHR) / (effectiveMaxHR - restingHR)))

            // Bannister weighting factor: e^(1.92 × HRreserve) for general use
            // Men typically use 1.92, women 1.67
            let intensityFactor = exp(1.92 * hrReserve)

            // TRIMP = duration × HRreserve × intensity factor
            return durationMinutes * hrReserve * intensityFactor
        }

        /// Intensity score 0-100 based on duration and HR
        var intensityScore: Double {
            var score = min(durationMinutes / 60.0 * 30, 50)  // Up to 50 points for duration (2hr max)

            if let avgHR = averageHR, let maxHR = maxHR, maxHR > 0 {
                let hrIntensity = avgHR / maxHR
                score += hrIntensity * 50  // Up to 50 points for HR intensity
            } else if let calories = caloriesBurned {
                score += min(calories / 500 * 25, 50)  // Fallback: calories
            }

            return min(score, 100)
        }

        /// Whether this counts as a "hard" workout
        var isHardWorkout: Bool {
            intensityScore > 60 || durationMinutes > 60
        }
    }

    /// Fetch latest VO2max from HealthKit
    func fetchVO2Max() async -> Double? {
        guard isHealthKitAvailable else { return nil }

        let vo2Type = HKQuantityType.quantityType(forIdentifier: .vo2Max)!
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: vo2Type,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let sample = samples?.first as? HKQuantitySample {
                    let vo2 = sample.quantity.doubleValue(for: HKUnit(from: "ml/kg*min"))
                    debugLog("[HealthKitManager] Fetched VO2max: \(vo2)")
                    continuation.resume(returning: vo2)
                } else {
                    debugLog("[HealthKitManager] No VO2max data found")
                    continuation.resume(returning: nil)
                }
            }
            healthStore.execute(query)
        }
    }

    // MARK: - Recovery Vitals

    /// Recovery vitals from overnight/sleep period
    struct RecoveryVitals {
        let respiratoryRate: Double?        // breaths per minute
        let respiratoryRateBaseline: Double? // 7-day average
        let oxygenSaturation: Double?       // percentage (0-100)
        let oxygenSaturationMin: Double?    // lowest during sleep
        let wristTemperature: Double?       // deviation from baseline in °C
        let restingHeartRate: Double?       // lowest during sleep

        /// Respiratory rate deviation from baseline (positive = elevated)
        var respiratoryDeviation: Double? {
            guard let rate = respiratoryRate, let baseline = respiratoryRateBaseline else { return nil }
            return rate - baseline
        }

        /// Is respiratory rate elevated? (>2 breaths/min above baseline suggests illness/stress)
        var isRespiratoryElevated: Bool {
            guard let deviation = respiratoryDeviation else { return false }
            return deviation > 2.0
        }

        /// Is SpO2 concerning? (<95% or high variability)
        var isSpO2Concerning: Bool {
            guard let spo2 = oxygenSaturation else { return false }
            return spo2 < 95.0
        }

        /// Is temperature elevated? (>0.5°C above baseline)
        var isTemperatureElevated: Bool {
            guard let temp = wristTemperature else { return false }
            return temp > 0.5
        }

        /// Overall vitals status
        var status: VitalsStatus {
            if isRespiratoryElevated && isTemperatureElevated {
                return .warning // Likely illness
            } else if isRespiratoryElevated || isTemperatureElevated || isSpO2Concerning {
                return .elevated
            }
            return .normal
        }

        enum VitalsStatus {
            case normal, elevated, warning
        }
    }

    /// Fetch recovery vitals from last night's sleep
    func fetchRecoveryVitals() async -> RecoveryVitals {
        async let respRate = fetchRespiratoryRate()
        async let respBaseline = fetchRespiratoryRateBaseline()
        async let spo2 = fetchOxygenSaturation()
        async let spo2Min = fetchOxygenSaturationMin()
        async let temp = fetchWristTemperature()
        async let rhr = fetchRestingHeartRate()

        return await RecoveryVitals(
            respiratoryRate: respRate,
            respiratoryRateBaseline: respBaseline,
            oxygenSaturation: spo2,
            oxygenSaturationMin: spo2Min,
            wristTemperature: temp,
            restingHeartRate: rhr
        )
    }

    /// Fetch last night's respiratory rate
    private func fetchRespiratoryRate() async -> Double? {
        guard isHealthKitAvailable else { return nil }

        let respType = HKQuantityType.quantityType(forIdentifier: .respiratoryRate)!
        let calendar = Calendar.current
        let now = Date()
        // Extend window to 24 hours to catch overnight data
        let lastNight = calendar.date(byAdding: .hour, value: -24, to: now)!

        let predicate = HKQuery.predicateForSamples(withStart: lastNight, end: now, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: respType,
                predicate: predicate,
                limit: 10,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                if let error = error {
                    debugLog("[HealthKitManager] Respiratory rate query error: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else {
                    debugLog("[HealthKitManager] No respiratory rate samples found in last 24h")
                    continuation.resume(returning: nil)
                    return
                }
                // Average the samples
                let avg = samples.map { $0.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) }.reduce(0, +) / Double(samples.count)
                debugLog("[HealthKitManager] Respiratory rate: \(String(format: "%.1f", avg)) breaths/min from \(samples.count) samples")
                continuation.resume(returning: avg)
            }
            healthStore.execute(query)
        }
    }

    /// Fetch 7-day respiratory rate baseline
    private func fetchRespiratoryRateBaseline() async -> Double? {
        guard isHealthKitAvailable else { return nil }

        let respType = HKQuantityType.quantityType(forIdentifier: .respiratoryRate)!
        let calendar = Calendar.current
        let now = Date()
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: now)!

        let predicate = HKQuery.predicateForSamples(withStart: weekAgo, end: now, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: respType,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, statistics, error in
                if let error = error {
                    debugLog("[HealthKitManager] Respiratory baseline query error: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                if let avg = statistics?.averageQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) {
                    continuation.resume(returning: avg)
                } else {
                    debugLog("[HealthKitManager] No respiratory baseline data found in last 7 days")
                    continuation.resume(returning: nil)
                }
            }
            healthStore.execute(query)
        }
    }

    /// Fetch last night's oxygen saturation
    private func fetchOxygenSaturation() async -> Double? {
        guard isHealthKitAvailable else { return nil }

        let spo2Type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation)!
        let calendar = Calendar.current
        let now = Date()
        // Extend to 24-hour window for overnight data
        let lastNight = calendar.date(byAdding: .hour, value: -24, to: now)!

        let predicate = HKQuery.predicateForSamples(withStart: lastNight, end: now, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: spo2Type,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, statistics, error in
                if let error = error {
                    debugLog("[HealthKitManager] SpO2 query error: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                if let avg = statistics?.averageQuantity()?.doubleValue(for: .percent()) {
                    let percentage = avg * 100 // Convert to percentage
                    debugLog("[HealthKitManager] SpO2: \(String(format: "%.1f", percentage))%")
                    continuation.resume(returning: percentage)
                } else {
                    debugLog("[HealthKitManager] No SpO2 data found in last 24h")
                    continuation.resume(returning: nil)
                }
            }
            healthStore.execute(query)
        }
    }

    /// Fetch minimum SpO2 during sleep
    private func fetchOxygenSaturationMin() async -> Double? {
        guard isHealthKitAvailable else { return nil }

        let spo2Type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation)!
        let calendar = Calendar.current
        let now = Date()
        // Extend to 24-hour window for overnight data
        let lastNight = calendar.date(byAdding: .hour, value: -24, to: now)!

        let predicate = HKQuery.predicateForSamples(withStart: lastNight, end: now, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: spo2Type,
                quantitySamplePredicate: predicate,
                options: .discreteMin
            ) { _, statistics, error in
                if let error = error {
                    debugLog("[HealthKitManager] SpO2 min query error: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                if let min = statistics?.minimumQuantity()?.doubleValue(for: .percent()) {
                    continuation.resume(returning: min * 100)
                } else {
                    continuation.resume(returning: nil)
                }
            }
            healthStore.execute(query)
        }
    }

    /// Fetch wrist temperature deviation (iOS 16+)
    private func fetchWristTemperature() async -> Double? {
        guard isHealthKitAvailable else { return nil }

        if #available(iOS 16.0, *) {
            let tempType = HKQuantityType.quantityType(forIdentifier: .appleSleepingWristTemperature)!
            let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

            // Look for temperature data from the last 24 hours (overnight sleep)
            let calendar = Calendar.current
            let now = Date()
            let yesterday = calendar.date(byAdding: .hour, value: -24, to: now)!
            let predicate = HKQuery.predicateForSamples(withStart: yesterday, end: now, options: .strictStartDate)

            return await withCheckedContinuation { continuation in
                let query = HKSampleQuery(
                    sampleType: tempType,
                    predicate: predicate,
                    limit: 1,
                    sortDescriptors: [sortDescriptor]
                ) { _, samples, error in
                    if let error = error {
                        debugLog("[HealthKitManager] Wrist temp query error: \(error.localizedDescription)")
                        continuation.resume(returning: nil)
                        return
                    }
                    if let sample = samples?.first as? HKQuantitySample {
                        let temp = sample.quantity.doubleValue(for: .degreeCelsius())
                        debugLog("[HealthKitManager] Wrist temp raw value: \(String(format: "%.2f", temp))°C from \(sample.endDate)")
                        // Apple's appleSleepingWristTemperature should be deviation from baseline
                        // Valid deviations are typically -3 to +3°C
                        // If value is outside this range, it's likely raw temp or invalid data
                        if temp >= -5 && temp <= 5 {
                            continuation.resume(returning: temp)
                        } else {
                            debugLog("[HealthKitManager] Wrist temp value \(temp) appears invalid (not a deviation), ignoring")
                            continuation.resume(returning: nil)
                        }
                    } else {
                        debugLog("[HealthKitManager] No wrist temp samples found in last 24h")
                        continuation.resume(returning: nil)
                    }
                }
                healthStore.execute(query)
            }
        } else {
            return nil
        }
    }

    /// Fetch resting heart rate (lowest during sleep)
    private func fetchRestingHeartRate() async -> Double? {
        guard isHealthKitAvailable else { return nil }

        let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        let calendar = Calendar.current
        let now = Date()
        // Use 24-hour window to capture overnight sleep data
        let lastNight = calendar.date(byAdding: .hour, value: -24, to: now)!

        let predicate = HKQuery.predicateForSamples(withStart: lastNight, end: now, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: hrType,
                quantitySamplePredicate: predicate,
                options: .discreteMin
            ) { _, statistics, error in
                if let error = error {
                    debugLog("[HealthKitManager] Resting HR query error: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                if let min = statistics?.minimumQuantity()?.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) {
                    debugLog("[HealthKitManager] Resting HR: \(String(format: "%.0f", min)) bpm (min from last 24h)")
                    continuation.resume(returning: min)
                } else {
                    debugLog("[HealthKitManager] No heart rate data found in last 24h")
                    continuation.resume(returning: nil)
                }
            }
            healthStore.execute(query)
        }
    }

    /// Fetch recent workouts (last N days)
    func fetchRecentWorkouts(days: Int = 7) async -> [WorkoutSummary] {
        guard isHealthKitAvailable else { return [] }

        let calendar = Calendar.current
        let endDate = Date()
        guard let startDate = calendar.date(byAdding: .day, value: -days, to: endDate) else { return [] }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                guard let workouts = samples as? [HKWorkout] else {
                    continuation.resume(returning: [])
                    return
                }

                let summaries = workouts.map { workout -> WorkoutSummary in
                    let duration = workout.duration / 60.0  // Convert to minutes

                    let calories: Double?
                    if let stats = workout.statistics(for: HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!) {
                        calories = stats.sumQuantity()?.doubleValue(for: .kilocalorie())
                    } else {
                        calories = nil
                    }

                    let avgHR: Double?
                    let maxHR: Double?
                    if let hrStats = workout.statistics(for: HKQuantityType.quantityType(forIdentifier: .heartRate)!) {
                        avgHR = hrStats.averageQuantity()?.doubleValue(for: HKUnit(from: "count/min"))
                        maxHR = hrStats.maximumQuantity()?.doubleValue(for: HKUnit(from: "count/min"))
                    } else {
                        avgHR = nil
                        maxHR = nil
                    }

                    return WorkoutSummary(
                        date: workout.startDate,
                        type: workout.workoutActivityType,
                        durationMinutes: duration,
                        caloriesBurned: calories,
                        averageHR: avgHR,
                        maxHR: maxHR
                    )
                }

                debugLog("[HealthKitManager] Fetched \(summaries.count) workouts from last \(days) days")
                continuation.resume(returning: summaries)
            }
            healthStore.execute(query)
        }
    }

    /// Fetch workouts for extended period (needed for CTL calculation)
    func fetchWorkoutsExtended(days: Int = 60) async -> [WorkoutSummary] {
        guard isHealthKitAvailable else { return [] }

        let calendar = Calendar.current
        let endDate = Date()
        guard let startDate = calendar.date(byAdding: .day, value: -days, to: endDate) else { return [] }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                guard let workouts = samples as? [HKWorkout] else {
                    continuation.resume(returning: [])
                    return
                }

                let summaries = workouts.map { workout -> WorkoutSummary in
                    let duration = workout.duration / 60.0

                    let calories: Double?
                    if let stats = workout.statistics(for: HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!) {
                        calories = stats.sumQuantity()?.doubleValue(for: .kilocalorie())
                    } else {
                        calories = nil
                    }

                    let avgHR: Double?
                    let maxHR: Double?
                    if let hrStats = workout.statistics(for: HKQuantityType.quantityType(forIdentifier: .heartRate)!) {
                        avgHR = hrStats.averageQuantity()?.doubleValue(for: HKUnit(from: "count/min"))
                        maxHR = hrStats.maximumQuantity()?.doubleValue(for: HKUnit(from: "count/min"))
                    } else {
                        avgHR = nil
                        maxHR = nil
                    }

                    return WorkoutSummary(
                        date: workout.startDate,
                        type: workout.workoutActivityType,
                        durationMinutes: duration,
                        caloriesBurned: calories,
                        averageHR: avgHR,
                        maxHR: maxHR
                    )
                }

                debugLog("[HealthKitManager] Fetched \(summaries.count) workouts from last \(days) days")
                continuation.resume(returning: summaries)
            }
            healthStore.execute(query)
        }
    }

    /// Calculate TrainingPeaks-style ATL/CTL/TSB using exponentially weighted moving averages
    /// - ATL: 7-day time constant (acute training load / "fatigue")
    /// - CTL: 42-day time constant (chronic training load / "fitness")
    /// - TSB: CTL - ATL ("form" or freshness)
    /// - forMorningReading: If true, calculates through YESTERDAY (morning readings reflect overnight recovery)
    func calculateTrainingMetrics(restingHR: Double = 60, userMaxHR: Double? = nil, forMorningReading: Bool = true) async -> TrainingMetrics {
        // Fetch 60 days of workouts for accurate CTL calculation
        let allWorkouts = await fetchWorkoutsExtended(days: 60)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        // Build daily TRIMP totals
        var dailyTrimp: [Date: Double] = [:]

        // Initialize all days with 0 (going back 60 days from yesterday for morning readings)
        let referenceDate = forMorningReading ? yesterday : today
        for dayOffset in 0..<60 {
            if let date = calendar.date(byAdding: .day, value: -dayOffset, to: referenceDate) {
                dailyTrimp[date] = 0
            }
        }

        // Sum TRIMP for each day
        for workout in allWorkouts {
            let workoutDay = calendar.startOfDay(for: workout.date)
            let trimp = workout.calculateTrimp(restingHR: restingHR, maxHR: userMaxHR)
            dailyTrimp[workoutDay, default: 0] += trimp
        }

        // Calculate EWMA for ATL (7-day) and CTL (42-day)
        // TrainingPeaks/Banister impulse-response model:
        // Load_today = Load_yesterday × (1 - 1/τ) + TRIMP_today × (1/τ)
        // where τ (tau) is the time constant in days
        let atlK = 1.0 / 7.0    // ≈ 0.143 for 7-day time constant
        let ctlK = 1.0 / 42.0   // ≈ 0.024 for 42-day time constant

        // Seed EWMA with average daily TRIMP to avoid cold-start problem
        // This matches how TrainingPeaks/FITIV handle initialization
        let sortedDays = dailyTrimp.keys.sorted()
        let trimpValues = sortedDays.compactMap { dailyTrimp[$0] }.filter { $0 > 0 }
        let avgDailyTrimp = trimpValues.isEmpty ? 0.0 : trimpValues.reduce(0, +) / Double(trimpValues.count)

        // Initialize with average to represent "steady state" training
        var atl = avgDailyTrimp
        var ctl = avgDailyTrimp

        // Process days from oldest to newest, STOPPING at reference date
        // For morning readings, we calculate through yesterday (today's training hasn't affected recovery yet)
        for date in sortedDays {
            // Skip today for morning readings - morning HRV reflects yesterday's end state
            if forMorningReading && date >= today {
                continue
            }
            let dayTrimp = dailyTrimp[date] ?? 0
            atl = dayTrimp * atlK + atl * (1 - atlK)
            ctl = dayTrimp * ctlK + ctl * (1 - ctlK)
        }

        let tsb = ctl - atl
        let todayTrimp = dailyTrimp[today] ?? 0
        let yesterdayTrimp = dailyTrimp[yesterday] ?? 0

        debugLog("[HealthKitManager] Training Metrics (morning=\(forMorningReading)): ATL=\(String(format: "%.1f", atl)), CTL=\(String(format: "%.1f", ctl)), TSB=\(String(format: "%.1f", tsb)), Yesterday TRIMP=\(String(format: "%.0f", yesterdayTrimp)), Avg Daily TRIMP seed=\(String(format: "%.1f", avgDailyTrimp))")

        return TrainingMetrics(
            atl: atl,
            ctl: ctl,
            tsb: tsb,
            dailyTrimp: dailyTrimp,
            todayTrimp: todayTrimp
        )
    }

    /// Calculate comprehensive training load
    /// - forMorningReading: If true, calculates through yesterday (for stored morning HRV context)
    ///                      If false, includes today's training (for live current-state display)
    func calculateTrainingLoad(days: Int = 7, forMorningReading: Bool = true) async -> TrainingLoad {
        let workouts = await fetchRecentWorkouts(days: days)
        let vo2Max = await fetchVO2Max()
        let metrics = await calculateTrainingMetrics(forMorningReading: forMorningReading)

        // Calculate weekly load score (sum of intensity scores, capped at 100)
        let weeklyLoad = min(workouts.reduce(0) { $0 + $1.intensityScore } / Double(max(days, 1)) * 7, 100)

        // Find days since last hard workout
        let hardWorkouts = workouts.filter { $0.isHardWorkout }
        let daysSinceHard: Int?
        if let lastHard = hardWorkouts.first {
            daysSinceHard = Calendar.current.dateComponents([.day], from: lastHard.date, to: Date()).day
        } else {
            daysSinceHard = nil
        }

        debugLog("[HealthKitManager] Training load: weeklyScore=\(weeklyLoad), daysSinceHard=\(daysSinceHard ?? -1), ACR=\(metrics.acuteChronicRatio ?? 0)")

        return TrainingLoad(
            vo2Max: vo2Max,
            recentWorkouts: workouts,
            weeklyLoadScore: weeklyLoad,
            daysSinceHardWorkout: daysSinceHard,
            acuteChronicRatio: metrics.acuteChronicRatio,
            metrics: metrics
        )
    }

    // MARK: - Errors

    enum HealthKitError: Error, LocalizedError {
        case notAvailable
        case notAuthorized
        case noSleepData

        var errorDescription: String? {
            switch self {
            case .notAvailable:
                return "HealthKit is not available on this device"
            case .notAuthorized:
                return "HealthKit access not authorized"
            case .noSleepData:
                return "No sleep data found for the requested period"
            }
        }
    }
}
