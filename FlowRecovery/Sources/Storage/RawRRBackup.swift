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
import CryptoKit

/// Raw RR data backup - writes immediately to prevent any data loss
/// This is a safety net: raw RR intervals with timestamps are stored
/// independently of the session archive, so even if the app crashes
/// or the user rejects/cancels, the raw data is never lost.
final class RawRRBackup {

    // MARK: - Types

    /// Raw RR backup entry
    struct BackupEntry: Codable {
        let id: UUID
        let captureDate: Date
        let deviceId: String?
        let points: [RRPoint]
        let hash: String  // SHA256 of the RR data for integrity verification

        /// Duration in seconds
        var duration: TimeInterval {
            guard let first = points.first, let last = points.last else { return 0 }
            return Double(last.t_ms - first.t_ms) / 1000.0
        }

        /// Beat count
        var beatCount: Int { points.count }
    }

    // MARK: - Properties

    private let backupDirectory: URL
    private let indexFile: URL
    private var index: [BackupIndex] = []
    private let fileManager = FileManager.default

    /// Index entry (lightweight reference without full RR data)
    private struct BackupIndex: Codable {
        let id: UUID
        let captureDate: Date
        let fileName: String
        let beatCount: Int
        let hash: String
        /// Has this backup been successfully incorporated into an archived session?
        var archived: Bool
        /// When was the last backup performed (for time-based incremental backups)
        var lastBackupTime: Date?
    }

    /// App Group identifier for shared container (survives app reinstalls)
    private static let appGroupIdentifier = "group.com.chrissharp.flowrecovery"

    // MARK: - Initialization

