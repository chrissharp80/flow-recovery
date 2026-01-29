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
import Combine
import AudioToolbox
import UIKit

/// RR interval collector - orchestrates Polar H10 recording and analysis
@MainActor
final class RRCollector: ObservableObject {

    // MARK: - Published State

    @Published private(set) var isCollecting = false
    @Published private(set) var currentSession: HRVSession?
    @Published private(set) var collectedPoints: [RRPoint] = []
    @Published private(set) var lastError: Error?
    @Published private(set) var verificationResult: Verification.Result?
    @Published private(set) var recoveryWindow: WindowSelector.RecoveryWindow?
    @Published private(set) var needsAcceptance: Bool = false
    @Published private(set) var baselineDeviation: BaselineTracker.BaselineDeviation?

    // Streaming mode state
    @Published private(set) var isStreamingMode: Bool = false
    @Published private(set) var streamingTargetSeconds: Int = 180  // Default 3 min
    @Published private(set) var streamingElapsedSeconds: Int = 0
    @Published private(set) var isOvernightStreaming: Bool = false  // True for overnight streaming mode (no time limit)

    // Archive update trigger - increment to notify SwiftUI of archive changes
    @Published private(set) var archiveVersion: Int = 0

    // Forward fetchProgress for reliable UI updates (nested observables can be flaky)
    @Published private(set) var fetchProgress: PolarManager.FetchProgress?

    /// Callback when streaming auto-completes
    var onStreamingComplete: (() -> Void)?

    private var streamingTimer: Timer?

    /// Polar connection manager - exposed for UI bindings
    let polarManager = PolarManager()

    /// HealthKit manager for sleep data integration
    private let healthKit = HealthKitManager()

    /// Cached training load for readiness calculations
    private var cachedTrainingLoad: HealthKitManager.TrainingLoad?

