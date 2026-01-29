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
import CoreBluetooth

#if canImport(PolarBleSdk)
import PolarBleSdk
import RxSwift

// Extension to add async/await support to RxSwift Observable (for older RxSwift versions)
extension ObservableType {
    var values: AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream { continuation in
            let disposable = self.subscribe(
                onNext: { value in
                    continuation.yield(value)
                },
                onError: { error in
                    continuation.finish(throwing: error)
                },
                onCompleted: {
                    continuation.finish()
                }
            )
            continuation.onTermination = { _ in
                disposable.dispose()
            }
        }
    }
}
#endif

/// Manages Polar H10 connection and internal RR recording
/// Uses H10's internal memory to store RR data - survives disconnect and app backgrounding
@MainActor
final class PolarManager: NSObject, ObservableObject {

    // MARK: - Published State

    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var recordingState: RecordingState = .idle
    @Published private(set) var connectedDeviceId: String?
    @Published private(set) var discoveredDevices: [DiscoveredDevice] = []
    @Published private(set) var lastError: Error?
    @Published private(set) var batteryLevel: Int?
    @Published private(set) var isRecordingOnDevice: Bool = false
    @Published private(set) var isH10RecordingFeatureReady: Bool = false
    @Published private(set) var isHrStreamingReady: Bool = false  // True when .feature_hr is ready for streaming
    @Published private(set) var isCheckingRecordingStatus: Bool = false  // True while checking H10 status on connect
    @Published private(set) var hasPendingExercise: Bool = false
    @Published private(set) var hasStoredExercise: Bool = false  // True if H10 has stored data that can be recovered
    @Published private(set) var storedExerciseDate: Date?  // Date of stored exercise on H10 (for archive comparison)
    @Published private(set) var fetchProgress: FetchProgress?  // Non-nil during fetch operations

    // Fetch cancellation
    private var fetchCancelled = false

    // Streaming mode state
    @Published private(set) var isStreaming: Bool = false
    @Published private(set) var streamedRRPoints: [RRPoint] = []
    @Published private(set) var streamingElapsedSeconds: Int = 0

    // Heartbeat logging (only log if nothing noteworthy happened in 30 min)
    nonisolated(unsafe) private var lastSignificantLogTime: Date = Date()

    // Live HR monitoring (active when connected, even if not streaming RR data)
    @Published private(set) var currentHeartRate: Int?

    // Connection health tracking - true when keep-alive pings are failing
    @Published private(set) var connectionHealthWarning: Bool = false

    /// Current streaming buffer (alias for streamedRRPoints)
    var streamingBuffer: [RRPoint] { streamedRRPoints }

    // MARK: - Types

    /// Stored exercise entry for deferred clearing
    #if canImport(PolarBleSdk)
    private var pendingExerciseEntry: PolarExerciseEntry?
    #endif

    struct DiscoveredDevice: Identifiable, Equatable {
        let id: String
        let name: String
        let rssi: Int
    }

    enum ConnectionState: Equatable {
        case disconnected
        case scanning
        case connecting
        case connected
    }

    enum RecordingState: Equatable {
        case idle
        case starting
        case recording
        case stopping
        case fetching
    }

    /// Progress tracking for fetch operations
    struct FetchProgress: Equatable {
        enum Stage: String {
            case stopping = "Stopping recording..."
            case finalizing = "Waiting for H10 to finalize..."
            case listingExercises = "Finding recorded data..."
            case fetchingData = "Downloading from H10..."
            case reconnecting = "Reconnecting to H10..."
            case retrying = "Retrying..."
            case complete = "Complete"
            case failed = "Failed"
        }

        var stage: Stage
        var progress: Double  // 0.0 to 1.0
        var attempt: Int
        var maxAttempts: Int
        var statusMessage: String

        static let idle = FetchProgress(stage: .stopping, progress: 0, attempt: 0, maxAttempts: 3, statusMessage: "")

        var displayMessage: String {
            if attempt > 1 {
                return "\(stage.rawValue) (attempt \(attempt)/\(maxAttempts))"
            }
            return stage.rawValue
        }
    }

    enum PolarError: Error, LocalizedError {
        case notConnected
        case alreadyRecording
        case notRecording
        case recordingFailed(String)
        case fetchFailed(String)
        case sdkNotAvailable
        case noRecordingFound
        case hasUnrecoveredData  // H10 has data that wasn't successfully retrieved

        var errorDescription: String? {
            switch self {
            case .notConnected: return "Polar H10 not connected"
            case .alreadyRecording: return "Recording already in progress"
            case .notRecording: return "No recording in progress"
            case .recordingFailed(let msg): return "Recording failed: \(msg)"
            case .fetchFailed(let msg): return "Fetch failed: \(msg)"
            case .sdkNotAvailable: return "Polar SDK not available"
            case .noRecordingFound: return "No recording found on device"
            case .hasUnrecoveredData: return "Your H10 has unrecovered recording data. Recover it first or explicitly discard it."
            }
        }
    }

    // MARK: - Persisted State

    private let lastDeviceIdKey = "PolarManager.lastDeviceId"

    var lastConnectedDeviceId: String? {
        get { UserDefaults.standard.string(forKey: lastDeviceIdKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastDeviceIdKey) }
    }

    // MARK: - Private Properties

    #if canImport(PolarBleSdk)
    private var api: PolarBleApi?
    private var disposeBag = DisposeBag()
    private var searchTask: Task<Void, Never>?
    private var streamingDisposable: Disposable?
    private var streamingTimer: Timer?
    private var streamingStartTime: Date?
    private var streamingCumulativeMs: Int64 = 0
    private var hrMonitorDisposable: Disposable?  // For live HR on connect

    // Streaming reconnection state
    private var streamingReconnectAttempts: Int = 0
    @Published private(set) var isReconnectingStream: Bool = false
    @Published private(set) var streamingReconnectCount: Int = 0  // Total successful reconnects

    // Keep-alive ping failure tracking
    private var consecutivePingFailures: Int = 0
    private let maxPingFailuresBeforeWarning: Int = 3
    #endif

    // MARK: - Initialization

    override init() {
        super.init()
        setupPolarApi()

        // Listen for significant log events to reset heartbeat timer
        NotificationCenter.default.addObserver(
            forName: DebugLogger.significantLogPosted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.lastSignificantLogTime = Date()
        }
    }

