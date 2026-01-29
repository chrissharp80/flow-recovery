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

/// Personal baseline tracking for multi-night HRV trends
/// Per design spec v8.1: Rolling 7-day baseline with deviation tracking
final class BaselineTracker {

    // MARK: - Types

    /// Personal baseline snapshot
    struct Baseline: Codable {
        let date: Date
        let rmssd: Double
        let sdnn: Double
        let meanHR: Double
        let hf: Double?
        let lf: Double?
        let lfHfRatio: Double?
        let dfaAlpha1: Double?
        let stressIndex: Double?
        let readinessScore: Double?
        let sampleCount: Int

        /// Minimum samples required for valid baseline
        static let minimumSamples = 3
    }

    /// Deviation from baseline for a single session
    struct BaselineDeviation: Codable {
        let rmssdDeviation: Double?       // Percentage deviation
        let sdnnDeviation: Double?
        let meanHRDeviation: Double?
        let hfDeviation: Double?
        let lfHfDeviation: Double?
        let stressDeviation: Double?
        let readinessDeviation: Double?

        /// Interpretation of the deviation
        var rmssdInterpretation: DeviationInterpretation {
            guard let dev = rmssdDeviation else { return .insufficient }
            if dev < -20 { return .significantlyBelow }
            if dev < -10 { return .belowBaseline }
            if dev > 20 { return .significantlyAbove }
            if dev > 10 { return .aboveBaseline }
            return .withinNormal
        }

        var overallStatus: OverallStatus {
            guard let rmssdDev = rmssdDeviation else { return .noBaseline }

            // Weight RMSSD most heavily
            if rmssdDev < -15 { return .belowBaseline }
            if rmssdDev > 15 { return .aboveBaseline }
            return .normal
        }
    }

    enum DeviationInterpretation: String {
        case significantlyBelow = "Significantly below baseline"
        case belowBaseline = "Below baseline"
        case withinNormal = "Within normal range"
        case aboveBaseline = "Above baseline"
        case significantlyAbove = "Significantly above baseline"
        case insufficient = "Insufficient baseline data"
    }

    enum OverallStatus: String {
        case belowBaseline = "Recovery may be compromised"
        case normal = "Within your normal range"
        case aboveBaseline = "Elevated recovery capacity"
        case noBaseline = "Building baseline..."
    }

    // MARK: - Storage

    private let baselineFile: URL
    private var currentBaseline: Baseline?
    private var historicalData: [BaselineDataPoint] = []
    private let fileManager = FileManager.default

    /// Data point for baseline calculation
    private struct BaselineDataPoint: Codable {
        let date: Date
        let rmssd: Double
        let sdnn: Double
        let meanHR: Double
        let hf: Double?
        let lf: Double?
        let lfHfRatio: Double?
        let dfaAlpha1: Double?
        let stressIndex: Double?
        let readinessScore: Double?

        // Window quality metrics (for replacement decisions)
        let isConsolidated: Bool?
        let isOrganizedRecovery: Bool?
        let windowHRStability: Double?
        let artifactPercentage: Double?
    }

    private struct StoredData: Codable {
        var baseline: Baseline?
        var historicalData: [BaselineDataPoint]
    }

    // MARK: - Configuration

    /// Rolling window for baseline calculation (days)
    static let baselineWindowDays = 7

    /// Maximum historical points to store (limit storage growth)
    static let maxHistoricalPoints = 90

    // MARK: - Initialization

    /// App Group identifier for shared container (survives app reinstalls)
    private static let appGroupIdentifier = "group.com.chrissharp.flowrecovery"

