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
import SwiftUI

// MARK: - Reading Tags

/// Tag for categorizing HRV readings
struct ReadingTag: Codable, Hashable, Identifiable {
    let id: UUID
    let name: String
    let colorHex: String
    let isSystem: Bool

    init(id: UUID = UUID(), name: String, colorHex: String, isSystem: Bool = false) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.isSystem = isSystem
    }

    var color: Color {
        Color(hex: colorHex) ?? .gray
    }

    // Helper to safely create UUID from string (for system presets)
    private static func systemUUID(_ string: String) -> UUID {
        // System UUIDs are hardcoded and guaranteed to be valid
        // But we guard to satisfy Swift safety requirements
        guard let uuid = UUID(uuidString: string) else {
            // This should never happen with hardcoded valid UUIDs, but handle gracefully
            assertionFailure("Invalid system UUID string: \(string)")
            return UUID()
        }
        return uuid
    }

    // System preset tags
    static let morning = ReadingTag(
        id: systemUUID("00000000-0000-0000-0000-000000000001"),
        name: "Morning",
        colorHex: "#4A90D9",
        isSystem: true
    )
    static let postExercise = ReadingTag(
        id: systemUUID("00000000-0000-0000-0000-000000000002"),
        name: "Post-Exercise",
        colorHex: "#E85D4C",
        isSystem: true
    )
    static let recovery = ReadingTag(
        id: systemUUID( "00000000-0000-0000-0000-000000000003"),
        name: "Recovery",
        colorHex: "#50C878",
        isSystem: true
    )
    static let evening = ReadingTag(
        id: systemUUID( "00000000-0000-0000-0000-000000000004"),
        name: "Evening",
        colorHex: "#9B59B6",
        isSystem: true
    )
    static let preSleep = ReadingTag(
        id: systemUUID( "00000000-0000-0000-0000-000000000005"),
        name: "Pre-Sleep",
        colorHex: "#34495E",
        isSystem: true
    )
    static let stressed = ReadingTag(
        id: systemUUID( "00000000-0000-0000-0000-000000000006"),
        name: "Stressed",
        colorHex: "#E74C3C",
        isSystem: true
    )
    static let relaxed = ReadingTag(
        id: systemUUID( "00000000-0000-0000-0000-000000000007"),
        name: "Relaxed",
        colorHex: "#1ABC9C",
        isSystem: true
    )
    static let alcohol = ReadingTag(
        id: systemUUID( "00000000-0000-0000-0000-000000000008"),
        name: "Alcohol",
        colorHex: "#C0392B",
        isSystem: true
    )
    static let poorSleep = ReadingTag(
        id: systemUUID( "00000000-0000-0000-0000-000000000009"),
        name: "Poor Sleep",
        colorHex: "#7F8C8D",
        isSystem: true
    )
    static let travel = ReadingTag(
        id: systemUUID( "00000000-0000-0000-0000-00000000000A"),
        name: "Travel",
        colorHex: "#3498DB",
        isSystem: true
    )
    static let lateMeal = ReadingTag(
        id: systemUUID( "00000000-0000-0000-0000-00000000000B"),
        name: "Late Meal",
        colorHex: "#E67E22",
        isSystem: true
    )
    static let caffeine = ReadingTag(
        id: systemUUID( "00000000-0000-0000-0000-00000000000C"),
        name: "Caffeine",
        colorHex: "#784212",
        isSystem: true
    )
    static let illness = ReadingTag(
        id: systemUUID( "00000000-0000-0000-0000-00000000000D"),
        name: "Illness",
        colorHex: "#27AE60",
        isSystem: true
    )
    static let menstrual = ReadingTag(
        id: systemUUID( "00000000-0000-0000-0000-00000000000E"),
        name: "Menstrual",
        colorHex: "#E91E63",
        isSystem: true
    )

    static var systemTags: [ReadingTag] {
        [.morning, .postExercise, .recovery, .evening, .preSleep, .stressed, .relaxed,
         .alcohol, .poorSleep, .travel, .lateMeal, .caffeine, .illness, .menstrual]
    }
}

// MARK: - Color Extension for Hex

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0

        self.init(red: r, green: g, blue: b)
    }

    var hexString: String {
        let uiColor = UIColor(self)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0

        // getRed handles both RGB and grayscale color spaces correctly
        if uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) {
            return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        }

        // Fallback for colors that don't support getRed (rare)
        return "#000000"
    }
}

// MARK: - Comparable Extension

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        return min(max(self, limits.lowerBound), limits.upperBound)
    }
}

// MARK: - Device Provenance

