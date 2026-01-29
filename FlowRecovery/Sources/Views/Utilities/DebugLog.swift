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
import UIKit

/// Persistent debug logger that stores logs in memory for export
final class DebugLogger: ObservableObject {
    static let shared = DebugLogger()

    private let maxEntries = 10000  // Increased from 2000 - with reduced logging verbosity this will cover much longer periods
    private let queue = DispatchQueue(label: "com.hrv.debuglogger", qos: .utility)

    @Published private(set) var entries: [LogEntry] = []  // Last 7 days of all logs
    @Published private(set) var errorCatalog: [LogEntry] = []  // Permanent error/warning catalog

    // Notify when significant events are logged (for heartbeat timer reset)
    static let significantLogPosted = Notification.Name("DebugLogger.SignificantLog")

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
        let category: String

        var formatted: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            return "[\(formatter.string(from: timestamp))] [\(category)] \(message)"
        }
    }

    private init() {}

    func log(_ message: String, category: String = "App") {
        let entry = LogEntry(timestamp: Date(), message: message, category: category)

        queue.async { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }

                // Remove entries older than 7 days from main log
                let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
                self.entries.removeAll { $0.timestamp < sevenDaysAgo }

                self.entries.append(entry)

                // Also enforce max entries as backup
                if self.entries.count > self.maxEntries {
                    self.entries.removeFirst(self.entries.count - self.maxEntries)
                }

                // Notify if this is a significant event (errors, state changes)
                let lowerMessage = message.lowercased()
                let isSignificant = lowerMessage.contains("error") ||
                                   lowerMessage.contains("failed") ||
                                   lowerMessage.contains("started") ||
                                   lowerMessage.contains("stopped") ||
                                   lowerMessage.contains("reconnect") ||
                                   lowerMessage.contains("disconnect") ||
                                   lowerMessage.contains("❌") ||
                                   lowerMessage.contains("✅") ||
                                   lowerMessage.contains("warning")

                if isSignificant {
                    NotificationCenter.default.post(name: DebugLogger.significantLogPosted, object: nil)
                }

                // If it's an error or warning, add to permanent error catalog
                let isError = lowerMessage.contains("error") ||
                              lowerMessage.contains("failed") ||
                              lowerMessage.contains("❌") ||
                              lowerMessage.contains("warning") ||
                              lowerMessage.contains("⚠️") ||
                              lowerMessage.contains("disconnected") ||
                              lowerMessage.contains("insufficient")

                if isError {
                    self.errorCatalog.append(entry)
                    // Keep error catalog under 1000 entries (years of errors)
                    if self.errorCatalog.count > 1000 {
                        self.errorCatalog.removeFirst(self.errorCatalog.count - 1000)
                    }
                }
            }
        }
    }

    func clear() {
        DispatchQueue.main.async {
            self.entries.removeAll()
            // Don't clear error catalog - it's permanent
        }
    }

    func clearErrorCatalog() {
        DispatchQueue.main.async { self.errorCatalog.removeAll() }
    }

    func exportLogs() -> String {
        let header = """
        Flow Recovery Debug Log (Last 7 Days)
        Exported: \(Date())
        Device: \(UIDevice.current.name)
        iOS: \(UIDevice.current.systemVersion)
        App Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
        Build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown")
        Entries: \(entries.count)
        ========================================

        """
        return header + entries.map { $0.formatted }.joined(separator: "\n")
    }

    func exportErrorCatalog() -> String {
        let header = """
        Flow Recovery Error Catalog (Permanent)
        Exported: \(Date())
        Device: \(UIDevice.current.name)
        iOS: \(UIDevice.current.systemVersion)
        Total Errors Recorded: \(errorCatalog.count)
        ========================================

        """
        return header + errorCatalog.map { $0.formatted }.joined(separator: "\n")
    }

    func exportToFile() -> URL? {
        let content = exportLogs()
        let fileName = "hrv_debug_log_\(Int(Date().timeIntervalSince1970)).txt"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
            #if DEBUG
            print("[DebugLogger] Exported \(entries.count) log entries to \(tempURL.path)")
            #endif
            return tempURL
        } catch {
            #if DEBUG
            print("[DebugLogger] Export failed: \(error)")
            #endif
            // Try alternate location if temp directory fails
            let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent(fileName)
            if let docsURL = docsURL {
                do {
                    try content.write(to: docsURL, atomically: true, encoding: .utf8)
                    #if DEBUG
                    print("[DebugLogger] Exported to documents directory: \(docsURL.path)")
                    #endif
                    return docsURL
                } catch {
                    #if DEBUG
                    print("[DebugLogger] Documents export also failed: \(error)")
                    #endif
                }
            }
            return nil
        }
    }
}

/// Debug-only logging - compiled out in Release builds
@inline(__always)
func debugLog(_ message: @autoclosure () -> String, file: String = #file, line: Int = #line) {
    let filename = (file as NSString).lastPathComponent
    let category = filename.replacingOccurrences(of: ".swift", with: "")

    #if DEBUG
    print("[\(filename):\(line)] \(message())")
    #endif

    // Also log to runtime logger if enabled
    if RuntimeLogger.shared.isEnabled {
        RuntimeLogger.shared.log(message(), file: file, line: line)
    }

    // Only log to persistent DebugLogger in DEBUG builds to protect health data privacy
    #if DEBUG
    DebugLogger.shared.log("[\(line)] \(message())", category: category)
    #endif
}

/// Runtime logger that works in Release builds
/// Enable via Settings or by setting UserDefaults "RuntimeLoggingEnabled" = true
final class RuntimeLogger: ObservableObject {
    static let shared = RuntimeLogger()

    private let userDefaultsKey = "RuntimeLoggingEnabled"
    private let maxLogLines = 1000

    @Published private(set) var logs: [LogEntry] = []

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: userDefaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: userDefaultsKey)
            if newValue {
                log("Runtime logging enabled", file: #file, line: #line)
            }
        }
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
        let file: String
        let line: Int

        var formattedTime: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            return formatter.string(from: timestamp)
        }

        var shortFile: String {
            (file as NSString).lastPathComponent
        }
    }

    private init() {}

    func log(_ message: String, file: String, line: Int) {
        let entry = LogEntry(timestamp: Date(), message: message, file: file, line: line)
        DispatchQueue.main.async {
            self.logs.append(entry)
            // Trim old logs
            if self.logs.count > self.maxLogLines {
                self.logs.removeFirst(self.logs.count - self.maxLogLines)
            }
        }
    }

    func clear() {
        DispatchQueue.main.async {
            self.logs.removeAll()
        }
    }

    /// Export logs as text
    func exportLogs() -> String {
        logs.map { "[\($0.formattedTime)] [\($0.shortFile):\($0.line)] \($0.message)" }
            .joined(separator: "\n")
    }
}
