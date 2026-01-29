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
import UniformTypeIdentifiers

/// Handles importing RR interval data from various file formats
/// Supports: CSV, JSON, TXT (raw RR values), Kubios exports, EliteHRV, HRV4Training formats
final class RRDataImporter {

    // MARK: - Supported Formats

    enum ImportFormat: String, CaseIterable, Identifiable {
        case csv = "CSV"
        case json = "JSON"
        case txt = "Text (RR values)"
        case kubios = "Kubios Export"
        case eliteHRV = "Elite HRV Summary"
        case flowHRVMultiSession = "Flow Recovery RR Export"

        var id: String { rawValue }

        var fileExtensions: [String] {
            switch self {
            case .csv: return ["csv"]
            case .json: return ["json"]
            case .txt: return ["txt"]
            case .kubios: return ["hrv", "csv"]
            case .eliteHRV: return ["csv"]
            case .flowHRVMultiSession: return ["csv"]
            }
        }

        var description: String {
            switch self {
            case .csv: return "Comma-separated RR intervals in milliseconds"
            case .json: return "JSON array of RR intervals"
            case .txt: return "Plain text with one RR interval per line"
            case .kubios: return "Kubios HRV export with raw RR data"
            case .eliteHRV: return "Elite HRV summary export (multiple sessions)"
            case .flowHRVMultiSession: return "Flow Recovery multi-session RR export (raw data)"
            }
        }
    }

    /// Result for Elite HRV summary import (multiple sessions with pre-computed metrics)
    struct EliteHRVSummaryResult {
        struct SessionSummary {
            let date: Date
            let rmssd: Double
            let rmssdRaw: Double
            let artifactPercent: Double
            let beatCount: Int
            let rrMin: Double
            let rrMax: Double
            let fileName: String
        }

        let sessions: [SessionSummary]
        let originalFileName: String
    }

    /// Result for Flow Recovery multi-session RR export (raw RR data per session)
    struct FlowHRVMultiSessionResult {
        struct SessionRRData {
            let sessionDate: String  // Original session_date string (e.g. "2026-01-25_0443")
            let date: Date
            let rrIntervals: [Int]   // Raw RR intervals in milliseconds
            let timestamps: [Int64]  // Original timestamps

            var beatCount: Int { rrIntervals.count }
            var durationMinutes: Double {
                Double(rrIntervals.reduce(0, +)) / 60000.0
            }
        }

        let sessions: [SessionRRData]
        let originalFileName: String
    }

    enum ImportError: LocalizedError {
        case fileNotFound
        case unreadableFile
        case invalidFormat(String)
        case noRRData
        case insufficientData(found: Int, required: Int)
        case invalidRRValues(String)

        var errorDescription: String? {
            switch self {
            case .fileNotFound:
                return "The selected file could not be found."
            case .unreadableFile:
                return "Unable to read the file contents."
            case .invalidFormat(let details):
                return "Invalid file format: \(details)"
            case .noRRData:
                return "No RR interval data found in file."
            case .insufficientData(let found, let required):
                return "Insufficient data: found \(found) RR intervals, need at least \(required)."
            case .invalidRRValues(let details):
                return "Invalid RR values: \(details)"
            }
        }
    }

    struct ImportResult {
        let rrIntervals: [Int]  // RR intervals in milliseconds
        let sourceFormat: ImportFormat
        let originalFileName: String
        let recordingDate: Date?
        let metadata: [String: String]

        var beatCount: Int { rrIntervals.count }
        var durationMinutes: Double {
            Double(rrIntervals.reduce(0, +)) / 60000.0
        }
    }

    // MARK: - Public API

    /// Supported UTTypes for file picker
    static var supportedTypes: [UTType] {
        [.commaSeparatedText, .json, .plainText]
    }

