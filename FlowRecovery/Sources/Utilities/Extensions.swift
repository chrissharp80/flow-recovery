//
//  Copyright © 2024-2026 Chris Sharp. All rights reserved.
//

import Foundation

// MARK: - Optional Comparisons

extension Optional where Wrapped: Comparable {
    /// Returns true if self is nil or self < value
    func isNilOrLessThan(_ value: Wrapped) -> Bool {
        guard let unwrapped = self else { return true }
        return unwrapped < value
    }

    /// Returns true if self is nil or self > value
    func isNilOrGreaterThan(_ value: Wrapped) -> Bool {
        guard let unwrapped = self else { return true }
        return unwrapped > value
    }

    /// Update self to the minimum of current value and new value
    mutating func updateMin(_ value: Wrapped) {
        if isNilOrGreaterThan(value) {
            self = value
        }
    }

    /// Update self to the maximum of current value and new value
    mutating func updateMax(_ value: Wrapped) {
        if isNilOrLessThan(value) {
            self = value
        }
    }
}

// MARK: - Collection Statistics

extension Collection where Element: BinaryFloatingPoint {
    /// Calculate the average of all elements, or nil if empty
    var average: Element? {
        guard !isEmpty else { return nil }
        let sum = reduce(0, +)
        return sum / Element(count)
    }

    /// Calculate the average, returning 0 if empty
    var averageOrZero: Element {
        average ?? 0
    }

    /// Calculate the sum of all elements
    var sum: Element {
        reduce(0, +)
    }
}

extension Collection where Element: BinaryInteger {
    /// Calculate the average as Double, or nil if empty
    var average: Double? {
        guard !isEmpty else { return nil }
        let sum = reduce(0, +)
        return Double(sum) / Double(count)
    }

    /// Calculate the average, returning 0 if empty
    var averageOrZero: Double {
        average ?? 0
    }
}

// MARK: - Number Formatting

extension Double {
    /// Format with no decimal places
    var formatted0: String {
        String(format: "%.0f", self)
    }

    /// Format with 1 decimal place
    var formatted1: String {
        String(format: "%.1f", self)
    }

    /// Format with 2 decimal places
    var formatted2: String {
        String(format: "%.2f", self)
    }

    /// Format with specified decimal places
    func formatted(decimals: Int) -> String {
        String(format: "%.\(decimals)f", self)
    }

    /// Format as percentage (e.g., 0.85 -> "85%")
    var asPercentage: String {
        String(format: "%.0f%%", self * 100)
    }

    /// Format as percentage with 1 decimal (e.g., 0.856 -> "85.6%")
    var asPercentage1: String {
        String(format: "%.1f%%", self * 100)
    }
}

extension Int {
    /// Format with thousands separator
    var withSeparator: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: self)) ?? String(self)
    }
}

// MARK: - Duration Formatting