    init() {
        // Try App Group container first (survives reinstalls), fall back to Documents
        if let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) {
            backupDirectory = containerURL.appendingPathComponent("RRBackup", isDirectory: true)
            debugLog("[RawRRBackup] Using App Group container: \(backupDirectory.path)")
        } else if let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            backupDirectory = documentsPath.appendingPathComponent("RRBackup", isDirectory: true)
            debugLog("[RawRRBackup] Using Documents directory (App Group not configured): \(backupDirectory.path)")
        } else {
            // Fallback to temporary directory (should never happen on iOS)
            backupDirectory = fileManager.temporaryDirectory.appendingPathComponent("RRBackup", isDirectory: true)
            debugLog("[RawRRBackup] WARNING: Using temporary directory as fallback")
        }
        indexFile = backupDirectory.appendingPathComponent("backup_index.json")

        createBackupDirectoryIfNeeded()
        loadIndex()

        let unarchivedCount = index.filter { !$0.archived }.count
        // Only log on startup if there are unarchived backups (potential data loss)
        if unarchivedCount > 0 {
            debugLog("[RawRRBackup] Found \(unarchivedCount) unarchived backups")
        }
    }

    // MARK: - Backup API

    /// Immediately backup raw RR data as soon as it's collected
    /// Call this BEFORE any analysis or user interaction
    /// - Parameters:
    ///   - points: The raw RR intervals with timestamps
    ///   - sessionId: Session ID for cross-reference
    ///   - deviceId: Optional device identifier
    @discardableResult
    func backup(points: [RRPoint], sessionId: UUID, deviceId: String? = nil) throws -> BackupEntry {
        guard !points.isEmpty else {
            throw BackupError.noDataToBackup
        }

        // Compute hash of the RR data for integrity
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let pointsData = try encoder.encode(points)
        let hash = SHA256.hash(data: pointsData)
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()

        // Create backup entry
        let entry = BackupEntry(
            id: sessionId,
            captureDate: Date(),
            deviceId: deviceId,
            points: points,
            hash: hashString
        )

        // Write to file
        let fileName = "\(sessionId.uuidString)_\(Int(Date().timeIntervalSince1970)).json"
        let filePath = backupDirectory.appendingPathComponent(fileName)

        let entryData = try encoder.encode(entry)
        try entryData.write(to: filePath)

        // Update index
        let indexEntry = BackupIndex(
            id: sessionId,
            captureDate: entry.captureDate,
            fileName: fileName,
            beatCount: points.count,
            hash: hashString,
            archived: false,
            lastBackupTime: Date()
        )

        // Remove any existing backup for same session ID
        index.removeAll { $0.id == sessionId }
        index.append(indexEntry)
        try saveIndex()

        // Only log initial backup, incremental backups are logged in incrementalBackup()
        if index.filter({ $0.id == sessionId }).count == 1 && points.count < 100 {
            debugLog("[RawRRBackup] Backed up \(points.count) beats for session \(sessionId.uuidString.prefix(8))")
        }
        return entry
    }

    /// Mark a backup as successfully archived (still kept for safety)
    func markAsArchived(_ sessionId: UUID) {
        guard let idx = index.firstIndex(where: { $0.id == sessionId }) else { return }
        index[idx].archived = true
        try? saveIndex()
        // No logging needed - archival is already logged in Archive.swift
    }

    /// Incremental backup during streaming - updates existing backup with new points
    /// This is called periodically during overnight streaming to prevent data loss if app crashes
    /// Uses TIME-BASED flushing (every 5 minutes) instead of count-based to handle streaming reconnections
    /// - Parameters:
    ///   - points: All RR points collected so far (not just new ones)
    ///   - sessionId: Session ID for cross-reference
    ///   - deviceId: Optional device identifier
    ///   - force: Force backup even if time threshold not met (for reconnection events)
    /// - Returns: True if backup was updated, false if skipped (too soon, not enough data)
    @discardableResult
    func incrementalBackup(points: [RRPoint], sessionId: UUID, deviceId: String? = nil, force: Bool = false) -> Bool {
        // Skip if not enough data
        guard points.count >= 60 else { return false }  // At least 1 minute of data

        // Check if we have an existing backup
        let existingEntry = index.first { $0.id == sessionId }

        // TIME-BASED backup: flush every 5 minutes regardless of beat count
        // This handles streaming reconnection where buffer resets but time keeps advancing
        let now = Date()
        let backupInterval: TimeInterval = 5 * 60  // 5 minutes

        let shouldBackup: Bool
        if force {
            // Force backup (reconnection event)
            shouldBackup = true
        } else if let lastBackup = existingEntry?.lastBackupTime {
            // Has enough time passed since last backup?
            shouldBackup = now.timeIntervalSince(lastBackup) >= backupInterval
        } else {
            // No previous backup - do initial backup if we have at least 60 beats
            shouldBackup = points.count >= 60
        }

        guard shouldBackup else {
            return false
        }

        do {
            try backup(points: points, sessionId: sessionId, deviceId: deviceId)
            // No logging during incremental backups - happens every 5 min and is too noisy
            // Errors are still logged below
            return true
        } catch {
            debugLog("[RawRRBackup] ❌ Incremental backup failed: \(error)")
            return false
        }
    }

    /// Get count of unarchived backups (potential data recovery candidates)
    var unarchivedBackupCount: Int {
        index.filter { !$0.archived }.count
    }

    /// Get IDs of unarchived backups for potential recovery
    var unarchivedSessionIds: [UUID] {
        index.filter { !$0.archived }.sorted { $0.captureDate > $1.captureDate }.map { $0.id }
    }

    /// Retrieve a backup entry by session ID
    func retrieve(_ sessionId: UUID) throws -> BackupEntry? {
        guard let indexEntry = index.first(where: { $0.id == sessionId }) else {
            return nil
        }

        let filePath = backupDirectory.appendingPathComponent(indexEntry.fileName)
        let data = try Data(contentsOf: filePath)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(BackupEntry.self, from: data)

        // Verify hash
        guard entry.hash == indexEntry.hash else {
            throw BackupError.hashMismatch
        }

        return entry
    }

    /// Retrieve all backups (for export/recovery)
    func allBackups() -> [BackupEntry] {
        index.compactMap { indexEntry in
            try? retrieve(indexEntry.id)
        }.sorted { $0.captureDate > $1.captureDate }
    }

    /// Get total backup size in bytes
    var totalBackupSize: Int64 {
        var size: Int64 = 0
        for indexEntry in index {
            let filePath = backupDirectory.appendingPathComponent(indexEntry.fileName)
            if let attrs = try? fileManager.attributesOfItem(atPath: filePath.path),
               let fileSize = attrs[.size] as? Int64 {
                size += fileSize
            }
        }
        return size
    }

    /// Purge old archived backups (keep last N days)
    /// - Parameter keepDays: Number of days to keep archived backups
    func purgeOldBackups(keepDays: Int = 90) throws {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -keepDays, to: Date())!

        var toRemove: [BackupIndex] = []
        for entry in index where entry.archived && entry.captureDate < cutoffDate {
            toRemove.append(entry)
        }

        for entry in toRemove {
            let filePath = backupDirectory.appendingPathComponent(entry.fileName)
            try? fileManager.removeItem(at: filePath)
            index.removeAll { $0.id == entry.id }
        }

        if !toRemove.isEmpty {
            try saveIndex()
            debugLog("[RawRRBackup] Purged \(toRemove.count) old archived backups")
        }
    }

    /// Export a backup to CSV format
    func exportToCSV(_ sessionId: UUID) throws -> String {
        guard let entry = try retrieve(sessionId) else {
            throw BackupError.notFound
        }

        var csv = "timestamp_ms,rr_ms,hr_bpm\n"
        for point in entry.points {
            let hr = 60000.0 / Double(point.rr_ms)
            csv += "\(point.t_ms),\(point.rr_ms),\(String(format: "%.1f", hr))\n"
        }
        return csv
    }

    // MARK: - Private

    private func createBackupDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: backupDirectory.path) {
            try? fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        }
    }

    private func loadIndex() {
        guard fileManager.fileExists(atPath: indexFile.path) else { return }

        do {
            let data = try Data(contentsOf: indexFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            index = try decoder.decode([BackupIndex].self, from: data)
        } catch {
            debugLog("[RawRRBackup] Failed to load index: \(error)")
            index = []
        }
    }

    private func saveIndex() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)
        try data.write(to: indexFile)
    }

    // MARK: - Errors

    enum BackupError: Error, LocalizedError {
        case noDataToBackup
        case hashMismatch
        case notFound

        var errorDescription: String? {
            switch self {
            case .noDataToBackup:
                return "No RR data to backup"
            case .hashMismatch:
                return "Backup data integrity check failed"
            case .notFound:
                return "Backup not found"
            }
        }
    }
}