    init() {
        // Try App Group container first, fall back to Documents
        if let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) {
            baselineFile = containerURL.appendingPathComponent("HRVBaseline.json")
            debugLog("[Baseline] Using App Group container")
        } else if let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            baselineFile = documentsPath.appendingPathComponent("HRVBaseline.json")
            debugLog("[Baseline] Using Documents directory (App Group not configured)")
        } else {
            // Fallback to temporary directory (should never happen on iOS)
            baselineFile = fileManager.temporaryDirectory.appendingPathComponent("HRVBaseline.json")
            debugLog("[Baseline] WARNING: Using temporary directory as fallback")
        }
        load()
        // Sync loaded baseline to UserSettings on startup
        syncToUserSettings()
        debugLog("[Baseline] Loaded \(historicalData.count) data points, baseline: \(currentBaseline != nil ? "available" : "not yet established")")
    }

    // MARK: - Public API

    /// Get current baseline
    var baseline: Baseline? {
        currentBaseline
    }

    /// Check if baseline is established (minimum samples collected)
    var hasValidBaseline: Bool {
        guard let baseline = currentBaseline else { return false }
        return baseline.sampleCount >= Baseline.minimumSamples
    }

    /// Days of data collected
    var daysCollected: Int {
        historicalData.count
    }

    /// Update baseline with new session data
    /// - Parameter session: Completed session with analysis results
    /// Note: Only overnight sessions update the baseline. Naps and quick readings are excluded.
    func update(with session: HRVSession) {
        guard let result = session.analysisResult else { return }
        // Any session type can contribute to baseline if it's the best reading for the day
        // (overnight, nap, quick - all compete for daily readiness score)

        // Create data point from session
        let dataPoint = BaselineDataPoint(
            date: session.startDate,
            rmssd: result.timeDomain.rmssd,
            sdnn: result.timeDomain.sdnn,
            meanHR: result.timeDomain.meanHR,
            hf: result.frequencyDomain?.hf,
            lf: result.frequencyDomain?.lf,
            lfHfRatio: result.frequencyDomain?.lfHfRatio,
            dfaAlpha1: result.nonlinear.dfaAlpha1,
            stressIndex: result.ansMetrics?.stressIndex,
            readinessScore: result.ansMetrics?.readinessScore,
            isConsolidated: result.isConsolidated,
            isOrganizedRecovery: result.isOrganizedRecovery,
            windowHRStability: result.windowHRStability,
            artifactPercentage: result.artifactPercentage
        )

        // Add to historical data with smart replacement logic
        let calendar = Calendar.current

        // Check if this is a morning reading (before 10am)
        let hour = calendar.component(.hour, from: dataPoint.date)
        let isMorningReading = hour < 10

        // Find existing data point for today
        if let existingIndex = historicalData.firstIndex(where: { calendar.isDate($0.date, inSameDayAs: dataPoint.date) }) {
            let existing = historicalData[existingIndex]
            let existingHour = calendar.component(.hour, from: existing.date)
            let existingIsMorning = existingHour < 10

            // Only replace if new reading is better AND has earned the right
            // New window must be objectively superior - would have won window selection
            let shouldReplace: Bool
            if isMorningReading && existingIsMorning {
                // Both morning readings - new must be objectively better
                shouldReplace = newWindowIsObjectivelyBetter(new: dataPoint, existing: existing)
            } else if isMorningReading && !existingIsMorning {
                // New is morning, existing is not - replace with morning reading
                shouldReplace = true
            } else if !isMorningReading && existingIsMorning {
                // New is not morning, existing is morning - keep the morning reading
                shouldReplace = false
            } else {
                // Both non-morning - new must be objectively better
                shouldReplace = newWindowIsObjectivelyBetter(new: dataPoint, existing: existing)
            }

            if shouldReplace {
                historicalData[existingIndex] = dataPoint
            }
            // If not replacing, don't add the new data point at all
        } else {
            // No existing data for today - add it
            historicalData.append(dataPoint)
        }

        // Trim to max points
        historicalData.sort { $0.date < $1.date }
        if historicalData.count > Self.maxHistoricalPoints {
            historicalData = Array(historicalData.suffix(Self.maxHistoricalPoints))
        }

        // Recalculate baseline
        recalculateBaseline()

        // Sync to UserSettings so it shows in Settings view
        syncToUserSettings()

        // Persist
        save()
    }

    /// Sync calculated baseline to UserSettings for display
    private func syncToUserSettings() {
        guard let baseline = currentBaseline, baseline.sampleCount >= Baseline.minimumSamples else {
            return
        }
        SettingsManager.shared.updateBaseline(rmssd: baseline.rmssd, hr: baseline.meanHR)
    }

    /// Calculate deviation from baseline for a session
    /// - Parameter session: Session to compare against baseline
    /// - Returns: Deviation metrics, or nil if no baseline
    func deviation(for session: HRVSession) -> BaselineDeviation? {
        guard let baseline = currentBaseline,
              baseline.sampleCount >= Baseline.minimumSamples,
              let result = session.analysisResult else {
            return nil
        }

        return BaselineDeviation(
            rmssdDeviation: percentDeviation(current: result.timeDomain.rmssd, baseline: baseline.rmssd),
            sdnnDeviation: percentDeviation(current: result.timeDomain.sdnn, baseline: baseline.sdnn),
            meanHRDeviation: percentDeviation(current: result.timeDomain.meanHR, baseline: baseline.meanHR),
            hfDeviation: optionalPercentDeviation(current: result.frequencyDomain?.hf, baseline: baseline.hf),
            lfHfDeviation: optionalPercentDeviation(current: result.frequencyDomain?.lfHfRatio, baseline: baseline.lfHfRatio),
            stressDeviation: optionalPercentDeviation(current: result.ansMetrics?.stressIndex, baseline: baseline.stressIndex),
            readinessDeviation: optionalPercentDeviation(current: result.ansMetrics?.readinessScore, baseline: baseline.readinessScore)
        )
    }

    /// Reset baseline (start fresh)
    func reset() {
        currentBaseline = nil
        historicalData = []
        save()
    }

    // MARK: - Private Methods

    /// Determine if new window is objectively better than existing window
    /// New window must have "earned the right" to replace - would have won window selection
    /// - Parameters:
    ///   - new: New data point candidate
    ///   - existing: Existing data point currently in baseline
    /// - Returns: True if new window is objectively superior and should replace existing
    private func newWindowIsObjectivelyBetter(new: BaselineDataPoint, existing: BaselineDataPoint) -> Bool {
        let newScore = new.readinessScore ?? 0
        let existingScore = existing.readinessScore ?? 0

        // 1. Consolidated windows take priority over non-consolidated
        //    A true consolidated recovery (sustained plateau + stable HR) beats a spike
        let newConsolidated = new.isConsolidated ?? false
        let existingConsolidated = existing.isConsolidated ?? false

        if existingConsolidated && !newConsolidated {
            // Existing is consolidated, new is not
            // New must have SIGNIFICANTLY higher readiness to replace (>15% better)
            let scoreDelta = newScore - existingScore
            let threshold = existingScore * 0.15
            debugLog("[Baseline] New window not consolidated vs existing consolidated - requires >15% score improvement")
            return scoreDelta > threshold
        }

        if newConsolidated && !existingConsolidated {
            // New is consolidated, existing is not - consolidated wins if score is close
            if newScore >= existingScore * 0.9 {  // Within 10% or better
                debugLog("[Baseline] New window is consolidated vs existing non-consolidated - replacing")
                return true
            }
        }

        // 2. If both have same consolidation status, check organized recovery
        if newConsolidated == existingConsolidated {
            let newOrganized = new.isOrganizedRecovery ?? false
            let existingOrganized = existing.isOrganizedRecovery ?? false

            if existingOrganized && !newOrganized {
                // Existing has organized recovery, new doesn't
                // Organized recovery (DFA α1 0.75-1.0) is critical for readiness
                debugLog("[Baseline] New window lacks organized recovery vs existing organized - rejecting")
                return false
            }

            if newOrganized && !existingOrganized {
                // New has organized recovery, existing doesn't - strong advantage
                if newScore >= existingScore * 0.95 {  // Within 5% or better
                    debugLog("[Baseline] New window has organized recovery vs existing unorganized - replacing")
                    return true
                }
            }
        }

        // 3. Check artifact rate - lower is better (quality control)
        let newArtifacts = new.artifactPercentage ?? 100.0
        let existingArtifacts = existing.artifactPercentage ?? 100.0

        if newArtifacts > existingArtifacts * 1.5 {
            // New window has significantly more artifacts (>50% more)
            debugLog("[Baseline] New window has high artifact rate (\(String(format: "%.1f", newArtifacts))% vs \(String(format: "%.1f", existingArtifacts))%) - rejecting")
            return false
        }

        // 4. Check HR stability - lower CV is better (more stable)
        if let newStability = new.windowHRStability,
           let existingStability = existing.windowHRStability {
            if newStability > existingStability * 1.3 {
                // New window has significantly less stable HR (>30% worse CV)
                debugLog("[Baseline] New window has poor HR stability (CV \(String(format: "%.3f", newStability)) vs \(String(format: "%.3f", existingStability))) - rejecting")
                return false
            }
        }

        // 5. Final decision: readiness score comparison
        //    At this point, both windows have similar quality characteristics
        //    New must be meaningfully better (>5% improvement minimum)
        let scoreDelta = newScore - existingScore
        let minImprovement = existingScore * 0.05  // 5% minimum improvement

        if scoreDelta > minImprovement {
            debugLog("[Baseline] New window is objectively better - score improvement: \(String(format: "%.1f", scoreDelta)) (>\(String(format: "%.1f", minImprovement)) threshold)")
            return true
        } else {
            debugLog("[Baseline] New window does not meet improvement threshold - delta: \(String(format: "%.1f", scoreDelta)), need: >\(String(format: "%.1f", minImprovement))")
            return false
        }
    }

    private func recalculateBaseline() {
        // Get data from last N days
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -Self.baselineWindowDays, to: Date())!
        let recentData = historicalData.filter { $0.date >= cutoffDate }

        guard !recentData.isEmpty else {
            currentBaseline = nil
            return
        }

        // Compute averages
        let n = Double(recentData.count)

        let rmssdAvg = recentData.map { $0.rmssd }.reduce(0, +) / n
        let sdnnAvg = recentData.map { $0.sdnn }.reduce(0, +) / n
        let meanHRAvg = recentData.map { $0.meanHR }.reduce(0, +) / n

        let hfValues = recentData.compactMap { $0.hf }
        let hfAvg = hfValues.isEmpty ? nil : hfValues.reduce(0, +) / Double(hfValues.count)

        let lfValues = recentData.compactMap { $0.lf }
        let lfAvg = lfValues.isEmpty ? nil : lfValues.reduce(0, +) / Double(lfValues.count)

        let lfHfValues = recentData.compactMap { $0.lfHfRatio }
        let lfHfAvg = lfHfValues.isEmpty ? nil : lfHfValues.reduce(0, +) / Double(lfHfValues.count)

        let dfaValues = recentData.compactMap { $0.dfaAlpha1 }
        let dfaAvg = dfaValues.isEmpty ? nil : dfaValues.reduce(0, +) / Double(dfaValues.count)

        let stressValues = recentData.compactMap { $0.stressIndex }
        let stressAvg = stressValues.isEmpty ? nil : stressValues.reduce(0, +) / Double(stressValues.count)

        let readinessValues = recentData.compactMap { $0.readinessScore }
        let readinessAvg = readinessValues.isEmpty ? nil : readinessValues.reduce(0, +) / Double(readinessValues.count)

        currentBaseline = Baseline(
            date: Date(),
            rmssd: rmssdAvg,
            sdnn: sdnnAvg,
            meanHR: meanHRAvg,
            hf: hfAvg,
            lf: lfAvg,
            lfHfRatio: lfHfAvg,
            dfaAlpha1: dfaAvg,
            stressIndex: stressAvg,
            readinessScore: readinessAvg,
            sampleCount: recentData.count
        )
    }

    private func percentDeviation(current: Double, baseline: Double) -> Double? {
        guard baseline > 0 else { return nil }
        return ((current - baseline) / baseline) * 100
    }

    private func optionalPercentDeviation(current: Double?, baseline: Double?) -> Double? {
        guard let c = current, let b = baseline, b > 0 else { return nil }
        return ((c - b) / b) * 100
    }

    // MARK: - Persistence

    private func load() {
        guard fileManager.fileExists(atPath: baselineFile.path) else { return }

        do {
            let data = try Data(contentsOf: baselineFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let stored = try decoder.decode(StoredData.self, from: data)
            currentBaseline = stored.baseline
            historicalData = stored.historicalData
        } catch {
            debugLog("Failed to load baseline: \(error)")
        }
    }

    private func save() {
        do {
            let stored = StoredData(baseline: currentBaseline, historicalData: historicalData)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted]
            let data = try encoder.encode(stored)
            try data.write(to: baselineFile)
        } catch {
            debugLog("Failed to save baseline: \(error)")
        }
    }
}

// MARK: - Formatting Extension

extension BaselineTracker.BaselineDeviation {

    /// Format deviation as display string
    func formattedRMSSD() -> String {
        guard let dev = rmssdDeviation else { return "—" }
        let sign = dev >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", dev))%"
    }

    func formattedHR() -> String {
        guard let dev = meanHRDeviation else { return "—" }
        let sign = dev >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", dev))%"
    }

    func formattedStress() -> String {
        guard let dev = stressDeviation else { return "—" }
        let sign = dev >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.1f", dev))%"
    }
}
