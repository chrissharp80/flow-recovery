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

// MARK: - Domain Error Types

/// Errors that can occur during HRV analysis
enum AnalysisError: Error, LocalizedError {
    case insufficientData(pointCount: Int, required: Int)
    case excessiveArtifacts(rate: Double, maxAllowed: Double)
    case noValidWindow
    case windowSelectionFailed(reason: String)
    case analysisTimeout

    var errorDescription: String? {
        switch self {
        case .insufficientData(let count, let required):
            return "Insufficient data: \(count) points (need \(required))"
        case .excessiveArtifacts(let rate, let max):
            return "Too many artifacts: \(String(format: "%.1f%%", rate * 100)) (max \(String(format: "%.0f%%", max * 100)))"
        case .noValidWindow:
            return "No valid analysis window found"
        case .windowSelectionFailed(let reason):
            return "Window selection failed: \(reason)"
        case .analysisTimeout:
            return "Analysis timed out"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .insufficientData:
            return "Try recording for a longer duration"
        case .excessiveArtifacts:
            return "Ensure the chest strap is properly moistened and positioned"
        case .noValidWindow:
            return "Try recording during a period of rest"
        case .windowSelectionFailed:
            return "Check data quality and try again"
        case .analysisTimeout:
            return "Reduce the recording duration or try again"
        }
    }
}

/// Errors that can occur during recording
enum RecordingError: Error, LocalizedError {
    case deviceNotConnected
    case recordingAlreadyActive
    case internalRecordingFailed(underlying: Error?)
    case dataFetchFailed(reason: String)
    case sessionCreationFailed
    case bluetoothUnavailable

    var errorDescription: String? {
        switch self {
        case .deviceNotConnected:
            return "Polar H10 not connected"
        case .recordingAlreadyActive:
            return "A recording is already in progress"
        case .internalRecordingFailed(let error):
            if let e = error {
                return "Internal recording failed: \(e.localizedDescription)"
            }
            return "Internal recording failed"
        case .dataFetchFailed(let reason):
            return "Failed to fetch data: \(reason)"
        case .sessionCreationFailed:
            return "Failed to create session"
        case .bluetoothUnavailable:
            return "Bluetooth is not available"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .deviceNotConnected:
            return "Put on your Polar H10 and moisten the electrodes"
        case .recordingAlreadyActive:
            return "Stop the current recording first"
        case .internalRecordingFailed:
            return "Try reconnecting the device and starting again"
        case .dataFetchFailed:
            return "Check device connection and try again"
        case .sessionCreationFailed:
            return "Restart the app and try again"
        case .bluetoothUnavailable:
            return "Enable Bluetooth in Settings"
        }
    }
}

/// Errors that can occur during data import
enum ImportError: Error, LocalizedError {
    case invalidFormat
    case noRRData
    case invalidRRValues(reason: String)
    case fileTooLarge
    case unsupportedFileType(String)
    case decodingFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Invalid file format"
        case .noRRData:
            return "No RR interval data found"
        case .invalidRRValues(let reason):
            return "Invalid RR values: \(reason)"
        case .fileTooLarge:
            return "File is too large to import"
        case .unsupportedFileType(let type):
            return "Unsupported file type: \(type)"
        case .decodingFailed(let error):
            return "Failed to decode file: \(error.localizedDescription)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .invalidFormat:
            return "Ensure the file is in a supported format (CSV, JSON, or Kubios)"
        case .noRRData:
            return "Check that the file contains RR interval data"
        case .invalidRRValues:
            return "Verify the data is valid heart rate variability data"
        case .fileTooLarge:
            return "Try splitting the data into smaller files"
        case .unsupportedFileType:
            return "Convert to CSV or JSON format"
        case .decodingFailed:
            return "Check the file for corruption or invalid data"
        }
    }
}

/// Errors that can occur with HealthKit
enum HealthKitError: Error, LocalizedError {
    case notAvailable
    case authorizationDenied
    case noData
    case queryFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "HealthKit is not available on this device"
        case .authorizationDenied:
            return "HealthKit access was denied"
        case .noData:
            return "No health data available"
        case .queryFailed(let error):
            return "Health data query failed: \(error.localizedDescription)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notAvailable:
            return "This feature requires Apple Health"
        case .authorizationDenied:
            return "Enable Flow Recovery access in Settings > Privacy > Health"
        case .noData:
            return "Record some sessions to see health data"
        case .queryFailed:
            return "Try again later"
        }
    }
}

// MARK: - Error Formatting Helpers

extension Error {
    /// User-friendly description for display
    var displayDescription: String {
        if let localizedError = self as? LocalizedError {
            return localizedError.errorDescription ?? localizedDescription
        }
        return localizedDescription
    }

    /// Recovery suggestion for display
    var displayRecoverySuggestion: String? {
        if let localizedError = self as? LocalizedError {
            return localizedError.recoverySuggestion
        }
        return nil
    }
}