    /// Import RR data from a file URL
    func importFile(at url: URL) async throws -> ImportResult {
        guard url.startAccessingSecurityScopedResource() else {
            throw ImportError.fileNotFound
        }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let data = try? Data(contentsOf: url) else {
            throw ImportError.unreadableFile
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw ImportError.unreadableFile
        }

        let fileName = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        // Try to detect format
        let format = detectFormat(content: content, extension: ext)

        // Parse based on detected format
        let rrIntervals: [Int]
        var metadata: [String: String] = [:]
        var recordingDate: Date?

        switch format {
        case .json:
            let (intervals, meta, date) = try parseJSON(content)
            rrIntervals = intervals
            metadata = meta
            recordingDate = date

        case .csv, .kubios:
            let (intervals, meta, date) = try parseCSV(content)
            rrIntervals = intervals
            metadata = meta
            recordingDate = date

        case .txt:
            rrIntervals = try parsePlainText(content)

        case .eliteHRV:
            // Elite HRV summary files should use importEliteHRVFile instead
            throw ImportError.invalidFormat("Elite HRV summary format detected. Use batch import for summary files.")

        case .flowHRVMultiSession:
            // Flow Recovery multi-session files should use parseFlowHRVMultiSession instead
            throw ImportError.invalidFormat("Flow Recovery multi-session format detected. Use batch import for multi-session files.")
        }

        // Validate
        guard !rrIntervals.isEmpty else {
            throw ImportError.noRRData
        }

        let minRequired = 60  // At least 60 beats for meaningful analysis
        guard rrIntervals.count >= minRequired else {
            throw ImportError.insufficientData(found: rrIntervals.count, required: minRequired)
        }

        // Validate RR values are reasonable (200-2000ms = 30-300 bpm)
        let invalidValues = rrIntervals.filter { $0 < 200 || $0 > 2000 }
        if invalidValues.count > rrIntervals.count / 4 {
            throw ImportError.invalidRRValues("Too many values outside normal range (200-2000ms)")
        }

        return ImportResult(
            rrIntervals: rrIntervals,
            sourceFormat: format,
            originalFileName: fileName,
            recordingDate: recordingDate,
            metadata: metadata
        )
    }

    /// Create an HRVSession from import result
    func createSession(from result: ImportResult) -> HRVSession {
        let startDate = result.recordingDate ?? Date()

        // Build RRPoints with cumulative timestamps
        var points: [RRPoint] = []
        var currentTime: Int64 = 0

        for rr in result.rrIntervals {
            points.append(RRPoint(t_ms: currentTime, rr_ms: rr))
            currentTime += Int64(rr)
        }

        let series = RRSeries(
            points: points,
            sessionId: UUID(),
            startDate: startDate
        )

        var session = HRVSession(startDate: startDate)
        session.rrSeries = series
        session.endDate = startDate.addingTimeInterval(Double(currentTime) / 1000.0)
        session.notes = "Imported from \(result.originalFileName)"

        return session
    }

    // MARK: - Format Detection

    private func detectFormat(content: String, extension ext: String) -> ImportFormat {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // JSON detection
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            return .json
        }

        // CSV detection (has commas or semicolons as separators)
        if ext == "csv" || content.contains(",") || content.contains(";") {
            let firstLine = content.components(separatedBy: .newlines).first?.lowercased() ?? ""

            // Check for Elite HRV summary format (both old and new formats)
            // Old format: datetime,rmssd_clean_ms,rmssd_raw_ms,removed_rr_pct,n_rr,...
            // New format: Member,Type,...,HRV,...,Rmssd,...
            if firstLine.contains("rmssd_clean") || firstLine.contains("rmssd_raw") ||
               (firstLine.contains("datetime") && firstLine.contains("rmssd") && firstLine.contains("n_rr")) ||
               (firstLine.contains("member") && firstLine.contains("rmssd") && firstLine.contains("hrv")) {
                return .eliteHRV
            }

            // Check for Kubios markers
            if content.lowercased().contains("kubios") ||
               content.lowercased().contains("rr interval") ||
               content.lowercased().contains("artifact") {
                return .kubios
            }
            return .csv
        }

