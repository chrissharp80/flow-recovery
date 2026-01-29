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

/// Captures uncaught exceptions and signals, persists crash logs for later export
/// Works in Release builds - users can share crash logs via Settings
final class CrashLogManager {
    static let shared = CrashLogManager()

    private let crashLogFileName = "crash_log.txt"
    private let previousCrashFileName = "previous_crash.txt"

    private var crashLogURL: URL {
        storageDirectory.appendingPathComponent(crashLogFileName)
    }

    private var previousCrashURL: URL {
        storageDirectory.appendingPathComponent(previousCrashFileName)
    }

    private var storageDirectory: URL {
        // Use app group container if available, fall back to documents
        if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.chrissharp.flowrecovery"
        ) {
            return container
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Returns true if there's a crash log from a previous session
    var hasPreviousCrash: Bool {
        FileManager.default.fileExists(atPath: previousCrashURL.path)
    }

    /// Returns the previous crash log content, if any
    var previousCrashLog: String? {
        try? String(contentsOf: previousCrashURL, encoding: .utf8)
    }

    private init() {}

    /// Call this once at app startup to install crash handlers
    func install() {
        // Move any existing crash log to "previous" before we start
        promoteCurrentCrashLog()

        // Install exception handler for NSExceptions and Swift errors that bridge
        NSSetUncaughtExceptionHandler { exception in
            CrashLogManager.shared.writeCrashLog(
                type: "Exception",
                name: exception.name.rawValue,
                reason: exception.reason ?? "Unknown",
                stackTrace: exception.callStackSymbols.joined(separator: "\n")
            )
        }

        // Install signal handlers for crashes that don't throw exceptions
        installSignalHandlers()
    }

    /// Clears the previous crash log (call after user has seen/exported it)
    func clearPreviousCrash() {
        try? FileManager.default.removeItem(at: previousCrashURL)
    }

    /// Exports crash log to a shareable file, returns URL
    func exportCrashLog() -> URL? {
        guard let content = previousCrashLog else { return nil }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let fileName = "FlowRecovery_Crash_\(timestamp).txt"
        let exportURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        do {
            try content.write(to: exportURL, atomically: true, encoding: .utf8)
            return exportURL
        } catch {
            return nil
        }
    }

    // MARK: - Private

    private func promoteCurrentCrashLog() {
        let fm = FileManager.default
        // If there's a crash log from last run, move it to previous
        if fm.fileExists(atPath: crashLogURL.path) {
            try? fm.removeItem(at: previousCrashURL)
            try? fm.moveItem(at: crashLogURL, to: previousCrashURL)
        }
    }

    private func installSignalHandlers() {
        // These signals indicate fatal crashes
        let signals: [Int32] = [
            SIGABRT,  // Abort (assertion failure, etc.)
            SIGSEGV,  // Segmentation fault (bad memory access)
            SIGBUS,   // Bus error (alignment issues)
            SIGFPE,   // Floating point exception
            SIGILL,   // Illegal instruction
            SIGTRAP   // Debugger trap
        ]

        for sig in signals {
            signal(sig) { signalNumber in
                let signalName = CrashLogManager.signalName(signalNumber)
                CrashLogManager.shared.writeCrashLog(
                    type: "Signal",
                    name: signalName,
                    reason: "Received signal \(signalNumber)",
                    stackTrace: Thread.callStackSymbols.joined(separator: "\n")
                )
                // Re-raise to get default behavior (crash)
                signal(signalNumber, SIG_DFL)
                raise(signalNumber)
            }
        }
    }

    private static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS:  return "SIGBUS"
        case SIGFPE:  return "SIGFPE"
        case SIGILL:  return "SIGILL"
        case SIGTRAP: return "SIGTRAP"
        default:      return "SIGNAL_\(signal)"
        }
    }

    fileprivate func writeCrashLog(type: String, name: String, reason: String, stackTrace: String) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        let content = """
        ================================================================================
        FLOW RECOVERY CRASH LOG
        ================================================================================

        Timestamp: \(dateFormatter.string(from: Date()))

        Device: \(UIDevice.current.name)
        Model: \(UIDevice.current.model)
        iOS Version: \(UIDevice.current.systemVersion)
        App Version: \(appVersion) (\(buildNumber))

        --------------------------------------------------------------------------------
        CRASH INFO
        --------------------------------------------------------------------------------

        Type: \(type)
        Name: \(name)
        Reason: \(reason)

        --------------------------------------------------------------------------------
        STACK TRACE
        --------------------------------------------------------------------------------

        \(stackTrace)

        ================================================================================
        END OF CRASH LOG
        ================================================================================
        """

        // Write synchronously - we're crashing so async won't complete
        try? content.write(to: crashLogURL, atomically: false, encoding: .utf8)
    }
}