    private func setupPolarApi() {
        #if canImport(PolarBleSdk)
        // H10 internal recording requires pairing ONCE, then it remembers
        // This enables recording RR to H10 memory - survives disconnect/app backgrounding
        api = PolarBleApiDefaultImpl.polarImplementation(
            DispatchQueue.main,
            features: [
                .feature_hr,
                .feature_battery_info,
                .feature_device_info,
                .feature_polar_h10_exercise_recording  // Required for internal RR storage
            ]
        )
        api?.polarFilter(true)
        api?.observer = self
        api?.deviceInfoObserver = self
        api?.deviceFeaturesObserver = self
        api?.powerStateObserver = self
        api?.logger = self
        debugLog("[PolarManager] API initialized with H10 internal recording: \(api != nil)")
        #else
        debugLog("[PolarManager] PolarBleSdk not available")
        #endif
    }

    // MARK: - Scanning

    func startScanning() {
        #if canImport(PolarBleSdk)
        guard connectionState == .disconnected else {
            debugLog("[PolarManager] startScanning: already in state \(connectionState)")
            return
        }

        guard let api = api else {
            debugLog("[PolarManager] ERROR: api is nil, cannot scan")
            lastError = PolarError.sdkNotAvailable
            return
        }

        discoveredDevices = []
        connectionState = .scanning
        debugLog("[PolarManager] Starting scan...")

        // Cancel any existing search
        searchTask?.cancel()

        // Use async/await with .values extension (matches official Polar example pattern)
        searchTask = Task { [weak self] in
            do {
                for try await deviceInfo in api.searchForDevice().values {
                    if Task.isCancelled { break }
                    debugLog("[PolarManager] Found: \(deviceInfo.name) (\(deviceInfo.deviceId))")
                    await MainActor.run {
                        self?.handleDiscoveredDevice(deviceInfo)
                    }
                }
            } catch {
                if !Task.isCancelled {
                    debugLog("[PolarManager] Search error: \(error)")
                    await MainActor.run {
                        self?.lastError = error
                        self?.connectionState = .disconnected
                    }
                }
            }
        }

        debugLog("[PolarManager] Scan started")
        #else
        lastError = PolarError.sdkNotAvailable
        #endif
    }

