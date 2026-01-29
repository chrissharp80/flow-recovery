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

/// Session archive manager for persistent storage
final class SessionArchive {

    // MARK: - Properties

    private let archiveDirectory: URL
    private let indexFile: URL
    private let deletedIndexFile: URL
    private var index: [SessionArchiveEntry] = []
    private var deletedSessionIds: Set<UUID> = []
    private let fileManager = FileManager.default
    private let archiveLock = NSLock()

    // MARK: - Initialization

    /// App Group identifier for shared container (survives app reinstalls)
    /// To use: Add this App Group in Xcode -> Signing & Capabilities
    private static let appGroupIdentifier = "group.com.chrissharp.flowrecovery"

    init() {
        // Try App Group container first (survives reinstalls), fall back to Documents
        if let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) {
            archiveDirectory = containerURL.appendingPathComponent("HRVArchive", isDirectory: true)
            debugLog("[Archive] Using App Group container: \(archiveDirectory.path)")
        } else if let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            archiveDirectory = documentsPath.appendingPathComponent("HRVArchive", isDirectory: true)
            debugLog("[Archive] Using Documents directory (App Group not configured): \(archiveDirectory.path)")
        } else {
            // Fallback to temporary directory (should never happen on iOS)
            archiveDirectory = fileManager.temporaryDirectory.appendingPathComponent("HRVArchive", isDirectory: true)
            debugLog("[Archive] WARNING: Using temporary directory as fallback")
        }
        indexFile = archiveDirectory.appendingPathComponent("index.json")
        deletedIndexFile = archiveDirectory.appendingPathComponent("deleted.json")

        createArchiveDirectoryIfNeeded()
        loadIndex()
        loadDeletedIndex()

        // Only log if count is unusual (helps debug archive corruption)
        if index.count == 0 || index.count > 1000 {
            debugLog("[Archive] Loaded \(index.count) sessions from archive")
        }
    }

    // MARK: - Manual Repair

    /// Repair corrupted archive by removing .encrypted files and rebuilding index from .json files
    /// Call this manually from Settings > Debug when needed
    /// - Returns: Number of sessions recovered
    @discardableResult
    func repairArchive() -> Int {
        archiveLock.lock()
        defer { archiveLock.unlock() }

        guard let files = try? fileManager.contentsOfDirectory(at: archiveDirectory, includingPropertiesForKeys: nil) else {
            debugLog("[Archive] Repair: Could not list directory")
            return 0
        }

        // Delete all .encrypted files
        let encryptedFiles = files.filter { $0.pathExtension == "encrypted" }
        for file in encryptedFiles {
            try? fileManager.removeItem(at: file)
            debugLog("[Archive] Repair: Removed encrypted file: \(file.lastPathComponent)")
        }

        // Find all valid .json session files
        let jsonFiles = files.filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" && $0.lastPathComponent != "deleted.json" }

        // Rebuild index from .json files
        var rebuiltIndex: [SessionArchiveEntry] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        for fileURL in jsonFiles {
            let filename = fileURL.deletingPathExtension().lastPathComponent
            guard let sessionId = UUID(uuidString: filename) else { continue }

            // Skip deleted sessions
            if deletedSessionIds.contains(sessionId) {
                debugLog("[Archive] Repair: Skipping deleted session: \(filename)")
                continue
            }

            do {
                let fileData = try Data(contentsOf: fileURL)
                var jsonData = fileData
                var wasDecrypted = false

                // Try decoding as JSON first
                var session: HRVSession
                do {
                    session = try decoder.decode(HRVSession.self, from: jsonData)
                } catch {
                    // JSON decode failed - try decrypting (file may contain encrypted data)
                    debugLog("[Archive] Repair: JSON decode failed for \(filename), trying decryption...")
                    do {
                        let decrypted = try EncryptionManager.shared.decrypt(fileData)
                        session = try decoder.decode(HRVSession.self, from: decrypted)
                        jsonData = decrypted
                        wasDecrypted = true
                        debugLog("[Archive] Repair: Successfully decrypted \(filename)")
                    } catch {
                        debugLog("[Archive] Repair: Could not decrypt \(filename): \(error)")
                        continue
                    }
                }

                // If we decrypted, save back as plain JSON
                if wasDecrypted {
                    let plainJsonData = try encoder.encode(session)
                    try plainJsonData.write(to: fileURL)
                    jsonData = plainJsonData
                    debugLog("[Archive] Repair: Saved \(filename) as plain JSON")
                }

                // Calculate correct hash
                let hash = SHA256.hash(data: jsonData)
                let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()

                let entry = SessionArchiveEntry(
                    sessionId: sessionId,
                    date: session.startDate,
                    fileHash: hashString,
                    filePath: fileURL.path,
                    recoveryScore: session.recoveryScore,
                    meanRMSSD: session.analysisResult?.timeDomain.rmssd,
                    tags: session.tags,
                    notes: session.notes,
                    sessionType: session.sessionType
                )
                rebuiltIndex.append(entry)
                debugLog("[Archive] Repair: Rebuilt entry for \(filename), date: \(session.startDate)")
            } catch {
                debugLog("[Archive] Repair: Could not read \(filename): \(error)")
            }
        }

        index = rebuiltIndex.sorted { $0.date > $1.date }
        try? saveIndex()
        debugLog("[Archive] Repair complete: \(index.count) sessions recovered")
        return index.count
    }

    // MARK: - Public API

    /// Archive a completed session
    /// - Parameter session: The session to archive
    /// - Returns: Archive entry with file hash
    @discardableResult
    func archive(_ session: HRVSession) throws -> SessionArchiveEntry {
        archiveLock.lock()
        defer { archiveLock.unlock() }

        let fileName = "\(session.id.uuidString).json"
        let filePath = archiveDirectory.appendingPathComponent(fileName)

        // Encode session
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(session)

        // Write to file
        try data.write(to: filePath)

        // Compute hash of actual file bytes
        let fileData = try Data(contentsOf: filePath)
        let hash = SHA256.hash(data: fileData)
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()

        // Create archive entry
        let entry = SessionArchiveEntry(
            sessionId: session.id,
            date: session.startDate,
            fileHash: hashString,
            filePath: filePath.path,
            recoveryScore: session.recoveryScore,
            meanRMSSD: session.analysisResult?.timeDomain.rmssd,
            tags: session.tags,
            notes: session.notes,
            sessionType: session.sessionType
        )

        // Update index
        let removedCount = index.filter { $0.sessionId == session.id }.count
        if removedCount > 0 {
            debugLog("[Archive] Replacing existing entry for session \(session.id.uuidString.prefix(8))")
        } else {
            debugLog("[Archive] Adding new entry for session \(session.id.uuidString.prefix(8)), date: \(session.startDate)")
        }
        index.removeAll { $0.sessionId == session.id }
        index.append(entry)
        try saveIndex()
        debugLog("[Archive] Total sessions in archive: \(index.count)")

        return entry
    }

    /// Retrieve an archived session
    /// - Parameter id: Session ID
    /// - Returns: The session, or nil if not found
    func retrieve(_ id: UUID) throws -> HRVSession? {
        archiveLock.lock()
        defer { archiveLock.unlock() }

        guard let entry = index.first(where: { $0.sessionId == id }) else {
            debugLog("[Archive] Session \(id) not in index")
            return nil
        }

        let fileURL = URL(fileURLWithPath: entry.filePath)

        // Check if file exists
        guard fileManager.fileExists(atPath: entry.filePath) else {
            debugLog("[Archive] ERROR: File not found at \(entry.filePath)")
            debugLog("[Archive] Session date: \(entry.date)")
            throw ArchiveError.fileNotFound
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            debugLog("[Archive] ERROR: Could not read file at \(entry.filePath): \(error)")
            throw error
        }

        // Verify hash
        let hash = SHA256.hash(data: data)
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()

        guard hashString == entry.fileHash else {
            debugLog("[Archive] ERROR: Hash mismatch for session \(id)")
            debugLog("[Archive] Expected: \(entry.fileHash)")
            debugLog("[Archive] Actual:   \(hashString)")
            debugLog("[Archive] File size: \(data.count) bytes")
            throw ArchiveError.hashMismatch
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            return try decoder.decode(HRVSession.self, from: data)
        } catch {
            debugLog("[Archive] ERROR: Could not decode session \(id): \(error)")
            throw error
        }
    }

    /// Get all archive entries
    var entries: [SessionArchiveEntry] {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        return index.sorted { $0.date > $1.date }
    }

    /// Get entries filtered by tags
    /// - Parameters:
    ///   - includeTags: Only include entries with at least one of these tags (empty = include all)
    ///   - excludeTags: Exclude entries with any of these tags
    func entries(includingTags includeTags: [ReadingTag], excludingTags excludeTags: [ReadingTag] = []) -> [SessionArchiveEntry] {
        let includeIds = Set(includeTags.map { $0.id })
        let excludeIds = Set(excludeTags.map { $0.id })

        return entries.filter { entry in
            // Check exclusion first
            let entryTagIds = Set(entry.tags.map { $0.id })
            if !excludeIds.isEmpty && !excludeIds.isDisjoint(with: entryTagIds) {
                return false
            }

            // Check inclusion
            if includeIds.isEmpty {
                return true
            }
            return !includeIds.isDisjoint(with: entryTagIds)
        }
    }

    /// Get entries for a specific date range
    func entries(from startDate: Date, to endDate: Date) -> [SessionArchiveEntry] {
        entries.filter { $0.date >= startDate && $0.date <= endDate }
    }

    /// Check if a session exists in archive
    func exists(_ id: UUID) -> Bool {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        return index.contains { $0.sessionId == id }
    }

    /// Check if a session exists near a given date (within tolerance window)
    /// Used to determine if H10 data has already been archived
    func hasSessionNear(date: Date, toleranceMinutes: Int = 30) -> Bool {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        let tolerance = TimeInterval(toleranceMinutes * 60)
        let windowStart = date.addingTimeInterval(-tolerance)
        let windowEnd = date.addingTimeInterval(tolerance)
        return index.contains { $0.date >= windowStart && $0.date <= windowEnd }
    }

    /// Update tags for an existing session
    func updateTags(_ id: UUID, tags: [ReadingTag], notes: String? = nil) throws {
        archiveLock.lock()
        let sessionExists = index.contains(where: { $0.sessionId == id })
        archiveLock.unlock()

        guard sessionExists else {
            throw ArchiveError.fileNotFound
        }

        // Load and update the session
        guard var session = try retrieve(id) else {
            throw ArchiveError.fileNotFound
        }
        session.tags = tags
        session.notes = notes ?? session.notes

        // Re-archive with updated data
        try archive(session)
    }

    /// Delete an archived session (moves to trash, tracks as intentionally deleted)
    func delete(_ id: UUID) throws {
        archiveLock.lock()
        defer { archiveLock.unlock() }

        guard let entry = index.first(where: { $0.sessionId == id }) else {
            return
        }

        // Track as intentionally deleted (prevents recovery from showing this)
        deletedSessionIds.insert(id)
        try saveDeletedIndex()

        // Remove from active index
        index.removeAll { $0.sessionId == id }
        try saveIndex()

        // Delete the file (backup system will still have it if needed)
        let fileURL = URL(fileURLWithPath: entry.filePath)
        try? fileManager.removeItem(at: fileURL)
    }

    /// Check if a session was intentionally deleted by the user
    func wasIntentionallyDeleted(_ id: UUID) -> Bool {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        return deletedSessionIds.contains(id)
    }

    /// Get all intentionally deleted session IDs
    var deletedIds: Set<UUID> {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        return deletedSessionIds
    }

    /// Remove a session from the deleted list (for trash restore)
    func unmarkAsDeleted(_ id: UUID) throws {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        deletedSessionIds.remove(id)
        try saveDeletedIndex()
    }

    /// Permanently forget a deleted session (removes from deleted tracking)
    func forgetDeletedSession(_ id: UUID) throws {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        deletedSessionIds.remove(id)
        try saveDeletedIndex()
    }

    /// Mark a session as intentionally deleted (for lost sessions that user wants to dismiss)
    /// This adds the ID to the deleted tracking without requiring the session to be in the archive
    func markAsDeleted(_ id: UUID) throws {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        deletedSessionIds.insert(id)
        try saveDeletedIndex()
    }

    /// Clear all deleted session tracking
    func clearDeletedHistory() throws {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        deletedSessionIds.removeAll()
        try saveDeletedIndex()
    }

    /// Verify archive integrity
    func verifyIntegrity() -> [UUID: Bool] {
        archiveLock.lock()
        let entriesToVerify = index
        archiveLock.unlock()

        var results: [UUID: Bool] = [:]

        for entry in entriesToVerify {
            do {
                let fileURL = URL(fileURLWithPath: entry.filePath)
                let data = try Data(contentsOf: fileURL)
                let hash = SHA256.hash(data: data)
                let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
                results[entry.sessionId] = (hashString == entry.fileHash)
            } catch {
                results[entry.sessionId] = false
            }
        }

        return results
    }

    /// Check if a session with a similar start time already exists
    /// Uses a 1-hour window to detect duplicates during import
    /// This allows multiple sessions per day while preventing true duplicates
    func sessionExists(for date: Date) -> Bool {
        archiveLock.lock()
        defer { archiveLock.unlock() }
        let oneHour: TimeInterval = 3600
        return index.contains { entry in
            abs(entry.date.timeIntervalSince(date)) < oneHour
        }
    }

    /// Batch archive multiple sessions efficiently
    /// Writes all sessions first, then updates the index once
    /// - Parameter sessions: Array of sessions to archive
    /// - Returns: (new: Int, updated: Int) - count of new sessions and updated sessions
    @discardableResult
    func archiveBatch(_ sessions: [HRVSession]) throws -> Int {
        archiveLock.lock()
        defer { archiveLock.unlock() }

        var newEntries: [SessionArchiveEntry] = []
        var updatedCount = 0
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        // Time proximity threshold for considering sessions as duplicates (1 hour)
        // This allows multiple legitimate sessions on the same day while preventing true duplicates
        let duplicateThresholdSeconds: TimeInterval = 3600

        debugLog("[Archive] archiveBatch: Processing \(sessions.count) sessions, index has \(index.count) entries")

        for session in sessions {
            let dateStr = ISO8601DateFormatter().string(from: session.startDate)
            debugLog("[Archive] Session: \(dateStr) ID:\(session.id.uuidString.prefix(8))")

            // Check if this exact session ID already exists
            if index.contains(where: { $0.sessionId == session.id }) {
                debugLog("[Archive]   SKIP: Exact ID match")
                continue  // Skip exact duplicates by ID
            }

            // Check if a session with similar time exists (within threshold)
            // Use time proximity instead of calendar day to allow multiple same-day sessions
            if let existingEntry = index.first(where: { abs($0.date.timeIntervalSince(session.startDate)) < duplicateThresholdSeconds }) {
                let timeDiff = abs(existingEntry.date.timeIntervalSince(session.startDate))
                debugLog("[Archive]   DUPLICATE: \(Int(timeDiff))s from existing \(ISO8601DateFormatter().string(from: existingEntry.date))")
                // Merge/update: load existing session and update with new info
                do {
                    if var existingSession = try retrieve(existingEntry.sessionId) {
                        // Update with any new/better data from import
                        let wasUpdated = mergeSessionData(from: session, into: &existingSession)
                        if wasUpdated {
                            try archive(existingSession)
                            updatedCount += 1
                            debugLog("[Archive]   -> Updated existing session")
                        }
                    }
                } catch {
                    debugLog("[Archive] Failed to update existing session: \(error)")
                }
                continue
            }

            // Also check against sessions we're adding in this batch
            if newEntries.contains(where: { abs($0.date.timeIntervalSince(session.startDate)) < duplicateThresholdSeconds }) {
                debugLog("[Archive]   SKIP: Similar to another session in this batch")
                continue  // Skip - similar session already added in this batch
            }

            debugLog("[Archive]   -> NEW: Will save to archive")

            // New session - write it
            let fileName = "\(session.id.uuidString).json"
            let filePath = archiveDirectory.appendingPathComponent(fileName)

            // Encode and write
            let data = try encoder.encode(session)
            try data.write(to: filePath)

            // Compute hash
            let fileData = try Data(contentsOf: filePath)
            let hash = SHA256.hash(data: fileData)
            let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()

            let entry = SessionArchiveEntry(
                sessionId: session.id,
                date: session.startDate,
                fileHash: hashString,
                filePath: filePath.path,
                recoveryScore: session.recoveryScore,
                meanRMSSD: session.analysisResult?.timeDomain.rmssd,
                tags: session.tags,
                notes: session.notes,
                sessionType: session.sessionType
            )
            newEntries.append(entry)
        }

        // Batch update index
        if !newEntries.isEmpty {
            debugLog("[Archive] Adding \(newEntries.count) new entries to index")
            index.append(contentsOf: newEntries)
            debugLog("[Archive] Index now has \(index.count) entries, saving...")
            try saveIndex()
            debugLog("[Archive] Index saved successfully")
        } else {
            debugLog("[Archive] No new entries to add to index")
        }

        debugLog("[Archive] === BATCH RESULT ===")
        debugLog("[Archive] New sessions written: \(newEntries.count)")
        debugLog("[Archive] Existing sessions updated: \(updatedCount)")
        debugLog("[Archive] Total index entries: \(index.count)")
        return newEntries.count + updatedCount
    }

    /// Merge data from an imported session into an existing session
    /// Returns true if any changes were made
    private func mergeSessionData(from imported: HRVSession, into existing: inout HRVSession) -> Bool {
        var changed = false

        // If existing has no analysis result but imported does, use imported
        if existing.analysisResult == nil && imported.analysisResult != nil {
            existing.analysisResult = imported.analysisResult
            changed = true
        }

        // If existing has no RR series but imported does (unlikely but possible)
        if existing.rrSeries == nil && imported.rrSeries != nil {
            existing.rrSeries = imported.rrSeries
            changed = true
        }

        // Merge tags (add any new tags from import)
        let existingTagIds = Set(existing.tags.map { $0.id })
        for tag in imported.tags {
            if !existingTagIds.contains(tag.id) {
                existing.tags.append(tag)
                changed = true
            }
        }

        // Update notes if existing is empty and imported has notes
        if (existing.notes == nil || existing.notes?.isEmpty == true) && imported.notes != nil && !imported.notes!.isEmpty {
            existing.notes = imported.notes
            changed = true
        }

        // Update recovery score if missing
        if existing.recoveryScore == nil && imported.recoveryScore != nil {
            existing.recoveryScore = imported.recoveryScore
            changed = true
        }

        // Merge imported metrics if existing doesn't have them
        if existing.importedMetrics == nil && imported.importedMetrics != nil {
            existing.importedMetrics = imported.importedMetrics
            changed = true
        }

        return changed
    }

    // MARK: - Private

    private func createArchiveDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: archiveDirectory.path) {
            try? fileManager.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        }
    }

    private func loadIndex() {
        guard fileManager.fileExists(atPath: indexFile.path) else { return }

        do {
            let data = try Data(contentsOf: indexFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            index = try decoder.decode([SessionArchiveEntry].self, from: data)
        } catch {
            debugLog("Failed to load archive index: \(error)")
            index = []
        }
    }

    private func loadDeletedIndex() {
        guard fileManager.fileExists(atPath: deletedIndexFile.path) else { return }

        do {
            let data = try Data(contentsOf: deletedIndexFile)
            let decoder = JSONDecoder()
            let uuidStrings = try decoder.decode([String].self, from: data)
            deletedSessionIds = Set(uuidStrings.compactMap { UUID(uuidString: $0) })
        } catch {
            debugLog("Failed to load deleted index: \(error)")
            deletedSessionIds = []
        }
    }

    private func saveDeletedIndex() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let uuidStrings = deletedSessionIds.map { $0.uuidString }
        let data = try encoder.encode(uuidStrings)
        try data.write(to: deletedIndexFile)
    }

    private func saveIndex() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)
        try data.write(to: indexFile)
    }

    // MARK: - Errors

    enum ArchiveError: Error {
        case hashMismatch
        case fileNotFound
    }
}