extension TimeInterval {
    /// Format as hours and minutes (e.g., "7h 30m")
    var asHoursMinutes: String {
        let totalMinutes = Int(self / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    /// Format as minutes and seconds (e.g., "3:45")
    var asMinutesSeconds: String {
        let totalSeconds = Int(self)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

extension Int {
    /// Format minutes as hours and minutes (e.g., 450 -> "7h 30m")
    var minutesAsHoursMinutes: String {
        let hours = self / 60
        let minutes = self % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

// MARK: - Safe Array Access

extension Array {
    /// Safely access element at index, returning nil if out of bounds
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Date Helpers

extension Date {
    /// Start of day for this date
    var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }

    /// Add hours to date
    func addingHours(_ hours: Int) -> Date {
        Calendar.current.date(byAdding: .hour, value: hours, to: self) ?? self
    }

    /// Add days to date
    func addingDays(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: self) ?? self
    }

    /// Add minutes to date
    func addingMinutes(_ minutes: Int) -> Date {
        Calendar.current.date(byAdding: .minute, value: minutes, to: self) ?? self
    }

    /// Hour component of the date
    var hour: Int {
        Calendar.current.component(.hour, from: self)
    }

    /// Check if date is in the overnight window (6pm to 12pm next day)
    var isInOvernightWindow: Bool {
        let hour = self.hour
        return hour >= 18 || hour < 12
    }
}

// MARK: - String Helpers

extension String {
    /// Truncate to specified length with ellipsis
    func truncated(to length: Int) -> String {
        if count <= length {
            return self
        }
        return String(prefix(length - 1)) + "…"
    }
}

// MARK: - Result Helpers

extension Result {
    /// Returns the success value or nil
    var success: Success? {
        if case .success(let value) = self {
            return value
        }
        return nil
    }

    /// Returns the failure error or nil
    var failure: Failure? {
        if case .failure(let error) = self {
            return error
        }
        return nil
    }
}

// MARK: - Shared Date Formatters

/// Shared DateFormatter instances to avoid repeated allocations
enum SharedDateFormatters {
    /// Time format: "h:mm a" (e.g., "10:30 PM")
    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    /// Debug timestamp format: "yyyy-MM-dd HH:mm:ss.SSS"
    static let debugFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// Short date format: "MMM d" (e.g., "Jan 15")
    static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    /// Full date format: "MMMM d, yyyy" (e.g., "January 15, 2026")
    static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    /// Date and time format: "MMM d, h:mm a" (e.g., "Jan 15, 10:30 PM")
    static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter
    }()

    /// Hour only format: "ha" (e.g., "10PM")
    static let hourFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "ha"
        return formatter
    }()
}

extension Date {
    /// Format as time string (e.g., "10:30 PM")
    var asTimeString: String {
        SharedDateFormatters.timeFormatter.string(from: self)
    }

    /// Format as short date (e.g., "Jan 15")
    var asShortDate: String {
        SharedDateFormatters.shortDateFormatter.string(from: self)
    }

    /// Format as full date (e.g., "January 15, 2026")
    var asFullDate: String {
        SharedDateFormatters.fullDateFormatter.string(from: self)
    }

    /// Format as date and time (e.g., "Jan 15, 10:30 PM")
    var asDateTime: String {
        SharedDateFormatters.dateTimeFormatter.string(from: self)
    }

    /// Format as hour only (e.g., "10PM")
    var asHourString: String {
        SharedDateFormatters.hourFormatter.string(from: self)
    }
}

// MARK: - Sleep Duration Helpers

extension Int {
    /// Convert total minutes to hours (Double)
    var minutesAsHours: Double {
        Double(self) / 60.0
    }
}

// MARK: - Percentage Deviation

/// Calculate percentage deviation from a baseline value
/// - Parameters:
///   - value: The current value
///   - baseline: The baseline value to compare against
/// - Returns: Percentage deviation (positive = above baseline, negative = below)
func percentageDeviation(from baseline: Double, to value: Double) -> Double {
    guard baseline > 0 else { return 0 }
    return ((value - baseline) / baseline) * 100
}

// MARK: - Tag Lookup

extension Set where Element == ReadingTag {
    /// Check if the set contains a tag with the given name
    /// - Parameter name: The name to search for (case-sensitive)
    /// - Returns: true if a tag with that name exists
    func contains(tagNamed name: String) -> Bool {
        contains(where: { $0.name == name })
    }

    /// Get the tag with the given name, if it exists
    /// - Parameter name: The name to search for (case-sensitive)
    /// - Returns: The tag, or nil if not found
    func tag(named name: String) -> ReadingTag? {
        first(where: { $0.name == name })
    }
}

extension Array where Element == ReadingTag {
    /// Check if the array contains a tag with the given name
    func contains(tagNamed name: String) -> Bool {
        contains(where: { $0.name == name })
    }

    /// Get the tag with the given name, if it exists
    func tag(named name: String) -> ReadingTag? {
        first(where: { $0.name == name })
    }
}

// MARK: - Bundle Extensions

extension Bundle {
    /// App version string (e.g., "1.0.0")
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    /// App build number (e.g., "42")
    var appBuild: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

    /// Combined version and build string (e.g., "1.0.0 (42)")
    var appVersionString: String {
        "\(appVersion) (\(appBuild))"
    }
}

// MARK: - HRV Session Extensions

extension Array where Element == HRVSession {
    /// Filter to only valid completed sessions with analysis results
    var validSessions: [HRVSession] {
        filter { $0.state == .complete && $0.analysisResult != nil }
    }

    /// Extract RMSSD values from valid sessions
    var rmssdValues: [Double] {
        compactMap { $0.analysisResult?.timeDomain.rmssd }
    }

    /// Extract mean HR values from valid sessions
    var meanHRValues: [Double] {
        compactMap { $0.analysisResult?.timeDomain.meanHR }
    }

    /// Extract DFA alpha1 values from valid sessions
    var dfaAlpha1Values: [Double] {
        compactMap { $0.analysisResult?.nonlinear.dfaAlpha1 }
    }
}