    #if canImport(PolarBleSdk)
    private func handleDiscoveredDevice(_ info: PolarDeviceInfo) {
        debugLog("[PolarManager] handleDiscoveredDevice called: \(info.name) (\(info.deviceId)), rssi: \(info.rssi), connectable: \(info.connectable)")

        // polarFilter(true) already filters to Polar devices only
        // Accept all discovered devices - don't filter by name here
        let device = DiscoveredDevice(
            id: info.deviceId,
            name: info.name,
            rssi: Int(info.rssi)
        )

        // Update or add
        if let index = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[index] = device
            debugLog("[PolarManager] Updated device: \(device.name), total: \(discoveredDevices.count)")
        } else {
            discoveredDevices.append(device)
            debugLog("[PolarManager] Added new device: \(device.name), total: \(discoveredDevices.count)")
        }
    }
    #endif

    func stopScanning() {
        #if canImport(PolarBleSdk)
        debugLog("[PolarManager] stopScanning called")
        searchTask?.cancel()
        searchTask = nil
        if connectionState == .scanning {
            connectionState = .disconnected
        }
        #endif
    }

    // MARK: - Connection

    func connect(deviceId: String) {
        #if canImport(PolarBleSdk)
        stopScanning()
        guard connectionState != .connected else { return }
        // Note: Don't set connectedDeviceId here - wait for deviceConnected callback
        // This prevents a brief state inconsistency where UI shows connected before it's true
        connectionState = .connecting
        do {
            try api?.connectToDevice(deviceId)
        } catch {
            lastError = error
            connectionState = .disconnected
        }
        #else
        lastError = PolarError.sdkNotAvailable
        #endif
    }

    func connectToLastDevice() {
        guard let deviceId = lastConnectedDeviceId else { return }
        connect(deviceId: deviceId)
    }

    func disconnect() {
        #if canImport(PolarBleSdk)
        guard let deviceId = connectedDeviceId else { return }
        do {
            try api?.disconnectFromDevice(deviceId)
        } catch {
            lastError = error
        }
        connectedDeviceId = nil
        connectionState = .disconnected
        // Don't reset recordingState or isRecordingOnDevice - H10 continues recording internally
        #endif
    }

    // MARK: - Recording Control (H10 Internal Memory)

    /// Start RR recording on H10's internal memory
    /// Recording survives disconnect and app backgrounding
    func startRecording() async throws {
        #if canImport(PolarBleSdk)
        guard let api = api, let deviceId = connectedDeviceId else {
            throw PolarError.notConnected
        }
        guard connectionState == .connected else {
            throw PolarError.notConnected
        }
        guard isH10RecordingFeatureReady else {
            throw PolarError.recordingFailed("H10 recording feature not ready - wait a moment after connecting")
        }
        guard recordingState == .idle && !isRecordingOnDevice else {
            throw PolarError.alreadyRecording
        }

        await MainActor.run {
            recordingState = .starting
        }

        // Clear any existing exercises before starting new recording
        // Data should already be backed up in archive, or user has chosen to start fresh
        debugLog("[PolarManager] Clearing any existing exercises before start...")
        do {
            try await clearAnyExistingExercises()
        } catch {
            debugLog("[PolarManager] Warning: Could not clear existing exercises: \(error)")
            // Continue anyway - the start might still work
        }

        let exerciseId = generateExerciseId()

        do {
            // Start RR recording on H10 internal memory
            debugLog("[PolarManager] Starting H10 internal recording with exerciseId: \(exerciseId)")
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                api.startRecording(
                    deviceId,
                    exerciseId: exerciseId,
                    interval: .interval_1s,
                    sampleType: .rr
                )
                .subscribe(
                    onCompleted: {
                        continuation.resume()
                    },
                    onError: { error in
                        continuation.resume(throwing: error)
                    }
                )
                .disposed(by: disposeBag)
            }

            lastConnectedDeviceId = deviceId

            await MainActor.run {
                recordingState = .recording
                isRecordingOnDevice = true
            }

            debugLog("[PolarManager] Started H10 internal RR recording successfully")
        } catch {
            debugLog("[PolarManager] ERROR starting recording: \(error)")
            await MainActor.run {
                recordingState = .idle
                lastError = PolarError.recordingFailed(error.localizedDescription)
            }
            throw error
        }
        #else
        throw PolarError.sdkNotAvailable
        #endif
    }

    /// Clear any existing exercises from H10 before starting new recording
    /// This prevents error 106 (operationNotPermitted)
    private func clearAnyExistingExercises() async throws {
        #if canImport(PolarBleSdk)
        guard let api = api, let deviceId = connectedDeviceId else {
            return
        }

        // List exercises on the device
        let entries: [PolarExerciseEntry] = try await withCheckedThrowingContinuation { continuation in
            var collectedEntries: [PolarExerciseEntry] = []
            api.fetchStoredExerciseList(deviceId)
                .subscribe(
                    onNext: { entry in
                        collectedEntries.append(entry)
                    },
                    onError: { error in
                        continuation.resume(throwing: error)
                    },
                    onCompleted: {
                        continuation.resume(returning: collectedEntries)
                    }
                )
                .disposed(by: disposeBag)
        }

        if entries.isEmpty {
            debugLog("[PolarManager] No existing exercises to clear")
            return
        }

        debugLog("[PolarManager] Found \(entries.count) existing exercise(s), removing...")

        // Remove all existing exercises
        for entry in entries {
            debugLog("[PolarManager] Removing exercise: \(entry.path)")
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                api.removeExercise(deviceId, entry: entry)
                    .subscribe(
                        onCompleted: {
                            continuation.resume()
                        },
                        onError: { error in
                            continuation.resume(throwing: error)
                        }
                    )
                    .disposed(by: disposeBag)
            }
        }

        // Clear any pending exercise state
        await MainActor.run {
            pendingExerciseEntry = nil
            hasPendingExercise = false
        }

        debugLog("[PolarManager] Cleared \(entries.count) exercise(s) from H10")
        #endif
    }

    /// Check if H10 has an active recording (call after reconnecting)
    /// - Parameter deviceId: Optional device ID to use. If nil, uses connectedDeviceId.
    func checkRecordingStatus(deviceId: String? = nil) async throws -> Bool {
        #if canImport(PolarBleSdk)
        guard let api = api, let deviceId = deviceId ?? connectedDeviceId else {
            throw PolarError.notConnected
        }

        let status: PolarRecordingStatus = try await withCheckedThrowingContinuation { continuation in
            api.requestRecordingStatus(deviceId)
                .subscribe(
                    onSuccess: { status in
                        continuation.resume(returning: status)
                    },
                    onFailure: { error in
                        continuation.resume(throwing: error)
                    }
                )
                .disposed(by: disposeBag)
        }

        await MainActor.run {
            isRecordingOnDevice = status.ongoing
            if status.ongoing {
                recordingState = .recording
            }
        }

        debugLog("[PolarManager] Recording status: ongoing=\(status.ongoing)")
        return status.ongoing
        #else
        throw PolarError.sdkNotAvailable
        #endif
    }

    /// Check if H10 has stored exercise data that can be recovered
    /// Call this on connect to notify user of recoverable data
    /// - Parameter deviceId: Optional device ID to use. If nil, uses connectedDeviceId.
    func checkForStoredExercises(deviceId: String? = nil) async {
        #if canImport(PolarBleSdk)
        guard let api = api, let deviceId = deviceId ?? connectedDeviceId else {
            debugLog("[PolarManager] checkForStoredExercises: No device ID available")
            return
        }

        do {
            let entries: [PolarExerciseEntry] = try await withCheckedThrowingContinuation { continuation in
                var collectedEntries: [PolarExerciseEntry] = []
                api.fetchStoredExerciseList(deviceId)
                    .subscribe(
                        onNext: { entry in
                            collectedEntries.append(entry)
                        },
                        onError: { error in
                            continuation.resume(throwing: error)
                        },
                        onCompleted: {
                            continuation.resume(returning: collectedEntries)
                        }
                    )
                    .disposed(by: disposeBag)
            }

            let hasStored = !entries.isEmpty
            let exerciseDate = entries.first?.date
            debugLog("[PolarManager] Found \(entries.count) stored exercise(s) on H10, date: \(exerciseDate?.description ?? "none")")

            await MainActor.run {
                self.hasStoredExercise = hasStored
                self.storedExerciseDate = exerciseDate
            }
        } catch {
            debugLog("[PolarManager] Error checking for stored exercises: \(error)")
            await MainActor.run {
                self.hasStoredExercise = false
                self.storedExerciseDate = nil
            }
        }
        #endif
    }

    /// Helper to update fetch progress on main thread
    private func updateProgress(_ stage: FetchProgress.Stage, progress: Double, attempt: Int = 1, maxAttempts: Int = 5, message: String = "") async {
        await MainActor.run {
            self.fetchProgress = FetchProgress(
                stage: stage,
                progress: progress,
                attempt: attempt,
                maxAttempts: maxAttempts,
                statusMessage: message
            )
        }
    }

    /// Cancel an ongoing fetch operation
    func cancelFetch() {
        fetchCancelled = true
        debugLog("[PolarManager] Fetch cancellation requested")
    }

    /// Stop recording and fetch RR data from H10 internal memory
    func stopAndFetchRecording() async throws -> [RRPoint] {
        #if canImport(PolarBleSdk)
        guard let api = api, let deviceId = connectedDeviceId else {
            throw PolarError.notConnected
        }

        // Reset cancellation flag
        fetchCancelled = false

        // Initialize progress
        await updateProgress(.stopping, progress: 0.05, message: "Checking recording status...")

        // Check current recording status
        let status: PolarRecordingStatus = try await withCheckedThrowingContinuation { continuation in
            api.requestRecordingStatus(deviceId)
                .subscribe(
                    onSuccess: { status in
                        continuation.resume(returning: status)
                    },
                    onFailure: { error in
                        continuation.resume(throwing: error)
                    }
                )
                .disposed(by: disposeBag)
        }

        if status.ongoing {
            await MainActor.run {
                recordingState = .stopping
            }
            await updateProgress(.stopping, progress: 0.1, message: "Stopping H10 recording...")

            // Stop the recording
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                api.stopRecording(deviceId)
                    .subscribe(
                        onCompleted: {
                            continuation.resume()
                        },
                        onError: { error in
                            continuation.resume(throwing: error)
                        }
                    )
                    .disposed(by: disposeBag)
            }

            // Give H10 time to finalize the recording before fetching
            debugLog("[PolarManager] Recording stopped, waiting for H10 to finalize...")
            await updateProgress(.finalizing, progress: 0.2, message: "H10 is saving data...")

            // Animated wait with progress updates
            for i in 1...15 {
                try await Task.sleep(nanoseconds: 100_000_000)  // 0.1 seconds
                let prog = 0.2 + (Double(i) / 15.0) * 0.15  // 0.2 to 0.35
                await updateProgress(.finalizing, progress: prog, message: "H10 is saving data...")
            }
        } else {
            await updateProgress(.listingExercises, progress: 0.35, message: "Recording already stopped")
        }

        await MainActor.run {
            recordingState = .fetching
        }

        // Fetch with retry logic - H10 may need a moment after stop
        // Note: The Polar SDK has a known issue with large downloads timing out (GitHub #181)
        // Community workaround: disconnect/reconnect between retry attempts
        let maxAttempts = 5
        var lastError: Error?
        for attempt in 1...maxAttempts {
            // Check for cancellation before each attempt
            if fetchCancelled {
                debugLog("[PolarManager] Fetch cancelled by user")
                await MainActor.run {
                    self.fetchProgress = nil
                    recordingState = .idle
                }
                throw PolarError.fetchFailed("Cancelled by user")
            }

            do {
                await updateProgress(.listingExercises, progress: 0.4, attempt: attempt, maxAttempts: maxAttempts, message: "Searching for data on H10...")

                let rrPoints = try await fetchExerciseDataWithProgress(api: api, deviceId: deviceId, attempt: attempt, maxAttempts: maxAttempts)

                await updateProgress(.complete, progress: 1.0, attempt: attempt, maxAttempts: maxAttempts, message: "Downloaded \(rrPoints.count) heartbeats!")

                await MainActor.run {
                    recordingState = .idle
                    isRecordingOnDevice = false
                }

                // Clear progress after brief delay to show completion
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run {
                    self.fetchProgress = nil
                }

                debugLog("[PolarManager] Fetched \(rrPoints.count) RR points from H10 (pending clear)")
                return rrPoints
            } catch {
                // Check if cancelled during fetch
                if fetchCancelled {
                    debugLog("[PolarManager] Fetch cancelled during attempt \(attempt)")
                    await MainActor.run {
                        self.fetchProgress = nil
                        recordingState = .idle
                    }
                    throw PolarError.fetchFailed("Cancelled by user")
                }

                lastError = error
                debugLog("[PolarManager] Fetch attempt \(attempt) failed: \(error)")
                if attempt < maxAttempts {
                    // Disconnect and reconnect between retry attempts (proven workaround for SDK timeout issue)
                    await updateProgress(.reconnecting, progress: 0.35, attempt: attempt + 1, maxAttempts: maxAttempts, message: "Resetting connection...")
                    debugLog("[PolarManager] Disconnecting and reconnecting for retry...")

                    // Disconnect
                    do {
                        try api.disconnectFromDevice(deviceId)
                    } catch {
                        debugLog("[PolarManager] Disconnect error (continuing): \(error)")
                    }

                    // Wait for disconnect to complete
                    for i in 1...30 {
                        if fetchCancelled { break }
                        try await Task.sleep(nanoseconds: 100_000_000)  // 0.1 seconds each
                        let prog = 0.35 + (Double(i) / 30.0) * 0.05
                        await updateProgress(.reconnecting, progress: prog, attempt: attempt + 1, maxAttempts: maxAttempts, message: "Disconnecting...")
                    }

                    // Reconnect
                    await updateProgress(.reconnecting, progress: 0.42, attempt: attempt + 1, maxAttempts: maxAttempts, message: "Reconnecting to H10...")
                    do {
                        try api.connectToDevice(deviceId)
                    } catch {
                        debugLog("[PolarManager] Reconnect error: \(error)")
                        // Continue anyway - the retry might still work
                    }

                    // Wait for reconnection and feature ready
                    for i in 1...50 {
                        if fetchCancelled { break }
                        try await Task.sleep(nanoseconds: 100_000_000)  // 0.1 seconds each
                        let prog = 0.42 + (Double(i) / 50.0) * 0.08
                        await updateProgress(.reconnecting, progress: prog, attempt: attempt + 1, maxAttempts: maxAttempts, message: "Waiting for connection...")

                        // Check if connected and feature ready
                        if i > 20 && connectionState == .connected && isH10RecordingFeatureReady {
                            debugLog("[PolarManager] Reconnected and feature ready")
                            break
                        }
                    }

                    await updateProgress(.retrying, progress: 0.38, attempt: attempt + 1, maxAttempts: maxAttempts, message: "Retrying download...")
                }
            }
        }

        await updateProgress(.failed, progress: 0, maxAttempts: maxAttempts, message: "Failed after \(maxAttempts) attempts")
        await MainActor.run {
            recordingState = .idle
        }
        throw lastError ?? PolarError.fetchFailed("Unknown error after retries")
        #else
        throw PolarError.sdkNotAvailable
        #endif
    }

    /// Internal helper to fetch exercise data from H10 (no progress updates)
    private func fetchExerciseData(api: PolarBleApi, deviceId: String) async throws -> [RRPoint] {
        return try await fetchExerciseDataWithProgress(api: api, deviceId: deviceId, attempt: 1, maxAttempts: 5)
    }

    /// Internal helper to fetch exercise data from H10 with progress updates
    private func fetchExerciseDataWithProgress(api: PolarBleApi, deviceId: String, attempt: Int, maxAttempts: Int) async throws -> [RRPoint] {
        // List exercises on the device
        let entries: [PolarExerciseEntry] = try await withCheckedThrowingContinuation { continuation in
            var collectedEntries: [PolarExerciseEntry] = []
            api.fetchStoredExerciseList(deviceId)
                .subscribe(
                    onNext: { entry in
                        collectedEntries.append(entry)
                    },
                    onError: { error in
                        continuation.resume(throwing: error)
                    },
                    onCompleted: {
                        continuation.resume(returning: collectedEntries)
                    }
                )
                .disposed(by: disposeBag)
        }

        guard let entry = entries.first else {
            throw PolarError.noRecordingFound
        }

        await updateProgress(.fetchingData, progress: 0.5, attempt: attempt, maxAttempts: maxAttempts, message: "Found recording, downloading...")

        // Fetch the exercise data
        let exercise: PolarExerciseData = try await withCheckedThrowingContinuation { continuation in
            api.fetchExercise(deviceId, entry: entry)
                .subscribe(
                    onSuccess: { data in
                        continuation.resume(returning: data)
                    },
                    onFailure: { error in
                        continuation.resume(throwing: error)
                    }
                )
                .disposed(by: disposeBag)
        }

        await updateProgress(.fetchingData, progress: 0.8, attempt: attempt, maxAttempts: maxAttempts, message: "Processing data...")

        // Convert to RRPoints
        let rrPoints = convertToRRPoints(exercise)

        await updateProgress(.fetchingData, progress: 0.9, attempt: attempt, maxAttempts: maxAttempts, message: "Got \(rrPoints.count) heartbeats")

        // Store entry for deferred clearing - user must accept report first
        await MainActor.run {
            pendingExerciseEntry = entry
            hasPendingExercise = true
        }

        return rrPoints
    }

    /// Recovered exercise data with recording timestamp
    struct RecoveredExercise {
        let rrPoints: [RRPoint]
        let recordingDate: Date  // When the recording ENDED on H10 (from PolarExerciseEntry.date)
    }

    /// Recover exercise data from H10 with progress tracking and retry logic
    /// Use this to fetch stored RR data for recovery purposes
    /// Does NOT mark for clearing - data stays on H10 until explicitly cleared
    func recoverExerciseData() async throws -> RecoveredExercise {
        #if canImport(PolarBleSdk)
        guard let api = api, let deviceId = connectedDeviceId else {
            throw PolarError.notConnected
        }
        guard connectionState == .connected else {
            throw PolarError.notConnected
        }

        // Reset cancellation flag
        fetchCancelled = false

        debugLog("[PolarManager] Recovering exercise data from H10...")

        // Initialize progress
        await updateProgress(.listingExercises, progress: 0.1, message: "Finding stored data...")

        // First, get the exercise entry (this is quick, no retry needed)
        let entries: [PolarExerciseEntry] = try await withCheckedThrowingContinuation { continuation in
            var collectedEntries: [PolarExerciseEntry] = []
            api.fetchStoredExerciseList(deviceId)
                .subscribe(
                    onNext: { entry in
                        collectedEntries.append(entry)
                    },
                    onError: { error in
                        continuation.resume(throwing: error)
                    },
                    onCompleted: {
                        continuation.resume(returning: collectedEntries)
                    }
                )
                .disposed(by: disposeBag)
        }

        guard let entry = entries.first else {
            await MainActor.run { self.fetchProgress = nil }
            throw PolarError.noRecordingFound
        }

        debugLog("[PolarManager] Found exercise: \(entry.path) recorded at \(entry.date), fetching data...")

        // Fetch with retry logic - same as stopAndFetchRecording
        // Note: The Polar SDK has a known issue with large downloads timing out (GitHub #181)
        // Community workaround: disconnect/reconnect between retry attempts
        let maxAttempts = 5
        var lastError: Error?

        for attempt in 1...maxAttempts {
            // Check for cancellation before each attempt
            if fetchCancelled {
                debugLog("[PolarManager] Recovery cancelled by user")
                await MainActor.run { self.fetchProgress = nil }
                throw PolarError.fetchFailed("Cancelled by user")
            }

            do {
                await updateProgress(.fetchingData, progress: 0.3, attempt: attempt, maxAttempts: maxAttempts, message: "Downloading from H10...")

                // Fetch the exercise data
                let exercise: PolarExerciseData = try await withCheckedThrowingContinuation { continuation in
                    api.fetchExercise(deviceId, entry: entry)
                        .subscribe(
                            onSuccess: { data in
                                continuation.resume(returning: data)
                            },
                            onFailure: { error in
                                continuation.resume(throwing: error)
                            }
                        )
                        .disposed(by: disposeBag)
                }

                await updateProgress(.fetchingData, progress: 0.8, attempt: attempt, maxAttempts: maxAttempts, message: "Processing data...")

                // Convert to RRPoints
                let rrPoints = convertToRRPoints(exercise)

                await updateProgress(.complete, progress: 1.0, attempt: attempt, maxAttempts: maxAttempts, message: "Recovered \(rrPoints.count) heartbeats!")

                // Clear progress after brief delay to show completion
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run { self.fetchProgress = nil }

                debugLog("[PolarManager] Recovered \(rrPoints.count) RR points from H10 (NOT cleared), recorded at \(entry.date)")
                return RecoveredExercise(rrPoints: rrPoints, recordingDate: entry.date)

            } catch {
                // Check if cancelled during fetch
                if fetchCancelled {
                    debugLog("[PolarManager] Recovery cancelled during attempt \(attempt)")
                    await MainActor.run { self.fetchProgress = nil }
                    throw PolarError.fetchFailed("Cancelled by user")
                }

                lastError = error
                debugLog("[PolarManager] Recovery attempt \(attempt) failed: \(error)")

                if attempt < maxAttempts {
                    // Disconnect and reconnect between retry attempts (proven workaround for SDK timeout issue)
                    await updateProgress(.reconnecting, progress: 0.2, attempt: attempt + 1, maxAttempts: maxAttempts, message: "Resetting connection...")
                    debugLog("[PolarManager] Disconnecting and reconnecting for retry...")

                    // Disconnect
                    do {
                        try api.disconnectFromDevice(deviceId)
                    } catch {
                        debugLog("[PolarManager] Disconnect error (continuing): \(error)")
                    }

                    // Wait for disconnect to complete
                    for i in 1...30 {
                        if fetchCancelled { break }
                        try await Task.sleep(nanoseconds: 100_000_000)  // 0.1 seconds each
                        let prog = 0.2 + (Double(i) / 30.0) * 0.05
                        await updateProgress(.reconnecting, progress: prog, attempt: attempt + 1, maxAttempts: maxAttempts, message: "Disconnecting...")
                    }

                    // Reconnect
                    await updateProgress(.reconnecting, progress: 0.27, attempt: attempt + 1, maxAttempts: maxAttempts, message: "Reconnecting to H10...")
                    do {
                        try api.connectToDevice(deviceId)
                    } catch {
                        debugLog("[PolarManager] Reconnect error: \(error)")
                    }

                    // Wait for reconnection and feature ready
                    for i in 1...50 {
                        if fetchCancelled { break }
                        try await Task.sleep(nanoseconds: 100_000_000)  // 0.1 seconds each
                        let prog = 0.27 + (Double(i) / 50.0) * 0.08
                        await updateProgress(.reconnecting, progress: prog, attempt: attempt + 1, maxAttempts: maxAttempts, message: "Waiting for connection...")

                        // Check if connected and feature ready
                        if i > 20 && connectionState == .connected && isH10RecordingFeatureReady {
                            debugLog("[PolarManager] Reconnected and feature ready")
                            break
                        }
                    }

                    await updateProgress(.retrying, progress: 0.25, attempt: attempt + 1, maxAttempts: maxAttempts, message: "Retrying download...")
                }
            }
        }

        await updateProgress(.failed, progress: 0, maxAttempts: maxAttempts, message: "Failed after \(maxAttempts) attempts")
        await MainActor.run { self.fetchProgress = nil }
        throw lastError ?? PolarError.fetchFailed("Unknown error after retries")
        #else
        throw PolarError.sdkNotAvailable
        #endif
    }

    /// Clear the pending exercise from H10 memory
    /// Call this ONLY after user has accepted the report
    func clearPendingExercise() async throws {
        #if canImport(PolarBleSdk)
        guard let api = api, let deviceId = connectedDeviceId else {
            throw PolarError.notConnected
        }

        guard let entry = pendingExerciseEntry else {
            debugLog("[PolarManager] No pending exercise to clear")
            return
        }

        debugLog("[PolarManager] Clearing exercise from H10 memory...")

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            api.removeExercise(deviceId, entry: entry)
                .subscribe(
                    onCompleted: {
                        continuation.resume()
                    },
                    onError: { error in
                        continuation.resume(throwing: error)
                    }
                )
                .disposed(by: disposeBag)
        }

        await MainActor.run {
            pendingExerciseEntry = nil
            hasPendingExercise = false
        }

        debugLog("[PolarManager] Exercise cleared from H10")
        #else
        throw PolarError.sdkNotAvailable
        #endif
    }

    /// Discard pending exercise without clearing from device
    /// Use if user rejects the session
    func discardPendingExercise() {
        #if canImport(PolarBleSdk)
        pendingExerciseEntry = nil
        #endif
        hasPendingExercise = false
    }

    /// Explicitly discard any stored exercise data on H10
    /// Use when user chooses to start fresh and lose unrecovered data
    func discardStoredExercises() async throws {
        #if canImport(PolarBleSdk)
        guard let _ = api, let _ = connectedDeviceId else {
            throw PolarError.notConnected
        }

        debugLog("[PolarManager] User requested discard of stored exercises...")
        try await clearAnyExistingExercises()

        await MainActor.run {
            hasStoredExercise = false
        }
        #else
        throw PolarError.sdkNotAvailable
        #endif
    }

    // MARK: - Streaming Mode (Real-time RR Collection)

    /// Start streaming RR intervals in real-time
    /// Note: Requires app to stay in foreground. Must be called from main thread.
    @MainActor
    func startStreaming() throws {
        #if canImport(PolarBleSdk)
        guard let api = api, let deviceId = connectedDeviceId else {
            throw PolarError.notConnected
        }
        guard connectionState == .connected else {
            throw PolarError.notConnected
        }
        guard !isStreaming else {
            throw PolarError.alreadyRecording
        }

        // Reset streaming state (safe - we're on MainActor)
        streamedRRPoints = []
        streamingCumulativeMs = 0
        streamingStartTime = Date()
        streamingElapsedSeconds = 0
        streamingReconnectAttempts = 0
        streamingReconnectCount = 0
        isReconnectingStream = false
        isStreaming = true

        // Start elapsed time timer
        streamingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard let startTime = self.streamingStartTime else { return }
                self.streamingElapsedSeconds = Int(Date().timeIntervalSince(startTime))
            }
        }

        // Subscribe to HR stream which includes RR intervals
        streamingDisposable = api.startHrStreaming(deviceId)
            .observe(on: MainScheduler.instance)
            .subscribe(
                onNext: { [weak self] hrData in
                    self?.handleStreamedHRData(hrData)
                },
                onError: { [weak self] error in
                    debugLog("[PolarManager] Streaming error: \(error)")
                    debugLog("[PolarManager] Error type: \(type(of: error))")

                    // Check if this looks like another app took over the connection
                    let errorDesc = error.localizedDescription.lowercased()
                    if errorDesc.contains("disconnected") || errorDesc.contains("connection") {
                        debugLog("[PolarManager] ⚠️ GATT disconnection detected")
                        debugLog("[PolarManager] ⚠️ If you have other apps running (SnoreLab, Polar Beat, etc.), they may be competing for the H10 connection")
                    }

                    // Attempt to reconnect and resume streaming
                    Task { @MainActor in
                        await self?.attemptStreamingReconnect(afterError: error)
                    }
                },
                onCompleted: { [weak self] in
                    debugLog("[PolarManager] Streaming completed")
                    DispatchQueue.main.async {
                        self?.stopStreamingInternal()
                    }
                }
            )

        debugLog("[PolarManager] Started RR streaming")
        #else
        throw PolarError.sdkNotAvailable
        #endif
    }

    /// Stop streaming and return collected RR points
    func stopStreaming() -> [RRPoint] {
        #if canImport(PolarBleSdk)
        stopStreamingInternal()
        let points = streamedRRPoints
        debugLog("[PolarManager] Stopped streaming with \(points.count) RR points")
        return points
        #else
        return []
        #endif
    }

    /// Send a keep-alive ping to prevent iOS from putting BLE connection into low-power state
    /// Call this periodically during long streaming sessions (every 30-60 seconds)
    func sendKeepAlivePing() {
        #if canImport(PolarBleSdk)
        guard let api = api, let deviceId = connectedDeviceId else { return }
        guard connectionState == .connected else { return }

        // Request recording status as a lightweight ping
        // This forces BLE activity without affecting the ongoing stream
        Task { [weak self] in
            do {
                _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
                    api.requestRecordingStatus(deviceId)
                        .observe(on: MainScheduler.instance)
                        .subscribe(
                            onSuccess: { [weak self] status in
                                // Keep-alive ping successful (no logging - too noisy during overnight)
                                // Reset failure counter on success
                                DispatchQueue.main.async {
                                    self?.consecutivePingFailures = 0
                                    self?.connectionHealthWarning = false
                                }
                                cont.resume(returning: status.ongoing)
                            },
                            onFailure: { error in
                                debugLog("[PolarManager] Keep-alive ping failed: \(error)")
                                cont.resume(throwing: error)
                            }
                        )
                        .disposed(by: self?.disposeBag ?? DisposeBag())
                }
            } catch {
                // Track consecutive failures
                await MainActor.run { [weak self] in
                    guard let self = self else { return }
                    self.consecutivePingFailures += 1
                    debugLog("[PolarManager] Keep-alive ping error (\(self.consecutivePingFailures)/\(self.maxPingFailuresBeforeWarning)): \(error)")

                    if self.consecutivePingFailures >= self.maxPingFailuresBeforeWarning {
                        debugLog("[PolarManager] WARNING: Multiple keep-alive pings failed - connection may be degraded")
                        self.connectionHealthWarning = true
                    }
                }
            }
        }
        #endif
    }

    #if canImport(PolarBleSdk)
    private func stopStreamingInternal() {
        streamingDisposable?.dispose()
        streamingDisposable = nil
        streamingTimer?.invalidate()
        streamingTimer = nil
        streamingStartTime = nil
        isStreaming = false
        // Reset reconnection state when explicitly stopped
        streamingReconnectAttempts = 0
        isReconnectingStream = false
        // Reset ping failure tracking
        consecutivePingFailures = 0
        connectionHealthWarning = false
    }

    /// Attempt to reconnect and resume streaming after an error
    /// Preserves already-collected RR points and continues from where we left off
    @MainActor
    private func attemptStreamingReconnect(afterError error: Error) async {
        guard !isReconnectingStream else {
            debugLog("[PolarManager] Already attempting to reconnect stream, ignoring")
            return
        }

        streamingReconnectAttempts += 1
        debugLog("[PolarManager] Streaming reconnect attempt \(streamingReconnectAttempts) - Error: \(error.localizedDescription)")
        debugLog("[PolarManager] Preserved \(streamedRRPoints.count) RR points before reconnection")

        isReconnectingStream = true

        // Dispose of the failed stream but preserve RR data
        streamingDisposable?.dispose()
        streamingDisposable = nil

        // First 10 attempts: 2s between retries. After that: 30s between attempts
        let backoffSeconds: Double = streamingReconnectAttempts <= 10 ? 2.0 : 30.0
        debugLog("[PolarManager] Waiting \(backoffSeconds)s before reconnect...")
        try? await Task.sleep(nanoseconds: UInt64(backoffSeconds * 1_000_000_000))

        // Check if we're still supposed to be streaming
        guard isStreaming else {
            debugLog("[PolarManager] Streaming was stopped during reconnect wait")
            isReconnectingStream = false
            return
        }

        // Disconnect and reconnect
        guard let api = api, let deviceId = connectedDeviceId else {
            debugLog("[PolarManager] Cannot reconnect - no API or device ID")
            lastError = error
            stopStreamingInternal()
            isReconnectingStream = false
            return
        }

        debugLog("[PolarManager] Disconnecting for streaming reconnect...")
        do {
            try api.disconnectFromDevice(deviceId)
        } catch {
            debugLog("[PolarManager] Disconnect error during reconnect: \(error)")
        }

        // Wait for disconnect
        try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second

        debugLog("[PolarManager] Reconnecting for streaming...")
        do {
            try api.connectToDevice(deviceId)
        } catch {
            debugLog("[PolarManager] Reconnect error: \(error)")
            lastError = error
            stopStreamingInternal()
            isReconnectingStream = false
            return
        }

        // Wait for connection and HR streaming feature ready
        let maxWaitSeconds = 15
        for i in 0..<maxWaitSeconds {
            if connectionState == .connected && isHrStreamingReady {
                debugLog("[PolarManager] Reconnected and HR streaming ready after \(i) seconds")
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
        }

        guard connectionState == .connected && isHrStreamingReady else {
            debugLog("[PolarManager] Failed to reconnect within timeout")
            // Try again recursively
            isReconnectingStream = false
            await attemptStreamingReconnect(afterError: error)
            return
        }

        // Resume streaming - note we preserve streamedRRPoints and streamingCumulativeMs
        debugLog("[PolarManager] Resuming HR streaming with \(streamedRRPoints.count) existing points")
        streamingDisposable = api.startHrStreaming(deviceId)
            .observe(on: MainScheduler.instance)
            .subscribe(
                onNext: { [weak self] hrData in
                    self?.handleStreamedHRData(hrData)
                },
                onError: { [weak self] nextError in
                    debugLog("[PolarManager] Streaming error after reconnect: \(nextError)")
                    Task { @MainActor in
                        await self?.attemptStreamingReconnect(afterError: nextError)
                    }
                },
                onCompleted: { [weak self] in
                    debugLog("[PolarManager] Streaming completed after reconnect")
                    DispatchQueue.main.async {
                        self?.stopStreamingInternal()
                    }
                }
            )

        debugLog("[PolarManager] ✅ Successfully resumed streaming after reconnect")
        debugLog("[PolarManager] Continuing with \(streamedRRPoints.count) RR points preserved")
        isReconnectingStream = false
        // Reset attempt counter on successful reconnect
        streamingReconnectAttempts = 0
        streamingReconnectCount += 1
        debugLog("[PolarManager] Total reconnections this session: \(streamingReconnectCount)")
    }

    private func handleStreamedHRData(_ hrData: PolarHrData) {
        // Capture wall-clock time when this batch of RR intervals was received
        // This enables gap detection: if wall-clock advances faster than cumulative RR,
        // we know data was dropped (BLE hiccups, app backgrounding issues, etc.)
        let wallClockNow: Int64
        if let startTime = streamingStartTime {
            wallClockNow = Int64(Date().timeIntervalSince(startTime) * 1000.0)
        } else {
            wallClockNow = 0
        }

        // Don't log every batch - too verbose
        // Only log every 60 seconds or on errors

        // PolarHrData is an array of samples
        // Each sample is a tuple: (hr, ppgQuality, correctedHr, rrsMs, rrAvailable, contactStatus, contactStatusSupported)
        var rrCountInBatch = 0
        for sample in hrData {
            // Only process if RR intervals are available in this sample
            guard sample.rrAvailable else {
                // Only log if RR is consistently unavailable (potential issue)
                continue
            }

            // Capture HR from the sensor (calculated by H10)
            let sensorHR = Int(sample.hr)

            // Extract RR intervals from the sample
            for rr in sample.rrsMs {
                let rrInterval = Int(rr)
                let point = RRPoint(
                    t_ms: streamingCumulativeMs,
                    rr_ms: rrInterval,
                    wallClockMs: wallClockNow,
                    hr: sensorHR  // Store HR from sensor
                )
                streamedRRPoints.append(point)
                streamingCumulativeMs += Int64(rrInterval)
                rrCountInBatch += 1
            }
        }

        // Heartbeat: only log every 30 min if nothing else was logged
        let now = Date()
        let timeSinceLastLog = now.timeIntervalSince(lastSignificantLogTime)
        if timeSinceLastLog >= 1800 {  // 30 minutes
            let avgHR = hrData.map { Int($0.hr) }.reduce(0, +) / max(1, hrData.count)
            debugLog("[PolarManager] ✓ Heartbeat: \(streamedRRPoints.count) beats collected, avg HR: \(avgHR) bpm")
            lastSignificantLogTime = now
        }
    }
    #endif

    // MARK: - Helpers

    private func generateExerciseId() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: Date())
    }

    #if canImport(PolarBleSdk)
    private func convertToRRPoints(_ exercise: PolarExerciseData) -> [RRPoint] {
        // DEBUG: Log what properties PolarExerciseData actually has
        debugLog("[PolarManager] ===== PolarExerciseData DEBUG =====")
        debugLog("[PolarManager] samples count: \(exercise.samples.count)")

        // Try accessing other possible properties using reflection
        let mirror = Mirror(reflecting: exercise)
        for child in mirror.children {
            debugLog("[PolarManager] Property: \(child.label ?? "unknown") = \(child.value)")
        }

        var points: [RRPoint] = []
        var cumulativeMs: Int64 = 0

        for sample in exercise.samples {
            let rrInterval = Int(sample)
            let point = RRPoint(t_ms: cumulativeMs, rr_ms: rrInterval)
            points.append(point)
            cumulativeMs += Int64(rrInterval)
        }

        return points
    }
    #endif
}