        // Default to plain text
        return .txt
    }

    /// Check if content is Elite HRV summary format
    func isEliteHRVSummary(_ content: String) -> Bool {
        let firstLine = content.components(separatedBy: .newlines).first?.lowercased() ?? ""
        // Old format: rmssd_clean, rmssd_raw, n_rr columns
        // New format: Member, Type, Rmssd, lnRmssd, HRV, HR columns
        return firstLine.contains("rmssd_clean") || firstLine.contains("rmssd_raw") ||
               (firstLine.contains("datetime") && firstLine.contains("rmssd") && firstLine.contains("n_rr")) ||
               (firstLine.contains("member") && firstLine.contains("rmssd") && firstLine.contains("hrv"))
    }

    /// Check if content is Flow Recovery multi-session RR export format
    /// Format: session_date,timestamp_ms,rr_ms
    func isFlowHRVMultiSession(_ content: String) -> Bool {
        let firstLine = content.components(separatedBy: .newlines).first?.lowercased() ?? ""
        return firstLine.contains("session_date") &&
               firstLine.contains("timestamp_ms") &&
               firstLine.contains("rr_ms")
    }

    // MARK: - JSON Parsing

    private func parseJSON(_ content: String) throws -> ([Int], [String: String], Date?) {
        guard let data = content.data(using: .utf8) else {
            throw ImportError.unreadableFile
        }

        // Try parsing as array of numbers first
        if let array = try? JSONDecoder().decode([Double].self, from: data) {
            let rrValues = array.map { convertToMilliseconds($0) }
            return (rrValues, [:], nil)
        }

        // Try parsing as structured HRV export
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return try parseStructuredJSON(dict)
        }

        // Try parsing as array of dicts with RR field
        if let arrayOfDicts = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var rrValues: [Int] = []
            for item in arrayOfDicts {
                if let rr = item["rr"] as? Double {
                    rrValues.append(convertToMilliseconds(rr))
                } else if let rr = item["RR"] as? Double {
                    rrValues.append(convertToMilliseconds(rr))
                } else if let rr = item["rr_ms"] as? Int {
                    rrValues.append(rr)
                } else if let rr = item["rrInterval"] as? Double {
                    rrValues.append(convertToMilliseconds(rr))
                }
            }
            if !rrValues.isEmpty {
                return (rrValues, [:], nil)
            }
        }

        throw ImportError.invalidFormat("Unable to parse JSON as RR data")
    }

    private func parseStructuredJSON(_ dict: [String: Any]) throws -> ([Int], [String: String], Date?) {
        var rrValues: [Int] = []
        var metadata: [String: String] = [:]
        var recordingDate: Date?

        // Common keys for RR data
        let rrKeys = ["rr", "RR", "rr_intervals", "rrIntervals", "RRIntervals", "ibi", "IBI", "nn", "NN"]

        for key in rrKeys {
            if let values = dict[key] as? [Double] {
                rrValues = values.map { convertToMilliseconds($0) }
                break
            } else if let values = dict[key] as? [Int] {
                rrValues = values
                break
            }
        }

        // Extract metadata
        if let date = dict["date"] as? String ?? dict["timestamp"] as? String ?? dict["recordingDate"] as? String {
            recordingDate = parseDate(date)
        }

        if let device = dict["device"] as? String {
            metadata["device"] = device
        }

        if let notes = dict["notes"] as? String {
            metadata["notes"] = notes
        }

        if rrValues.isEmpty {
            throw ImportError.noRRData
        }

        return (rrValues, metadata, recordingDate)
    }

    // MARK: - CSV Parsing

    private func parseCSV(_ content: String) throws -> ([Int], [String: String], Date?) {
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else {
            throw ImportError.noRRData
        }

        var rrValues: [Int] = []
        let metadata: [String: String] = [:]
        let recordingDate: Date? = nil
        var rrColumnIndex: Int?
        var separator: Character = ","

        // Detect separator
        if lines[0].contains(";") && !lines[0].contains(",") {
            separator = ";"
        }

        // Check if first line is header
        let firstLine = lines[0].lowercased()
        let isHeader = firstLine.contains("rr") ||
                       firstLine.contains("ibi") ||
                       firstLine.contains("interval") ||
                       firstLine.contains("time") ||
                       firstLine.contains("ms")

        var dataStartIndex = 0

        if isHeader {
            dataStartIndex = 1
            let headers = lines[0].split(separator: separator).map { String($0).lowercased().trimmingCharacters(in: .whitespaces) }

            // Find RR column
            for (index, header) in headers.enumerated() {
                if header.contains("rr") || header.contains("ibi") || header == "ms" || header == "interval" {
                    rrColumnIndex = index
                    break
                }
            }
        }

        // Parse data lines
        for i in dataStartIndex..<lines.count {
            let line = lines[i]

            // Skip comment lines
            if line.hasPrefix("#") || line.hasPrefix("//") {
                continue
            }

            let columns = line.split(separator: separator).map { String($0).trimmingCharacters(in: .whitespaces) }

            if let colIndex = rrColumnIndex, colIndex < columns.count {
                // Use detected column
                if let value = Double(columns[colIndex]) {
                    rrValues.append(convertToMilliseconds(value))
                }
            } else if columns.count == 1 {
                // Single column = RR values
                if let value = Double(columns[0]) {
                    rrValues.append(convertToMilliseconds(value))
                }
            } else if columns.count >= 2 {
                // Try second column (common format: timestamp, RR)
                if let value = Double(columns[1]) {
                    let converted = convertToMilliseconds(value)
                    if converted >= 200 && converted <= 2000 {
                        rrValues.append(converted)
                    }
                }
                // Or first column if it looks like RR
                else if let value = Double(columns[0]) {
                    let converted = convertToMilliseconds(value)
                    if converted >= 200 && converted <= 2000 {
                        rrValues.append(converted)
                    }
                }
            }
        }

        return (rrValues, metadata, recordingDate)
    }

    // MARK: - Plain Text Parsing

    private func parsePlainText(_ content: String) throws -> [Int] {
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("//") }

        var rrValues: [Int] = []

        for line in lines {
            // Handle space-separated values on same line
            let values = line.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })

            for valueStr in values {
                if let value = Double(valueStr) {
                    let converted = convertToMilliseconds(value)
                    if converted >= 200 && converted <= 2000 {
                        rrValues.append(converted)
                    }
                }
            }
        }

        return rrValues
    }

    // MARK: - Elite HRV Summary Parsing

    /// Parse Elite HRV summary CSV format
    /// Old format: datetime,rmssd_clean_ms,rmssd_raw_ms,removed_rr_pct,n_rr,rr_min_ms,rr_max_ms,file
    /// New format: Member,Type,Position,Breathing Pattern,Date Time Start,Date Time End,Duration,Tags,Notes,Value 1,Value 2,Value 3,HRV,Morning Readiness,Balance,HRV CV,HR,lnRmssd,Rmssd,Nn50,Pnn50,Sdnn,Low Frequency Power,High Frequency Power,LF/HF Ratio,Total Power
    func parseEliteHRVSummary(_ content: String, fileName: String) throws -> EliteHRVSummaryResult {
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.count >= 2 else {
            throw ImportError.noRRData
        }

        // Parse header to find column indices
        let headerLine = lines[0].lowercased()
        let headers = headerLine.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }

        // Find column indices - support both old and new Elite HRV formats
        var dateIndex: Int?
        var rmssdIndex: Int?
        var artifactPctIndex: Int?
        var beatCountIndex: Int?
        var rrMinIndex: Int?
        var rrMaxIndex: Int?
        var fileNameIndex: Int?
        var durationIndex: Int?
        var hrIndex: Int?
        var typeIndex: Int?

        for (index, header) in headers.enumerated() {
            let h = header.trimmingCharacters(in: .whitespaces)
            // Date columns
            if h.contains("datetime") || h == "date" || h == "date time start" {
                dateIndex = index
            }
            // RMSSD - handle both formats
            else if h == "rmssd" || h.contains("rmssd_clean") {
                rmssdIndex = index
            }
            // Artifact percentage
            else if h.contains("removed") || h.contains("artifact") || h.contains("pct") {
                artifactPctIndex = index
            }
            // Beat count
            else if h.contains("n_rr") || h.contains("beats") || h.contains("count") {
                beatCountIndex = index
            }
            // RR min/max
            else if h.contains("rr_min") || h.contains("min_rr") {
                rrMinIndex = index
            }
            else if h.contains("rr_max") || h.contains("max_rr") {
                rrMaxIndex = index
            }
            // File name
            else if h == "file" || h.contains("filename") {
                fileNameIndex = index
            }
            // Duration
            else if h == "duration" {
                durationIndex = index
            }
            // Heart rate
            else if h == "hr" {
                hrIndex = index
            }
            // Type (used as identifier when file name not available)
            else if h == "type" {
                typeIndex = index
            }
            // Note: sdnn, pnn50, nn50, frequency domain, hrv score, readiness columns
            // are recognized but not currently used - metrics are recomputed from raw data
        }

        guard let rmssdIdx = rmssdIndex else {
            throw ImportError.invalidFormat("Elite HRV format requires RMSSD column (found headers: \(headers.joined(separator: ", ")))")
        }

        var sessions: [EliteHRVSummaryResult.SessionSummary] = []

        // Parse data rows
        for i in 1..<lines.count {
            // Handle quoted CSV values properly
            let columns = parseCSVLine(lines[i])

            guard columns.count > rmssdIdx else { continue }

            // Parse date
            var date = Date()
            if let dateIdx = dateIndex, dateIdx < columns.count {
                if let parsedDate = parseDate(columns[dateIdx]) {
                    date = parsedDate
                }
            }

            // Parse RMSSD
            guard let rmssd = Double(columns[rmssdIdx]), rmssd > 0 else { continue }

            // Calculate beat count from duration and HR if not directly available
            var beatCount = 100 // Default
            if let beatIdx = beatCountIndex, beatIdx < columns.count,
               let beats = Int(columns[beatIdx]) {
                beatCount = beats
            } else if let durIdx = durationIndex, let hrIdx = hrIndex,
                      durIdx < columns.count, hrIdx < columns.count,
                      let duration = Double(columns[durIdx]),
                      let hr = Double(columns[hrIdx]), hr > 0 {
                // Estimate beat count: duration (seconds) * HR (bpm) / 60
                beatCount = Int(duration * hr / 60.0)
            }

            // Calculate RR min/max from HR if not available
            var rrMin = 600.0
            var rrMax = 1000.0
            if let minIdx = rrMinIndex, minIdx < columns.count,
               let min = Double(columns[minIdx]) {
                rrMin = min
            } else if let hrIdx = hrIndex, hrIdx < columns.count,
                      let hr = Double(columns[hrIdx]), hr > 0 {
                // Estimate from HR: meanRR = 60000/HR, estimate min/max ± 15%
                let meanRR = 60000.0 / hr
                rrMin = meanRR * 0.85
                rrMax = meanRR * 1.15
            }

            if let maxIdx = rrMaxIndex, maxIdx < columns.count,
               let max = Double(columns[maxIdx]) {
                rrMax = max
            }

            var artifactPct = 0.0
            if let artIdx = artifactPctIndex, artIdx < columns.count,
               let art = Double(columns[artIdx]) {
                artifactPct = art
            }

            var sessionFileName = ""
            if let fileIdx = fileNameIndex, fileIdx < columns.count {
                sessionFileName = columns[fileIdx]
            } else if let typeIdx = typeIndex, typeIdx < columns.count {
                // Use type as identifier
                sessionFileName = columns[typeIdx]
            }

            let summary = EliteHRVSummaryResult.SessionSummary(
                date: date,
                rmssd: rmssd,
                rmssdRaw: rmssd,  // New format doesn't have separate raw value
                artifactPercent: artifactPct,
                beatCount: beatCount,
                rrMin: rrMin,
                rrMax: rrMax,
                fileName: sessionFileName
            )
            sessions.append(summary)
        }

        guard !sessions.isEmpty else {
            throw ImportError.noRRData
        }

        return EliteHRVSummaryResult(sessions: sessions, originalFileName: fileName)
    }

    /// Parse a CSV line handling quoted values
    private func parseCSVLine(_ line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false

        for char in line {
            if char == "\"" {
                inQuotes.toggle()
            } else if char == "," && !inQuotes {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(char)
            }
        }
        result.append(current.trimmingCharacters(in: .whitespaces))

        return result
    }

    /// Create a fully-analyzed HRV session directly from Elite HRV summary metrics
    /// Uses the pre-computed metrics from Elite HRV instead of re-analyzing
    func createAnalyzedSession(from summary: EliteHRVSummaryResult.SessionSummary, originalFileName: String) -> HRVSession {
        // Calculate derived metrics from Elite HRV data
        let meanRR = (summary.rrMin + summary.rrMax) / 2.0
        let meanHR = 60000.0 / meanRR
        let minHR = 60000.0 / summary.rrMax
        let maxHR = 60000.0 / summary.rrMin

        // Estimate SDNN from RMSSD (typical ratio RMSSD/SDNN ≈ 0.5-0.7 for morning readings)
        // Use the raw vs clean difference to estimate variability
        let estimatedSDNN = summary.rmssd * 1.8  // Conservative estimate

        // Estimate pNN50 from RMSSD using empirical relationship
        // Higher RMSSD generally means higher pNN50
        let estimatedPNN50 = min(50.0, max(0, (summary.rmssd - 10) * 1.5))

        // Create time domain metrics using Elite HRV's actual RMSSD
        let timeDomain = TimeDomainMetrics(
            meanRR: meanRR,
            sdnn: estimatedSDNN,
            rmssd: summary.rmssd,  // Use actual Elite HRV RMSSD!
            pnn50: estimatedPNN50,
            sdsd: summary.rmssd,  // SDSD ≈ RMSSD for short recordings
            meanHR: meanHR,
            sdHR: estimatedSDNN * meanHR / meanRR / 2,  // Approximate
            minHR: minHR,
            maxHR: maxHR,
            triangularIndex: nil  // Not available from Elite HRV
        )

        // Estimate nonlinear metrics
        // SD1 ≈ RMSSD / √2, SD2 from SDNN
        let sd1 = summary.rmssd / sqrt(2.0)
        let sd2 = sqrt(2.0 * estimatedSDNN * estimatedSDNN - sd1 * sd1)
        let nonlinear = NonlinearMetrics(
            sd1: sd1,
            sd2: max(sd1, sd2),  // SD2 should be >= SD1
            sd1Sd2Ratio: sd1 / max(sd1, sd2),
            sampleEntropy: nil,
            approxEntropy: nil,
            dfaAlpha1: nil,  // Would need raw RR data
            dfaAlpha2: nil,
            dfaAlpha1R2: nil
        )

        // Estimate ANS metrics
        // Stress Index from RMSSD (inverse relationship)
        let stressIndex = 1000.0 / (summary.rmssd + 10)  // Higher RMSSD = lower stress

        // Readiness score based on RMSSD relative to typical values
        // RMSSD < 20 = poor, 20-40 = moderate, 40-60 = good, 60+ = excellent
        let readinessScore: Double
        if summary.rmssd >= 60 {
            readinessScore = 8.0 + min(2.0, (summary.rmssd - 60) / 20.0)
        } else if summary.rmssd >= 40 {
            readinessScore = 6.0 + (summary.rmssd - 40) / 10.0
        } else if summary.rmssd >= 20 {
            readinessScore = 4.0 + (summary.rmssd - 20) / 10.0
        } else {
            readinessScore = max(1.0, summary.rmssd / 5.0)
        }

        let ansMetrics = ANSMetrics(
            stressIndex: stressIndex,
            pnsIndex: nil,  // Would need frequency domain
            snsIndex: nil,
            readinessScore: readinessScore,
            respirationRate: nil,
            nocturnalHRDip: nil,
            daytimeRestingHR: nil,
            nocturnalMedianHR: nil
        )

        // Create the analysis result with Elite HRV's metrics
        let analysisResult = HRVAnalysisResult(
            windowStart: 0,
            windowEnd: summary.beatCount,
            timeDomain: timeDomain,
            frequencyDomain: nil,  // Elite HRV summary doesn't include frequency data
            nonlinear: nonlinear,
            ansMetrics: ansMetrics,
            artifactPercentage: summary.artifactPercent,
            cleanBeatCount: Int(Double(summary.beatCount) * (1.0 - summary.artifactPercent / 100.0)),
            analysisDate: Date()
        )

        // Create minimal RR series for storage (just metadata, not fake data)
        let durationMs = Int64(Double(summary.beatCount) * meanRR)
        let series = RRSeries(
            points: [RRPoint(t_ms: 0, rr_ms: Int(meanRR))],  // Minimal placeholder
            sessionId: UUID(),
            startDate: summary.date
        )

        // Build the complete session
        let session = HRVSession(
            id: UUID(),
            startDate: summary.date,
            endDate: summary.date.addingTimeInterval(Double(durationMs) / 1000.0),
            state: .complete,
            rrSeries: series,
            analysisResult: analysisResult,
            artifactFlags: [ArtifactFlags.clean],
            recoveryScore: readinessScore,
            tags: [],
            notes: "Imported from Elite HRV: \(originalFileName)\nOriginal RMSSD: \(String(format: "%.1f", summary.rmssd)) ms\nBeats: \(summary.beatCount)",
            importedMetrics: HRVSession.ImportedMetrics(
                rmssd: summary.rmssd,
                rmssdRaw: summary.rmssdRaw,
                artifactPercent: summary.artifactPercent,
                source: "Elite HRV"
            )
        )

        return session
    }

    /// Import Elite HRV summary file and return multiple sessions
    func importEliteHRVFile(at url: URL) async throws -> EliteHRVSummaryResult {
        guard url.startAccessingSecurityScopedResource() else {
            throw ImportError.fileNotFound
        }
        defer { url.stopAccessingSecurityScopedResource() }

        guard let data = try? Data(contentsOf: url) else {
            throw ImportError.unreadableFile
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw ImportError.unreadableFile
        }

        let fileName = url.lastPathComponent
        return try parseEliteHRVSummary(content, fileName: fileName)
    }

    // MARK: - Flow Recovery Multi-Session Parsing

    /// Parse Flow Recovery multi-session RR export
    /// Format: session_date,timestamp_ms,rr_ms
    /// Each session_date value represents a different recording session
    func parseFlowHRVMultiSession(_ content: String, fileName: String) throws -> FlowHRVMultiSessionResult {
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.count >= 2 else {
            throw ImportError.noRRData
        }

        // Parse header to find column indices
        let headerLine = lines[0].lowercased()
        let headers = headerLine.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }

        var sessionDateIndex: Int?
        var timestampIndex: Int?
        var rrIndex: Int?

        for (index, header) in headers.enumerated() {
            if header.contains("session_date") {
                sessionDateIndex = index
            } else if header.contains("timestamp_ms") {
                timestampIndex = index
            } else if header.contains("rr_ms") {
                rrIndex = index
            }
        }

        guard let sessIdx = sessionDateIndex,
              let rrIdx = rrIndex else {
            throw ImportError.invalidFormat("Flow Recovery format requires session_date and rr_ms columns")
        }

        // Group RR data by session_date
        var sessionGroups: [String: [(timestamp: Int64, rr: Int)]] = [:]

        for i in 1..<lines.count {
            let columns = lines[i].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }

            guard columns.count > max(sessIdx, rrIdx) else { continue }

            let sessionDateStr = columns[sessIdx]
            guard let rrValue = Int(columns[rrIdx]), rrValue >= 200, rrValue <= 2000 else { continue }

            let timestamp: Int64
            if let tsIdx = timestampIndex, tsIdx < columns.count, let ts = Int64(columns[tsIdx]) {
                timestamp = ts
            } else {
                // Calculate from previous RR values if no timestamp
                if let lastPoint = sessionGroups[sessionDateStr]?.last {
                    timestamp = lastPoint.timestamp + Int64(lastPoint.rr)
                } else {
                    timestamp = 0
                }
            }

            if sessionGroups[sessionDateStr] == nil {
                sessionGroups[sessionDateStr] = []
            }
            sessionGroups[sessionDateStr]?.append((timestamp: timestamp, rr: rrValue))
        }

        // Convert to SessionRRData objects
        var sessions: [FlowHRVMultiSessionResult.SessionRRData] = []

        // Date formatter for session_date format (e.g., "2026-01-25_0443")
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HHmm"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        debugLog("[RRDataImporter] Found \(sessionGroups.count) unique session_date values:")
        for (sessionDateStr, points) in sessionGroups {
            debugLog("[RRDataImporter]   '\(sessionDateStr)' -> \(points.count) RR intervals")
        }

        for (sessionDateStr, points) in sessionGroups {
            guard points.count >= 60 else {
                debugLog("[RRDataImporter] Skipping '\(sessionDateStr)' - only \(points.count) beats (need 60)")
                continue
            }

            let parsedDate = dateFormatter.date(from: sessionDateStr)
            let date = parsedDate ?? Date()
            if parsedDate == nil {
                debugLog("[RRDataImporter] WARNING: Failed to parse date '\(sessionDateStr)', using current time")
            } else {
                debugLog("[RRDataImporter] Parsed '\(sessionDateStr)' -> \(date)")
            }

            // Sort by timestamp to ensure correct order
            let sortedPoints = points.sorted { $0.timestamp < $1.timestamp }

            let sessionData = FlowHRVMultiSessionResult.SessionRRData(
                sessionDate: sessionDateStr,
                date: date,
                rrIntervals: sortedPoints.map { $0.rr },
                timestamps: sortedPoints.map { $0.timestamp }
            )
            sessions.append(sessionData)
        }

        // Sort sessions by date (oldest first)
        sessions.sort { $0.date < $1.date }

        guard !sessions.isEmpty else {
            throw ImportError.noRRData
        }

        return FlowHRVMultiSessionResult(sessions: sessions, originalFileName: fileName)
    }

    /// Create an HRVSession from Flow Recovery RR data (requires full analysis)
    func createSessionFromFlowHRVData(_ sessionData: FlowHRVMultiSessionResult.SessionRRData, originalFileName: String) -> HRVSession {
        // Build RRPoints with original timestamps
        var points: [RRPoint] = []
        for (index, rr) in sessionData.rrIntervals.enumerated() {
            let timestamp = index < sessionData.timestamps.count ? sessionData.timestamps[index] : Int64(index) * Int64(rr)
            points.append(RRPoint(t_ms: timestamp, rr_ms: rr))
        }

        let series = RRSeries(
            points: points,
            sessionId: UUID(),
            startDate: sessionData.date
        )

        let durationMs = sessionData.rrIntervals.reduce(0, +)
        var session = HRVSession(startDate: sessionData.date)
        session.rrSeries = series
        session.endDate = sessionData.date.addingTimeInterval(Double(durationMs) / 1000.0)
        session.notes = "Imported from Flow Recovery: \(originalFileName)\nOriginal session: \(sessionData.sessionDate)"

        return session
    }

    // MARK: - Helpers

    /// Convert RR value to milliseconds
    /// Handles values in seconds (0.5-2.0) or already in ms (200-2000)
    private func convertToMilliseconds(_ value: Double) -> Int {
        if value < 10 {
            // Likely in seconds, convert to ms
            return Int(value * 1000)
        } else {
            // Already in milliseconds
            return Int(value)
        }
    }

    /// Parse various date formats
    private func parseDate(_ string: String) -> Date? {
        let formatters: [DateFormatter] = {
            let formats = [
                "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
                "yyyy-MM-dd'T'HH:mm:ssZ",
                "yyyy-MM-dd HH:mm:ss",
                "yyyy-MM-dd",
                "MM/dd/yyyy HH:mm:ss",
                "MM/dd/yyyy"
            ]
            return formats.map { format in
                let formatter = DateFormatter()
                formatter.dateFormat = format
                formatter.locale = Locale(identifier: "en_US_POSIX")
                return formatter
            }
        }()

        for formatter in formatters {
            if let date = formatter.date(from: string) {
                return date
            }
        }

        // Try ISO8601
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: string)
    }
}