/// Metadata about the source device for RR data
struct DeviceProvenance: Codable, Equatable {
    /// Device identifier (e.g., "Polar H10 A1B2C3D4")
    let deviceId: String
    /// Device model (e.g., "Polar H10")
    let deviceModel: String
    /// Firmware version if available (e.g., "5.0.0")
    let firmwareVersion: String?
    /// Recording mode used
    let recordingMode: RecordingMode
    /// App version that collected the data
    let appVersion: String
    /// iOS version at time of collection
    let osVersion: String
    /// Timestamp when provenance was captured
    let capturedAt: Date

    enum RecordingMode: String, Codable {
        case deviceInternal = "device_internal"  // H10 internal memory recording
        case streaming = "streaming"              // Real-time BLE streaming
        case imported = "imported"                // Imported from external source
    }

    /// Sampling assumptions for this device/mode
    var samplingNotes: String {
        switch deviceModel.lowercased() {
        case let model where model.contains("polar h10"):
            return "Polar H10: RR intervals at 1ms resolution, ECG-derived, no interpolation"
        case let model where model.contains("polar"):
            return "Polar device: RR intervals, optical or ECG-derived"
        default:
            return "Unknown device: RR interval accuracy may vary"
        }
    }

    /// Create provenance for current device
    static func current(deviceId: String, deviceModel: String = "Polar H10", firmwareVersion: String? = nil, recordingMode: RecordingMode) -> DeviceProvenance {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let osVersion = UIDevice.current.systemVersion
        return DeviceProvenance(
            deviceId: deviceId,
            deviceModel: deviceModel,
            firmwareVersion: firmwareVersion,
            recordingMode: recordingMode,
            appVersion: appVersion,
            osVersion: osVersion,
            capturedAt: Date()
        )
    }

    /// Create provenance for imported data
    static func imported(source: String) -> DeviceProvenance {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let osVersion = UIDevice.current.systemVersion
        return DeviceProvenance(
            deviceId: "imported",
            deviceModel: source,
            firmwareVersion: nil,
            recordingMode: .imported,
            appVersion: appVersion,
            osVersion: osVersion,
            capturedAt: Date()
        )
    }
}

// MARK: - Session Type

/// Type of HRV session - affects how it's stored and analyzed
enum SessionType: String, Codable, CaseIterable {
    case overnight = "overnight"  // Primary daily reading (used in trends)
    case nap = "nap"              // Nap recording (separate from daily readings)
    case quick = "quick"          // Quick spot-check readings (2-5 min)

    var displayName: String {
        switch self {
        case .overnight: return "Overnight"
        case .nap: return "Nap"
        case .quick: return "Quick Reading"
        }
    }

    var icon: String {
        switch self {
        case .overnight: return "moon.stars.fill"
        case .nap: return "powersleep"
        case .quick: return "bolt.fill"
        }
    }
}

// MARK: - HRV Session

/// Represents a complete HRV collection session
struct HRVSession: Codable, Identifiable {
    let id: UUID
    let startDate: Date
    var endDate: Date?
    var state: SessionState
    var sessionType: SessionType
    var rrSeries: RRSeries?
    var artifactFlags: [ArtifactFlags]?
    var analysisResult: HRVAnalysisResult?
    var recoveryScore: Double?
    var tags: [ReadingTag]
    var notes: String?
    var importedMetrics: ImportedMetrics?
    /// Device provenance - tracks source device, firmware, and collection method
    var deviceProvenance: DeviceProvenance?
    /// Sleep start time in milliseconds relative to recording start (from HealthKit)
    /// Used to filter pre-sleep data from overnight stats (nadir HR, peak HRV, etc.)
    var sleepStartMs: Int64?
    /// Sleep end time in milliseconds relative to recording start (from HealthKit)
    var sleepEndMs: Int64?

    enum SessionState: String, Codable {
        case collecting
        case analyzing
        case complete
        case failed
    }

    /// Metrics imported from external sources (e.g., Elite HRV summary)
    struct ImportedMetrics: Codable {
        let rmssd: Double
        let rmssdRaw: Double
        let artifactPercent: Double
        let source: String
    }

    init(startDate: Date = Date(), tags: [ReadingTag] = [], sessionType: SessionType = .overnight, deviceProvenance: DeviceProvenance? = nil) {
        self.id = UUID()
        self.startDate = startDate
        self.state = .collecting
        self.sessionType = sessionType
        self.tags = tags
        self.deviceProvenance = deviceProvenance
    }

    init(
        id: UUID,
        startDate: Date,
        endDate: Date?,
        state: SessionState,
        sessionType: SessionType = .overnight,
        rrSeries: RRSeries?,
        analysisResult: HRVAnalysisResult?,
        artifactFlags: [ArtifactFlags]?,
        recoveryScore: Double? = nil,
        tags: [ReadingTag] = [],
        notes: String? = nil,
        importedMetrics: ImportedMetrics? = nil,
        deviceProvenance: DeviceProvenance? = nil,
        sleepStartMs: Int64? = nil,
        sleepEndMs: Int64? = nil
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.state = state
        self.sessionType = sessionType
        self.rrSeries = rrSeries
        self.analysisResult = analysisResult
        self.artifactFlags = artifactFlags
        self.recoveryScore = recoveryScore
        self.tags = tags
        self.notes = notes
        self.importedMetrics = importedMetrics
        self.deviceProvenance = deviceProvenance
        self.sleepStartMs = sleepStartMs
        self.sleepEndMs = sleepEndMs
    }