// MARK: - PolarBleApiObserver

#if canImport(PolarBleSdk)
extension PolarManager: PolarBleApiObserver {
    nonisolated func deviceConnecting(_ polarDeviceInfo: PolarDeviceInfo) {
        DispatchQueue.main.async {
            self.connectionState = .connecting
        }
    }

    nonisolated func deviceConnected(_ polarDeviceInfo: PolarDeviceInfo) {
        let deviceId = polarDeviceInfo.deviceId

        DispatchQueue.main.async {
            self.connectedDeviceId = deviceId
            self.connectionState = .connected
            self.lastConnectedDeviceId = deviceId
        }

        // Start live HR monitoring
        Task { @MainActor in
            self.startHRMonitoring(deviceId: deviceId)
        }

        // Check if there's an ongoing recording or stored exercise data on the device
        // Pass deviceId directly to avoid race condition with connectedDeviceId being set on main queue
        Task {
            _ = try? await self.checkRecordingStatus(deviceId: deviceId)
            await self.checkForStoredExercises(deviceId: deviceId)
        }
    }

    nonisolated func deviceDisconnected(_ polarDeviceInfo: PolarDeviceInfo, pairingError: Bool) {
        _ = polarDeviceInfo.deviceId  // deviceId unused but available if needed

        DispatchQueue.main.async {
            let wasStreaming = self.isStreaming

            // Log disconnection with context
            if wasStreaming {
                debugLog("[PolarManager] 🔌 Device disconnected during streaming")
                debugLog("[PolarManager] ⚠️ Common causes: other apps (SnoreLab, Polar Beat), iOS Bluetooth power management, or signal loss")
                debugLog("[PolarManager] Pairing error: \(pairingError)")
            } else {
                debugLog("[PolarManager] Device disconnected (not streaming)")
            }

            // Stop HR monitoring
            self.hrMonitorDisposable?.dispose()
            self.hrMonitorDisposable = nil

            // If we were actively streaming, DON'T stop - let reconnect logic handle it
            // The streaming error handler will trigger attemptStreamingReconnect
            if wasStreaming {
                debugLog("[PolarManager] Reconnect logic will attempt to restore streaming")
                debugLog("[PolarManager] Preserving device ID for reconnection: \(self.connectedDeviceId ?? "none")")
                // Don't call stopStreamingInternal() - that would prevent reconnection
            }

            self.connectionState = .disconnected
            // CRITICAL: Don't clear connectedDeviceId if streaming - reconnect logic needs it!
            if !wasStreaming {
                self.connectedDeviceId = nil
            }
            self.isH10RecordingFeatureReady = false
            self.isHrStreamingReady = false
            self.currentHeartRate = nil
            self.connectionHealthWarning = false
            // Don't reset isRecordingOnDevice - H10 continues recording internally

            // Don't set error if we were streaming - reconnect logic will handle it
            // Only set error if NOT streaming (e.g., user manually disconnected)
            if wasStreaming {
                debugLog("[PolarManager] Streaming was active, letting reconnect logic handle disconnect")
            }
        }
    }

