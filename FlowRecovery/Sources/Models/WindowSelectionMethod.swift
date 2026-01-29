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

/// Methods for selecting the 5-minute analysis window
enum WindowSelectionMethod: String, Codable, CaseIterable {
    case consolidatedRecovery
    case peakRMSSD
    case peakSDNN
    case peakTotalPower
    case custom

    var displayName: String {
        switch self {
        case .consolidatedRecovery:
            return "Consolidated Recovery"
        case .peakRMSSD:
            return "Peak RMSSD"
        case .peakSDNN:
            return "Peak SDNN"
        case .peakTotalPower:
            return "Peak Total Power"
        case .custom:
            return "Custom Window"
        }
    }

    var tooltip: String {
        switch self {
        case .consolidatedRecovery:
            return "Scans the 30-70% sleep band for the best 5-minute window with highest RMSSD, stable HR, and organized parasympathetic control (DFA α1 ~0.75-1.0). Weighted scoring prevents isolated spikes."
        case .peakRMSSD:
            return "Finds the 5-minute window with the highest RMSSD value in the 30-70% sleep band. Pure parasympathetic activation - no weighting for stability or organization."
        case .peakSDNN:
            return "Finds the 5-minute window with the highest SDNN value in the 30-70% sleep band. Measures total HRV - both parasympathetic and sympathetic contributions."
        case .peakTotalPower:
            return "Finds the 5-minute window with the highest spectral power (VLF+LF+HF) in the 30-70% sleep band. Represents overall autonomic nervous system activity."
        case .custom:
            return "Manually position the 5-minute analysis window anywhere in your recording. Use this to explore specific time periods or investigate anomalies."
        }
    }

    var icon: String? {
        switch self {
        case .custom:
            return "pencil"
        default:
            return nil
        }
    }

    /// Factory default method
    static var defaultMethod: WindowSelectionMethod {
        .consolidatedRecovery
    }
}
