//
//  Copyright © 2024-2026 Chris Sharp. All rights reserved.
//

import Foundation
import Combine

/// Recording state for the UI
enum RecordingUIState: Equatable {
    case idle
    case connecting
    case recording(progress: Double)
    case processing
    case completed(session: UUID)
    case error(message: String)

    var isActive: Bool {
        switch self {
        case .recording, .processing, .connecting:
            return true
        default:
            return false
        }
    }
}

/// ViewModel for RecordView - manages recording state and interactions
@MainActor
final class RecordingViewModel: ObservableObject {

    // MARK: - Published State

    @Published private(set) var state: RecordingUIState = .idle
    @Published private(set) var connectionState: DataSourceConnectionState = .disconnected
    @Published private(set) var collectedBeats: Int = 0
    @Published private(set) var elapsedSeconds: Int = 0
    @Published private(set) var currentSession: HRVSession?
    @Published var selectedSessionType: SessionType = .overnight
    @Published var selectedTags: Set<ReadingTag> = []
    @Published var sessionNotes: String = ""

    // MARK: - Services

    private let collector: RRCollector
    private var cancellables = Set<AnyCancellable>()
    private var elapsedTimer: Timer?

    // MARK: - Computed Properties

    var isConnected: Bool {
        collector.polarManager.connectionState == .connected
    }

    var isRecording: Bool {
        collector.isCollecting || collector.isStreamingMode
    }

    var canStartRecording: Bool {
        isConnected && !isRecording && !collector.needsAcceptance
    }

    var hasStoredData: Bool {
        collector.polarManager.hasStoredExercise
    }

    var deviceName: String? {
        collector.polarManager.connectedDeviceId
    }

    // MARK: - Initialization

    init(collector: RRCollector) {
        self.collector = collector
        setupBindings()
    }

    private func setupBindings() {
        // Observe collector state
        collector.$isCollecting
            .combineLatest(collector.$isStreamingMode)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (isCollecting, isStreaming) in
                guard let self = self else { return }
                if isCollecting || isStreaming {
                    self.state = .recording(progress: 0)
                    self.startElapsedTimer()
                } else if self.state.isActive {
                    self.state = .idle
                    self.stopElapsedTimer()
                }
            }
            .store(in: &cancellables)

        collector.$collectedPoints
            .receive(on: DispatchQueue.main)
            .sink { [weak self] points in
                self?.collectedBeats = points.count
            }
            .store(in: &cancellables)

        collector.$currentSession
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in
                self?.currentSession = session
            }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    func startRecording() async throws {
        state = .connecting
        try await collector.startSession(sessionType: selectedSessionType)
        state = .recording(progress: 0)
    }

    func stopRecording() async throws -> HRVSession? {
        state = .processing
        stopElapsedTimer()

        let session = try await collector.stopSession()
        if let session = session, session.state == .complete {
            state = .completed(session: session.id)
        } else {
            state = .error(message: "Recording failed")
        }
        return session
    }

    func startStreaming(durationSeconds: Int) throws {
        state = .connecting
        try collector.startStreamingSession(durationSeconds: durationSeconds)
        state = .recording(progress: 0)
    }

    func stopStreaming() async -> HRVSession? {
        state = .processing
        stopElapsedTimer()

        let session = await collector.stopStreamingSession()
        if let session = session, session.state == .complete {
            state = .completed(session: session.id)
        } else {
            state = .error(message: "Streaming failed")
        }
        return session
    }

    func acceptSession() async throws {
        try await collector.acceptSession()
    }

    func rejectSession() {
        Task {
            await collector.rejectSession()
        }
        state = .idle
    }

    func reset() {
        state = .idle
        elapsedSeconds = 0
        collectedBeats = 0
        selectedTags = []
        sessionNotes = ""
        stopElapsedTimer()
    }

    // MARK: - Timer

    private func startElapsedTimer() {
        elapsedSeconds = 0
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedSeconds += 1
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }
}