    // MARK: - Live HR Monitoring

    /// Start HR monitoring for live display (separate from RR streaming)
    private func startHRMonitoring(deviceId: String) {
        guard let api = api else { return }

        hrMonitorDisposable?.dispose()

        hrMonitorDisposable = api.startHrStreaming(deviceId)
            .observe(on: MainScheduler.instance)
            .subscribe(
                onNext: { [weak self] hrData in
                    if let sample = hrData.first {
                        DispatchQueue.main.async {
                            self?.currentHeartRate = Int(sample.hr)
                        }
                    }
                },
                onError: { [weak self] error in
                    debugLog("[PolarManager] HR monitoring error: \(error)")
                    DispatchQueue.main.async {
                        self?.currentHeartRate = nil
                    }
                },
                onCompleted: { [weak self] in
                    debugLog("[PolarManager] HR monitoring completed")
                    DispatchQueue.main.async {
                        self?.currentHeartRate = nil
                    }
                }
            )

        debugLog("[PolarManager] Started live HR monitoring")
    }
}

// MARK: - PolarBleApiDeviceInfoObserver

extension PolarManager: PolarBleApiDeviceInfoObserver {
    nonisolated func batteryLevelReceived(_ identifier: String, batteryLevel: UInt) {
        DispatchQueue.main.async {
            self.batteryLevel = Int(batteryLevel)
        }
    }

