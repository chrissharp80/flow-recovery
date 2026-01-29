//
//  Copyright © 2024-2026 Chris Sharp. All rights reserved.
//

import Foundation

/// Protocol for session persistence operations
protocol SessionRepositoryProtocol {

    /// All archived session entries (metadata only)
    var entries: [SessionArchiveEntry] { get }

    /// Save a session to the archive
    @discardableResult
    func archive(_ session: HRVSession) throws -> SessionArchiveEntry

    /// Retrieve a full session by ID
    func retrieve(_ id: UUID) throws -> HRVSession?

    /// Delete a session by ID
    func delete(_ id: UUID) throws

    /// Check if a session exists
    func exists(_ id: UUID) -> Bool

    /// Check if a session exists near a given date
    func hasSessionNear(date: Date, toleranceMinutes: Int) -> Bool

    /// Update tags and notes for a session
    func updateTags(_ id: UUID, tags: [ReadingTag], notes: String?) throws

    /// Check if a session was intentionally deleted
    func wasIntentionallyDeleted(_ id: UUID) -> Bool
}

// MARK: - SessionArchive Conformance

extension SessionArchive: SessionRepositoryProtocol {}

