//
//  Copyright © 2024-2026 Chris Sharp. All rights reserved.
//

import Foundation
import Combine

/// Connection state for data sources
enum DataSourceConnectionState: Equatable {
    case disconnected
    case searching
    case connecting
    case connected
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Protocol for RR data sources (Polar H10, imported files, etc.)
protocol RRDataSourceProtocol: AnyObject {

    /// Current connection state
    var connectionState: DataSourceConnectionState { get }

    /// Publisher for connection state changes
    var connectionStatePublisher: AnyPublisher<DataSourceConnectionState, Never> { get }

    /// Connected device identifier
    var connectedDeviceId: String? { get }

    /// Whether the device is currently recording
    var isRecording: Bool { get }

    /// Whether the device has stored exercise data
    var hasStoredExercise: Bool { get }

    /// Date of stored exercise if available
    var storedExerciseDate: Date? { get }

    /// Start searching for devices
    func startSearching()

    /// Stop searching for devices
    func stopSearching()

    /// Connect to a specific device
    func connect(deviceId: String) async throws

    /// Disconnect from current device
    func disconnect()

    /// Start recording on the device
    func startRecording() async throws

    /// Stop recording and fetch RR data
    func stopAndFetchRecording() async throws -> [RRPoint]

    /// Fetch stored exercise data without stopping recording
    func fetchStoredExercise() async throws -> [RRPoint]
}

/// Protocol for streaming RR data
protocol RRStreamingProtocol: RRDataSourceProtocol {

    /// Publisher for real-time RR data
    var rrDataPublisher: AnyPublisher<RRPoint, Never> { get }

    /// Start streaming RR data
    func startStreaming() async throws

    /// Stop streaming
    func stopStreaming()

    /// Collected streaming points
    var streamingPoints: [RRPoint] { get }
}