    nonisolated func batteryChargingStatusReceived(_ identifier: String, chargingStatus: BleBasClient.ChargeState) {
        // Battery charging status received
    }

    nonisolated func disInformationReceived(_ identifier: String, uuid: CBUUID, value: String) {
        // Device information received
    }

    nonisolated func disInformationReceivedWithKeysAsStrings(_ identifier: String, key: String, value: String) {
        // Device information received with string keys
    }
}

// MARK: - PolarBleApiDeviceFeaturesObserver

extension PolarManager: PolarBleApiDeviceFeaturesObserver {
    nonisolated func bleSdkFeatureReady(_ identifier: String, feature: PolarBleSdkFeature) {
        // Only log important features to reduce noise
        if feature == .feature_hr {
            DispatchQueue.main.async {
                self.isHrStreamingReady = true
                debugLog("[PolarManager] HR streaming ready")
            }
        }
        if feature == .feature_polar_h10_exercise_recording {
            DispatchQueue.main.async {
                self.isH10RecordingFeatureReady = true
                self.isCheckingRecordingStatus = true  // Block start button while checking
                debugLog("[PolarManager] H10 recording ready, checking for existing data...")
            }

            // NOW check for ongoing recording or stored exercises - the feature is ready
            Task {
                _ = try? await self.checkRecordingStatus(deviceId: identifier)
                await self.checkForStoredExercises(deviceId: identifier)

                await MainActor.run {
                    self.isCheckingRecordingStatus = false
                }
            }
        }
    }
}

// MARK: - PolarBleApiPowerStateObserver

extension PolarManager: PolarBleApiPowerStateObserver {
    nonisolated func blePowerOn() {
        // Bluetooth powered on
    }

    nonisolated func blePowerOff() {
        DispatchQueue.main.async {
            self.connectionState = .disconnected
            self.connectedDeviceId = nil
        }
    }
}

// MARK: - PolarBleApiLogger

extension PolarManager: PolarBleApiLogger {
    nonisolated func message(_ str: String) {
        // Always log to RuntimeLogger if enabled (works in Release)
        if RuntimeLogger.shared.isEnabled {
            RuntimeLogger.shared.log("[PolarSDK] \(str)", file: "PolarSDK", line: 0)
        }
        #if DEBUG
        print("[PolarSDK] \(str)")
        #endif
    }
}

#endif