    /// Create a TrainingContext snapshot from cached training load
    /// This gets stored with each session for historical trend analysis
    private func createTrainingContext() -> TrainingContext? {
        guard let load = cachedTrainingLoad, let metrics = load.metrics else { return nil }

        // Get yesterday's TRIMP
        let calendar = Calendar.current
        let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))
        let yesterdayTrimp = yesterday.flatMap { metrics.dailyTrimp[$0] } ?? 0

        // Create workout snapshots from recent workouts (last 5)
        let recentWorkouts: [WorkoutSnapshot] = load.recentWorkouts.prefix(5).map { workout in
            WorkoutSnapshot(
                date: workout.date,
                type: workout.typeDescription,
                durationMinutes: workout.durationMinutes,
                trimp: workout.calculateTrimp()
            )
        }

        return TrainingContext(
            atl: metrics.atl,
            ctl: metrics.ctl,
            tsb: metrics.tsb,
            yesterdayTrimp: yesterdayTrimp,
            vo2Max: load.vo2Max,
            daysSinceHardWorkout: load.daysSinceHardWorkout,
            recentWorkouts: recentWorkouts.isEmpty ? nil : recentWorkouts
        )
    }

    /// Verification helper (overnight sessions - strict)
    private let verification = Verification()

    /// Verification for streaming (relaxed - short readings)
    private let streamingVerification = Verification(config: Verification.Config(
        minPoints: 120,           // ~2 min at 60 bpm
        minDurationHours: 0.025,  // 1.5 minutes minimum
        maxArtifactPercent: 20.0, // More lenient for short readings
        warnArtifactPercent: 10.0
    ))

    /// Get all archived sessions for trend analysis
    var archivedSessions: [HRVSession] {
        var sessions: [HRVSession] = []
        let entries = archive.entries
        debugLog("[RRCollector] archivedSessions: Loading \(entries.count) entries from archive")
        var errorCount = 0
        for entry in entries {
            do {
                if let session = try archive.retrieve(entry.sessionId) {
                    sessions.append(session)
                } else {
                    debugLog("[RRCollector] WARNING: Session \(entry.sessionId) not found in archive (nil)")
                    errorCount += 1
                }
            } catch {
                debugLog("[RRCollector] ERROR: Failed to retrieve session \(entry.sessionId): \(error)")
                debugLog("[RRCollector] Entry date: \(entry.date), path: \(entry.filePath)")
                errorCount += 1
            }
        }
        debugLog("[RRCollector] archivedSessions: Loaded \(sessions.count) sessions (\(errorCount) errors)")

        // Log summary of loaded sessions
        let completeSessions = sessions.filter { $0.state == .complete }
        let analyzedSessions = sessions.filter { $0.analysisResult != nil }
        debugLog("[RRCollector] archivedSessions: \(completeSessions.count) complete, \(analyzedSessions.count) with analysis")
        return sessions
    }

    /// True if H10 has stored data that's NOT already in the archive
    /// Use this to block starting new recordings until data is recovered
    var hasUnrecoveredData: Bool {
        guard polarManager.hasStoredExercise,
              let exerciseDate = polarManager.storedExerciseDate else {
            return false
        }
        // Check if we already have a session near this date
        return !archive.hasSessionNear(date: exerciseDate, toleranceMinutes: 30)
    }

    // MARK: - Private Properties

    private let artifactDetector = ArtifactDetector()
    private let windowSelector = WindowSelector()
    let archive = SessionArchive()  // Exposed for tag updates and deletion
    let rawBackup = RawRRBackup()   // Raw RR data backup - written immediately, never lost
    private let reconciliation: ReconciliationManager

    /// Baseline tracker for multi-night trends
    let baselineTracker = BaselineTracker()

    private var sessionStartTime: Date?
    private var cancellables = Set<AnyCancellable>()

    /// Track last seen reconnect count to force backup on reconnection
    private var lastSeenReconnectCount: Int = 0

    // MARK: - Persisted Recording State Keys

    private static let activeRecordingStartTimeKey = "RRCollector.activeRecordingStartTime"
    private static let activeRecordingSessionIdKey = "RRCollector.activeRecordingSessionId"
    private static let activeRecordingTypeKey = "RRCollector.activeRecordingSessionType"

    // MARK: - Initialization

    init() {
        self.reconciliation = ReconciliationManager(archive: archive)
        setupBindings()
    }

    // MARK: - Persisted Recording State

    /// Persist recording start time and session info to survive app crashes
    private func persistRecordingState(sessionId: UUID, startTime: Date, sessionType: SessionType) {
        UserDefaults.standard.set(startTime, forKey: Self.activeRecordingStartTimeKey)
        UserDefaults.standard.set(sessionId.uuidString, forKey: Self.activeRecordingSessionIdKey)
        UserDefaults.standard.set(sessionType.rawValue, forKey: Self.activeRecordingTypeKey)
        debugLog("[RRCollector] Persisted recording state: session=\(sessionId.uuidString.prefix(8)), start=\(startTime)")
    }

    /// Clear persisted recording state (call on successful completion or explicit cancel)
    private func clearPersistedRecordingState() {
        UserDefaults.standard.removeObject(forKey: Self.activeRecordingStartTimeKey)
        UserDefaults.standard.removeObject(forKey: Self.activeRecordingSessionIdKey)
        UserDefaults.standard.removeObject(forKey: Self.activeRecordingTypeKey)
        debugLog("[RRCollector] Cleared persisted recording state")
    }

    /// Retrieve persisted recording state (for recovery after crash/disconnect)
    func getPersistedRecordingState() -> (sessionId: UUID, startTime: Date, sessionType: SessionType)? {
        guard let startTime = UserDefaults.standard.object(forKey: Self.activeRecordingStartTimeKey) as? Date,
              let sessionIdString = UserDefaults.standard.string(forKey: Self.activeRecordingSessionIdKey),
              let sessionId = UUID(uuidString: sessionIdString) else {
            return nil
        }
        let sessionTypeRaw = UserDefaults.standard.string(forKey: Self.activeRecordingTypeKey) ?? "overnight"
        let sessionType = SessionType(rawValue: sessionTypeRaw) ?? .overnight
        return (sessionId, startTime, sessionType)
    }

    /// Check if there's a persisted recording that needs recovery
    var hasPersistedRecordingState: Bool {
        getPersistedRecordingState() != nil
    }

    private func setupBindings() {
        // Forward polarManager's objectWillChange to this object so SwiftUI updates
        // Use receive(on:) to ensure main thread for @Published updates
        polarManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Forward Polar errors
        polarManager.$lastError
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] error in
                self?.lastError = error
            }
            .store(in: &cancellables)

        // Track recording state (H10 internal recording)
        polarManager.$isRecordingOnDevice
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                self?.isCollecting = isRecording
            }
            .store(in: &cancellables)

        // Forward fetch progress for reliable UI updates
        polarManager.$fetchProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in
                self?.fetchProgress = progress
            }
            .store(in: &cancellables)
    }

    // MARK: - Recording API

    /// Start a new collection session (H10 internal recording)
    /// - Parameter sessionType: The type of session (overnight, nap, or quick)
    func startSession(sessionType: SessionType = .overnight) async throws {
        guard polarManager.connectionState == .connected else {
            throw CollectorError.notConnected
        }

        guard !polarManager.isRecordingOnDevice else {
            throw CollectorError.alreadyRecording
        }

        // Capture device provenance before starting - tracks source device and collection method
        let provenance = DeviceProvenance.current(
            deviceId: polarManager.connectedDeviceId ?? "unknown",
            deviceModel: "Polar H10",
            firmwareVersion: nil,  // TODO: Query from PolarBleSdk if available
            recordingMode: .deviceInternal
        )

        let session = HRVSession(sessionType: sessionType, deviceProvenance: provenance)
        let startTime = Date()

        // Check if session already exists (reconciliation block)
        guard !reconciliation.sessionExists(session.id) else {
            throw CollectorError.sessionExists
        }

        // Start H10 internal recording (survives disconnect)
        try await polarManager.startRecording()

        // Persist recording state IMMEDIATELY after successful start
        // This survives app crashes, phone reboots, etc.
        persistRecordingState(sessionId: session.id, startTime: startTime, sessionType: sessionType)

        await MainActor.run {
            currentSession = session
            collectedPoints = []
            sessionStartTime = startTime
        }
    }

    /// Stop recording, fetch RR data from H10, and analyze
    func stopSession() async throws -> HRVSession? {
        guard polarManager.connectionState == .connected else {
            throw CollectorError.notConnected
        }

        // Get base session info - prefer currentSession, fall back to persisted state
        let baseSession: HRVSession
        if let current = currentSession {
            baseSession = current
        } else if let persisted = getPersistedRecordingState() {
            // App was restarted - use persisted start time
            debugLog("[RRCollector] Using persisted recording state for session start time: \(persisted.startTime)")
            baseSession = HRVSession(
                id: persisted.sessionId,
                startDate: persisted.startTime,
                endDate: nil,
                state: .collecting,
                sessionType: persisted.sessionType,
                rrSeries: nil,
                analysisResult: nil,
                artifactFlags: nil
            )
        } else {
            // No persisted state - will calculate from RR data after fetch
            debugLog("[RRCollector] Warning: No current session or persisted state, will calculate start time from data")
            baseSession = HRVSession()
        }

        // Stop streaming and get collected RR data
        let rrPoints: [RRPoint]
        do {
            rrPoints = try await polarManager.stopAndFetchRecording()
        } catch {
            let failedSession = HRVSession(
                id: baseSession.id,
                startDate: baseSession.startDate,
                endDate: Date(),
                state: .failed,
                sessionType: baseSession.sessionType,
                rrSeries: nil,
                analysisResult: nil,
                artifactFlags: nil
            )
            let capturedError = error
            await MainActor.run {
                currentSession = failedSession
                lastError = capturedError
            }
            return failedSession
        }

        // IMMEDIATELY backup raw RR data before any processing
        // This ensures data is never lost even if app crashes or user cancels
        if !rrPoints.isEmpty {
            do {
                try rawBackup.backup(
                    points: rrPoints,
                    sessionId: baseSession.id,
                    deviceId: polarManager.connectedDeviceId
                )
            } catch {
                debugLog("[RRCollector] Warning: Failed to backup raw RR data: \(error)")
                // Continue anyway - don't fail the session for backup issues
            }
        }

        guard rrPoints.count >= 120 else {
            let failedSession = HRVSession(
                id: baseSession.id,
                startDate: baseSession.startDate,
                endDate: Date(),
                state: .failed,
                sessionType: baseSession.sessionType,
                rrSeries: nil,
                analysisResult: nil,
                artifactFlags: nil
            )
            await MainActor.run {
                currentSession = failedSession
                lastError = CollectorError.insufficientData
            }
            return failedSession
        }

        // Calculate correct startDate if we had to use fallback (no persisted state)
        let sessionStartDate: Date
        if currentSession != nil || getPersistedRecordingState() != nil {
            // We have valid session info from persisted state
            sessionStartDate = baseSession.startDate
            debugLog("[RRCollector] Using persisted session start: \(sessionStartDate)")
        } else {
            // No persisted state - align to HealthKit sleep times
            let totalDurationMs = rrPoints.last?.endMs ?? 0
            let durationSeconds = TimeInterval(totalDurationMs) / 1000.0

            // Try to get HealthKit sleep data to anchor the recording
            let searchEnd = Date()
            let searchStart = searchEnd.addingTimeInterval(-24 * 60 * 60)

            var calculatedStart: Date? = nil
            if let sleepData = try? await healthKit.fetchSleepData(for: searchStart, recordingEnd: searchEnd),
               let hkSleepStart = sleepData.sleepStart {
                // Detect HR drop (sleep onset) in the data
                let sleepOnsetMs = detectSleepOnset(in: rrPoints) ?? 0
                let sleepOnsetSeconds = TimeInterval(sleepOnsetMs) / 1000.0

                // Recording start = HealthKit sleep start - time until HR dropped
                calculatedStart = hkSleepStart.addingTimeInterval(-sleepOnsetSeconds)
                debugLog("[RRCollector] Aligned to HealthKit sleep start: \(hkSleepStart)")
                debugLog("[RRCollector] HR drop at \(sleepOnsetMs / 60000) min, calculated start: \(calculatedStart!)")
            }

            // Fall back to fetch time if no HealthKit data
            sessionStartDate = calculatedStart ?? Date().addingTimeInterval(-durationSeconds)
            if calculatedStart == nil {
                debugLog("[RRCollector] No HealthKit data, using fetch time fallback: \(sessionStartDate)")
            }
        }

        // Build RR series
        let series = RRSeries(
            points: rrPoints,
            sessionId: baseSession.id,
            startDate: sessionStartDate
        )

        let analyzingSession = HRVSession(
            id: baseSession.id,
            startDate: sessionStartDate,
            endDate: Date(),
            state: .analyzing,
            sessionType: baseSession.sessionType,
            rrSeries: series,
            analysisResult: nil,
            artifactFlags: nil
        )

        await MainActor.run {
            currentSession = analyzingSession
        }

        let flags = artifactDetector.detectArtifacts(in: series)

        // Verify data quality
        let verifyResult = verification.verify(series, flags: flags)

        // Try to get sleep boundaries from HealthKit for accurate window selection
        var sleepStartMs: Int64? = nil
        var wakeTimeMs: Int64? = nil
        do {
            let sleepData = try await healthKit.fetchSleepData(for: sessionStartDate, recordingEnd: Date())
            if let sleepStart = sleepData.sleepStart {
                // Convert sleep start to milliseconds relative to session start
                sleepStartMs = Int64(sleepStart.timeIntervalSince(sessionStartDate) * 1000)
                debugLog("[RRCollector] Using HealthKit sleep start for window selection: \(sleepStart)")
            }
            if let sleepEnd = sleepData.sleepEnd {
                // Convert wake time to milliseconds relative to session start
                wakeTimeMs = Int64(sleepEnd.timeIntervalSince(sessionStartDate) * 1000)
                debugLog("[RRCollector] Using HealthKit wake time for window selection: \(sleepEnd)")
            }
        } catch {
            debugLog("[RRCollector] Could not fetch HealthKit sleep data for window selection: \(error)")
        }

        // Fetch training load for readiness context (if enabled)
        if SettingsManager.shared.settings.enableTrainingLoadIntegration {
            cachedTrainingLoad = await healthKit.calculateTrainingLoad()
            if let load = cachedTrainingLoad {
                debugLog("[RRCollector] Training load: weeklyScore=\(String(format: "%.1f", load.weeklyLoadScore)), daysSinceHard=\(load.daysSinceHardWorkout ?? -1)")
            }
        }

        // Select recovery window and compute peak capacity
        // recoveryWindow may be nil if no organized parasympathetic plateau detected
        // peakCapacity is computed independently and may exist even without recovery window
        let windowResult = windowSelector.findBestWindowWithCapacity(in: series, flags: flags, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs)

        // Analyze using selected window (or full session if no organized recovery)
        let analysisResult: HRVAnalysisResult?
        if let windowResult = windowResult, let recoveryWindow = windowResult.recoveryWindow {
            // Organized recovery detected - analyze using recovery window
            analysisResult = await analyze(analyzingSession, window: recoveryWindow, flags: flags, peakCapacity: windowResult.peakCapacity)
        } else if let windowResult = windowResult {
            // No organized recovery, but we have peak capacity data
            debugLog("[RRCollector] No consolidated recovery detected - analyzing full session")
            analysisResult = await analyze(analyzingSession, peakCapacity: windowResult.peakCapacity)
        } else {
            // No valid windows at all - fall back to full session analysis
            analysisResult = await analyze(analyzingSession)
        }

        // Clamp sleep boundaries to valid range (>= 0 and within recording duration)
        let recordingDurationMs = series.points.last?.endMs ?? 0
        let clampedSleepStart = sleepStartMs.map { max(0, $0) }
        let clampedSleepEnd = wakeTimeMs.map { max(0, min($0, recordingDurationMs)) }

        let finalSession = HRVSession(
            id: analyzingSession.id,
            startDate: analyzingSession.startDate,
            endDate: analyzingSession.endDate,
            state: analysisResult != nil ? .complete : .failed,
            sessionType: baseSession.sessionType,
            rrSeries: series,
            analysisResult: analysisResult,
            artifactFlags: flags,
            sleepStartMs: clampedSleepStart,
            sleepEndMs: clampedSleepEnd
        )

        // Compute baseline deviation for UI
        let deviation = baselineTracker.deviation(for: finalSession)

        // DO NOT archive yet - wait for user acceptance
        // Store verification result for UI
        await MainActor.run {
            currentSession = finalSession
            verificationResult = verifyResult
            recoveryWindow = windowResult?.recoveryWindow
            needsAcceptance = finalSession.state == .complete
            baselineDeviation = deviation
            sessionStartTime = nil
        }

        return finalSession
    }

    // MARK: - Streaming Mode API (Quick Readings)

    /// Start a streaming session for quick HRV reading
    /// - Parameter durationSeconds: Target duration (180 for 3min, 300 for 5min)
    @MainActor
    func startStreamingSession(durationSeconds: Int = 180) throws {
        guard polarManager.connectionState == .connected else {
            throw CollectorError.notConnected
        }
        guard !polarManager.isStreaming && !polarManager.isRecordingOnDevice else {
            throw CollectorError.alreadyRecording
        }

        // Capture device provenance for streaming mode
        let provenance = DeviceProvenance.current(
            deviceId: polarManager.connectedDeviceId ?? "unknown",
            deviceModel: "Polar H10",
            firmwareVersion: nil,
            recordingMode: .streaming  // Real-time BLE streaming, not device internal
        )

        let session = HRVSession(sessionType: .quick, deviceProvenance: provenance)

        try polarManager.startStreaming()

        currentSession = session
        collectedPoints = []
        sessionStartTime = Date()
        isStreamingMode = true
        streamingTargetSeconds = durationSeconds
        streamingElapsedSeconds = 0
        isCollecting = true

        debugLog("[RRCollector] Started streaming session: target=\(durationSeconds)s (\(durationSeconds/60)min)")

        // Start countdown timer - runs on main thread for UI updates
        startStreamingTimer()
    }

    /// Start the streaming countdown timer
    private func startStreamingTimer() {
        streamingTimer?.invalidate()

        streamingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            Task { @MainActor in
                // Thread safety: check if streaming was stopped while Task was pending
                // This prevents race condition where timer callback executes after invalidation
                guard self.isStreamingMode, self.streamingTimer != nil else { return }

                self.streamingElapsedSeconds += 1

                // Update collected points count from polar manager
                self.collectedPoints = self.polarManager.streamingBuffer

                // Check if we've reached target duration
                if self.streamingElapsedSeconds >= self.streamingTargetSeconds {
                    debugLog("[RRCollector] Streaming complete: elapsed=\(self.streamingElapsedSeconds)s, target=\(self.streamingTargetSeconds)s")
                    self.streamingTimer?.invalidate()
                    self.streamingTimer = nil

                    // Play completion sound and vibrate (works even in silent mode)
                    self.playCompletionAlert()

                    // Notify that streaming is complete (UI should call stopStreamingSession)
                    self.onStreamingComplete?()
                }
            }
        }
    }

    // MARK: - Sound Constants

    /// System sound ID for the "received message" chime (standard iOS notification sound)
    private static let kCompletionSoundID: SystemSoundID = 1007

    /// Play completion sound and haptic feedback
    private func playCompletionAlert() {
        // Haptic feedback - works in silent mode
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        // Also trigger a heavier impact for more noticeable vibration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let impact = UIImpactFeedbackGenerator(style: .heavy)
            impact.impactOccurred()
        }

        // Play system sound (respects silent mode for sound, but we mainly want vibration)
        AudioServicesPlaySystemSound(Self.kCompletionSoundID)

        // Also play alert sound that works even in silent mode
        AudioServicesPlayAlertSound(kSystemSoundID_Vibrate)
    }

    /// Cancel streaming timer
    private func stopStreamingTimer() {
        streamingTimer?.invalidate()
        streamingTimer = nil
    }

    /// Stop streaming session and analyze
    func stopStreamingSession() async -> HRVSession? {
        guard isStreamingMode else { return nil }

        // Stop the timer
        stopStreamingTimer()

        let baseSession = currentSession ?? HRVSession()
        let rrPoints = polarManager.stopStreaming()

        await MainActor.run {
            isStreamingMode = false
            isCollecting = false
            collectedPoints = rrPoints
            streamingElapsedSeconds = 0
        }

        // IMMEDIATELY backup raw RR data before any processing
        if !rrPoints.isEmpty {
            do {
                try rawBackup.backup(
                    points: rrPoints,
                    sessionId: baseSession.id,
                    deviceId: polarManager.connectedDeviceId
                )
            } catch {
                debugLog("[RRCollector] Warning: Failed to backup streaming RR data: \(error)")
            }
        }

        // For streaming, 120 beats is enough (~2 min at 60 bpm)
        guard rrPoints.count >= 120 else {
            let failedSession = HRVSession(
                id: baseSession.id,
                startDate: baseSession.startDate,
                endDate: Date(),
                state: .failed,
                sessionType: baseSession.sessionType,
                rrSeries: nil,
                analysisResult: nil,
                artifactFlags: nil
            )
            await MainActor.run {
                currentSession = failedSession
                lastError = CollectorError.insufficientData
            }
            return failedSession
        }

        // Build RR series
        let series = RRSeries(
            points: rrPoints,
            sessionId: baseSession.id,
            startDate: baseSession.startDate
        )

        let analyzingSession = HRVSession(
            id: baseSession.id,
            startDate: baseSession.startDate,
            endDate: Date(),
            state: .analyzing,
            sessionType: baseSession.sessionType,
            rrSeries: series,
            analysisResult: nil,
            artifactFlags: nil
        )

        await MainActor.run {
            currentSession = analyzingSession
        }

        // Detect artifacts
        let flags = artifactDetector.detectArtifacts(in: series)

        // For streaming, use full series as the window (no wake-time based selection)
        let analysisResult = analyzeFullSeries(series, flags: flags)

        // Use relaxed verification for streaming sessions
        let verifyResult = streamingVerification.verify(series, flags: flags)

        let finalSession = HRVSession(
            id: analyzingSession.id,
            startDate: analyzingSession.startDate,
            endDate: analyzingSession.endDate,
            state: analysisResult != nil ? .complete : .failed,
            sessionType: baseSession.sessionType,
            rrSeries: series,
            analysisResult: analysisResult,
            artifactFlags: flags
        )

        // Compute baseline deviation for UI
        let deviation = baselineTracker.deviation(for: finalSession)

        await MainActor.run {
            currentSession = finalSession
            verificationResult = verifyResult
            recoveryWindow = nil  // No recovery window for streaming
            needsAcceptance = false  // Streaming doesn't use H10 memory, no acceptance needed
            baselineDeviation = deviation
            sessionStartTime = nil
        }

        // Auto-archive streaming sessions (no H10 data to clear)
        if finalSession.state == .complete {
            do {
                try archive.archive(finalSession)
                // Mark the raw backup as archived
                rawBackup.markAsArchived(finalSession.id)
                // Update baseline with streaming session data
                baselineTracker.update(with: finalSession)
                // Trigger SwiftUI update for archive changes
                await MainActor.run { archiveVersion += 1 }
            } catch {
                debugLog("[RRCollector] Warning: Failed to archive streaming session: \(error)")
            }
        }

        return finalSession
    }

    // MARK: - Overnight Streaming Mode (Background Audio)

    /// Start overnight streaming with background audio to keep app alive
    /// This uses real-time BLE streaming instead of H10 internal recording
    /// - Parameter sessionType: .overnight or .nap
    @MainActor
    func startOvernightStreaming(sessionType: SessionType = .overnight) throws {
        guard polarManager.connectionState == .connected else {
            throw CollectorError.notConnected
        }
        // Allow both streaming and internal recording to run simultaneously (hybrid mode)
        guard !polarManager.isStreaming else {
            throw CollectorError.alreadyRecording
        }

        // Start background audio and location to keep app alive
        BackgroundAudioManager.shared.startBackgroundAudio()
        BackgroundLocationManager.shared.startBackgroundLocation()

        // Capture device provenance - using hybrid mode (both streaming and internal recording)
        let provenance = DeviceProvenance.current(
            deviceId: polarManager.connectedDeviceId ?? "unknown",
            deviceModel: "Polar H10",
            firmwareVersion: nil,
            recordingMode: .streaming  // Primary mode is streaming, internal is backup
        )

        let session = HRVSession(sessionType: sessionType, deviceProvenance: provenance)

        // HYBRID APPROACH: Start both internal recording (backup) and streaming (primary)
        // Internal recording acts as redundancy in case streaming fails or app crashes

        // Step 1: Start H10 internal recording first (async operation)
        Task {
            do {
                try await polarManager.startRecording()
                debugLog("[RRCollector] ✅ H10 internal recording started (backup)")
            } catch {
                // Log error but don't fail - streaming is our primary method
                debugLog("[RRCollector] ⚠️ Failed to start H10 internal recording (backup): \(error)")
                debugLog("[RRCollector] Continuing with streaming only")
            }
        }

        // Step 2: Start streaming (primary data source)
        try polarManager.startStreaming()

        currentSession = session
        collectedPoints = []
        sessionStartTime = Date()
        isStreamingMode = true
        isOvernightStreaming = true
        streamingTargetSeconds = Int.max  // No time limit for overnight
        streamingElapsedSeconds = 0
        isCollecting = true
        lastSeenReconnectCount = 0  // Reset reconnect tracking for new session

        // Persist recording state for recovery
        persistRecordingState(sessionId: session.id, startTime: Date(), sessionType: sessionType)

        debugLog("[RRCollector] ✅ Started overnight streaming (hybrid mode)")
        debugLog("[RRCollector] Session ID: \(session.id)")
        debugLog("[RRCollector] Session type: \(sessionType.rawValue)")
        debugLog("[RRCollector] Connected device: \(polarManager.connectedDeviceId ?? "unknown")")
        debugLog("[RRCollector] Recording mode: Streaming (primary) + H10 internal (backup)")
        debugLog("[RRCollector] Background audio: started")
        debugLog("[RRCollector] Background location: started")

        // Start timer for elapsed time display (no auto-stop for overnight)
        startOvernightStreamingTimer()
    }

    /// Timer for overnight streaming - tracks elapsed time and performs incremental backups
    private func startOvernightStreamingTimer() {
        streamingTimer?.invalidate()

        streamingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            Task { @MainActor in
                // Thread safety: check if streaming was stopped while Task was pending
                // This prevents race condition where timer callback executes after invalidation
                guard self.isOvernightStreaming, self.streamingTimer != nil else { return }

                self.streamingElapsedSeconds += 1
                // Update collected points from polar manager
                self.collectedPoints = self.polarManager.streamingBuffer

                // Send keep-alive ping every 30 seconds to prevent iOS from
                // putting BLE connection into low-power state during background
                if self.streamingElapsedSeconds % 30 == 0 {
                    self.polarManager.sendKeepAlivePing()
                }

                // Check if reconnection occurred - force immediate backup if so
                let currentReconnectCount = self.polarManager.streamingReconnectCount
                let reconnectionOccurred = currentReconnectCount > self.lastSeenReconnectCount
                if reconnectionOccurred {
                    debugLog("[RRCollector] Streaming reconnection detected (\(self.lastSeenReconnectCount) → \(currentReconnectCount)) - forcing backup")
                    self.lastSeenReconnectCount = currentReconnectCount
                }

                // Perform incremental backup:
                // - TIME-BASED: Every ~5 minutes regardless of beat count
                // - FORCE: Immediately after streaming reconnection
                // This ensures data is saved periodically during overnight streaming
                // even if buffer resets on reconnection
                if let session = self.currentSession {
                    self.rawBackup.incrementalBackup(
                        points: self.collectedPoints,
                        sessionId: session.id,
                        deviceId: self.polarManager.connectedDeviceId,
                        force: reconnectionOccurred
                    )
                }
            }
        }
    }

    /// Stop overnight streaming session, analyze, and require acceptance
    func stopOvernightStreaming() async -> HRVSession? {
        guard isOvernightStreaming else { return nil }

        // Stop the timer
        stopStreamingTimer()

        // Stop background audio and location
        BackgroundAudioManager.shared.stopBackgroundAudio()
        BackgroundLocationManager.shared.stopBackgroundLocation()

        let baseSession = currentSession ?? HRVSession()

        // Step 1: Stop streaming and get collected RR points (primary data source)
        let streamingPoints = polarManager.stopStreaming()

        await MainActor.run {
            isStreamingMode = false
            isOvernightStreaming = false
            isCollecting = false
            collectedPoints = streamingPoints
            streamingElapsedSeconds = 0
        }

        // Clear persisted recording state
        clearPersistedRecordingState()

        // Step 2: Try to fetch H10 internal recording (backup data source)
        var internalPoints: [RRPoint]? = nil
        if polarManager.isRecordingOnDevice {
            debugLog("[RRCollector] Fetching H10 internal recording (backup)...")
            do {
                internalPoints = try await polarManager.stopAndFetchRecording()
                debugLog("[RRCollector] ✅ H10 internal recording fetched: \(internalPoints?.count ?? 0) beats")
            } catch {
                debugLog("[RRCollector] ⚠️ Failed to fetch H10 internal recording: \(error)")
                debugLog("[RRCollector] This is OK - streaming data is our primary source")
            }
        }

        // Step 3: Choose best data source (or create composite if needed)
        // Strategy: Prefer internal, create composite if gaps detected, fallback to streaming

        let hasValidStreaming = streamingPoints.count >= 120
        let hasValidInternal = internalPoints?.count ?? 0 >= 120

        guard hasValidStreaming || hasValidInternal else {
            // Both failed
            debugLog("[RRCollector] ❌ Overnight recording FAILED: insufficient data from both sources")
            debugLog("[RRCollector] Streaming: \(streamingPoints.count) beats, Internal: \(internalPoints?.count ?? 0) beats")
            debugLog("[RRCollector] Duration: \(Int(Date().timeIntervalSince(baseSession.startDate)))s")
            debugLog("[RRCollector] Reconnections during session: \(polarManager.streamingReconnectCount)")

            let failedSession = HRVSession(
                id: baseSession.id,
                startDate: baseSession.startDate,
                endDate: Date(),
                state: .failed,
                sessionType: baseSession.sessionType,
                rrSeries: nil,
                analysisResult: nil,
                artifactFlags: nil
            )
            await MainActor.run {
                currentSession = failedSession
                lastError = CollectorError.insufficientData
            }
            return failedSession
        }

        // Decide which data source to use (or create composite if needed)
        let finalPoints: [RRPoint]
        let dataSource: String

        if let internalData = internalPoints, hasValidInternal {
            if hasValidStreaming {
                // Both succeeded - compare and decide
                let internalCount = internalData.count
                let streamingCount = streamingPoints.count
                let beatDiff = abs(internalCount - streamingCount)
                let percentDiff = (Double(beatDiff) / Double(max(internalCount, streamingCount))) * 100.0

                debugLog("[RRCollector] 📊 Both recordings succeeded")
                debugLog("[RRCollector] Beat count: internal=\(internalCount) vs streaming=\(streamingCount) (diff: \(beatDiff), \(String(format: "%.1f", percentDiff))%)")

                // If internal has significantly fewer beats (>5% difference), create composite
                if internalCount < streamingCount && percentDiff > 5.0 {
                    debugLog("[RRCollector] 🔀 Internal recording has gaps (\(String(format: "%.1f", percentDiff))%) - creating composite")

                    // Build composite by filling gaps
                    let internalSeries = RRSeries(points: internalData, sessionId: baseSession.id, startDate: baseSession.startDate)
                    let streamingSeries = RRSeries(points: streamingPoints, sessionId: baseSession.id, startDate: baseSession.startDate)

                    if let composite = createCompositePoints(internalSeries: internalSeries, streamingSeries: streamingSeries) {
                        finalPoints = composite
                        dataSource = "composite (internal + streaming gap-fill)"
                        debugLog("[RRCollector] Created composite with \(composite.count) beats")
                    } else {
                        // Composite failed, use internal anyway
                        finalPoints = internalData
                        dataSource = "internal"
                        debugLog("[RRCollector] Composite failed, using internal")
                    }
                } else {
                    // Difference is small, just use internal (preferred)
                    finalPoints = internalData
                    dataSource = "internal"
                    debugLog("[RRCollector] Using internal recording (preferred)")
                }
            } else {
                // Only internal succeeded
                finalPoints = internalData
                dataSource = "internal"
                debugLog("[RRCollector] Using internal recording (streaming failed)")
            }
        } else if hasValidStreaming {
            // Only streaming succeeded
            finalPoints = streamingPoints
            dataSource = "streaming (internal failed)"
            debugLog("[RRCollector] ⚠️ Internal recording failed, using streaming")
        } else {
            // Should never reach here due to earlier guard, but handle gracefully
            debugLog("[RRCollector] ❌ Logic error: no valid data available - returning failed session")
            let failedSession = HRVSession(
                id: baseSession.id,
                startDate: baseSession.startDate,
                endDate: Date(),
                state: .failed,
                sessionType: baseSession.sessionType,
                rrSeries: nil,
                analysisResult: nil,
                artifactFlags: nil
            )
            await MainActor.run {
                currentSession = failedSession
                lastError = CollectorError.insufficientData
            }
            return failedSession
        }

        debugLog("[RRCollector] Final data source: \(dataSource)")
        debugLog("[RRCollector] Final beat count: \(finalPoints.count)")
        debugLog("[RRCollector] Duration: \(Int(Date().timeIntervalSince(baseSession.startDate)))s")

        // Process the ONE final session
        let finalSession = await processOvernightData(
            points: finalPoints,
            baseSession: baseSession,
            dataSource: dataSource,
            reconnectCount: polarManager.streamingReconnectCount
        )

        await MainActor.run {
            currentSession = finalSession
        }

        return finalSession
    }

    /// Process overnight data (used for both internal and streaming)
    private func processOvernightData(
        points: [RRPoint],
        baseSession: HRVSession,
        dataSource: String,
        reconnectCount: Int
    ) async -> HRVSession {
        debugLog("[RRCollector] Processing \(dataSource) data for analysis...")

        // IMMEDIATELY backup raw RR data before any processing
        do {
            try rawBackup.backup(
                points: points,
                sessionId: baseSession.id,
                deviceId: polarManager.connectedDeviceId
            )
        } catch {
            debugLog("[RRCollector] Warning: Failed to backup \(dataSource) RR data: \(error)")
        }

        // Build RR series
        let series = RRSeries(
            points: points,
            sessionId: baseSession.id,
            startDate: baseSession.startDate
        )

        // Log gap detection and data loss information (streaming mode provides wall-clock timestamps)
        if series.hasWallClockTimestamps {
            let gaps = series.detectGaps()
            if !gaps.isEmpty {
                debugLog("[RRCollector] Detected \(gaps.count) data gaps during overnight streaming:")
                for (idx, gap) in gaps.enumerated() {
                    let gapSeconds = Double(gap.gapDurationMs) / 1000.0
                    debugLog("[RRCollector]   Gap \(idx + 1): \(String(format: "%.1f", gapSeconds))s at point \(gap.startIndex)")
                }
                debugLog("[RRCollector] Total gap time: \(String(format: "%.1f", Double(series.totalGapDurationMs) / 1000.0))s")
            }
            if let dataLoss = series.estimatedDataLossPercent {
                debugLog("[RRCollector] Estimated data loss: \(String(format: "%.2f", dataLoss))%")
            }
            if let wallDuration = series.wallClockDurationMs {
                let rrDuration = series.durationMs
                debugLog("[RRCollector] Wall-clock duration: \(wallDuration / 60000)min, RR cumulative: \(rrDuration / 60000)min")
            }
        }

        let analyzingSession = HRVSession(
            id: baseSession.id,
            startDate: baseSession.startDate,
            endDate: Date(),
            state: .analyzing,
            sessionType: baseSession.sessionType,
            rrSeries: series,
            analysisResult: nil,
            artifactFlags: nil
        )

        await MainActor.run {
            currentSession = analyzingSession
        }

        // Detect artifacts
        let flags = artifactDetector.detectArtifacts(in: series)

        // Verify data quality
        let verifyResult = verification.verify(series, flags: flags)

        // Try to get sleep boundaries from HealthKit for accurate window selection
        var sleepStartMs: Int64? = nil
        var wakeTimeMs: Int64? = nil
        var sleepBoundarySource: HealthKitManager.SleepBoundarySource = .recordingBounds
        if let sleepData = try? await healthKit.fetchSleepData(for: baseSession.startDate, recordingEnd: Date()) {
            if let sleepStart = sleepData.sleepStart {
                sleepStartMs = Int64(sleepStart.timeIntervalSince(baseSession.startDate) * 1000)
            }
            if let sleepEnd = sleepData.sleepEnd {
                wakeTimeMs = Int64(sleepEnd.timeIntervalSince(baseSession.startDate) * 1000)
            }
            sleepBoundarySource = sleepData.boundarySource
        }

        // If no HealthKit sleep data, try HR-based estimation
        if sleepStartMs == nil && sleepBoundarySource != .healthKit {
            if let hrEstimate = HealthKitManager.estimateSleepFromHR(rrPoints: points, recordingStart: baseSession.startDate) {
                if let sleepStart = hrEstimate.sleepStart {
                    sleepStartMs = Int64(sleepStart.timeIntervalSince(baseSession.startDate) * 1000)
                }
                if let sleepEnd = hrEstimate.sleepEnd {
                    wakeTimeMs = Int64(sleepEnd.timeIntervalSince(baseSession.startDate) * 1000)
                }
                sleepBoundarySource = .hrEstimated
            }
        }

        // Select recovery window and compute peak capacity (same as internal recording)
        let windowResult = windowSelector.findBestWindowWithCapacity(in: series, flags: flags, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs)

        // Analyze using selected window
        let analysisResult: HRVAnalysisResult?
        if let windowResult = windowResult, let recoveryWindow = windowResult.recoveryWindow {
            analysisResult = await analyze(analyzingSession, window: recoveryWindow, flags: flags, peakCapacity: windowResult.peakCapacity)
        } else if let windowResult = windowResult, let peakCapacity = windowResult.peakCapacity {
            analysisResult = analyzeFullSeriesWithCapacity(series, flags: flags, peakCapacity: peakCapacity)
        } else {
            analysisResult = analyzeFullSeries(series, flags: flags)
        }

        // Clamp sleep boundaries to valid range (>= 0 and within recording duration)
        let recordingDurationMs = series.points.last?.endMs ?? 0
        let clampedSleepStart = sleepStartMs.map { max(0, $0) }
        let clampedSleepEnd = wakeTimeMs.map { max(0, min($0, recordingDurationMs)) }

        let finalSession = HRVSession(
            id: analyzingSession.id,
            startDate: analyzingSession.startDate,
            endDate: analyzingSession.endDate,
            state: analysisResult != nil ? .complete : .failed,
            sessionType: baseSession.sessionType,
            rrSeries: series,
            analysisResult: analysisResult,
            artifactFlags: flags,
            sleepStartMs: clampedSleepStart,
            sleepEndMs: clampedSleepEnd
        )

        // Compute baseline deviation
        let deviation = baselineTracker.deviation(for: finalSession)

        await MainActor.run {
            currentSession = finalSession
            verificationResult = verifyResult
            self.recoveryWindow = windowResult?.recoveryWindow
            // Overnight streaming needs acceptance like internal recording
            needsAcceptance = finalSession.state == .complete
            baselineDeviation = deviation
            sessionStartTime = nil
        }

        // Pre-archive the session (will be confirmed on acceptance)
        if finalSession.state == .complete {
            do {
                debugLog("[RRCollector] Pre-archiving overnight session ID: \(finalSession.id.uuidString)")
                try archive.archive(finalSession)
                rawBackup.markAsArchived(finalSession.id)
                await MainActor.run { archiveVersion += 1 }
            } catch {
                debugLog("[RRCollector] ❌ Warning: Failed to pre-archive overnight streaming session: \(error)")
            }
        }

        debugLog("[RRCollector] Overnight streaming analysis complete: \(points.count) RR points")
        return finalSession
    }

    /// Creates composite RR points by merging internal recording with streaming data to fill gaps
    /// Returns merged points array, or nil if no gaps were found (internal is good enough)
    private func createCompositePoints(
        internalSeries: RRSeries,
        streamingSeries: RRSeries
    ) -> [RRPoint]? {
        debugLog("[RRCollector] Analyzing for gaps to create composite...")

        // Strategy: Use internal recording as base, fill gaps with streaming data
        // Since internal recording likely doesn't have wall-clock timestamps, we use
        // RR interval timing to align the two series

        let internalPoints = internalSeries.points
        let streamingPoints = streamingSeries.points

        guard !internalPoints.isEmpty, !streamingPoints.isEmpty else {
            debugLog("[RRCollector] Cannot create composite: empty series")
            return nil
        }

        // Build a composite by merging based on cumulative time
        var lastInternalTimeMs: Int64 = 0

        // First pass: Track internal recording duration
        for internalPoint in internalPoints {
            lastInternalTimeMs = internalPoint.endMs
        }

        debugLog("[RRCollector] Internal recording: \(internalPoints.count) beats, duration: \(lastInternalTimeMs / 60000)min")

        // Second pass: Find streaming points that might fill gaps
        // We look for large time jumps in the internal recording (gaps)
        var gapsFilled = 0
        var beatsAdded = 0

        for i in 1..<internalPoints.count {
            let prevPoint = internalPoints[i-1]
            let currPoint = internalPoints[i]

            // Expected time between beats (just the RR interval)
            let expectedGap = Int64(prevPoint.rr_ms)
            // Actual time jump
            let actualGap = currPoint.t_ms - prevPoint.endMs

            // If there's a significant gap (>2 seconds), try to fill with streaming
            if actualGap > expectedGap + 2000 {
                let gapStart = prevPoint.endMs
                let gapEnd = currPoint.t_ms

                debugLog("[RRCollector] Found gap: \(gapStart / 1000)s to \(gapEnd / 1000)s (missing \((gapEnd - gapStart) / 1000)s)")

                // Find streaming points that fall in this gap
                let gapPoints = streamingPoints.filter { point in
                    point.t_ms >= gapStart && point.t_ms <= gapEnd
                }

                if !gapPoints.isEmpty {
                    debugLog("[RRCollector] Filling gap with \(gapPoints.count) beats from streaming")
                    gapsFilled += 1
                    beatsAdded += gapPoints.count
                }
            }
        }

        if gapsFilled == 0 {
            debugLog("[RRCollector] No significant gaps found to fill - composite not needed")
            return nil
        }

        // Actually build the composite by interleaving points chronologically
        var mergedPoints: [RRPoint] = []
        var internalIdx = 0
        var streamingIdx = 0

        while internalIdx < internalPoints.count || streamingIdx < streamingPoints.count {
            if internalIdx >= internalPoints.count {
                // Only streaming left
                mergedPoints.append(streamingPoints[streamingIdx])
                streamingIdx += 1
            } else if streamingIdx >= streamingPoints.count {
                // Only internal left
                mergedPoints.append(internalPoints[internalIdx])
                internalIdx += 1
            } else {
                // Both available - choose earlier timestamp
                let internalTime = internalPoints[internalIdx].t_ms
                let streamingTime = streamingPoints[streamingIdx].t_ms

                if internalTime <= streamingTime {
                    mergedPoints.append(internalPoints[internalIdx])
                    internalIdx += 1
                } else {
                    mergedPoints.append(streamingPoints[streamingIdx])
                    streamingIdx += 1
                }
            }
        }

        debugLog("[RRCollector] Composite: \(mergedPoints.count) beats (added \(beatsAdded) from streaming to fill \(gapsFilled) gaps)")

        return mergedPoints
    }

    /// Analyze full series with peak capacity (for overnight streaming without organized recovery)
    private func analyzeFullSeriesWithCapacity(_ series: RRSeries, flags: [ArtifactFlags], peakCapacity: PeakCapacity) -> HRVAnalysisResult? {
        // Calculate window indices from peak capacity for graph overlay
        var windowStartIdx = 0
        var windowEndIdx = series.points.count
        var windowStartMs: Int64? = nil
        var windowEndMs: Int64? = nil

        if let relPos = peakCapacity.windowRelativePosition, !series.points.isEmpty,
           let firstPoint = series.points.first, let lastPoint = series.points.last {
            let totalDurationMs = lastPoint.endMs - firstPoint.t_ms
            let windowDurationMs = Int64(peakCapacity.windowDurationMinutes * 60000)
            let windowCenterMs = firstPoint.t_ms + Int64(Double(totalDurationMs) * relPos)

            let startMs = windowCenterMs - (windowDurationMs / 2)
            let endMs = windowCenterMs + (windowDurationMs / 2)
            windowStartMs = startMs
            windowEndMs = endMs

            for (idx, point) in series.points.enumerated() {
                if point.t_ms >= startMs && windowStartIdx == 0 {
                    windowStartIdx = idx
                }
                if point.t_ms >= endMs {
                    windowEndIdx = idx
                    break
                }
            }
        }

        // Analyze full series with calculated window indices
        guard var result = analyzeFullSeries(series, flags: flags, windowStart: windowStartIdx, windowEnd: windowEndIdx) else { return nil }
        result.peakCapacity = peakCapacity
        result.trainingContext = createTrainingContext()

        // Set window metadata for display
        if let wsMs = windowStartMs, let weMs = windowEndMs, let relPos = peakCapacity.windowRelativePosition {
            result.windowStartMs = wsMs
            result.windowEndMs = weMs
            result.windowRelativePosition = relPos
            result.windowClassification = "Peak Capacity"

            debugLog("[RRCollector] Peak capacity window for graphs: indices [\(windowStartIdx)-\(windowEndIdx)] of \(series.points.count), timestamps [\(wsMs)-\(weMs)]")
        }

        return result
    }

    /// Analyze full series (for streaming mode - no window selection)
    private func analyzeFullSeries(_ series: RRSeries, flags: [ArtifactFlags], windowStart: Int = 0, windowEnd: Int? = nil) -> HRVAnalysisResult? {
        let windowEndIdx = windowEnd ?? series.points.count

        let timeDomain = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: series.points.count
        )

        let frequencyDomain = FrequencyDomainAnalyzer.computeFrequencyDomain(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: series.points.count
        )

        let nonlinear = NonlinearAnalyzer.computeNonlinear(
            series,
            flags: flags,
            windowStart: 0,
            windowEnd: series.points.count
        )

        guard let td = timeDomain, let nl = nonlinear else {
            return nil
        }

        // Compute ANS metrics
        let ansMetrics = computeANSMetrics(
            series: series,
            flags: flags,
            windowStart: 0,
            windowEnd: series.points.count,
            timeDomain: td,
            nonlinear: nl
        )

        let artifactPct = artifactDetector.artifactPercentage(flags, start: 0, end: flags.count)
        let cleanCount = flags.filter { !$0.isArtifact }.count

        return HRVAnalysisResult(
            windowStart: windowStart,
            windowEnd: windowEndIdx,
            timeDomain: td,
            frequencyDomain: frequencyDomain,
            nonlinear: nl,
            ansMetrics: ansMetrics,
            artifactPercentage: artifactPct,
            cleanBeatCount: cleanCount,
            analysisDate: Date()
        )
    }

    /// Compute ANS metrics from time domain and nonlinear results
    /// - Parameters:
    ///   - daytimeRestingHR: Optional daytime resting HR from HealthKit for nocturnal HR dip calculation
    private func computeANSMetrics(
        series: RRSeries,
        flags: [ArtifactFlags],
        windowStart: Int,
        windowEnd: Int,
        timeDomain: TimeDomainMetrics,
        nonlinear: NonlinearMetrics,
        daytimeRestingHR: Double? = nil
    ) -> ANSMetrics {
        // Extract clean RR intervals for stress/respiration analysis
        var cleanRR = [Double]()
        for i in windowStart..<windowEnd {
            if !flags[i].isArtifact {
                cleanRR.append(Double(series.points[i].rr_ms))
            }
        }

        // Stress Index (Baevsky's SI)
        let stressIndex = StressAnalyzer.computeStressIndex(cleanRR)

        // PNS Index
        let pnsIndex = StressAnalyzer.computePNSIndex(
            meanRR: timeDomain.meanRR,
            rmssd: timeDomain.rmssd,
            sd1: nonlinear.sd1
        )

        // SNS Index (requires stress index)
        let snsIndex: Double?
        if let si = stressIndex {
            snsIndex = StressAnalyzer.computeSNSIndex(
                meanHR: timeDomain.meanHR,
                stressIndex: si,
                sd2: nonlinear.sd2
            )
        } else {
            snsIndex = nil
        }

        // Readiness Score - now with training load context
        let settings = SettingsManager.shared.settings
        let baselineRMSSD = settings.baselineRMSSD ?? settings.populationBaselineRMSSD

        // Get VO2max: prefer user override, then HealthKit (if enabled)
        let vo2Max: Double?
        if let override = settings.vo2MaxOverride {
            vo2Max = override
        } else if settings.useHealthKitVO2Max {
            vo2Max = cachedTrainingLoad?.vo2Max
        } else {
            vo2Max = nil
        }

        // Get training load adjustment (if integration enabled)
        let trainingLoadAdjustment: Double
        if settings.enableTrainingLoadIntegration, let load = cachedTrainingLoad {
            trainingLoadAdjustment = load.readinessAdjustment
        } else {
            trainingLoadAdjustment = 0
        }

        let readinessScore = StressAnalyzer.computeReadinessScore(
            rmssd: timeDomain.rmssd,
            baselineRMSSD: baselineRMSSD,
            alpha1: nonlinear.dfaAlpha1,
            pnsIndex: pnsIndex,
            snsIndex: snsIndex,
            trainingLoadAdjustment: trainingLoadAdjustment,
            vo2Max: vo2Max
        )

        // Respiration Rate
        let respirationRate = RespirationAnalyzer.estimateRespirationRate(cleanRR)

        // Nocturnal HR Dip calculation
        // Uses median HR from clean window for robustness (per research: better than min or mean)
        var nocturnalHRDip: Double? = nil
        var nocturnalMedianHR: Double? = nil

        if !cleanRR.isEmpty {
            // Convert RR to HR and get median
            let hrValues = cleanRR.map { 60000.0 / $0 }
            let sortedHR = hrValues.sorted()
            if sortedHR.count % 2 == 0 {
                nocturnalMedianHR = (sortedHR[sortedHR.count / 2 - 1] + sortedHR[sortedHR.count / 2]) / 2.0
            } else {
                nocturnalMedianHR = sortedHR[sortedHR.count / 2]
            }

            // Calculate dip if daytime HR is available
            // Dip = (daytimeHR - nocturnalHR) / daytimeHR * 100
            // Normal: 10-20%, Blunted: <10%, Exaggerated: >20%
            if let daytimeHR = daytimeRestingHR, let sleepHR = nocturnalMedianHR, daytimeHR > 0 {
                nocturnalHRDip = (daytimeHR - sleepHR) / daytimeHR * 100.0
                debugLog("[RRCollector] HR Dip: \(String(format: "%.1f", nocturnalHRDip!))% (daytime: \(String(format: "%.1f", daytimeHR)) bpm, sleep: \(String(format: "%.1f", sleepHR)) bpm)")
            }
        }

        return ANSMetrics(
            stressIndex: stressIndex,
            pnsIndex: pnsIndex,
            snsIndex: snsIndex,
            readinessScore: readinessScore,
            respirationRate: respirationRate,
            nocturnalHRDip: nocturnalHRDip,
            daytimeRestingHR: daytimeRestingHR,
            nocturnalMedianHR: nocturnalMedianHR
        )
    }

    // MARK: - Acceptance Flow

    /// Accept the current session - archives, updates baseline, and clears H10
    func acceptSession() async throws {
        guard let session = currentSession, session.state == .complete else {
            throw CollectorError.noSessionToAccept
        }

        // Archive the session
        do {
            debugLog("[RRCollector] Accepting and archiving session ID: \(session.id.uuidString)")
            try archive.archive(session)
            // Mark the raw backup as successfully archived (still kept for safety)
            rawBackup.markAsArchived(session.id)
        } catch {
            await MainActor.run {
                lastError = error
            }
            throw error
        }

        // Update baseline with new session data
        baselineTracker.update(with: session)

        // Clear persisted recording state - session is now safely archived
        clearPersistedRecordingState()

        // NOTE: We intentionally do NOT clear the H10 memory here
        // Data stays on the H10 as a backup until a new recording starts
        // This ensures data can be recovered if something goes wrong after archive

        await MainActor.run {
            currentSession = nil  // Clear session after archiving to prevent ID reuse
            needsAcceptance = false
            verificationResult = nil
            recoveryWindow = nil
            archiveVersion += 1  // Trigger SwiftUI update
        }
    }

    /// Reject the current session - discards without archiving
    func rejectSession() async {
        polarManager.discardPendingExercise()

        // Clear persisted recording state - user explicitly rejected
        clearPersistedRecordingState()

        await MainActor.run {
            currentSession = nil
            needsAcceptance = false
            verificationResult = nil
            recoveryWindow = nil
        }
    }

    // MARK: - Data Recovery

    /// Recover RR data from H10 and patch an existing archived session
    /// Use this when a session was archived without RR data but data is still on the strap
    /// - Parameter sessionId: Optional session ID to patch. If nil, patches most recent session from today that NEEDS RR data
    /// - Returns: Number of RR points recovered
    @discardableResult
    func recoverAndPatchSession(sessionId: UUID? = nil) async throws -> Int {
        guard polarManager.connectionState == .connected else {
            throw CollectorError.notConnected
        }

        // Fetch RR data from H10
        let rrPoints: [RRPoint]
        do {
            let recovered = try await polarManager.recoverExerciseData()
            rrPoints = recovered.rrPoints
        } catch {
            let capturedError = error
            await MainActor.run {
                lastError = capturedError
            }
            throw capturedError
        }

        guard !rrPoints.isEmpty else {
            throw CollectorError.insufficientData
        }

        // Find the session to patch
        let targetSessionId: UUID
        var existingSession: HRVSession?

        if let id = sessionId {
            targetSessionId = id
            existingSession = try archive.retrieve(id)
        } else {
            // Find most recent session from today that is MISSING RR data (needs recovery)
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            let todaySessions = archive.entries
                .filter { calendar.startOfDay(for: $0.date) == today }
                .sorted { $0.date > $1.date }

            // Try to find one that's missing RR data
            var foundSession: HRVSession?
            for entry in todaySessions {
                if let session = try? archive.retrieve(entry.sessionId) {
                    let hasRRData = session.rrSeries != nil && !(session.rrSeries?.points.isEmpty ?? true)
                    if !hasRRData {
                        foundSession = session
                        break
                    }
                }
            }

            // If all sessions have RR data, use the most recent one (user explicitly requested recovery)
            if foundSession == nil, let mostRecent = todaySessions.first {
                foundSession = try? archive.retrieve(mostRecent.sessionId)
            }

            guard let session = foundSession else {
                throw CollectorError.noSessionToRecover
            }
            targetSessionId = session.id
            existingSession = session
        }

        guard var session = existingSession else {
            throw CollectorError.noSessionToRecover
        }

        // Check current state of session
        let existingRR = session.rrSeries
        let hasExistingRR = existingRR != nil && !(existingRR?.points.isEmpty ?? true)
        var needsUpdate = false
        var needsReanalysis = false
        var updateReason = ""

        if let existingRR = existingRR, hasExistingRR {
            let existingCount = existingRR.points.count
            let newCount = rrPoints.count

            // Compare by count and first/last timestamps
            let existingFirstT = existingRR.points.first?.t_ms ?? 0
            let existingLastT = existingRR.points.last?.t_ms ?? 0
            let newFirstT = rrPoints.first?.t_ms ?? 0
            let newLastT = rrPoints.last?.t_ms ?? 0

            let isSameData = existingCount == newCount &&
                             abs(existingFirstT - newFirstT) < 1000 &&
                             abs(existingLastT - newLastT) < 1000

            if isSameData {
                // Same RR data - but check if session is missing other fields that need recomputing
                // (e.g., analysisResult might be nil if prior ingestion failed mid-way)
                if session.analysisResult == nil {
                    needsUpdate = true
                    needsReanalysis = true
                    updateReason = "re-analyzing (analysis was missing)"
                    debugLog("[RRCollector] Session has RR data but missing analysis - will recompute")
                } else if session.artifactFlags == nil {
                    needsUpdate = true
                    needsReanalysis = true
                    updateReason = "re-analyzing (artifact flags were missing)"
                    debugLog("[RRCollector] Session has RR data but missing artifact flags - will recompute")
                } else {
                    debugLog("[RRCollector] Session already complete with identical RR data - no recovery needed")
                    throw CollectorError.dataAlreadyExists
                }
            } else {
                // Different data - replacing
                needsUpdate = true
                needsReanalysis = true
                updateReason = "replacing \(existingCount) points with \(newCount) from strap"
                debugLog("[RRCollector] Session has different RR data - \(updateReason)")
            }
        } else {
            // No existing RR data - definitely need to patch
            needsUpdate = true
            needsReanalysis = true
            updateReason = "adding missing RR data"
            debugLog("[RRCollector] Session missing RR data - patching")
        }

        guard needsUpdate else {
            throw CollectorError.dataAlreadyExists
        }

        // Backup raw RR data first (always)
        do {
            try rawBackup.backup(
                points: rrPoints,
                sessionId: targetSessionId,
                deviceId: polarManager.connectedDeviceId
            )
        } catch {
            debugLog("[RRCollector] Warning: Failed to backup recovered RR data: \(error)")
        }

        // Build RR series (or use existing if same data)
        let series: RRSeries
        if let existing = existingRR, hasExistingRR,
           !updateReason.contains("replacing"), !updateReason.contains("adding") {
            series = existing
        } else {
            series = RRSeries(
                points: rrPoints,
                sessionId: targetSessionId,
                startDate: session.startDate
            )
            session.rrSeries = series
        }

        // Re-run analysis if needed
        if needsReanalysis {
            let flags = artifactDetector.detectArtifacts(in: series)
            session.artifactFlags = flags

            // Try to get sleep boundaries from HealthKit for window selection
            var sleepStartMs: Int64? = nil
            var wakeTimeMs: Int64? = nil
            if let endDate = session.endDate {
                do {
                    let sleepData = try await healthKit.fetchSleepData(for: session.startDate, recordingEnd: endDate)
                    if let sleepStart = sleepData.sleepStart {
                        sleepStartMs = Int64(sleepStart.timeIntervalSince(session.startDate) * 1000)
                        debugLog("[RRCollector] Using HealthKit sleep start for reanalysis: \(sleepStart)")
                    }
                    if let sleepEnd = sleepData.sleepEnd {
                        wakeTimeMs = Int64(sleepEnd.timeIntervalSince(session.startDate) * 1000)
                        debugLog("[RRCollector] Using HealthKit wake time for reanalysis: \(sleepEnd)")
                    }
                } catch {
                    debugLog("[RRCollector] Could not fetch HealthKit data for reanalysis: \(error)")
                }
            }

            // Run window selection and analysis
            if let windowResult = windowSelector.findBestWindowWithCapacity(in: series, flags: flags, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs) {
                let analysisResult: HRVAnalysisResult?
                if let recoveryWindow = windowResult.recoveryWindow {
                    analysisResult = await analyze(session, window: recoveryWindow, flags: flags, peakCapacity: windowResult.peakCapacity)
                } else {
                    // No organized recovery - analyze full session
                    analysisResult = await analyze(session, peakCapacity: windowResult.peakCapacity)
                }
                if let result = analysisResult {
                    session.analysisResult = result
                    debugLog("[RRCollector] Re-analyzed session: RMSSD=\(String(format: "%.1f", result.timeDomain.rmssd))ms")
                } else {
                    debugLog("[RRCollector] Warning: Analysis failed")
                }
            } else {
                debugLog("[RRCollector] Warning: Could not find valid analysis window")
            }
        }

        // Re-archive the patched session
        try archive.archive(session)
        rawBackup.markAsArchived(targetSessionId)

        await MainActor.run {
            archiveVersion += 1  // Trigger SwiftUI update
        }

        debugLog("[RRCollector] Recovered and patched session \(targetSessionId.uuidString.prefix(8)) - \(updateReason)")
        return rrPoints.count
    }

    // MARK: - Retry Fetch (when initial fetch fails but data is still on H10)

    /// Retry fetching RR data from H10 after a failed fetch
    /// Data remains on H10 until successfully retrieved and user accepts
    func retryFetchRecording() async throws -> HRVSession? {
        guard polarManager.connectionState == .connected else {
            throw CollectorError.notConnected
        }

        let baseSession = currentSession ?? HRVSession()

        // Attempt to fetch again - data should still be on H10
        let rrPoints: [RRPoint]
        do {
            rrPoints = try await polarManager.stopAndFetchRecording()
        } catch {
            let capturedError = error
            await MainActor.run {
                lastError = capturedError
            }
            throw capturedError
        }

        // IMMEDIATELY backup raw RR data before any processing
        if !rrPoints.isEmpty {
            do {
                try rawBackup.backup(
                    points: rrPoints,
                    sessionId: baseSession.id,
                    deviceId: polarManager.connectedDeviceId
                )
            } catch {
                debugLog("[RRCollector] Warning: Failed to backup retry fetch RR data: \(error)")
            }
        }

        guard rrPoints.count >= 120 else {
            await MainActor.run {
                lastError = CollectorError.insufficientData
            }
            throw CollectorError.insufficientData
        }

        // Build RR series
        let series = RRSeries(
            points: rrPoints,
            sessionId: baseSession.id,
            startDate: baseSession.startDate
        )

        let analyzingSession = HRVSession(
            id: baseSession.id,
            startDate: baseSession.startDate,
            endDate: Date(),
            state: .analyzing,
            sessionType: baseSession.sessionType,
            rrSeries: series,
            analysisResult: nil,
            artifactFlags: nil
        )

        await MainActor.run {
            currentSession = analyzingSession
        }

        let flags = artifactDetector.detectArtifacts(in: series)

        // Verify data quality
        let verifyResult = verification.verify(series, flags: flags)

        // Try to get sleep boundaries from HealthKit for window selection
        var sleepStartMs: Int64? = nil
        var wakeTimeMs: Int64? = nil
        do {
            let sleepData = try await healthKit.fetchSleepData(for: baseSession.startDate, recordingEnd: Date())
            if let sleepStart = sleepData.sleepStart {
                sleepStartMs = Int64(sleepStart.timeIntervalSince(baseSession.startDate) * 1000)
                debugLog("[RRCollector] Using HealthKit sleep start for retry window selection: \(sleepStart)")
            }
            if let sleepEnd = sleepData.sleepEnd {
                wakeTimeMs = Int64(sleepEnd.timeIntervalSince(baseSession.startDate) * 1000)
                debugLog("[RRCollector] Using HealthKit wake time for retry window selection: \(sleepEnd)")
            }
        } catch {
            debugLog("[RRCollector] Could not fetch HealthKit data for retry: \(error)")
        }

        // Select recovery window and compute peak capacity
        // recoveryWindow may be nil if no organized parasympathetic plateau detected
        let windowResult = windowSelector.findBestWindowWithCapacity(in: series, flags: flags, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs)

        // Analyze using selected window (or full session if no organized recovery)
        let analysisResult: HRVAnalysisResult?
        if let windowResult = windowResult, let recoveryWindow = windowResult.recoveryWindow {
            analysisResult = await analyze(analyzingSession, window: recoveryWindow, flags: flags, peakCapacity: windowResult.peakCapacity)
        } else if let windowResult = windowResult {
            debugLog("[RRCollector] No consolidated recovery (retry) - analyzing full session")
            analysisResult = await analyze(analyzingSession, peakCapacity: windowResult.peakCapacity)
        } else {
            analysisResult = await analyze(analyzingSession)
        }

        // Clamp sleep boundaries to valid range (>= 0 and within recording duration)
        let recordingDurationMs = series.points.last?.endMs ?? 0
        let clampedSleepStart = sleepStartMs.map { max(0, $0) }
        let clampedSleepEnd = wakeTimeMs.map { max(0, min($0, recordingDurationMs)) }

        let finalSession = HRVSession(
            id: analyzingSession.id,
            startDate: analyzingSession.startDate,
            endDate: analyzingSession.endDate,
            state: analysisResult != nil ? .complete : .failed,
            sessionType: baseSession.sessionType,
            rrSeries: series,
            analysisResult: analysisResult,
            artifactFlags: flags,
            sleepStartMs: clampedSleepStart,
            sleepEndMs: clampedSleepEnd
        )

        // Compute baseline deviation for UI
        let deviation = baselineTracker.deviation(for: finalSession)

        await MainActor.run {
            currentSession = finalSession
            verificationResult = verifyResult
            recoveryWindow = windowResult?.recoveryWindow
            needsAcceptance = finalSession.state == .complete
            baselineDeviation = deviation
            sessionStartTime = nil
        }

        return finalSession
    }

    /// Recover stored exercise data from H10 (for data that was recorded but never fetched)
    /// Use this when H10 has stored data from a previous session that wasn't retrieved
    func recoverFromDevice() async throws -> HRVSession? {
        guard polarManager.connectionState == .connected else {
            throw CollectorError.notConnected
        }

        // Fetch stored exercise data from H10 (doesn't clear it yet)
        let recovered: PolarManager.RecoveredExercise
        do {
            recovered = try await polarManager.recoverExerciseData()
        } catch {
            let capturedError = error
            await MainActor.run {
                lastError = capturedError
            }
            throw capturedError
        }

        let rrPoints = recovered.rrPoints
        guard rrPoints.count >= 120 else {
            await MainActor.run {
                lastError = CollectorError.insufficientData
            }
            throw CollectorError.insufficientData
        }

        // Check for persisted recording state (preferred source of truth for start time)
        let persistedState = getPersistedRecordingState()
        let sessionId: UUID
        let sessionType: SessionType

        // H10 recording date (Polar SDK entry.date is the END of recording) and calculated duration
        let h10EndDate = recovered.recordingDate
        let totalDurationMs = rrPoints.last?.endMs ?? 0
        _ = h10EndDate.addingTimeInterval(-TimeInterval(totalDurationMs) / 1000.0)  // H10 start date (unused, RTC unreliable)

        // Determine start time - priority: persisted > HealthKit > calculated from H10
        var startDate: Date
        var endDate: Date

        // Track HealthKit sleep start for window selection
        var healthKitSleepStart: Date? = nil

        if let persisted = persistedState {
            // We have persisted state - use the actual start time we recorded
            sessionId = persisted.sessionId
            sessionType = persisted.sessionType
            startDate = persisted.startTime
            debugLog("[RRCollector] Using PERSISTED recording start time: \(startDate)")

            // For end time, try HealthKit wake time first, fall back to H10
            do {
                let sleepData = try await healthKit.fetchSleepData(for: startDate, recordingEnd: h10EndDate)
                healthKitSleepStart = sleepData.sleepStart
                if let sleepStart = sleepData.sleepStart {
                    debugLog("[RRCollector] HealthKit sleep start: \(sleepStart)")
                }
                if let sleepEnd = sleepData.sleepEnd {
                    endDate = sleepEnd
                    debugLog("[RRCollector] Using HealthKit wake time: \(endDate)")
                } else {
                    endDate = h10EndDate
                    debugLog("[RRCollector] No HealthKit wake time, using H10 end: \(endDate)")
                }
            } catch {
                endDate = h10EndDate
                debugLog("[RRCollector] Could not fetch HealthKit data: \(error), using H10 end: \(endDate)")
            }
        } else {
            // No persisted state - align RR data to HealthKit sleep times
            // H10's entry.date is unreliable (no persistent RTC)
            sessionId = UUID()
            sessionType = .overnight

            let durationSeconds = TimeInterval(totalDurationMs) / 1000.0

            // Get HealthKit sleep data - this is when the user ACTUALLY slept
            let searchEnd = Date()
            let searchStart = searchEnd.addingTimeInterval(-24 * 60 * 60) // 24 hours ago

            do {
                let sleepData = try await healthKit.fetchSleepData(for: searchStart, recordingEnd: searchEnd)
                healthKitSleepStart = sleepData.sleepStart

                if let hkSleepStart = sleepData.sleepStart {
                    // Detect when HR dropped (sleep onset) in the RR data
                    // This tells us how many ms into the recording sleep started
                    let sleepOnsetMs = detectSleepOnset(in: rrPoints) ?? 0

                    // Recording started = HealthKit sleep start - time until HR dropped
                    // e.g., if HR dropped 30 min into recording and HealthKit says sleep at 10 PM
                    // then recording started at 9:30 PM
                    let sleepOnsetSeconds = TimeInterval(sleepOnsetMs) / 1000.0
                    startDate = hkSleepStart.addingTimeInterval(-sleepOnsetSeconds)
                    endDate = startDate.addingTimeInterval(durationSeconds)

                    debugLog("[RRCollector] HealthKit sleep start: \(hkSleepStart)")
                    debugLog("[RRCollector] HR drop detected at \(sleepOnsetMs / 60000) min into recording")
                    debugLog("[RRCollector] Calculated recording start: \(startDate)")
                    debugLog("[RRCollector] Calculated recording end: \(endDate)")
                } else if let hkEnd = sleepData.sleepEnd {
                    // Only have wake time - align recording end to wake
                    endDate = hkEnd
                    startDate = hkEnd.addingTimeInterval(-durationSeconds)
                    debugLog("[RRCollector] Using HealthKit wake time: \(hkEnd), calculated start: \(startDate)")
                } else {
                    // No HealthKit sleep data at all - last resort fallback
                    let fetchTime = Date()
                    endDate = fetchTime
                    startDate = fetchTime.addingTimeInterval(-durationSeconds)
                    debugLog("[RRCollector] WARNING: No HealthKit sleep data found, using fetch time as fallback")
                }
            } catch {
                // HealthKit fetch failed - last resort fallback
                let fetchTime = Date()
                endDate = fetchTime
                startDate = fetchTime.addingTimeInterval(-durationSeconds)
                debugLog("[RRCollector] HealthKit error: \(error), using fetch time as fallback")
            }

            debugLog("[RRCollector] NOTE: H10 entry.date (\(h10EndDate)) ignored - aligned to HealthKit sleep data")
        }

        debugLog("[RRCollector] Final session times: start=\(startDate), end=\(endDate)")

        // Backup raw RR data immediately
        do {
            try rawBackup.backup(
                points: rrPoints,
                sessionId: sessionId,
                deviceId: polarManager.connectedDeviceId
            )
        } catch {
            debugLog("[RRCollector] Warning: Failed to backup recovered RR data: \(error)")
        }

        // Build RR series with absolute timestamps based on known start time
        let series = RRSeries(
            points: rrPoints,
            sessionId: sessionId,
            startDate: startDate
        )

        let analyzingSession = HRVSession(
            id: sessionId,
            startDate: startDate,
            endDate: endDate,
            state: .analyzing,
            sessionType: sessionType,
            rrSeries: series,
            analysisResult: nil,
            artifactFlags: nil
        )

        await MainActor.run {
            currentSession = analyzingSession
        }

        let flags = artifactDetector.detectArtifacts(in: series)

        // Verify data quality
        let verifyResult = verification.verify(series, flags: flags)

        // Use HealthKit sleep boundaries for window selection
        let sleepStartMs: Int64? = healthKitSleepStart.map { Int64($0.timeIntervalSince(startDate) * 1000) }
        let wakeTimeMs = Int64(endDate.timeIntervalSince(startDate) * 1000)
        debugLog("[RRCollector] Using wake time for recovered session window selection: \(endDate)")
        if let sleepMs = sleepStartMs {
            debugLog("[RRCollector] Using sleep start for recovered session window selection: \(sleepMs)ms from recording start")
        }

        // Select best analysis window and compute peak capacity
        // recoveryWindow may be nil if no organized parasympathetic plateau detected
        let windowResult = windowSelector.findBestWindowWithCapacity(in: series, flags: flags, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs)

        // Analyze using selected window (or full session if no organized recovery)
        let analysisResult: HRVAnalysisResult?
        if let windowResult = windowResult, let recoveryWindow = windowResult.recoveryWindow {
            analysisResult = await analyze(analyzingSession, window: recoveryWindow, flags: flags, peakCapacity: windowResult.peakCapacity)
        } else if let windowResult = windowResult {
            debugLog("[RRCollector] No consolidated recovery (recovered session) - analyzing full session")
            analysisResult = await analyze(analyzingSession, peakCapacity: windowResult.peakCapacity)
        } else {
            analysisResult = await analyze(analyzingSession)
        }

        // Clamp sleep boundaries to valid range (>= 0 and within recording duration)
        let recordingDurationMs = series.points.last?.endMs ?? 0
        let clampedSleepStart = sleepStartMs.map { max(0, $0) }
        let clampedSleepEnd: Int64? = max(0, min(wakeTimeMs, recordingDurationMs))

        let finalSession = HRVSession(
            id: sessionId,
            startDate: startDate,
            endDate: endDate,
            state: analysisResult != nil ? .complete : .failed,
            sessionType: sessionType,
            rrSeries: series,
            analysisResult: analysisResult,
            artifactFlags: flags,
            sleepStartMs: clampedSleepStart,
            sleepEndMs: clampedSleepEnd
        )

        // Compute baseline deviation for UI
        let deviation = baselineTracker.deviation(for: finalSession)

        await MainActor.run {
            currentSession = finalSession
            verificationResult = verifyResult
            recoveryWindow = windowResult?.recoveryWindow
            needsAcceptance = finalSession.state == .complete
            baselineDeviation = deviation
            sessionStartTime = nil
        }

        // Re-check for stored exercises (should now be empty or have this one pending clear)
        await polarManager.checkForStoredExercises()

        debugLog("[RRCollector] Recovered \(rrPoints.count) RR points from H10 storage")
        return finalSession
    }

    // MARK: - Convenience Properties for UI

    /// Is connected to Polar H10
    var isConnected: Bool {
        polarManager.connectionState == .connected
    }

    /// Is currently streaming data
    var isStreaming: Bool {
        polarManager.isStreaming || isStreamingMode
    }

    /// Current heart rate from streaming (calculated from recent RR intervals)
    var currentHeartRate: Double? {
        let recentPoints = polarManager.streamedRRPoints.suffix(5)
        guard recentPoints.count >= 2 else { return nil }
        let avgRR = recentPoints.map { Double($0.rr_ms) }.reduce(0, +) / Double(recentPoints.count)
        guard avgRR > 0 else { return nil }
        return 60000.0 / avgRR  // Convert ms to bpm
    }

    /// Duration of current streaming session
    var streamingDuration: TimeInterval {
        sessionStartTime.map { Date().timeIntervalSince($0) } ?? 0
    }

    /// Start scanning for Polar H10
    func startScanning() {
        polarManager.startScanning()
    }

    /// Start streaming with tags
    @MainActor
    func startStreaming(withTags tags: [ReadingTag] = []) {
        do {
            try startStreamingSession(durationSeconds: streamingTargetSeconds)
            // Tags will be saved when session completes
            if var session = currentSession {
                session.tags = tags
                currentSession = session
            }
        } catch {
            lastError = error
        }
    }

    /// Stop streaming
    func stopStreaming() {
        Task {
            _ = await stopStreamingSession()
        }
    }

    /// Reset current session state for new recording
    func resetSession() {
        currentSession = nil
        collectedPoints = []
        verificationResult = nil
        recoveryWindow = nil
        needsAcceptance = false
        baselineDeviation = nil
    }

    /// Notify that the archive has changed (for external updates like delete/tag changes)
    func notifyArchiveChanged() {
        archiveVersion += 1
    }

    // MARK: - Import

    /// Save an imported session to the archive
    /// - Parameter session: An already-analyzed session from imported data
    func saveImportedSession(_ session: HRVSession) async throws {
        guard session.state == .complete,
              session.analysisResult != nil else {
            throw CollectorError.insufficientData
        }

        // Check for duplicate by date
        if archive.sessionExists(for: session.startDate) {
            // Skip duplicate but don't throw - it's expected during re-import
            return
        }

        // Archive the session
        try archive.archive(session)

        // Update baseline with imported data
        baselineTracker.update(with: session)

        // Update baseline deviation if available
        if let deviation = baselineTracker.deviation(for: session) {
            await MainActor.run {
                baselineDeviation = deviation
                archiveVersion += 1  // Trigger SwiftUI update
            }
        } else {
            await MainActor.run {
                archiveVersion += 1  // Trigger SwiftUI update
            }
        }
    }

    /// Batch save multiple imported sessions efficiently
    /// - Parameter sessions: Array of already-analyzed sessions
    /// - Returns: Number of sessions saved (skips duplicates)
    func saveImportedSessionsBatch(_ sessions: [HRVSession]) async throws -> Int {
        debugLog("[RRCollector] saveImportedSessionsBatch called with \(sessions.count) sessions")

        let validSessions = sessions.filter { $0.state == .complete && $0.analysisResult != nil }
        debugLog("[RRCollector] Valid sessions (complete + analyzed): \(validSessions.count)")

        guard !validSessions.isEmpty else {
            debugLog("[RRCollector] ERROR: No valid sessions to save!")
            return 0
        }

        for (i, session) in validSessions.enumerated() {
            debugLog("[RRCollector] Session[\(i)]: ID=\(session.id.uuidString.prefix(8)) date=\(session.startDate) RMSSD=\(session.analysisResult?.timeDomain.rmssd ?? -1)")
        }

        // Archive all at once (handles duplicate detection internally)
        debugLog("[RRCollector] Calling archive.archiveBatch...")
        let savedCount = try archive.archiveBatch(validSessions)
        debugLog("[RRCollector] archiveBatch returned: \(savedCount) saved")

        // Update baseline with all imported sessions (sorted by date, oldest first)
        let sortedSessions = validSessions.sorted { $0.startDate < $1.startDate }
        for session in sortedSessions {
            baselineTracker.update(with: session)
        }
        debugLog("[RRCollector] Updated baseline with \(sortedSessions.count) sessions")

        // Single UI update at the end
        await MainActor.run {
            archiveVersion += 1
            debugLog("[RRCollector] archiveVersion incremented to \(self.archiveVersion)")
        }

        debugLog("[RRCollector] Archive now has \(archive.entries.count) entries")
        return savedCount
    }

    /// Get collection status
    var status: CollectionStatus {
        CollectionStatus(
            isCollecting: isCollecting,
            pointCount: collectedPoints.count,
            duration: sessionStartTime.map { Date().timeIntervalSince($0) },
            artifactPercentage: currentArtifactPercentage,
            connectionState: polarManager.connectionState,
            recordingState: polarManager.recordingState
        )
    }

    // MARK: - Backup Recovery

    /// Check for sessions that have raw backups but aren't in the archive
    /// Returns list of backup entries that could potentially be recovered
    /// Excludes sessions that were intentionally deleted by the user
    func checkForLostSessions() -> [(id: UUID, date: Date, beatCount: Int)] {
        let archivedIds = Set(archive.entries.map { $0.sessionId })
        let deletedIds = archive.deletedIds  // Get intentionally deleted session IDs
        let allBackups = rawBackup.allBackups()

        var lost: [(id: UUID, date: Date, beatCount: Int)] = []
        for backup in allBackups {
            // Only consider truly lost sessions - not archived AND not intentionally deleted
            if !archivedIds.contains(backup.id) && !deletedIds.contains(backup.id) {
                lost.append((id: backup.id, date: backup.captureDate, beatCount: backup.beatCount))
            }
        }

        // Only log summary, not individual sessions (too noisy)
        if lost.count > 0 {
            debugLog("[RRCollector] Found \(lost.count) lost sessions with backups")
        }
        return lost
    }

    /// Check for sessions that were intentionally deleted but still have backups (trash)
    /// Returns list of backup entries that can be restored from trash
    func checkForDeletedSessions() -> [(id: UUID, date: Date, beatCount: Int)] {
        let deletedIds = archive.deletedIds
        let allBackups = rawBackup.allBackups()

        var deleted: [(id: UUID, date: Date, beatCount: Int)] = []
        for backup in allBackups {
            if deletedIds.contains(backup.id) {
                deleted.append((id: backup.id, date: backup.captureDate, beatCount: backup.beatCount))
            }
        }
        return deleted
    }

    /// Restore a session from trash (re-analyze and archive)
    func restoreFromTrash(_ sessionId: UUID) async -> HRVSession? {
        // First, remove from deleted list
        try? archive.unmarkAsDeleted(sessionId)

        // Then recover using standard recovery process
        return await recoverFromBackup(sessionId)
    }

    /// Permanently delete a session (remove from deleted tracking)
    /// Note: backup file is kept until automatic purge (90 days)
    func permanentlyDelete(_ sessionId: UUID) {
        try? archive.forgetDeletedSession(sessionId)
    }

    /// Delete lost sessions (mark as intentionally deleted so they don't appear in lost sessions list)
    /// - Parameter sessionIds: The session IDs to mark as deleted
    func deleteLostSessions(_ sessionIds: [UUID]) {
        for id in sessionIds {
            try? archive.markAsDeleted(id)
        }
        debugLog("[RRCollector] Marked \(sessionIds.count) lost sessions as deleted")
    }

    /// Recover a session from raw backup
    /// - Parameter sessionId: The session ID to recover
    /// - Returns: The recovered session, or nil if recovery failed
    func recoverFromBackup(_ sessionId: UUID) async -> HRVSession? {
        debugLog("[RRCollector] Attempting to recover session \(sessionId) from backup")

        guard let backup = try? rawBackup.retrieve(sessionId) else {
            debugLog("[RRCollector] No backup found for session \(sessionId)")
            return nil
        }

        debugLog("[RRCollector] Found backup with \(backup.beatCount) beats from \(backup.captureDate)")

        // Create series from backup
        let series = RRSeries(
            points: backup.points,
            sessionId: sessionId,
            startDate: backup.captureDate
        )

        // Detect artifacts
        let flags = artifactDetector.detectArtifacts(in: series)

        // Calculate end date from last point
        let endDate: Date?
        if let lastPoint = backup.points.last {
            endDate = backup.captureDate.addingTimeInterval(Double(lastPoint.t_ms) / 1000.0)
        } else {
            endDate = nil
        }

        // Create session with the BACKUP's session ID (critical for trash tracking)
        var session = HRVSession(
            id: sessionId,  // Use backup's ID so delete tracking works
            startDate: backup.captureDate,
            endDate: endDate,
            state: .collecting,
            sessionType: .overnight,
            rrSeries: series,
            analysisResult: nil,
            artifactFlags: flags
        )

        // Run analysis
        if let windowResult = windowSelector.findBestWindowWithCapacity(in: series, flags: flags) {
            let analysisResult: HRVAnalysisResult?
            if let recoveryWindow = windowResult.recoveryWindow {
                analysisResult = await analyze(session, window: recoveryWindow, flags: flags, peakCapacity: windowResult.peakCapacity)
            } else {
                analysisResult = await analyze(session, peakCapacity: windowResult.peakCapacity)
            }
            session.analysisResult = analysisResult
            session.state = analysisResult != nil ? .complete : .failed
        } else {
            session.state = .failed
        }

        // Archive the recovered session
        if session.state == .complete {
            do {
                try archive.archive(session)
                rawBackup.markAsArchived(sessionId)
                await MainActor.run {
                    archiveVersion += 1
                }
                debugLog("[RRCollector] Successfully recovered and archived session \(sessionId)")
            } catch {
                debugLog("[RRCollector] Failed to archive recovered session: \(error)")
            }
        }

        return session
    }

    /// Recover all lost sessions from backups
    /// - Returns: Number of sessions recovered
    func recoverAllLostSessions() async -> Int {
        let lost = checkForLostSessions()
        var recovered = 0

        for (id, date, _) in lost {
            debugLog("[RRCollector] Recovering session from \(date)...")
            if await recoverFromBackup(id) != nil {
                recovered += 1
            }
        }

        debugLog("[RRCollector] Recovered \(recovered) of \(lost.count) lost sessions")
        return recovered
    }

    // MARK: - Corrupted Session Recovery

    /// Information about a potentially corrupted session
    struct CorruptedSessionInfo {
        let sessionId: UUID
        let archiveDate: Date      // Current date in archive (possibly wrong)
        let backupDate: Date       // Original capture date from backup
        let dateMismatchDays: Int  // How many days off the dates are
        let beatCount: Int
    }

    /// Find sessions where archive date doesn't match backup date
    /// This detects sessions corrupted by the reanalyzeSession bug
    /// - Parameter toleranceDays: How many days difference to consider a mismatch (default 1)
    /// - Returns: List of potentially corrupted sessions
    func findCorruptedSessions(toleranceDays: Int = 1) -> [CorruptedSessionInfo] {
        let calendar = Calendar.current
        var corrupted: [CorruptedSessionInfo] = []

        // Get all backups
        let allBackups = rawBackup.allBackups()

        for backup in allBackups {
            // Find matching archive entry by session ID
            if let archiveEntry = archive.entries.first(where: { $0.sessionId == backup.id }) {
                // Compare dates
                let archiveDay = calendar.startOfDay(for: archiveEntry.date)
                let backupDay = calendar.startOfDay(for: backup.captureDate)

                let daysDifference = abs(calendar.dateComponents([.day], from: backupDay, to: archiveDay).day ?? 0)

                if daysDifference > toleranceDays {
                    corrupted.append(CorruptedSessionInfo(
                        sessionId: backup.id,
                        archiveDate: archiveEntry.date,
                        backupDate: backup.captureDate,
                        dateMismatchDays: daysDifference,
                        beatCount: backup.beatCount
                    ))
                    debugLog("[RRCollector] Found corrupted session \(backup.id.uuidString.prefix(8)): archive=\(archiveEntry.date), backup=\(backup.captureDate), diff=\(daysDifference) days")
                }
            }
        }

        // Only log if corrupted sessions actually found
        if corrupted.count > 0 {
            debugLog("[RRCollector] ❌ Found \(corrupted.count) potentially corrupted sessions")
        }
        return corrupted.sorted { $0.backupDate > $1.backupDate }
    }

    /// Restore a corrupted session using the original date from backup
    /// - Parameter sessionId: The session ID to restore
    /// - Returns: The restored session, or nil if restoration failed
    func restoreCorruptedSession(_ sessionId: UUID) async -> HRVSession? {
        debugLog("[RRCollector] Attempting to restore corrupted session \(sessionId)")

        // Get the backup with original date
        guard let backup = try? rawBackup.retrieve(sessionId) else {
            debugLog("[RRCollector] No backup found for session \(sessionId)")
            return nil
        }

        // Get current archived session (if exists) to preserve tags/notes
        let existingSession = try? archive.retrieve(sessionId)
        let existingTags = existingSession?.tags ?? []
        let existingNotes = existingSession?.notes
        let existingSessionType = existingSession?.sessionType ?? .overnight

        debugLog("[RRCollector] Restoring with original date: \(backup.captureDate)")
        debugLog("[RRCollector] Beat count: \(backup.beatCount)")

        // Create series with ORIGINAL date from backup
        let series = RRSeries(
            points: backup.points,
            sessionId: sessionId,
            startDate: backup.captureDate
        )

        // Detect artifacts
        let flags = artifactDetector.detectArtifacts(in: series)

        // Calculate end date from RR data duration
        let durationMs = backup.points.last?.endMs ?? 0
        let endDate = backup.captureDate.addingTimeInterval(Double(durationMs) / 1000.0)

        // Create session with correct date
        var session = HRVSession(
            id: sessionId,
            startDate: backup.captureDate,
            endDate: endDate,
            state: .analyzing,
            sessionType: existingSessionType,
            rrSeries: series,
            analysisResult: nil,
            artifactFlags: flags,
            tags: existingTags,
            notes: existingNotes
        )

        // Run analysis
        if let windowResult = windowSelector.findBestWindowWithCapacity(in: series, flags: flags) {
            let analysisResult: HRVAnalysisResult?
            if let recoveryWindow = windowResult.recoveryWindow {
                analysisResult = await analyze(session, window: recoveryWindow, flags: flags, peakCapacity: windowResult.peakCapacity)
            } else {
                analysisResult = await analyze(session, peakCapacity: windowResult.peakCapacity)
            }
            session.analysisResult = analysisResult
            session.state = analysisResult != nil ? .complete : .failed
        } else {
            session.state = .failed
        }

        // Re-archive with correct date
        if session.state == .complete {
            do {
                try archive.archive(session)
                await MainActor.run {
                    archiveVersion += 1
                }
                debugLog("[RRCollector] Successfully restored session \(sessionId) with date \(backup.captureDate)")
            } catch {
                debugLog("[RRCollector] Failed to archive restored session: \(error)")
                return nil
            }
        }

        return session
    }

    /// Restore all corrupted sessions to their original dates
    /// - Parameter toleranceDays: How many days difference to consider corrupted (default 1)
    /// - Returns: Number of sessions restored
    func restoreAllCorruptedSessions(toleranceDays: Int = 1) async -> Int {
        let corrupted = findCorruptedSessions(toleranceDays: toleranceDays)
        var restoredCount = 0

        for info in corrupted {
            debugLog("[RRCollector] Restoring session from \(info.backupDate) (was showing as \(info.archiveDate))...")
            if await restoreCorruptedSession(info.sessionId) != nil {
                restoredCount += 1
            }
        }

        debugLog("[RRCollector] Restored \(restoredCount) of \(corrupted.count) corrupted sessions")
        return restoredCount
    }

    // MARK: - Re-Analysis

    /// Re-analyze a session with current algorithms
    /// Uses the session's existing timestamps - does NOT modify dates
    /// - Parameter session: Session with existing rrSeries data
    /// - Returns: Updated session with new analysis results, or nil if no RR data
    func reanalyzeSession(_ session: HRVSession, method: WindowSelectionMethod = .consolidatedRecovery) async -> HRVSession? {
        guard let series = session.rrSeries, !series.points.isEmpty else {
            debugLog("[RRCollector] Cannot re-analyze: no RR data in session")
            return nil
        }

        debugLog("[RRCollector] Re-analyzing session \(session.id) with \(series.points.count) points")
        debugLog("[RRCollector] Using window selection method: \(method.displayName)")
        debugLog("[RRCollector] Session startDate: \(session.startDate)")

        // Fetch training load for readiness context (if enabled)
        if SettingsManager.shared.settings.enableTrainingLoadIntegration {
            cachedTrainingLoad = await healthKit.calculateTrainingLoad()
        }

        // Run artifact detection with current algorithms
        let flags = artifactDetector.detectArtifacts(in: series)

        // Fetch HealthKit sleep data AROUND THE SESSION'S DATE (not today!)
        // This is critical - we must search for sleep data from when the session was recorded
        // DO NOT use extendForDisplay here - we need sleep boundaries that match the RR data we have
        var sleepData: HealthKitManager.SleepData? = nil
        let sessionEndDate = session.endDate ?? session.startDate.addingTimeInterval(12 * 60 * 60)

        do {
            sleepData = try await healthKit.fetchSleepData(for: session.startDate, recordingEnd: sessionEndDate)
            if let hkSleepStart = sleepData?.sleepStart {
                debugLog("[RRCollector] Found HealthKit sleep start for session date: \(hkSleepStart)")
            }
        } catch {
            debugLog("[RRCollector] Could not fetch HealthKit data for session date: \(error)")
        }

        // Calculate sleep boundaries relative to session startDate
        var sleepStartMs: Int64? = nil
        var wakeTimeMs: Int64? = nil

        if let hkSleepStart = sleepData?.sleepStart {
            sleepStartMs = Int64(hkSleepStart.timeIntervalSince(session.startDate) * 1000)
            debugLog("[RRCollector] Converted sleepStartMs: \(sleepStartMs!) (\(sleepStartMs! / 60000) min from session start)")
        }
        if let hkSleepEnd = sleepData?.sleepEnd {
            wakeTimeMs = Int64(hkSleepEnd.timeIntervalSince(session.startDate) * 1000)
            debugLog("[RRCollector] Converted wakeTimeMs: \(wakeTimeMs!) (\(wakeTimeMs! / 60000) min from session start)")
        }
        // Fall back to recording boundaries if no HealthKit data
        if sleepStartMs == nil {
            sleepStartMs = 0  // Default to recording start
            debugLog("[RRCollector] No HealthKit sleep start - using recording start")
        }
        if wakeTimeMs == nil {
            wakeTimeMs = Int64(sessionEndDate.timeIntervalSince(session.startDate) * 1000)
            debugLog("[RRCollector] No HealthKit wake time - using session end")
        }

        // Find best window using selected method and compute peak capacity
        let windowResult: WindowSelector.WindowSelectionResult?
        if method == .consolidatedRecovery {
            // Use existing comprehensive method
            windowResult = windowSelector.findBestWindowWithCapacity(in: series, flags: flags, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs)
        } else {
            // Use specific method - get recovery window
            let recoveryWindow = windowSelector.selectWindowByMethod(method, in: series, flags: flags, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs)
            // Peak capacity still needs to be computed separately
            let windowWithCapacity = windowSelector.findBestWindowWithCapacity(in: series, flags: flags, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs)
            windowResult = WindowSelector.WindowSelectionResult(
                recoveryWindow: recoveryWindow,
                peakCapacity: windowWithCapacity?.peakCapacity
            )
        }

        guard let finalResult = windowResult else {
            debugLog("[RRCollector] Could not find valid window for re-analysis")
            return nil
        }

        // Create updated session preserving original timestamps
        // IMPORTANT: We preserve session.startDate and session.endDate exactly as-is
        // The previous bug was changing these dates based on wrong HealthKit lookups
        var updatedSession = HRVSession(
            id: session.id,
            startDate: session.startDate,
            endDate: session.endDate,
            state: session.state,
            sessionType: session.sessionType,
            rrSeries: series,
            analysisResult: session.analysisResult,
            artifactFlags: flags,
            recoveryScore: session.recoveryScore,
            tags: session.tags,
            notes: session.notes,
            importedMetrics: session.importedMetrics,
            deviceProvenance: session.deviceProvenance
        )

        // Run full analysis (or full session if no organized recovery)
        let newResult: HRVAnalysisResult?
        if let window = finalResult.recoveryWindow {
            newResult = await analyze(updatedSession, window: window, flags: flags, peakCapacity: finalResult.peakCapacity)
        } else {
            debugLog("[RRCollector] No recovery window found (reanalysis) - analyzing full session")
            newResult = await analyze(updatedSession, peakCapacity: finalResult.peakCapacity)
        }

        guard let analysisResult = newResult else {
            debugLog("[RRCollector] Analysis failed during re-analysis")
            return nil
        }

        updatedSession.analysisResult = analysisResult

        // Update in archive (archive() replaces existing session with same ID)
        do {
            try archive.archive(updatedSession)
            // Update baseline with new analysis
            baselineTracker.update(with: updatedSession)
            await MainActor.run {
                archiveVersion += 1
            }
            debugLog("[RRCollector] Re-analysis complete. New RMSSD: \(String(format: "%.1f", analysisResult.timeDomain.rmssd))")
        } catch {
            debugLog("[RRCollector] Failed to save re-analyzed session: \(error)")
        }

        return updatedSession
    }

    /// Re-analyze all sessions with current algorithms
    /// - Returns: Number of sessions successfully re-analyzed
    func reanalyzeAllSessions() async -> Int {
        let sessions = archivedSessions.filter { $0.rrSeries != nil && !($0.rrSeries?.points.isEmpty ?? true) }
        var successCount = 0

        for session in sessions {
            if await reanalyzeSession(session) != nil {
                successCount += 1
            }
        }

        debugLog("[RRCollector] Re-analyzed \(successCount)/\(sessions.count) sessions")
        return successCount
    }

    // MARK: - Analysis

    /// Analyze session using provided window
    private func analyze(_ session: HRVSession, window: WindowSelector.RecoveryWindow, flags: [ArtifactFlags], peakCapacity: PeakCapacity? = nil) async -> HRVAnalysisResult? {
        guard let series = session.rrSeries else { return nil }

        let timeDomain = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: window.startIndex,
            windowEnd: window.endIndex
        )

        let frequencyDomain = FrequencyDomainAnalyzer.computeFrequencyDomain(
            series,
            flags: flags,
            windowStart: window.startIndex,
            windowEnd: window.endIndex
        )

        let nonlinear = NonlinearAnalyzer.computeNonlinear(
            series,
            flags: flags,
            windowStart: window.startIndex,
            windowEnd: window.endIndex
        )

        guard let td = timeDomain, let nl = nonlinear else {
            return nil
        }

        // Fetch daytime resting HR for nocturnal HR dip calculation
        // Uses afternoon/evening HR from the day before the sleep recording
        let daytimeRestingHR: Double?
        do {
            daytimeRestingHR = try await healthKit.fetchDaytimeRestingHR(for: session.startDate)
        } catch {
            debugLog("[RRCollector] Could not fetch daytime resting HR: \(error)")
            daytimeRestingHR = nil
        }

        // Compute ANS metrics
        let ansMetrics = computeANSMetrics(
            series: series,
            flags: flags,
            windowStart: window.startIndex,
            windowEnd: window.endIndex,
            timeDomain: td,
            nonlinear: nl,
            daytimeRestingHR: daytimeRestingHR
        )

        let artifactPct = artifactDetector.artifactPercentage(flags, start: window.startIndex, end: window.endIndex)
        let cleanCount = flags[window.startIndex..<window.endIndex].filter { !$0.isArtifact }.count

        var result = HRVAnalysisResult(
            windowStart: window.startIndex,
            windowEnd: window.endIndex,
            timeDomain: td,
            frequencyDomain: frequencyDomain,
            nonlinear: nl,
            ansMetrics: ansMetrics,
            artifactPercentage: artifactPct,
            cleanBeatCount: cleanCount,
            analysisDate: Date()
        )

        // Add window selection info for display
        result.windowStartMs = window.startMs
        result.windowEndMs = window.endMs
        result.windowMeanHR = window.meanHR
        result.windowHRStability = window.hrStability
        result.windowSelectionReason = window.selectionReason
        result.windowRelativePosition = window.relativePosition
        result.isConsolidated = window.isConsolidated
        result.isOrganizedRecovery = window.isOrganizedRecovery
        result.windowClassification = window.windowClassification.rawValue
        result.peakCapacity = peakCapacity
        result.trainingContext = createTrainingContext()

        return result
    }

    /// Analyze session using full recording when no organized recovery window detected
    /// This is used when peakCapacity exists but no consolidated recovery occurred
    private func analyze(_ session: HRVSession, peakCapacity: PeakCapacity?) async -> HRVAnalysisResult? {
        guard let series = session.rrSeries else { return nil }

        let flags = artifactDetector.detectArtifacts(in: series)

        // Use entire recording for analysis
        let windowStart = 0
        let windowEnd = series.points.count

        let timeDomain = TimeDomainAnalyzer.computeTimeDomain(
            series,
            flags: flags,
            windowStart: windowStart,
            windowEnd: windowEnd
        )

        let frequencyDomain = FrequencyDomainAnalyzer.computeFrequencyDomain(
            series,
            flags: flags,
            windowStart: windowStart,
            windowEnd: windowEnd
        )

        let nonlinear = NonlinearAnalyzer.computeNonlinear(
            series,
            flags: flags,
            windowStart: windowStart,
            windowEnd: windowEnd
        )

        guard let td = timeDomain, let nl = nonlinear else {
            return nil
        }

        // Fetch daytime resting HR for nocturnal HR dip calculation
        let daytimeRestingHR: Double?
        do {
            daytimeRestingHR = try await healthKit.fetchDaytimeRestingHR(for: session.startDate)
        } catch {
            debugLog("[RRCollector] Could not fetch daytime resting HR: \(error)")
            daytimeRestingHR = nil
        }

        // Compute ANS metrics
        let ansMetrics = computeANSMetrics(
            series: series,
            flags: flags,
            windowStart: windowStart,
            windowEnd: windowEnd,
            timeDomain: td,
            nonlinear: nl,
            daytimeRestingHR: daytimeRestingHR
        )

        let artifactPct = artifactDetector.artifactPercentage(flags, start: windowStart, end: windowEnd)
        let cleanCount = flags[windowStart..<windowEnd].filter { !$0.isArtifact }.count

        var result = HRVAnalysisResult(
            windowStart: windowStart,
            windowEnd: windowEnd,
            timeDomain: td,
            frequencyDomain: frequencyDomain,
            nonlinear: nl,
            ansMetrics: ansMetrics,
            artifactPercentage: artifactPct,
            cleanBeatCount: cleanCount,
            analysisDate: Date()
        )

        // Mark as not consolidated - no organized recovery window detected
        result.windowStartMs = series.points.first?.t_ms ?? 0
        result.windowEndMs = series.points.last?.t_ms ?? 0
        result.windowMeanHR = nil
        result.windowHRStability = nil
        result.windowSelectionReason = "No consolidated recovery detected"
        result.windowRelativePosition = nil
        result.isConsolidated = false
        result.isOrganizedRecovery = false
        result.windowClassification = WindowSelector.RecoveryWindow.WindowClassification.highVariability.rawValue
        result.peakCapacity = peakCapacity
        result.trainingContext = createTrainingContext()

        debugLog("[RRCollector] Analyzed full session (no organized recovery): RMSSD=\(String(format: "%.1f", td.rmssd))ms")

        return result
    }

    /// Fallback: analyze session finding best window automatically
    /// Note: This fallback uses session timestamps only, not HealthKit.
    /// For HealthKit-aware window selection, use the primary analysis paths.
    private func analyze(_ session: HRVSession) async -> HRVAnalysisResult? {
        guard let series = session.rrSeries else { return nil }

        let flags = artifactDetector.detectArtifacts(in: series)

        // Try to get sleep boundaries from HealthKit for better window selection
        var sleepStartMs: Int64? = nil
        var wakeTimeMs: Int64? = nil
        if let endDate = session.endDate {
            do {
                let sleepData = try await healthKit.fetchSleepData(for: session.startDate, recordingEnd: endDate)
                if let sleepStart = sleepData.sleepStart {
                    sleepStartMs = Int64(sleepStart.timeIntervalSince(session.startDate) * 1000)
                }
                if let sleepEnd = sleepData.sleepEnd {
                    wakeTimeMs = Int64(sleepEnd.timeIntervalSince(session.startDate) * 1000)
                }
            } catch {
                // Fall back to recording boundaries
            }
            if sleepStartMs == nil {
                sleepStartMs = 0  // Default to recording start
            }
            if wakeTimeMs == nil {
                wakeTimeMs = Int64(endDate.timeIntervalSince(session.startDate) * 1000)
            }
        }

        guard let windowResult = windowSelector.findBestWindowWithCapacity(in: series, flags: flags, sleepStartMs: sleepStartMs, wakeTimeMs: wakeTimeMs) else {
            return nil
        }

        // Handle optional recovery window
        if let recoveryWindow = windowResult.recoveryWindow {
            return await analyze(session, window: recoveryWindow, flags: flags, peakCapacity: windowResult.peakCapacity)
        } else {
            // No organized recovery - analyze full session with peak capacity
            return await analyze(session, peakCapacity: windowResult.peakCapacity)
        }
    }

    // MARK: - Manual Window Reanalysis

    /// Reanalyze a session at a specific timestamp (for manual window selection)
    /// Returns a new HRVAnalysisResult with the window centered on the target time
    func reanalyzeAtPosition(_ session: HRVSession, targetMs: Int64) async -> HRVAnalysisResult? {
        guard let series = session.rrSeries else {
            debugLog("[RRCollector] Reanalysis failed: no RR series")
            return nil
        }

        let flags = artifactDetector.detectArtifacts(in: series)

        guard let window = windowSelector.analyzeAtPosition(in: series, flags: flags, targetMs: targetMs) else {
            debugLog("[RRCollector] Reanalysis failed: could not create window at \(targetMs) ms")
            return nil
        }

        debugLog("[RRCollector] Manual reanalysis at \(targetMs) ms -> window \(window.startIndex)-\(window.endIndex)")
        return await analyze(session, window: window, flags: flags)
    }

    /// Update the current session's analysis result (for manual reanalysis)
    func updateCurrentSessionResult(_ result: HRVAnalysisResult) {
        currentSession?.analysisResult = result
    }

    private var currentArtifactPercentage: Double {
        guard !collectedPoints.isEmpty else { return 0 }

        let series = RRSeries(
            points: collectedPoints,
            sessionId: currentSession?.id ?? UUID(),
            startDate: sessionStartTime ?? Date()
        )
        let flags = artifactDetector.detectArtifacts(in: series)
        return artifactDetector.artifactPercentage(flags, start: 0, end: flags.count)
    }

    // MARK: - Types

    struct CollectionStatus {
        let isCollecting: Bool
        let pointCount: Int
        let duration: TimeInterval?
        let artifactPercentage: Double
        let connectionState: PolarManager.ConnectionState
        let recordingState: PolarManager.RecordingState
    }

    // MARK: - Sleep Onset Detection

    /// Detect sleep onset by finding where HR suddenly drops and stays low
    /// Returns the timestamp (in ms from recording start) where sleep likely began
    private func detectSleepOnset(in rrPoints: [RRPoint]) -> Int64? {
        guard rrPoints.count > 300 else { return nil } // Need at least ~5 min of data

        // Calculate HR in 2-minute rolling windows (step by 30 seconds)
        let windowSize = 120 // ~2 min of beats
        let stepSize = 30    // ~30 sec steps
        var hrWindows: [(timeMs: Int64, hr: Double)] = []

        var i = 0
        while i + windowSize < rrPoints.count {
            let windowEnd = min(i + windowSize, rrPoints.count)
            let windowPoints = Array(rrPoints[i..<windowEnd])

            // Calculate mean HR for this window
            let validRRs = windowPoints.filter { $0.rr_ms > 300 && $0.rr_ms < 2000 }
            guard validRRs.count > windowSize / 2 else {
                i += stepSize
                continue
            }

            let meanRR = validRRs.map { Double($0.rr_ms) }.reduce(0, +) / Double(validRRs.count)
            let hr = 60000.0 / meanRR
            let midTime = windowPoints[windowSize / 2].t_ms

            hrWindows.append((midTime, hr))
            i += stepSize
        }

        guard hrWindows.count > 10 else { return nil }

        // Find the first significant HR drop (>8 bpm) that sustains
        // Look for: high HR -> sudden drop -> stays low for at least 10 minutes
        for j in 5..<(hrWindows.count - 10) {
            // Average HR before this point (last 5 windows = ~2.5 min)
            let beforeHR = hrWindows[(j-5)..<j].map { $0.hr }.reduce(0, +) / 5.0

            // Average HR after this point (next 10 windows = ~5 min)
            let afterHR = hrWindows[j..<(j+10)].map { $0.hr }.reduce(0, +) / 10.0

            // Look for significant sustained drop
            let hrDrop = beforeHR - afterHR
            if hrDrop > 8 && afterHR < 65 { // Dropped >8 bpm and now below 65
                debugLog("[RRCollector] Detected sleep onset: HR dropped from \(String(format: "%.1f", beforeHR)) to \(String(format: "%.1f", afterHR)) bpm at \(hrWindows[j].timeMs / 60000) min")
                return hrWindows[j].timeMs
            }
        }

        // No clear drop found - sleep might have started at recording start
        debugLog("[RRCollector] No clear HR drop detected - assuming sleep near recording start")
        return nil
    }

    enum CollectorError: Error, LocalizedError {
        case notConnected
        case alreadyRecording
        case sessionExists
        case insufficientData
        case noSessionToAccept
        case noSessionToRecover
        case dataAlreadyExists

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "Polar H10 not connected"
            case .alreadyRecording:
                return "A recording is already in progress on the device"
            case .sessionExists:
                return "A session with this ID already exists"
            case .insufficientData:
                return "Not enough RR data collected (need at least 120 beats)"
            case .noSessionToAccept:
                return "No completed session to accept"
            case .noSessionToRecover:
                return "No session found to recover data into"
            case .dataAlreadyExists:
                return "Session already has this RR data - no recovery needed"
            }
        }
    }
}