    // Custom decoder to handle missing fields in old data
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startDate = try container.decode(Date.self, forKey: .startDate)
        endDate = try container.decodeIfPresent(Date.self, forKey: .endDate)
        state = try container.decode(SessionState.self, forKey: .state)
        // Default to overnight for existing data that doesn't have sessionType
        sessionType = try container.decodeIfPresent(SessionType.self, forKey: .sessionType) ?? .overnight
        rrSeries = try container.decodeIfPresent(RRSeries.self, forKey: .rrSeries)
        artifactFlags = try container.decodeIfPresent([ArtifactFlags].self, forKey: .artifactFlags)
        analysisResult = try container.decodeIfPresent(HRVAnalysisResult.self, forKey: .analysisResult)
        recoveryScore = try container.decodeIfPresent(Double.self, forKey: .recoveryScore)
        tags = try container.decodeIfPresent([ReadingTag].self, forKey: .tags) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        importedMetrics = try container.decodeIfPresent(ImportedMetrics.self, forKey: .importedMetrics)
        // Device provenance - nil for legacy data (backwards compatible)
        deviceProvenance = try container.decodeIfPresent(DeviceProvenance.self, forKey: .deviceProvenance)
        // Sleep boundaries - nil for legacy data (backwards compatible)
        sleepStartMs = try container.decodeIfPresent(Int64.self, forKey: .sleepStartMs)
        sleepEndMs = try container.decodeIfPresent(Int64.self, forKey: .sleepEndMs)
    }

    private enum CodingKeys: String, CodingKey {
        case id, startDate, endDate, state, sessionType, rrSeries, artifactFlags
        case analysisResult, recoveryScore, tags, notes, importedMetrics, deviceProvenance
        case sleepStartMs, sleepEndMs
    }

    /// Duration of the session
    var duration: TimeInterval? {
        guard let endDate = endDate else { return nil }
        return endDate.timeIntervalSince(startDate)
    }

    /// Check if session has valid data for analysis
    var isValidForAnalysis: Bool {
        guard let series = rrSeries else { return false }
        return series.points.count >= 120
    }
}

/// Offline session for sync
struct OfflineSession: Codable, Identifiable {
    let id: UUID
    let session: HRVSession
    let createdAt: Date
    var syncedAt: Date?
    var syncAttempts: Int
    var lastError: String?

    init(session: HRVSession) {
        self.id = session.id
        self.session = session
        self.createdAt = Date()
        self.syncAttempts = 0
    }

    var needsSync: Bool {
        syncedAt == nil && syncAttempts < 3
    }
}

/// Session archive entry with quick-access metadata
struct SessionArchiveEntry: Codable {
    let sessionId: UUID
    let date: Date
    let fileHash: String
    let filePath: String
    let recoveryScore: Double?
    let meanRMSSD: Double?
    let tags: [ReadingTag]
    let notes: String?
    let sessionType: SessionType

    init(
        sessionId: UUID,
        date: Date,
        fileHash: String,
        filePath: String,
        recoveryScore: Double? = nil,
        meanRMSSD: Double? = nil,
        tags: [ReadingTag] = [],
        notes: String? = nil,
        sessionType: SessionType = .overnight
    ) {
        self.sessionId = sessionId
        self.date = date
        self.fileHash = fileHash
        self.filePath = filePath
        self.recoveryScore = recoveryScore
        self.meanRMSSD = meanRMSSD
        self.tags = tags
        self.notes = notes
        self.sessionType = sessionType
    }

    // Custom decoder to handle missing sessionType in old data
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(UUID.self, forKey: .sessionId)
        date = try container.decode(Date.self, forKey: .date)
        fileHash = try container.decode(String.self, forKey: .fileHash)
        filePath = try container.decode(String.self, forKey: .filePath)
        recoveryScore = try container.decodeIfPresent(Double.self, forKey: .recoveryScore)
        meanRMSSD = try container.decodeIfPresent(Double.self, forKey: .meanRMSSD)
        tags = try container.decodeIfPresent([ReadingTag].self, forKey: .tags) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        // Default to overnight for existing data that doesn't have sessionType
        sessionType = try container.decodeIfPresent(SessionType.self, forKey: .sessionType) ?? .overnight
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, date, fileHash, filePath, recoveryScore, meanRMSSD, tags, notes, sessionType
    }
}
